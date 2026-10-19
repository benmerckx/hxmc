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

import core.Globals;
import core.Globals.Pos;
import core.Ast;
import core.TType;
import core.TFunctions;
import core.ds.Failure;
import core.ds.NotFound;
import core.ds.GlobalsIntMap;
import haxe.io.Bytes;
import macros.MacroApi.CompilerApi;
import macros.eval.EvalValue;
import macros.eval.EvalContext;
import macros.eval.EvalHash;

using macros.eval.EvalValue.EvalValueTools;

// port: also covers eval.ml, which only includes modules.
//
// Deviations:
// - `Luv.Error.set_on_unhandled_exception` sets `EvalLuv.exceptionHandler`
//   (libuv works on the hxmc host only, see `EvalLuv`).
// - `valueSignature` returns the MD5 digest as a lowercase hex string
//   (the port keeps digests hexadecimal; upstream callers apply
//   `Digest.to_hex` to the raw digest).
// - The thread info is created after the context record, because the
//   thread id counter (`next_thread_id`) is a field of the context here.
class EvalMain {
	// port: OCaml int_of_string
	static function intOfString(s:String):Int {
		if (!~/^[-+]?(0[xX][0-9a-fA-F_]+|[0-9][0-9_]*)$/.match(s)) throw new Failure("int_of_string");
		var i = Std.parseInt(StringTools.replace(s, "_", ""));
		if (i == null) throw new Failure("int_of_string");
		return i;
	}

	// Create

