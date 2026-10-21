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
import core.TFunctions.*;
import core.Texpr;
import core.ds.AtomicLazy;
import core.ds.GlobalsIntMap;
import core.ds.NotFound;
import macros.eval.EvalValue;
import macros.eval.EvalContext;
import macros.eval.EvalHash;
import macros.eval.EvalEmitter;
import macros.eval.EvalJitContext;
import haxe.ds.Vector;

using macros.eval.EvalValue.EvalValueTools;
using core.ds.VectorTools;

// port: deviations:
// - Upstream shadows `jit_tfunction` and `jit_expr`: the recursive JIT functions
//   over a `JitContext` are `jitTfunctionRec`/`jitExprRec`; the context-level
//   entry points keep the names `jitTfunction`/`jitExpr`. `jitExpr` returns
//   `{jit, f}` for upstream's `(jit, f)` pair.
// - `ctx.overrides` is keyed by `"<dot path>.<field>"`.
class EvalJit {
	// port: hook (not upstream): called, when set, by the code of a static
	// variable's read or write (its class) as the macro runs; for the tool's
	// module cache, which finds the modules whose macros keep state
	public static var staticVarHook:Null<(c:TClass, write:Bool) -> Void> = null;

	static function hookStatic(c:TClass, cf:Null<TClassField>, write:Bool, exec:EvalEmitter.Emitter):EvalEmitter.Emitter {
		var h = staticVarHook;
		if (h == null || (cf != null && !cf.cfKind.match(Var(_)))) return exec;
		return env -> {
			h(c, write);
			exec(env);
		}
	}

	// Helper
	public static function ropePath(t:T):String {
		return switch follow(t) {
			case TInst({clPath: path}, _) | TEnum({ePath: path}, _) | TAbstract({aPath: path}, _): Globals.sTypePath(path);
			case TDynamic(_): "Dynamic";
			case TFun(_) | TAnon(_) | TMono(_) | TType(_) | TLazy(_): Globals.die("", "evalJit.ml:ropePath");
		}
	}

	public static final eone:TExpr = mk(TConst(TInt(1)), tDynamic, Globals.nullPos);

	public static function evalConst(c:TConstant):Value {
		return switch c {
			case TString(s): EvalString.createUnknown(s);
			case TInt(i32): VInt32(i32);
			case TFloat(f): VFloat(floatOfString(f));
			case TBool(b): EvalValueTools.vbool(b);
			case TNull: VNull;
			case TThis | TSuper: Globals.die("", "evalJit.ml:evalConst");
		}
	}

	// port: OCaml `float_of_string` on a lexed float literal.
	static function floatOfString(s:String):Float {
		return core.ds.OcamlFloat.ofString(s);
	}

	public static function isInt(t:T):Bool {
		return switch follow(t) {
			case TAbstract({aPath: {pack: [], name: "Int"}}, _): true;
			case _: false;
		}
	}

	public static function isString(t:T):Bool {
		return switch follow(t) {
			case TInst({clPath: {pack: [], name: "String"}}, _): true;
			case _: false;
		}
	}

	public static function isConstIntPattern(c:TSwitchCase):Bool {
		for (e in c.casePatterns) {
			switch e.eexpr {
				case TConst(TInt(_)):
				case _:
					return false;
			}
		}
		return true;
	}

	static function isPath(path:core.Globals.GlobalTypePath, pack:Array<String>, name:String):Bool {
		if (path.name != name || path.pack.length != pack.length) return false;
		for (i in 0...pack.length) if (path.pack[i] != pack[i]) return false;
		return true;
	}

	// port: `PMap.foldi (fun k _ acc -> (hash k,()) :: acc) an.a_fields []` (keys only).
	static function anonFieldKeys(an:TAnon):Array<Int> {
		return core.ds.PMap.foldi((k, _, acc:Array<Int>) -> {
			acc.unshift(EvalHash.hash(k));
			acc;
		}, an.aFields, []);
	}

