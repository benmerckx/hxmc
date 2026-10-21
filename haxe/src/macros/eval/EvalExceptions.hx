/*
	The Haxe Compiler
	Copyright (C) 2005-2019  Haxe Foundation

	This program is free software; you can redistribute it and/or
	modify it under the terms of the GNU General Public License
	as published by the Free Software Foundation; either version 2
	of the License, or (at your option) any later version.

	This program is distributed in the hope that it will be useful,
	but WITHOUT ANY WARRANTY; without even the implied warranty of
	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
	GNU General Public License for more details.

	You should have received a copy of the GNU General Public License
	along with this program; if not, write to the Free Software
	Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
 */

package macros.eval;

import core.Error;
import core.Globals;
import core.Globals.Pos;
import core.ds.NotFound;
import haxe.ds.Option;
import macros.eval.EvalValue;
import macros.eval.EvalContext;
import macros.eval.EvalHash;

// port: deviations:
// - `catch_exceptions ctx ?final f p` is `catchExceptions(ctx, f, p, ?finalFn)`
//   and returns a `haxe.ds.Option` (upstream `option`).
// - OCaml's `Stack_overflow` is recognised as a host exception whose string
//   form is "Stack overflow" (what HashLink and Eval throw).
class Break extends haxe.Exception {
	public static final instance = new Break();

	public function new() super("Break");

	public static inline function raise():Break return core.ds.FastThrow.of(instance);
}

class Continue extends haxe.Exception {
	public static final instance = new Continue();

	public function new() super("Continue");

	public static inline function raise():Continue return core.ds.FastThrow.of(instance);
}

class Return extends haxe.Exception {
	public final value:Value;

	public function new(value:Value) {
		super("Return");
		this.value = value;
	}
}

class EvalExceptions {
	public static function sValueKind(v:Value):String {
		return switch v {
			case VNull: "VNull";
			case VTrue: "VTrue";
			case VFalse: "VFalse";
			case VInt32(_): "VInt32";
			case VInt64(_): "VInt64";
			case VUInt64(_): "VUInt64";
			case VFloat(_): "VFloat";
			case VEnumValue(_): "VEnumValue";
			case VObject(_): "VObject";
			case VString(_): "VString";
			case VArray(_): "VArray";
			case VVector(_): "VVector";
			case VInstance(_): "VInstance";
			case VPrototype(_): "VPrototype";
			case VFunction(_): "VFunction";
			case VFieldClosure(_): "VFieldClosure";
			case VLazy(_): "VLazy";
			case VNativeString(_): "VNativeString";
			case VHandle(_): "VHandle";
		}
	}

	public static function unexpectedValue(v:Value, s:String):Dynamic {
		var str = switch v {
			case VNull: "Null Access";
			case _: 'Unexpected value ${sValueKind(v)}(${EvalPrinting.valueString(v)}), expected $s';
		}
		return EvalContext.excString(str);
	}

	public static function invalidCallArgNumber(i:Int, i2:Int):Dynamic {
		return EvalContext.excString('Invalid number of call arguments: Expected $i, got $i2');
	}

	public static function formatPos(p:Pos):String {
		function errorPrinter(file:String, line:Int):String return '$file:$line:';
		return syntax.Lexer.getErrorPos(errorPrinter, p);
	}

	public static function uncaughtExceptionString(v:Value, p:Pos, extra:String):String {
		return '${formatPos(p)} : Uncaught exception ${EvalPrinting.valueString(v)}$extra';
	}

	static inline function posEq(p1:Pos, p2:Pos):Bool return p1.pfile == p2.pfile && p1.pmin == p2.pmin && p1.pmax == p2.pmax;

	static inline function isNullPos(p:Pos):Bool return posEq(p, Globals.nullPos);

	public static function getExcErrorStack(ctx:Context, stack:Array<Env>):Array<Pos> {
		var pl:Array<Pos> = stack.map(env -> new Pos(EvalHash.revHash(env.envInfo.pfile), env.envLeavePmin, env.envLeavePmax));
		return pl.filter(p -> !isNullPos(p));
	}