	static function createImpl(com:context.Common.CommonContext, api:CompilerApi, isMacro:Bool, args:Array<String>):Context {
		GlobalState.sid++;
		var builtins = switch GlobalState.stdlib {
			case null:
				var builtins = new Builtins(GlobalsIntMap.empty(), GlobalsIntMap.empty(), new Map(), new Map());
				EvalStdLib.initStandardLibrary(builtins);
				GlobalState.stdlib = builtins;
				builtins;
			case builtins:
				builtins;
		}
		var debug = switch GlobalState.debug {
			case null:
				var supportDebugger = context.Common.defined(com, core.Define.EvalDebugger);
				var socket:Null<DebugSocket> = try {
					if (!supportDebugger) throw new EvalDebugMisc.Exit();
					function fail<T>(msg:String):T {
						Sys.println(msg);
						throw new EvalDebugMisc.Exit();
					}
					var s = context.Common.definedValue(com, core.Define.EvalDebugger);
					var i = s.indexOf(":");
					var host = if (i < 0) fail("Invalid host format, expected host:port") else s.substr(0, i);
					var port = s.substr(i + 1);
					var port = try intOfString(port) catch (_:Dynamic) fail("Invalid port, expected int");
					try {
						var socket = core.Socket.create(host, port);
						new DebugSocket(socket, EvalDebugSocket.makeConnection(socket));
					} catch (exc:EvalDebugMisc.Exit) {
						throw exc;
					} catch (exc:Dynamic) {
						fail(Std.string(exc));
					}
				} catch (_:EvalDebugMisc.Exit) {
					null;
				}
				var debug2 = new Debug(EvalDebugMisc.newIntHashtbl(), new core.ds.OcamlHashtbl<{type:Int, field:Int}, FunctionBreakpoint>((k:{type:Int, field:Int}) -> core.ds.OcamlHash.hash(core.ds.OcamlHash.OcamlValue.OBlock(0, [core.ds.OcamlHash.OcamlValue.OInt(k.type), core.ds.OcamlHash.OcamlValue.OInt(k.field)])),
					(a:{type:Int, field:Int}, b:{type:Int, field:Int}) -> a.type == b.type && a.field == b.field, 0), supportDebugger, socket, CatchUncaught, new EvalDebugContext());
				GlobalState.debug = debug2;
				debug2;
			case debug:
				debug;
		}
		var detailTimes = context.Common.defined(com, core.Define.EvalTimes);
		var fakeProtoCache:Map<Int, Vprototype> = new Map();
		var stringPrototype = EvalEncode.fakeProto(fakeProtoCache, EvalHash.key_String);
		var arrayPrototype = EvalEncode.fakeProto(fakeProtoCache, EvalHash.key_Array);
		var vectorPrototype = EvalEncode.fakeProto(fakeProtoCache, EvalHash.key_eval_Vector);
		var toplevel = EvalValueTools.vobject(new Vobject([], OProto(EvalEncode.fakeProto(fakeProtoCache, EvalHash.key_eval_toplevel))));
		var maxStackDepth = intOfString(context.Common.definedValueSafe(com, core.Define.EvalCallStackDepth, "1000"));
		var maxPrintDepth = intOfString(context.Common.definedValueSafe(com, core.Define.EvalPrintDepth, "5"));
		var printIndentation = switch context.Common.definedValueSafe(com, core.Define.EvalPrettyPrint) {
			case "": null;
			case "1": "  ";
			case indent: indent;
		}
		var ctx = new Context(GlobalState.sid, isMacro, detailTimes, builtins, debug, api, com.timerCtx, arrayPrototype, stringPrototype,
			vectorPrototype, com.partScope.fileKeys, EvalPrototype.getObjectPrototype, toplevel, maxStackDepth, maxPrintDepth,
			printIndentation);
		ctx.args = args;
		for (k => v in fakeProtoCache)
			ctx.fakeProtoCache.set(k, v);
		var thread = EvalThread.createThreadInfo(ctx, Thread(sys.thread.Thread.current(), new sys.thread.Lock()));
		var eval = EvalThread.createEval(thread);
		ctx.evals.add(0, eval);
		EvalContext.setEval(ctx, eval);
		if (debug.supportDebugger && !GlobalState.debuggerInitialized) {
			/* Let's wait till the debugger says we're good to continue. This allows it to finish configuration.
				Note that configuration is shared between macro and interpreter contexts, which is why the check
				is governed by a global variable. */
			GlobalState.debuggerInitialized = true;
			/* There's select_ctx in the json-rpc handling, so let's select this one. It's fine because it's the
				first context anyway. */
			EvalContext.select(ctx);
			eval.debugChannel.receive();
		}
		// If no user-defined exception handler is set then follow libuv behavior.
		// Which is printing an error to stderr and exiting with code 2.
		// Use get_ctx() to access the current context dynamically instead of capturing
		// `com` directly, so the compilation context can be garbage collected between requests.
		EvalLuv.exceptionHandler = ex -> {
			if (Std.isOfType(ex, macros.eval.EvalTypes.SysExit)) {
				throw ex;
			} else {
				var msg = if (Std.isOfType(ex, core.Error.TypingError)) {
					var messages = [];
					core.Error.recurseError((depth, err) -> {
						messages.unshift(core.Message.makeMessage(isMacro, core.Error.errorMsg(err.errMessage), err.errPos, depth,
							MKError));
					}, (ex : core.Error.TypingError).error);
					compiler.MessageReporting.formatMessages(EvalContext.getCtx().curapi.getCom().defines, messages);
				} else Std.string(ex);
				Sys.stderr().writeString(msg + "\n");
				Sys.exit(2);
			}
		};
		return ctx;
	}

	public static function create(com:context.Common.CommonContext, api:CompilerApi, isMacro:Bool, args:Array<String>):Context {
		return core.Timer.time(com.timerCtx, [(if (isMacro) "macro" else "interp"), "create"],
			(args:Array<String>) -> createImpl(com, api, isMacro, args), args);
	}

	// API for macroContext.ml

	public static function callPath(ctx:Context, path:Array<String>, f:String, vl:Array<Value>, api:CompilerApi):haxe.ds.Option<Value> {
		if (ctx.hadError)
			return None;
		else {
			var old = ctx.curapi;
			ctx.curapi = api;
			var path:GlobalTypePath = switch path.length {
				case 0: Globals.die("", "evalMain.ml call_path");
				case n: new GlobalTypePath(path.slice(0, n - 1), path[n - 1]);
			}
			return EvalExceptions.catchExceptions(ctx, () -> {
				var vtype = EvalContext.getStaticPrototypeAsValue(ctx, EvalHash.pathHash(path), api.pos);
				var vfield = EvalField.field(vtype, EvalHash.hash(f));
				var p = api.pos;
				var info = EvalContext.createEnvInfo(true, p.pfile, ctx.fileKeys.get(p.pfile),
					EKMacro(EvalHash.pathHash(path), EvalHash.hash(f)), EvalDebugMisc.newIntHashtbl(), 0, 0);
				var env = EvalContext.pushEnvironment(ctx, info);
				env.envLeavePmin = p.pmin;
				env.envLeavePmax = p.pmax;
				var v = EvalPrinting.callValueOn(vtype, vfield, vl);
				EvalContext.popEnvironment(ctx, env);
				return v;
			}, api.pos, () -> ctx.curapi = old);
		}
	}