	public static function opAssign(ctx:Context, jit:JitContext, e1:TExpr, e2:TExpr):Emitter {
		switch e1.eexpr {
			case TLocal(v):
				var exec = jitExprRec(jit, false, e2);
				if (hasVarFlag(v, VCaptured)) return EvalEmitter.emitCaptureWrite(EvalJitContext.getCaptureSlot(jit, v), exec);
				else return EvalEmitter.emitLocalWrite(EvalJitContext.getSlot(jit, v.vId, e1.epos), exec);
			case TField(ef, fa):
				var name = EvalHash.hash(fieldName(fa));
				var exec1 = jitExprRec(jit, false, ef);
				var exec2 = jitExprRec(jit, false, e2);
				switch fa {
					case FInstance({clPath: {pack: ["haxe", "io"], name: "Bytes"}}, _, {cfName: "length"}):
						return EvalEmitter.emitBytesLengthWrite(exec1, exec2);
					case FStatic(c = {clPath: path}, _):
						var proto = EvalContext.getStaticPrototype(jit.ctx, EvalHash.pathHash(path), ef.epos);
						return hookStatic(c, null, true, EvalEmitter.emitProtoFieldWrite(proto, EvalContext.getProtoFieldIndex(proto, name), exec2));
					case FEnum({ePath: path}, _):
						var proto = EvalContext.getStaticPrototype(jit.ctx, EvalHash.pathHash(path), ef.epos);
						return EvalEmitter.emitProtoFieldWrite(proto, EvalContext.getProtoFieldIndex(proto, name), exec2);
					case FInstance(c, _, _) if (!hasClassFlag(c, CInterface)):
						var proto = EvalContext.getInstancePrototype(jit.ctx, EvalHash.pathHash(c.clPath), ef.epos);
						var i = EvalContext.getInstanceFieldIndex(proto, name, ef.epos);
						return EvalEmitter.emitInstanceFieldWrite(exec1, ef.epos, i, exec2);
					case FAnon(cf):
						switch follow(ef.etype) {
							case TAnon(an):
								var l = anonFieldKeys(an);
								var proto = ctx.getObjectPrototype(ctx, l);
								var i = EvalContext.getInstanceFieldIndex(proto, name, ef.epos);
								return EvalEmitter.emitAnonFieldWrite(exec1, ef.epos, proto, i, name, exec2);
							case _:
								return EvalEmitter.emitFieldWrite(exec1, e1.epos, name, exec2);
						}
					case _:
						return EvalEmitter.emitFieldWrite(exec1, e1.epos, name, exec2);
				}
			case TArray(ea1, ea2):
				switch follow(ea1.etype) {
					case TInst({clPath: {pack: ["eval"], name: "Vector"}}, _):
						var exec1 = jitExprRec(jit, false, ea1);
						var exec2 = jitExprRec(jit, false, ea2);
						var exec3 = jitExprRec(jit, false, e2);
						return EvalEmitter.emitVectorWrite(exec1, ea1.epos, exec2, ea2.epos, exec3, ea2.epos);
					case _:
						var exec1 = jitExprRec(jit, false, ea1);
						var exec2 = jitExprRec(jit, false, ea2);
						var exec3 = jitExprRec(jit, false, e2);
						return EvalEmitter.emitArrayWrite(exec1, ea1.epos, exec2, ea2.epos, exec3, ea2.epos);
				}
			case _:
				return Globals.die("", "evalJit.ml:opAssign");
		}
	}

	public static function opAssignOp(jit:JitContext, op:Value->Value->Value, e1:TExpr, e2:TExpr, prefix:Bool):Emitter {
		switch e1.eexpr {
			case TLocal(v):
				var exec = jitExprRec(jit, false, e2);
				if (hasVarFlag(v,
					VCaptured)) return EvalEmitter.emitCaptureReadWrite(EvalJitContext.getCaptureSlot(jit, v), exec, op, prefix);
				else return EvalEmitter.emitLocalReadWrite(EvalJitContext.getSlot(jit, v.vId, e1.epos), exec, op, prefix);
			case TField(ef, fa):
				var name = EvalHash.hash(fieldName(fa));
				var exec1 = jitExprRec(jit, false, ef);
				var exec2 = jitExprRec(jit, false, e2);
				switch fa {
					case FStatic(c = {clPath: path}, _):
						var proto = EvalContext.getStaticPrototype(jit.ctx, EvalHash.pathHash(path), ef.epos);
						return hookStatic(c, null, true, EvalEmitter.emitProtoFieldReadWrite(proto, EvalContext.getProtoFieldIndex(proto, name), exec2, op, prefix));
					case FInstance(c, _, _) if (!hasClassFlag(c, CInterface)):
						var proto = EvalContext.getInstancePrototype(jit.ctx, EvalHash.pathHash(c.clPath), ef.epos);
						var i = EvalContext.getInstanceFieldIndex(proto, name, ef.epos);
						return EvalEmitter.emitInstanceFieldReadWrite(exec1, ef.epos, i, exec2, op, prefix);
					case _:
						return EvalEmitter.emitFieldReadWrite(exec1, e1.epos, name, exec2, op, prefix);
				}
			case TArray(ea1, ea2):
				switch follow(ea1.etype) {
					case TInst({clPath: {pack: ["eval"], name: "Vector"}}, _):
						var exec1 = jitExprRec(jit, false, ea1);
						var exec2 = jitExprRec(jit, false, ea2);
						var exec3 = jitExprRec(jit, false, e2);
						return EvalEmitter.emitVectorReadWrite(exec1, ea1.epos, exec2, ea2.epos, exec3, op, prefix);
					case _:
						var exec1 = jitExprRec(jit, false, ea1);
						var exec2 = jitExprRec(jit, false, ea2);
						var exec3 = jitExprRec(jit, false, e2);
						return EvalEmitter.emitArrayReadWrite(exec1, ea1.epos, exec2, ea2.epos, exec3, op, prefix);
				}
			case _:
				return Globals.die("", "evalJit.ml:opAssignOp");
		}
	}

	public static function opIncr(jit:JitContext, e1:TExpr, prefix:Bool, p:Pos):Emitter {
		return opAssignOp(jit, EvalMisc.getBinopFun(OpAdd, p), e1, eone, prefix);
	}

	public static function opDecr(jit:JitContext, e1:TExpr, prefix:Bool, p:Pos):Emitter {
		return opAssignOp(jit, EvalMisc.getBinopFun(OpSub, p), e1, eone, prefix);
	}