	public static function getExcErrorMessage(ctx:Context, v:Value, stack:Array<Env>, p:Pos):String {
		var pl = getExcErrorStack(ctx, stack);
		return switch pl {
			case []:
				uncaughtExceptionString(v, p, "");
			case _:
				var sstack = pl.map(p -> '${formatPos(p)} : Called from here').join("\n");
				'${if (isNullPos(p)) "" else formatPos(p) + " : "}Uncaught exception ${EvalPrinting.valueString(v)}\n$sstack';
		}
	}

	// port: upstream's `ctx` argument is the eval (thread) state.
	public static function buildExceptionStack(ctx:Eval, env:Env):Void {
		var eval = env.envEval;
		function loop(acc:Array<Env>, env2:Env):Array<Env> {
			while (true) {
				acc.push(env2);
				if (env == env2) return acc;
				switch env2.envParent {
					case null:
						return Globals.die("", "EvalExceptions.buildExceptionStack");
					case env3:
						env2 = env3;
				}
			}
		}
		var d = switch eval.env {
			case null: [];
			case env: loop([], env);
		}
		ctx.exceptionStack = d.map(env -> {
			pos: new Pos(EvalHash.revHash(env.envInfo.pfile), env.envLeavePmin, env.envLeavePmax),
			kind: env.envInfo.kind
		});
	}

	static function isStackOverflow(e:Dynamic):Bool {
		if (Std.isOfType(e, String)) return (e : String) == "Stack overflow";
		if (Std.isOfType(e, haxe.Exception)) {
			var e:haxe.Exception = e;
			return e.message == "Stack overflow" && !Std.isOfType(e, RunTimeException);
		}
		return false;
	}

	public static function handleStackOverflow<T>(eval:Eval, f:Void->T):T {
		try
			return f()
		catch (e:Dynamic) {
			if (isStackOverflow(e)) return EvalContext.excString("Stack overflow");
			throw e;
		}
	}