	// port: Unsigned.UInt64.to_string
	static function uint64ToString(u:haxe.Int64):String {
		if (u.high >= 0) return haxe.Int64.toStr(u);
		var q = haxe.Int64.div(haxe.Int64.ushr(u, 1), 5);
		var r = haxe.Int64.sub(u, haxe.Int64.mul(q, 10));
		return haxe.Int64.toStr(q) + haxe.Int64.toStr(r);
	}

	static final base64Chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789%:";

	public static function valueSignature(v:Value):String {
		var buf = new haxe.io.BytesBuffer();
		inline function add(s:String) buf.addString(s);
		inline function addc(c:String) buf.addString(c);
		var scache:Map<String, Int> = new Map();
		var scacheLength = 0;
		inline function adds(s:String) {
			var i = scache.get(s);
			if (i != null) {
				addc('R');
				add(Std.string(i));
			} else {
				scache.set(s, scacheLength++);
				addc('y');
				// port: EvalStdLib.StdStringTools.url_encode
				var s = core.StringHelper.urlEncodeString(s);
				add(Std.string(s.length));
				addc(':');
				add(s);
			}
		}
		var cache = EvalValueTools.createValueHashtbl();
		var cacheLength = 0;
		inline function cacheValue(v:Value, f:Void->Void) {
			var i = cache.findOpt(v);
			if (i != null) {
				addc('r');
				add(Std.string(i));
			} else {
				var i = cacheLength;
				cache.add(v, i);
				cacheLength++;
				f();
			}
		}
		var customCount = 0;
		// Custom format: enumerate custom entities as name_char0, name_char1 etc.
		// port: upstream caches the value passed to value_signature here, not the current one
		inline function customName(nameChar:String) {
			cacheValue(v, () -> {
				addc('F');
				add(Std.string(customCount));
				customCount++;
			});
		}
		var loopFields:Array<{name:Int, value:Value}>->Void = null;
		function loop(v:Value):Void {
			switch v {
				case VNull:
					addc('n');
				case VTrue:
					addc('t');
				case VFalse:
					addc('f');
				case VInt32(0):
					addc('z');
				case VInt32(i):
					addc('i');
					add(Std.string(i));
				case VInt64(i):
					add("i64");
					add(haxe.Int64.toStr(i));
				case VUInt64(u):
					add("u64");
					add(uint64ToString(u));
				case VFloat(f):
					if (f == Math.NEGATIVE_INFINITY) addc('m')
					else if (f == Math.POSITIVE_INFINITY) addc('p')
					else if (f != f) addc('k')
					else {
						addc('d');
						add(core.Numeric.validFloatLexeme(core.ds.OcamlPrintf.formatG(12, f)));
					}
				case VEnumValue(ve):
					cacheValue(v, () -> {
						addc('j');
						adds(EvalHash.revHash(ve.epath));
						addc(':');
						add(Std.string(ve.eindex));
						addc(':');
						add(Std.string(ve.eargs.length));
						for (a in ve.eargs)
							loop(a);
					});
				case VObject(o):
					cacheValue(v, () -> {
						addc('o');
						var fields = EvalContext.objectFields(o);
						loopFields(fields);
						addc('g');
					});
				case VInstance({ikind: IDate(f)}):
					cacheValue(v, () -> {
						addc('v');
						add(EvalPrinting.sDate(f).sstring);
					});
				case VInstance({ikind: IStringMap(map)}):
					cacheValue(v, () -> {
						addc('b');
						map.iter((s, e) -> {
							adds(s);
							loop(e.value);
						});
						addc('h');
					});
				case VInstance({ikind: IIntMap(map)}):
					cacheValue(v, () -> {
						addc('q');
						map.iter((i, value) -> {
							addc(':');
							add(Std.string(i));
							loop(value);
						});
						addc('h');
					});
				case VInstance({ikind: IInt64Map(map)}):
					cacheValue(v, () -> {
						addc('Q');
						map.iter((i, value) -> {
							addc(':');
							add(haxe.Int64.toStr(i));
							loop(value);
						});
						addc('h');
					});
				case VInstance({ikind: IObjectMap(map)}):
					cacheValue(v, () -> {
						addc('M');
						map.iter((key, value) -> {
							loop(key);
							loop(value);
						});
						addc('h');
					});
				case VInstance({ikind: IBytes(b)}):
					cacheValue(v, () -> {
						addc('s');
						var s = new haxe.crypto.BaseCode(Bytes.ofString(base64Chars)).encodeBytes(b).toString();
						add(Std.string(s.length));
						addc(':');
						add(s);
					});
				case VInstance(i):
					cacheValue(v, () -> {
						addc('c');
						adds(EvalHash.revHash(i.iproto.ppath));
						var fields = EvalContext.instanceFields(i);
						loopFields(fields);
						addc('g');
					});
				case VString(s):
					adds(s.sstring);
				case VNativeString(s):
					buf.add(s);
				case VArray({avalues: a}) | VVector(a):
					cacheValue(v, () -> {
						addc('a');
						inline function nulls(nullCount:Int) {
							if (nullCount > 0) {
								addc('u');
								add(Std.string(nullCount));
							}
						}
						var nullCount = 0;
						for (v in a) {
							switch v {
								case VNull:
									nullCount++;
								case _:
									nulls(nullCount);
									loop(v);
									nullCount = 0;
							}
						}
						nulls(nullCount);
						addc('h');
					});
				case VPrototype({pkind: PClass(_), ppath: path}):
					addc('A');
					adds(EvalHash.revHash(path));
				case VPrototype({pkind: PEnum(_), ppath: path}):
					addc('B');
					adds(EvalHash.revHash(path));
				case VPrototype(_):
					Globals.die("", "evalMain.ml value_signature");
				case VFunction(_) | VFieldClosure(_):
					customName('F');
				case VHandle(_):
					customName('H');
				case VLazy(f):
					loop(f.force());
			}
		}
		loopFields = fields -> {
			for (f in fields) {
				adds(EvalHash.revHash(f.name));
				loop(f.value);
			}
		};
		loop(v);
		return haxe.crypto.Md5.make(buf.getBytes()).toHex();
	}