	public static function unop(jit:JitContext, op:Unop, flag:UnopFlag, e1:TExpr, p:Pos):Emitter {
		switch op {
			case Not:
				var exec = jitExprRec(jit, false, e1);
				return EvalEmitter.emitNot(exec);
			case Neg:
				var exec = jitExprRec(jit, false, e1);
				return EvalEmitter.emitNeg(exec, p);
			case NegBits:
				var exec = jitExprRec(jit, false, e1);
				return EvalEmitter.emitOpSub(p, _ -> VInt32(-1), exec);
			case Increment:
				switch Texpr.skip(e1) {
					case {eexpr: TLocal(v)} if (!hasVarFlag(v, VCaptured)):
						var slot = EvalJitContext.getSlot(jit, v.vId, e1.epos);
						if (flag == Prefix) return EvalEmitter.emitLocalIncrPrefix(slot,
							e1.epos); else return EvalEmitter.emitLocalIncrPostfix(slot, e1.epos);
					case _:
						return opIncr(jit, e1, flag == Prefix, p);
				}
			case Decrement:
				return opDecr(jit, e1, flag == Prefix, p);
			case Spread:
				switch flag {
					case Postfix:
						return Globals.die("Postfix spread operator is not supported", "evalJit.ml:unop", p);
					case Prefix:
						return jitExprRec(jit, false, e1);
				}
		}
	}

	public static function jitDefault(jit:JitContext, ret:Bool, def:Null<TExpr>):Emitter {
		if (def == null) {
			return EvalEmitter.emitNull;
		} else {
			EvalJitContext.pushScope(jit, def.epos);
			var exec = jitExprRec(jit, ret, def);
			EvalJitContext.popScope(jit);
			return exec;
		}
	}

	static function hasContinue(e:TExpr):Bool {
		return switch e.eexpr {
			case TContinue: true;
			case TWhile(_) | TFunction(_): false;
			case _: Texpr.checkExpr(hasContinue, e);
		}
	}