	public static function catchExceptions<T>(ctx:Context, f:Void->T, p:Pos, ?finalFn:Void->Void):Option<T> {
		var finalFn:Void->Void = finalFn == null ? () -> {} : finalFn;
		var resetCtx = if (GlobalState.initialized) {
			var prev = GlobalState.getCtxRef;
			() -> GlobalState.getCtxRef = prev;
		} else {
			() -> {};
		}
		EvalContext.select(ctx);
		var eval = EvalContext.getEval(ctx);
		var env = eval.env;
		var r:Option<T> = try {
			var v = handleStackOverflow(eval, f);
			resetCtx();
			finalFn();
			Some(v);
		} catch (e:RunTimeException) {
			var v = e.value, evalStack = e.envs, p2 = e.pos;
			eval.caughtException = VNull;
			// port: restored before the stack is built: frames are not popped during unwinding
			// (EvalEmitter.createFunction), upstream's finally popped them.
			eval.env = env;
			if (env != null) buildExceptionStack(eval, env);

			// Careful: We have to get the message before resetting the context because toString() might access it.
			inline function getStack(ctx:Context):Array<Pos> {
				var stack = switch evalStack {
					case []: [];
					case l if (isNullPos(p2)): l; // If the exception position is null_pos, we're "probably" in a built-in function.
					case l: l.slice(1); // Otherwise, ignore topmost frame position.
				}
				inline function def():Array<Pos> return getExcErrorStack(ctx, stack);
				return switch v {
					case VInstance(vi) if (EvalContext.is(v, EvalHash.key_haxe_Exception)):
						try {
							var vf = EvalField.instanceField(vi, EvalHash.key_custom_stack);
							switch vf {
								case VVector(vv):
									[for (i in 0...vv.length) switch vv[i] {
										case VEnumValue({enpos: p}) if (p != null): p;
										case _: (Globals.die("", "EvalExceptions.catchExceptions") : Pos);
									}];
								case _:
									def();
							}
						} catch (_:NotFound) {
							def();
						}
					case _:
						def();
				}
			}

			if (EvalContext.is(v, EvalHash.key_haxe_macro_Error)) {
				var v1 = EvalField.field(v, EvalHash.key_exception_message);
				var v2 = EvalField.field(v, EvalHash.key_pos);
				var v3 = EvalField.field(v, EvalHash.key_child_errors);
				var stack:Array<{msg:ErrorMsg, pos:Pos}> = switch v3 {
					case VArray(sub):
						EvalArray.toList(sub).map(v -> {
							if (EvalContext.is(v, EvalHash.key_haxe_macro_Error)) {
								var v1 = EvalField.field(v, EvalHash.key_exception_message);
								var v2 = switch EvalField.field(v, EvalHash.key_pos) {
									case VInstance({ikind: IPos(p)}): p;
									case _: Globals.nullPos;
								}
								{msg: Custom(EvalPrinting.valueString(v1)), pos: v2};
							} else
								Error.raiseTypingError('Unexpected value where haxe.macro.Error was expected: ${EvalPrinting.sValue(0, v).sstring}',
									Globals.nullPos);
						});
					case _:
						var stack = getStack(ctx).copy();
						stack.reverse();
						stack.map(p -> {msg: Custom("Called from here"), pos: p});
				}
				resetCtx();
				finalFn();
				switch v1 {
					case VString(s):
						var p:Pos = switch v2 {
							case VInstance({ikind: IPos(p)}): p;
							case VObject(o):
								try {
									var fields = EvalContext.objectFields(o);
									function assoc(k:Int):Value {
										for (f in fields) if (f.name == k) return f.value;
										throw NotFound.raise();
									}
									var min = switch assoc(EvalHash.key_min) {
										case VInt32(i): i;
										case _: throw NotFound.raise();
									}
									var max = switch assoc(EvalHash.key_max) {
										case VInt32(i): i;
										case _: throw NotFound.raise();
									}
									var file = switch assoc(EvalHash.key_file) {
										case VString(s): s.sstring;
										case _: throw NotFound.raise();
									}
									new Pos(file, min, max);
								} catch (_:NotFound) {
									Globals.nullPos;
								}
							case _: Globals.nullPos;
						}
						switch stack {
							case []: Error.raiseMsg(s.sstring, p);
							case _: Error.raiseError(Error.makeError(Custom(s.sstring), p, stack.map(e -> Error.makeError(e.msg, e.pos))));
						}
					case v:
						Error.raiseTypingError('Invalid exception value where string was expected: ${EvalPrinting.sValue(0, v).sstring}',
							Globals.nullPos);
				}
			} else {
				var stack = getStack(ctx);
				resetCtx();
				finalFn();
				var p:Pos = p;
				if (stack.length > 0 && isNullPos(p2)) {
					// If the exception position is null_pos we're probably in a built-in function. Let's use the topmost stack
					// as error position.
					p = stack[0];
					stack = stack.slice(1);
				} else {
					p = if (isNullPos(p2)) p else p2;
				}
				// port: List.fold_left consing (position, count): built in order here, then reversed
				var counted:Array<{pos:Pos, n:Int}> = [];
				for (p in stack) {
					if (counted.length > 0 && posEq(counted[counted.length - 1].pos, p))
						counted[counted.length - 1].n++
					else
						counted.push({pos: p, n: 1});
				}
				counted.reverse();
				Error.raiseError(Error.makeError(Custom("Uncaught exception " + EvalPrinting.valueString(v)), p, counted.map(e -> {
					var suf = if (e.n > 1) ' (${e.n} times)' else "";
					Error.makeError(Custom("Called from here" + suf), e.pos);
				})));
			}
		} catch (e:macros.MacroApi.Abort) {
			eval.env = env;
			finalFn();
			None;
		} catch (e:Dynamic) {
			eval.env = env;
			resetCtx();
			finalFn();
			throw e;
		}
		return r;
	}
}