	public static function prepareCallback(v:Value, n:Int):Array<Value>->Value return EvalMisc.prepareCallback(v, n);

	public static function init(ctx:Context):Void {}

	public static function setup(getApi:(Void->context.Common.CommonContext)->(Void->CompilerApi)->Array<{name:String, value:Value}>):Void {
		var api = getApi(() -> EvalContext.getCtx().curapi.getCom(), () -> EvalContext.getCtx().curapi);
		for (e in api)
			GlobalState.macroLib.set(e.name, e.value);
	}

	public static function doReuse(ctx:Context, api:CompilerApi, args:Array<String>):Void {
		ctx.curapi = api;
		ctx.args = args;
		ctx.hadError = false;
		ctx.staticPrototypes.reset();
	}

	public static function setError(ctx:Context, b:Bool):Void {
		// TODO: Have to reset this somewhere if running compilation server. But where...
		ctx.hadError = b;
	}

	public static function addTypes(ctx:Context, types:Array<ModuleType>, ready:ModuleType->Void):Void {
		if (!ctx.hadError)
			EvalExceptions.catchExceptions(ctx, () -> {
				EvalPrototype.addTypes(ctx, types, ready);
				return VNull;
			}, Globals.nullPos);
	}

	public static function makeRuntimeError(msg:String, pos:Pos):Value {
		var vi = EvalEncode.encodeInstance(EvalHash.key_haxe_macro_Error);
		return switch vi {
			case VInstance(i):
				var s = EvalString.createUnknown(msg);
				EvalMisc.setInstanceField(i, EvalHash.key_exception_message, s);
				EvalMisc.setInstanceField(i, EvalHash.key_pos, EvalEncode.encodePos(pos));
				EvalMisc.setInstanceField(i, EvalHash.key_native_exception, s);
				vi;
			case _:
				Globals.die("", "evalMain.ml make_runtime_error");
		}
	}