	/**
		This is the main jit function. It turns expression [e] into a function, which can be
		executed int an environment of type [EvalContext.env].
	**/
	public static function jitExprRec(jit:JitContext, ret:Bool, e:TExpr):Emitter {
		var ctx = jit.ctx;
		function loop(e:TExpr):Emitter {
			switch e.eexpr {
				// objects and values
				case TVar(v, eo):
					var varacc = EvalJitContext.declareLocal(jit, v);
					var exec = if (eo == null) EvalEmitter.emitNull else jitExprRec(jit, false, eo);
					switch varacc {
						case Local(slot): return EvalEmitter.emitLocalDeclaration(slot, exec);
						case Env(slot): return EvalEmitter.emitCaptureDeclaration(slot, exec);
					}
				case TConst(TThis):
					return EvalEmitter.emitLocalRead(EvalJitContext.getSlot(jit, 0, e.epos));
				case TConst(ct):
					return EvalEmitter.emitConst(evalConst(ct));
				case TObjectDecl(fl):
					var fl2 = [
						for (f in fl) {key: EvalHash.hash(f.key.name), exec: jitExprRec(jit, false, f.expr)}
					];
					var proto = ctx.getObjectPrototype(ctx, [for (f in fl2) f.key]);
					var fa = [
						for (f in fl2) {i: EvalContext.getInstanceFieldIndex(proto, f.key, e.epos), exec: f.exec}
					];
					return EvalEmitter.emitObjectDeclaration(proto, fa);
				case TArrayDecl(el):
					var execs = el.map(e -> jitExprRec(jit, false, e));
					return EvalEmitter.emitArrayDeclaration(execs);
				case TTypeExpr(mt):
					var key = EvalHash.pathHash(tPath(mt));
					var proto = EvalContext.getStaticPrototypeAsValue(jit.ctx, key, e.epos);
					return EvalEmitter.emitTypeExpr(proto);
				case TFunction(tf):
					var jitClosure = EvalJitContext.create(ctx);
					jit.numClosures = jit.numClosures + 1;
					var r = jitTfunctionRec(jitClosure, true, e.epos, tf);
					var fl = r.fl, exec = r.exec;
					var hasret = jitClosure.hasNonfinalReturn;
					var eci = getEnvCreation(jitClosure, false, tf.tfExpr.epos.pfile, EKLocalFunction(jit.numClosures));
					var captures = jitClosure.captures.fold((vid, c:CaptureSlot, acc:Array<{i:Int, vid:Int, declared:Bool}>) -> {
						acc.unshift({i: c.slot, vid: vid, declared: c.declared});
						acc;
					}, []);
					// port: List.sort is stable; capture slots are distinct
					haxe.ds.ArraySort.sort(captures, (a, b) -> a.i < b.i ? -1 : (a.i > b.i ? 1 : 0));
					// Check if the out-of-scope var is in the outer scope because otherwise we have to promote outwards.
					for (v in jitClosure.capturesOutsideScope) EvalJitContext.getCaptureSlot(jit, v);
					var mappingI = [];
					var mappingSlot = [];
					for (c in captures) {
						if (c.declared) continue;
						var outer = jit.captures.findOpt(c.vid);
						if (outer == null) core.Error.raiseTypingError('Could not find capture variable ${c.vid}', e.epos);
						mappingI.push(c.i);
						mappingSlot.push(outer.slot);
					}
					return EvalEmitter.emitClosure(ctx, Vector.fromArrayCopy(mappingI), Vector.fromArrayCopy(mappingSlot), eci, hasret, exec, fl);
				// branching
				case TIf(e1, e2, eo):
					var execCond = jitExprRec(jit, false, e1);
					var execThen = jitExprRec(jit, ret, e2);
					var execElse = if (eo == null) EvalEmitter.emitNull else jitExprRec(jit, ret, eo);
					return EvalEmitter.emitIf(execCond, execThen, execElse);
				case TSwitch(sw) if (isInt(sw.switchSubject.etype) && sw.switchCases.foreach(isConstIntPattern)):
					var exec = jitExprRec(jit, false, sw.switchSubject);
					var h:GlobalsIntMap<Emitter> = GlobalsIntMap.empty();
					var max = 0;
					var min = 0x7FFFFFFF; // port: max_int: upstream's 63-bit int, larger than any case value
					var minUnset = true;
					for (c in sw.switchCases) {
						var el = c.casePatterns, ce = c.caseExpr;
						EvalJitContext.pushScope(jit, ce.epos);
						var exec = jitExprRec(jit, ret, ce);
						for (e in el) {
							switch e.eexpr {
								case TConst(TInt(i)):
									h = h.add(i, exec);
									if (i > max) max = i;
									if (minUnset || i < min) {
										min = i;
										minUnset = false;
									}
								case _:
									Globals.die("", "evalJit.ml:TSwitch");
							}
						}
						EvalJitContext.popScope(jit);
					}
					var execDef = jitDefault(jit, ret, sw.switchDefault);
					if (minUnset) {
						// port: upstream: min = max_int, so l = max - max_int + 1 <= 0
						return EvalEmitter.emitIntSwitchMap(exec, h, execDef, sw.switchSubject.epos);
					}
					// port: 64-bit arithmetic as upstream (no 32-bit overflow)
					var l:Float = (max : Float) - (min : Float) + 1;
					if (l > 0 && l < 256) {
						var li = Std.int(l);
						var cases = new Vector<Emitter>(li);
						for (i in 0...li) {
							var f = h.findOpt(i + min);
							cases[i] = f == null ? execDef : f;
						}
						return EvalEmitter.emitIntSwitchArray(-min, exec, cases, execDef, sw.switchSubject.epos);
					} else
						return EvalEmitter.emitIntSwitchMap(exec, h, execDef, sw.switchSubject.epos);
				/* | TSwitch(e1,cases,def) when is_string e1.etype ->
					let exec = jit_expr jit false e1 in
					let h = ref PMap.empty in
					List.iter (fun (el,e) ->
						push_scope jit e.epos;
						let exec = jit_expr jit return e in
						List.iter (fun e -> match e.eexpr with
							| TConst (TString s) -> h := PMap.add s exec !h;
							| _ -> die "" __LOC__
						) el;
						pop_scope jit;
					) cases;
					let exec_def = jit_default jit return def in
					emit_string_switch_map exec !h exec_def e1.epos */
				case TSwitch(sw):
					var exec = jitExprRec(jit, false, sw.switchSubject);
					var n = sw.switchCases.length;
					var execs = new Vector<Emitter>(n);
					var patterns = new Vector<Array<Emitter>>(n);
					for (i in 0...n) {
						var c = sw.switchCases[i];
						EvalJitContext.pushScope(jit, c.caseExpr.epos);
						var el = [for (e in c.casePatterns) jitExprRec(jit, false, e)];
						execs[i] = jitExprRec(jit, ret, c.caseExpr);
						EvalJitContext.popScope(jit);
						patterns[i] = el;
					}
					var execDef = jitDefault(jit, ret, sw.switchDefault);
					return EvalEmitter.emitSwitch(exec, execs, patterns, execDef);
				case TWhile({eexpr: TParenthesis(e1)}, e2, flag):
					return loop(mk(TWhile(e1, e2, flag), e.etype, e.epos));
				case TWhile(e1, e2, flag):
					var execCond = jitExprRec(jit, false, e1);
					var execBody = jitExprRec(jit, false, e2);
					switch flag {
						case NormalWhile:
							if (hasContinue(e2)) return EvalEmitter.emitWhileBreakContinue(execCond,
								execBody); else return EvalEmitter.emitWhileBreak(execCond, execBody);
						case DoWhile:
							return EvalEmitter.emitDoWhileBreakContinue(execCond, execBody);
					}
				case TTry(e1, catches):
					var exec = jitExprRec(jit, ret, e1);
					var catches = [
						for (c in catches) {
							var v = c.variable, ce = c.expr;
							EvalJitContext.pushScope(jit, ce.epos);
							var varacc = EvalJitContext.declareLocal(jit, v);
							var exec = jitExprRec(jit, ret, ce);
							EvalJitContext.popScope(jit);
							var key = EvalHash.hash(ropePath(v.vType));
							var f:Emitter->Emitter = switch varacc {
								case Local(slot): EvalEmitter.emitLocalWrite.bind(slot);
								case Env(slot): EvalEmitter.emitCaptureWrite.bind(slot);
							}
							new TryCatch(exec, key, f);
						}
					];
					return EvalEmitter.emitTry(exec, catches);
				// control flow
				case TBlock([]):
					return EvalEmitter.emitNull;
				case TBlock([e1]):
					EvalJitContext.pushScope(jit, e.epos);
					var exec = jitExprRec(jit, ret, e1);
					EvalJitContext.popScope(jit);
					return exec;
				case TBlock(el):
					EvalJitContext.pushScope(jit, e.epos);
					var execs = [];
					for (i in 0...el.length) execs.push(jitExprRec(jit, i == el.length - 1 ? ret : false, el[i]));
					EvalJitContext.popScope(jit);
					return step(execs);
				case TReturn(null):
					if (ret && !jit.ctx.debug.supportDebugger) return EvalEmitter.emitNull;
					else {
						jit.hasNonfinalReturn = true;
						return EvalEmitter.emitReturnNull;
					}
				case TReturn(e1):
					var exec = jitExprRec(jit, false, e1);
					if (ret && !jit.ctx.debug.supportDebugger) return EvalEmitter.emitValue(exec);
					else {
						jit.hasNonfinalReturn = true;
						return EvalEmitter.emitReturnValue(exec);
					}
				case TBreak:
					return EvalEmitter.emitBreak;
				case TContinue:
					return EvalEmitter.emitContinue;
				case TThrow(e1):
					var exec = jitExprRec(jit, false, e1);
					return EvalEmitter.emitThrow(exec, e.epos);
				case TCast(e1, mt) if (mt != null):
					var exec = jitExprRec(jit, false, e1);
					var t = typeOfModuleType(mt);
					return EvalEmitter.emitSafeCast(exec, EvalHash.hash(ropePath(t)), e.epos);
				// calls
				case TCall(e1, el):
					return jitCall(jit, ctx, e, e1, el);
				case TNew({clPath: {pack: [], name: "Array"}}, _, _):
					return EvalEmitter.emitNewArray;
				case TNew({clPath: {pack: ["eval"], name: "Vector"}}, _, [e1]):
					switch e1.eexpr {
						case TConst(TInt(i32)):
							return EvalEmitter.emitNewVectorInt(i32, e1.epos);
						case _:
							var exec1 = jitExprRec(jit, false, e1);
							return EvalEmitter.emitNewVector(exec1, e1.epos);
					}
				case TNew(c, _, el):
					var execs = [for (e in el) jitExprRec(jit, false, e)];
					var key = EvalHash.pathHash(c.clPath);
					try {
						var f = EvalContext.getSpecialInstanceConstructorRaise(ctx, key);
						return EvalEmitter.emitSpecialInstance(f, execs);
					} catch (_:NotFound) {
						var fnew = EvalContext.getInstanceConstructor(jit.ctx, key, e.epos);
						var proto = EvalContext.getInstancePrototype(jit.ctx, key, e.epos);
						var p = e.epos;
						var v = AtomicLazy.fromFun(() -> switch fnew.force() {
							case VFunction(f, _): f;
							case v: (EvalEmitter.cannotCall(v, p) : Vfunc);
						});
						return EvalEmitter.emitConstructorCall(proto, v, execs, e.epos);
					}
				// read
				case TLocal(v):
					if (hasVarFlag(v, VCaptured)) return EvalEmitter.emitCaptureRead(EvalJitContext.getCaptureSlot(jit, v));
					else return EvalEmitter.emitLocalRead(EvalJitContext.getSlot(jit, v.vId, e.epos));
				case TField(e1, fa):
					var name = EvalHash.hash(fieldName(fa));
					switch fa {
						case FInstance({clPath: {pack: [], name: "Array"}}, _, {cfName: "length"}):
							return EvalEmitter.emitArrayLengthRead(jitExprRec(jit, false, e1), e1.epos);
						case FInstance({clPath: {pack: ["eval"], name: "Vector"}}, _, {cfName: "length"}):
							return EvalEmitter.emitVectorLengthRead(jitExprRec(jit, false, e1), e1.epos);
						case FInstance({clPath: {pack: ["haxe", "io"], name: "Bytes"}}, _, {cfName: "length"}):
							return EvalEmitter.emitBytesLengthRead(jitExprRec(jit, false, e1), e1.epos);
						case FStatic(c = {clPath: path}, cf) if (staticVarHook != null && cf.cfKind.match(Var(_))):
							var proto = EvalContext.getStaticPrototype(ctx, EvalHash.pathHash(path), e1.epos);
							return hookStatic(c, cf, false, EvalEmitter.emitProtoFieldRead(proto, EvalContext.getProtoFieldIndex(proto, name)));
						case FStatic({clPath: path}, _) | FEnum({ePath: path}, _) |
							FInstance({clPath: path}, _, {cfKind: Method(MethNormal | MethInline)}):
							var proto = EvalContext.getStaticPrototype(ctx, EvalHash.pathHash(path), e1.epos);
							return EvalEmitter.emitProtoFieldRead(proto, EvalContext.getProtoFieldIndex(proto, name));
						case FInstance(c, _, _) if (!hasClassFlag(c, CInterface)):
							var proto = EvalContext.getInstancePrototype(ctx, EvalHash.pathHash(c.clPath), e1.epos);
							var i = EvalContext.getInstanceFieldIndex(proto, name, e1.epos);
							switch e1.eexpr {
								case TConst(TThis): return EvalEmitter.emitThisFieldRead(EvalJitContext.getSlot(jit, 0, e.epos), i);
								case _: return EvalEmitter.emitInstanceFieldRead(jitExprRec(jit, false, e1), e1.epos, i);
							}
						case FAnon(_):
							switch follow(e1.etype) {
								case TAnon(an):
									var l = anonFieldKeys(an);
									var proto = ctx.getObjectPrototype(ctx, l);
									var i = EvalContext.getInstanceFieldIndex(proto, name, e1.epos);
									return EvalEmitter.emitAnonFieldRead(jitExprRec(jit, false, e1), proto, i, name, e1.epos);
								case _:
									return EvalEmitter.emitFieldRead(jitExprRec(jit, false, e1), name, e1.epos);
							}
						case FClosure(_) | FDynamic(_):
							var exec = jitExprRec(jit, false, e1);
							return EvalEmitter.emitFieldClosure(exec, name);
						case _:
							var exec = jitExprRec(jit, false, e1);
							return EvalEmitter.emitFieldRead(exec, name, e1.epos);
					}
				case TArray(e1, e2):
					switch follow(e1.etype) {
						case TInst({clPath: {pack: ["eval"], name: "Vector"}}, _):
							var exec1 = jitExprRec(jit, false, e1);
							var exec2 = jitExprRec(jit, false, e2);
							return EvalEmitter.emitVectorRead(exec1, e1.epos, exec2, e2.epos);
						case _:
							var exec1 = jitExprRec(jit, false, e1);
							var exec2 = jitExprRec(jit, false, e2);
							return EvalEmitter.emitArrayRead(exec1, e1.epos, exec2, e2.epos);
					}
				case TEnumParameter(e1, _, i):
					var exec = jitExprRec(jit, false, e1);
					return EvalEmitter.emitEnumParameterRead(exec, i);
				case TEnumIndex(e1):
					var exec = jitExprRec(jit, false, e1);
					return EvalEmitter.emitEnumIndex(exec, e1.epos);
				// ops
				case TBinop(OpEq, e1, {eexpr: TConst(TNull)}) | TBinop(OpEq, {eexpr: TConst(TNull)}, e1):
					var exec = jitExprRec(jit, false, e1);
					return EvalEmitter.emitEqNull(exec);
				case TBinop(OpNotEq, e1, {eexpr: TConst(TNull)}) | TBinop(OpNotEq, {eexpr: TConst(TNull)}, e1):
					var exec = jitExprRec(jit, false, e1);
					return EvalEmitter.emitNotEqNull(exec);
				case TBinop(op, e1, e2):
					switch op {
						case OpAssign:
							return opAssign(ctx, jit, e1, e2);
						case OpAssignOp(op):
							var f = EvalMisc.getBinopFun(op, e.epos);
							return opAssignOp(jit, f, e1, e2, true);
						case OpBoolAnd:
							var exec1 = jitExprRec(jit, false, e1);
							var exec2 = jitExprRec(jit, false, e2);
							return EvalEmitter.emitBoolAnd(exec1, exec2);
						case OpBoolOr:
							var exec1 = jitExprRec(jit, false, e1);
							var exec2 = jitExprRec(jit, false, e2);
							return EvalEmitter.emitBoolOr(exec1, exec2);
						case _:
							var exec1 = jitExprRec(jit, false, e1);
							var exec2 = jitExprRec(jit, false, e2);
							return switch op {
								case OpAdd: EvalEmitter.emitOpAdd(e.epos, exec1, exec2);
								case OpMult: EvalEmitter.emitOpMult(e.epos, exec1, exec2);
								case OpDiv: EvalEmitter.emitOpDiv(e.epos, exec1, exec2);
								case OpSub: EvalEmitter.emitOpSub(e.epos, exec1, exec2);
								case OpEq: EvalEmitter.emitOpEq(exec1, exec2);
								case OpNotEq: EvalEmitter.emitOpNotEq(exec1, exec2);
								case OpGt: EvalEmitter.emitOpGt(exec1, exec2);
								case OpGte: EvalEmitter.emitOpGte(exec1, exec2);
								case OpLt: EvalEmitter.emitOpLt(exec1, exec2);
								case OpLte: EvalEmitter.emitOpLte(exec1, exec2);
								case OpAnd: EvalEmitter.emitOpAnd(e.epos, exec1, exec2);
								case OpOr: EvalEmitter.emitOpOr(e.epos, exec1, exec2);
								case OpXor: EvalEmitter.emitOpXor(e.epos, exec1, exec2);
								case OpShl: EvalEmitter.emitOpShl(e.epos, exec1, exec2);
								case OpShr: EvalEmitter.emitOpShr(e.epos, exec1, exec2);
								case OpUShr: EvalEmitter.emitOpUshr(e.epos, exec1, exec2);
								case OpMod: EvalEmitter.emitOpMod(e.epos, exec1, exec2);
								case _: Globals.die("", "evalJit.ml:TBinop");
							}
					}
				case TUnop(op, flag, v1):
					return unop(jit, op, flag, v1, e.epos);
				// rewrites/skips
				case TParenthesis(e1) | TMeta(_, e1) | TCast(e1, null):
					return loop(e1);
				case TIdent("$__mk_pos__"):
					return EvalEmitter.emitMkPos(e.epos);
				case TIdent(s):
					return core.Error.raiseTypingError("Unknown identifier: " + s, e.epos);
				case TCast(_, _):
					// port: unreachable: TCast(_, Some _) and TCast(_, None) are handled above
					return Globals.die("", "evalJit.ml:TCast");
			}
		}
		var f = loop(e);
		switch ctx.debug.debugSocket {
			case null:
				return f;
			case socket:
				function wrap() {
					return EvalDebug.debugLoop(jit, socket.connection, e, f);
				}
				switch e.eexpr {
					case TCall(_) | TNew(_) | TVar({vKind: VUser(_)}, _) | TIf(_) | TWhile(_) | TSwitch(_) | TTry(_) | TReturn(_) | TBreak |
						TContinue | TThrow(_) | TCast(_, _ != null => true):
						return wrap();
					case TUnop(Increment | Decrement, _, e1) | TBinop(OpAssign | OpAssignOp(_), e1, _):
						switch (Texpr.skip(e1)).eexpr {
							case TLocal({vKind: VGenerated | VInlined | VInlinedConstructorVariable(_) | VExtractorVariable}):
								return f;
							case _:
								return wrap();
						}
					case _:
						return f;
				}
		}
	}

	// port: groups the block's emitters into `emit_seq8`/`emit_seq4`/`emit_seq2` until one remains.
	static function step(el:Array<Emitter>):Emitter {
		var a = el;
		var i = a.length - 1;
		var acc:Array<Emitter> = [];
		while (true) {
			if (i >= 7) {
				var f8 = EvalEmitter.emitSeq8(a[i - 7], a[i - 6], a[i - 5], a[i - 4], a[i - 3], a[i - 2], a[i - 1], a[i]);
				acc.unshift(f8);
				i -= 8;
			} else if (i >= 3) {
				var f4 = EvalEmitter.emitSeq4(a[i - 3], a[i - 2], a[i - 1], a[i]);
				acc.unshift(f4);
				i -= 4;
			} else if (i >= 1) {
				var f2 = EvalEmitter.emitSeq2(a[i - 1], a[i]);
				acc.unshift(f2);
				i -= 2;
			} else if (i == 0) {
				acc.unshift(a[i]);
				break;
			} else
				break;
		}
		return switch acc.length {
			case 0: Globals.die("", "evalJit.ml:step");
			case 1: acc[0];
			case _: step(acc);
		}
	}

	// port: the `TCall` case of `jit_expr`.
	static function jitCall(jit:JitContext, ctx:Context, e:TExpr, e1:TExpr, el:Vector<TExpr>):Emitter {
		switch e1.eexpr {
			case TField({eexpr: TConst(TSuper), epos: pv}, FInstance(c, _, cf)):
				var proto = EvalContext.getInstancePrototype(ctx, EvalHash.pathHash(c.clPath), e1.epos);
				var name = EvalHash.hash(cf.cfName);
				var i = EvalContext.getProtoFieldIndex(proto, name);
				var slot = EvalJitContext.getSlot(jit, 0, pv);
				var execs = [for (e in el) jitExprRec(jit, false, e)];
				return EvalEmitter.emitSuperFieldCall(slot, proto, i, execs, e.epos);
			case TField(ef, fa):
				var name = EvalHash.hash(fieldName(fa));
				var execs = [for (e in el) jitExprRec(jit, false, e)];
				inline function isFinal(c:TClass, cf:TClassField):Bool {
					return hasClassFlag(c, CFinal)
						|| (hasClassFieldFlag(cf, CfFinal))
						|| /* In interp mode we can assume that a field is final if it is not overridden.
							We cannot do that in macro mode because overriding fields might be added
							after jitting this call. */ (!ctx.isMacro
							&& !ctx.overrides.exists(Globals.sTypePath(c.clPath) + "." + cf.cfName));
				}
				inline function isProperMethod(cf:TClassField):Bool {
					return switch cf.cfKind {
						case Method(MethDynamic): false;
						case Method(_): true;
						case Var(_): false;
					}
				}
				inline function lazyProtoField(proto:Vprototype):AtomicLazy<Vfunc> {
					var i = EvalContext.getProtoFieldIndex(proto, name);
					var p = e.epos;
					return AtomicLazy.fromFun(() -> switch proto.pfields[i] {
						case VFunction(f, _): f;
						case v: (EvalEmitter.cannotCall(v, p) : Vfunc);
					});
				}
				inline function jitWithNullCheck(ef:TExpr):Emitter {
					var exec = jitExprRec(jit, false, ef);
					return EvalEmitter.emitNullCheck(exec, ef.epos);
				}
				inline function instanceCall(c:TClass):Emitter {
					var exec = jitWithNullCheck(ef);
					var proto = EvalContext.getInstancePrototype(ctx, EvalHash.pathHash(c.clPath), ef.epos);
					var v = lazyProtoField(proto);
					return EvalEmitter.emitProtoFieldCall(v, [exec].concat(execs), e.epos);
				}
				inline function defaultCall():Emitter {
					var exec = jitWithNullCheck(ef);
					return EvalEmitter.emitMethodCall(exec, name, execs, e.epos);
				}
				switch fa {
					case FStatic({clPath: {pack: [], name: "StringTools"}}, {cfName: "fastCodeAt"}):
						if (execs.length == 2) return EvalEmitter.emitStringCca(execs[0], execs[1],
							e.epos); else return Globals.die("", "evalJit.ml:fastCodeAt");
					case FStatic({clPath: {pack: [], name: "StringTools"}}, {cfName: "unsafeCodeAt"}):
						if (execs.length == 2) return EvalEmitter.emitStringCcaUnsafe(execs[0], execs[1],
							e.epos); else return Globals.die("", "evalJit.ml:unsafeCodeAt");
					case FEnum({ePath: path}, ef):
						var key = EvalHash.pathHash(path);
						var pos:Null<Pos> = e.epos;
						return EvalEmitter.emitEnumConstruction(key, ef.efIndex, Vector.fromArrayCopy(execs), pos);
					case FStatic({clPath: path}, cf) if (isProperMethod(cf)):
						var proto = EvalContext.getStaticPrototype(ctx, EvalHash.pathHash(path), ef.epos);
						var v = lazyProtoField(proto);
						return EvalEmitter.emitProtoFieldCall(v, execs, e.epos);
					case FInstance(c, _, cf) if (isProperMethod(cf)):
						if (!isFinal(c, cf)) return defaultCall(); else if (!hasClassFlag(c, CInterface)) return instanceCall(c);
						// If we have exactly one implementer, use it instead of the super class/interface.
						else if (!ctx.isMacro && c.clImplements.length == 0 && c.clSuper == null) {
							if (c.clDescendants.length == 1
								&& !hasClassFlag(c.clDescendants[0], CInterface)
								&& isFinal(c.clDescendants[0], cf))
								return instanceCall(c.clDescendants[0]);
							else
								return defaultCall();
						} else return defaultCall();
					case _:
						var exec = jitWithNullCheck(ef);
						return EvalEmitter.emitFieldCall(exec, name, execs, e.epos);
				}
			case TConst(TSuper):
				switch follow(e1.etype) {
					case TInst(c, _):
						var key = EvalHash.pathHash(c.clPath);
						var execs = [for (e in el) jitExprRec(jit, false, e)];
						try {
							var f = EvalContext.getSpecialInstanceConstructorRaise(ctx, key);
							return EvalEmitter.emitSpecialSuperCall(f, execs);
						} catch (_:NotFound) {
							var fnew = EvalContext.getInstanceConstructor(jit.ctx, key, e1.epos);
							var p = e.epos;
							var v = AtomicLazy.fromFun(() -> switch fnew.force() {
								case VFunction(f, _): f;
								case v: (EvalEmitter.cannotCall(v, p) : Vfunc);
							});
							return EvalEmitter.emitSuperCall(v, execs, e.epos);
						}
					case _:
						return Globals.die("", "evalJit.ml:TSuper");
				}
			case _:
				var exec = jitExprRec(jit, false, e1);
				var execs = [for (e in el) jitExprRec(jit, false, e)];
				return EvalEmitter.emitCall(exec, execs, e.epos);
		}
	}