	public static function compilerError(err:core.Error.CompilerError):Dynamic {
		var vi = makeRuntimeError(core.Error.errorMsg(err.errMessage), err.errPos);
		return switch vi {
			case VInstance(i):
				switch err.errSub {
					case []:
						var ctx = EvalContext.getCtx();
						var eval = EvalContext.getEval(ctx);
						switch eval.env {
							case null:
							case _:
								var stack = EvalStackTrace.makeStackValue(EvalContext.callStack(eval));
								EvalMisc.setInstanceField(i, EvalHash.key_native_stack, stack);
						}
					case _:
						// port: built by consing upstream: newest first
						var stack:Array<Value> = [];
						var subs = err.errSub.copy();
						subs.reverse();
						for (err in subs) {
							core.Error.Error.recurseError((depth, err) -> {
								// TODO indent child errors depending on depth
								stack.unshift(makeRuntimeError(core.Error.errorMsg(err.errMessage), err.errPos));
							}, err);
							// TODO: not sure if we want rev or not here.. tests don't help atm
						}
						var l = stack.copy();
						l.reverse();
						EvalMisc.setInstanceField(i, EvalHash.key_child_errors, EvalEncode.encodeArray(l));
				}
				EvalContext.exc(vi);
			case _:
				Globals.die("", "evalMain.ml compiler_error");
		}
	}

	// port: Ast.efield
	static inline function efield(e:Expr, s:String):ExprDef return EField(e, s, EFNormal);

	// port: MacroApi.haxe_float
	// convert float value to haxe expression, handling inf/-inf/nan
	static function haxeFloat(f:Float, p:Pos):Expr {
		var std:Expr = {expr: EConst(Ident("std")), pos: p};
		var math:Expr = {expr: efield(std, "Math"), pos: p};
		return if (f == Math.POSITIVE_INFINITY) {
			expr: efield(math, "POSITIVE_INFINITY"),
			pos: p
		} else if (f == Math.NEGATIVE_INFINITY) {
			expr: efield(math, "NEGATIVE_INFINITY"),
			pos: p
		} else if (f != f) {
			expr: efield(math, "NaN"),
			pos: p
		} else {expr: EConst(Float(core.Numeric.floatRepres(f), null)), pos: p};
	}

	static function pathEquals(a:GlobalTypePath, b:GlobalTypePath):Bool {
		return a.name == b.name && a.pack.join(".") == b.pack.join(".") && a.pack.length == b.pack.length;
	}