	public static function jitTfunctionRec(jit:JitContext, isStatic:Bool, pos:Pos, tf:TFunc):{fl:Array<ArgSetter>, exec:Emitter} {
		var ctx = jit.ctx;
		EvalJitContext.pushScope(jit, pos);
		// Declare `this` (if not static) and function arguments as local variables.
		if (!isStatic) EvalJitContext.declareLocalThis(jit);
		var fl = [
			for (a in tf.tfArgs) {
				var varacc = EvalJitContext.declareLocal(jit, a.variable);
				switch varacc {
					case Env(slot):
						EvalEmitter.executeSetCapture(slot);
					case Local(slot):
						EvalEmitter.executeSetLocal(slot);
				}
			}
		];
		if (!isStatic) fl.unshift(EvalEmitter.executeSetLocal(0));
		// port: List.fold_right over the arguments: the last argument's default is concatenated first.
		var e = tf.tfExpr;
		var k = tf.tfArgs.length - 1;
		while (k >= 0) {
			var a = tf.tfArgs[k];
			if (a.defaultValue != null)
				e = concat(Texpr.setDefault(ctx.curapi.getCom().basic, a.variable, a.defaultValue, e.epos), e);
			k--;
		}
		inline function hasFinalReturn(el:Vector<TExpr>):Bool {
			return el.length > 0 && el[el.length - 1].eexpr.match(TReturn(_));
		}
		switch e.eexpr {
			case TBlock(el) if (ctx.debug.supportDebugger && core.TOther.ExtType.isVoid(follow(tf.tfType)) && !hasFinalReturn(el)):
				var pos2:Pos = {pfile: pos.pfile, pmin: pos.pmax, pmax: pos.pmax};
				e = mk(TBlock(el.snoc(mk(TReturn(null), tDynamic, pos2))), e.etype, e.epos);
			case _:
		}
		// Jit the function expression.
		var exec = jitExprRec(jit, true, e);
		EvalJitContext.popScope(jit);
		return {fl: fl, exec: exec};
	}