	public static function valueToExpr(v:Value, p:Pos):Expr {
		inline function path(i:Int):Expr {
			var mt = EvalContext.getCtx().typeCache.find(i);
			inline function makePath(t:ModuleType):Expr {
				function loop(l:Array<String>, idx:Int):Expr {
					// port: `l` is reversed: l[idx] is the head
					return switch l.length - idx {
						case 0: Globals.die("", "evalMain.ml value_to_expr");
						case 1: {expr: EConst(Ident(l[idx])), pos: p};
						case _: {expr: efield(loop(l, idx + 1), l[idx]), pos: p};
					}
				}
				var t = TFunctions.tInfos(t);
				var l = if (pathEquals(t.mtModule.mPath,
					t.mtPath)) t.mtPath.pack.concat([t.mtPath.name]) else
					t.mtModule.mPath.pack.concat([t.mtModule.mPath.name, t.mtPath.name]);
				l.reverse();
				return loop(l, 0);
			}
			return makePath(mt);
		}
		inline function makeMapEntry(eKey:Expr, v:Value):Expr {
			var eValue = valueToExpr(v, p);
			return {expr: EBinop(OpArrow, eKey, eValue), pos: p};
		}
		return switch v.vresolve() {
			case VNull: {expr: EConst(Ident("null")), pos: p};
			case VTrue: {expr: EConst(Ident("true")), pos: p};
			case VFalse: {expr: EConst(Ident("false")), pos: p};
			case VInt32(i): {expr: EConst(Int(Std.string(i), null)), pos: p};
			case VFloat(f): haxeFloat(f, p);
			case VString(s): {expr: EConst(String(s.sstring, SDoubleQuotes)), pos: p};
			case VArray(va): {expr: EArrayDecl([for (v in EvalArray.toList(va)) valueToExpr(v, p)]), pos: p};
			case VObject(o):
				var fields:Array<ObjectField> = [];
				for (f in EvalContext.objectFields(o)) {
					var n = EvalHash.revHash(f.name);
					// Workaround for #8261: Ignore generated pos fields
					switch f.value {
						case VInstance({ikind: IPos(_)}) if (n == "pos"):
						case _:
							fields.push({
								key: {name: n, pos: p, quote: (if (syntax.Lexer.isValidIdentifier(n)) NoQuotes else DoubleQuotes)},
								expr: valueToExpr(f.value, p)
							});
					}
				}
				{expr: EObjectDecl(fields), pos: p};
			case VEnumValue(e):
				var epath:Expr = {
					var proto = EvalContext.getStaticPrototypeRaise(EvalContext.getCtx(), e.epath);
					var expr = path(e.epath);
					var name = switch proto.pkind {
						case PEnum(names):
							if (e.eindex < 0 || e.eindex >= names.length) throw new Failure("nth");
							names[e.eindex].name;
						case _: Globals.die("", "evalMain.ml value_to_expr");
					}
					{expr: efield(expr, name), pos: p};
				}
				switch e.eargs {
					case []: epath;
					case _:
						var args = [for (v in e.eargs) valueToExpr(v, p)];
						{expr: ECall(epath, args), pos: p};
				}
			case VInstance({ikind: IIntMap(m)}):
				var el = m.fold((k, v, acc:Array<Expr>) -> {
					var eKey:Expr = {expr: EConst(Int(Std.string(k), null)), pos: p};
					acc.unshift(makeMapEntry(eKey, v));
					acc;
				}, []);
				{expr: EArrayDecl(el), pos: p};
			case VInstance({ikind: IInt64Map(m)}):
				var el = m.fold((k, v, acc:Array<Expr>) -> {
					var eKey:Expr = {expr: EConst(Int(haxe.Int64.toStr(k), "i64")), pos: p};
					acc.unshift(makeMapEntry(eKey, v));
					acc;
				}, []);
				{expr: EArrayDecl(el), pos: p};
			case VInstance({ikind: IStringMap(m)}):
				var el = m.fold((k, e, acc:Array<Expr>) -> {
					var eKey:Expr = {expr: EConst(String(k, SDoubleQuotes)), pos: p};
					acc.unshift(makeMapEntry(eKey, e.value));
					acc;
				}, []);
				{expr: EArrayDecl(el), pos: p};
			case VInstance({ikind: IObjectMap(m)}):
				var el = m.fold((k, v, acc:Array<Expr>) -> {
					var eKey = valueToExpr(k, p);
					acc.unshift(makeMapEntry(eKey, v));
					acc;
				}, []);
				{expr: EArrayDecl(el), pos: p};
			case _: EvalContext.excString("Cannot convert " + valueString(v) + " to expr");
		}
	}

	// port: `encode_obj = encode_obj_s`
	public static function encodeObj(l:Array<{name:String, value:Value}>):Value return EvalEncode.encodeObjS(l);

	public static function field(v:Value, f:String):Value return EvalField.field(v, EvalHash.hash(f));

	public static function valueString(v:Value):String return EvalPrinting.valueString(v);

	public static function excString(s:String):Dynamic return EvalContext.excString(s);

	public static function evalExpr(ctx:Context,
			e:TExpr):Null<Value> return if (ctx.hadError) null else EvalPrototype.evalExpr(ctx, EKEntrypoint, e);