	public static function getEnvCreation(jit:JitContext, isStatic:Bool, file:String, info:EnvKind):EnvInfo {
		return EvalContext.createEnvInfo(isStatic, file, jit.ctx.fileKeys.get(file), info, jit.captureInfos, jit.maxNumLocals,
			jit.captures.length());
	}

	public static function jitTimer<R>(ctx:Context, f:Void->R):R {
		return core.Timer.time(ctx.timerCtx, [(if (ctx.isMacro) "macro" else "interp"), "jit"], (_:Int) -> f(), 0);
	}

	/** Creates a [EvalValue.vfunc] of function [tf], which can be [static] or not. **/
	public static function jitTfunction(ctx:Context, keyType:Int, keyField:Int, tf:TFunc, isStatic:Bool, pos:Pos):Vfunc {
		function f():Vfunc {
			// Create a new JitContext with an initial scope
			var jit = EvalJitContext.create(ctx);
			var r = jitTfunctionRec(jit, isStatic, pos, tf);
			// Create the [vfunc] instance depending on the number of arguments.
			var hasret = jit.hasNonfinalReturn;
			var eci = getEnvCreation(jit, isStatic, tf.tfExpr.epos.pfile, EKMethod(keyType, keyField));
			return if (hasret) EvalEmitter.createFunction(ctx, eci, r.exec,
				r.fl) else EvalEmitter.createFunctionNoret(ctx, eci, r.exec, r.fl);
		}
		return jitTimer(ctx, f);
	}

	/** JITs expression [e] to a function. This is used for expressions that are not in a method. **/
	public static function jitExpr(ctx:Context, e:TExpr):{jit:JitContext, f:Emitter} {
		function f():{jit:JitContext, f:Emitter} {
			var jit = EvalJitContext.create(ctx);
			var f = jitExprRec(jit, false, mkBlock(e));
			return {jit: jit, f: f};
		}
		return jitTimer(ctx, f);
	}
}