	// port: returns the errors as upstream's list: the most recent first.
	public static function handleDecodingError(f:String->Void, v:Value, t:T):Array<{msg:String, line:Int}> {
		var line = 1;
		var errors:Array<{msg:String, line:Int}> = [];
		inline function error(msg:String, v:Value) {
			errors.unshift({msg: msg, line: line});
			f(valueString(v) + " <- " + msg);
		}
		function loop(tabs:String, t:T, v:Value):Void {
			switch t {
				case TAnon(an):
					f("{");
					var keys = [for (k in an.aFields.keys()) k];
					keys.sort((a, b) -> a == b ? 0 : (a < b ? -1 : 1));
					for (k in keys) {
						var cf = an.aFields.get(k);
						line++;
						f("\n" + (tabs + "\t") + cf.cfName + ": ");
						try {
							var vf = EvalField.fieldRaise(v, EvalHash.hash(cf.cfName));
							switch vf {
								case VNull if (!TFunctions.isExplicitNull(cf.cfType)): error("expected value", vf);
								case _: loop(tabs + "\t", cf.cfType, vf);
							}
						} catch (_:NotFound) {
							if (!TFunctions.isExplicitNull(cf.cfType)) error("expected value", VNull)
							else f("null");
						}
					}
					line++;
					f("\n" + tabs + "}");
				case TInst({clPath: {pack: [], name: "Array"}}, [t1]):
					switch v {
						case VArray(va):
							f("[");
							var first = true;
							for (v in EvalArray.toList(va)) {
								if (!first) f(", ");
								loop(tabs, t1, v);
								first = false;
							}
							f("]");
						case _: error("expected Array", v);
					}
				case TInst({clPath: {pack: [], name: "String"}}, _):
					switch v {
						case VString(_): f(valueString(v));
						case _: error("expected String", v);
					}
				case TAbstract({aPath: {pack: [], name: "Null"}}, [t1]):
					if (v.match(VNull)) f("null")
					else loop(tabs, t1, v);
				case TAbstract({aPath: {pack: [], name: "Bool"}}, _):
					switch v {
						case VTrue: f("true");
						case VFalse: f("false");
						case _: error("expected Bool", v);
					}
				case TAbstract({aPath: {pack: [], name: "Int" | "Float"}}, _):
					switch v {
						case VInt32(_) | VFloat(_): f(valueString(v));
						case _: error("expected Bool", v);
					}
				case TType(t, tl):
					loop(tabs, TFunctions.applyTypedef(t, tl), v);
				case TAbstract({aPath: {pack: ["haxe", "macro"], name: "Position"}}, _):
					switch v {
						case VInstance({ikind: IPos(_)}): f("#pos");
						case _: error("expected Position", v);
					}
				case TEnum(en, _):
					switch v {
						case VEnumValue(ev):
							if (ev.eindex < 0 || ev.eindex >= en.eNames.length) throw new Failure("nth");
							var ef = en.eConstrs.get(en.eNames[ev.eindex]);
							if (ef == null) throw NotFound.raise();
							f(ef.efName);
							function loop2(first:Bool, tl:Array<{name:String, optional:Bool, type:T}>, vl:Array<Value>, i:Int) {
								if (i >= vl.length || i >= tl.length) return;
								if (!first) f(", ");
								loop(tabs, tl[i].type, vl[i]);
								loop2(false, tl, vl, i + 1);
							}
							switch [TFunctions.follow(ef.efType), ev.eargs] {
								case [_, []]:
								case [TFun(sig), vl]:
									f("(");
									loop2(true, sig.args, vl, 0);
									f(")");
								case _:
							}
						case _: error("expected enum value", v);
					}
				case TInst(_) | TAbstract(_) | TFun(_):
					// TODO: might need some more of these, not sure
					Globals.die("", "evalMain.ml handle_decoding_error");
				case TMono(r):
					switch r.tmType {
						case null:
						case t: loop(tabs, t, v);
					}
				case TLazy(r):
					loop(tabs, TFunctions.lazyType(r), v);
				case TDynamic(_):
			}
		}
		loop("", t, v);
		return errors;
	}

	public static function getApiCallPos():Pos {
		var eval = EvalContext.getEval(EvalContext.getCtx());
		var env = eval.env;
		if (env == null) throw new Failure("Option.get"); // port: No_value upstream
		var env = switch env.envParent {
			case null: env;
			case env: env;
		}
		return new Pos(EvalHash.revHash(env.envInfo.pfile), env.envLeavePmin, env.envLeavePmax);
	}
}
