package macros.eval;

import core.Ast;
import core.Globals;
import core.Globals.Pos;
import core.ds.NotFound;
import core.ds.OcamlHashtbl;
import macros.eval.EvalContext;
import macros.eval.EvalHash;
import macros.eval.EvalValue;
import macros.eval.EvalExceptions;
import haxe.ds.Vector;

using macros.eval.EvalValue.EvalValueTools;
using core.ds.VectorTools;

// port: deviations:
// - The scope stack (`env.envDebug.scopes`, a snapshot of the JIT's) is an array
//   whose top is its last element (upstream: list head), so the loops over it
//   go from the end.
// - `Exit` is the control-flow exception `EvalDebugMisc.Exit`.
class BreakHere extends haxe.Exception {
	public function new() super("BreakHere");
}

class ParseExprError extends haxe.Exception {
	public final msg:String;

	public function new(msg:String) {
		super("Parse_expr_error");
		this.msg = msg;
	}
}

class NoValueExpr extends haxe.Exception {
	public function new() super("NoValueExpr");
}

class Exit extends haxe.Exception {
	public function new() super("Exit");
}

class EvalDebugMisc {
	public static function declaredBefore(vi:VarInfo, p:Pos):Bool {
		return vi.viPos.pmin < p.pmin;
	}

	/* Breakpoints */
	public static var breakpointId = -1;

	public static function makeBreakpoint(file:Int, line:Int, state:BreakpointState, column:BreakpointColumn, condition:Null<Expr>):Breakpoint {
		breakpointId++;
		return new Breakpoint(breakpointId, file, line, column, condition, state);
	}

	public static function makeFunctionBreakpoint(state:BreakpointState):FunctionBreakpoint {
		breakpointId++;
		return new FunctionBreakpoint(breakpointId, state);
	}

	public static function iterBreakpoints(ctx:Context, f:Breakpoint->Void):Void {
		ctx.debug.breakpoints.iter(function(_, breakpoints) {
			breakpoints.iter(function(_, breakpoint) f(breakpoint));
		});
	}

	public static function newIntHashtbl<V>():OcamlHashtbl<Int, V> return new OcamlHashtbl(OcamlHashtbl.hashInt, (a, b) -> a == b, 0);

	static function fileHash(ctx:Context, file:String):Int {
		return EvalHash.hash(core.Path.UniqueKey.toString(ctx.fileKeys.get(context.Common.findFile(ctx.curapi.getCom(), file))));
	}

	public static function addBreakpoint(ctx:Context, file:String, line:Int, column:BreakpointColumn, condition:Null<Expr>):Breakpoint {
		var hash = fileHash(ctx, file);
		var h = try {
			ctx.debug.breakpoints.find(hash);
		} catch (_:NotFound) {
			var h = newIntHashtbl();
			ctx.debug.breakpoints.add(hash, h);
			h;
		}
		var breakpoint = makeBreakpoint(hash, line, BPEnabled, column, condition);
		h.replace(line, breakpoint);
		return breakpoint;
	}

	public static function deleteBreakpoint(ctx:Context, file:String, line:Int):Void {
		var hash = fileHash(ctx, file);
		var h = ctx.debug.breakpoints.find(hash);
		h.remove(line);
	}

	public static function findBreakpoint(ctx:Context, sid:String):Breakpoint {
		var found:Null<Breakpoint> = null;
		var id = Std.parseInt(sid);
		if (id == null || !~/^[-+]?[0-9]+$/.match(sid)) throw NotFound.raise();
		try {
			iterBreakpoints(ctx, function(breakpoint) {
				if (breakpoint.bpid == id) {
					found = breakpoint;
					throw new Exit();
				}
			});
			throw NotFound.raise();
		} catch (_:Exit) {
			return switch found {
				case null: Globals.die("", "evalDebugMisc.ml");
				case breakpoint: breakpoint;
			}
		}
	}

	/* Helper */
	public static function parseExpr(ctx:Context, config:syntax.Parser.ParserConfiguration, s:String, p:Pos):Expr {
		function error(s:String, _:Pos):syntax.Parser.ParseResult<Expr> throw new ParseExprError(s);
		return switch syntax.ParserEntry.parseExprString(config, s, p, error, true) {
			case ParseSuccess(data, _): data;
			case ParseError(_, err, _): throw new ParseExprError(syntax.Parser.errorMsg(err.message));
		}
	}

	/* Vars */
	public static function getVarSlotByName(env:Env, isRead:Bool, scopes:Array<Scope>, name:String):Int {
		var k = scopes.length - 1;
		while (k >= 0) {
			var scope = scopes[k--];
			try {
				var id = scope.localIds.find(name);
				var slot = scope.locals.get(id);
				if (slot == null) throw NotFound.raise();
				var vi = scope.localInfos.find(slot);
				if (isRead && !(declaredBefore(vi, env.envDebug.debugPos))) throw NotFound.raise();
				return slot + scope.localOffset;
			} catch (_:NotFound) {}
		}
		throw NotFound.raise();
	}

	public static function getCaptureSlotByName(captureInfos:OcamlHashtbl<Int, VarInfo>, name:String):Int {
		var ret:Null<Int> = null;
		try {
			captureInfos.iter(function(slot, vi) {
				if (name == vi.viName) {
					ret = slot;
					throw new Exit();
				}
			});
			throw NotFound.raise();
		} catch (_:Exit) {
			return switch ret {
				case null: Globals.die("", "evalDebugMisc.ml");
				case name: name;
			}
		}
	}

	public static function getVariable(captureInfos:OcamlHashtbl<Int, VarInfo>, scopes:Array<Scope>, name:String, env:Env):Value {
		try {
			var slot = getVarSlotByName(env, true, scopes, name);
			var value = env.envLocals[slot];
			return value;
		} catch (_:NotFound) {
			var slot = getCaptureSlotByName(captureInfos, name);
			if (slot < 0 || slot >= env.envCaptures.length) throw NotFound.raise();
			var value = env.envCaptures[slot];
			return value;
		}
	}

	/* Expr to value */
	public static function resolveIdent(ctx:Context, env:Env, s:String):Value {
		var key = EvalHash.hash(s);
		try {
			/* 0. Extra locals */
			return env.envExtraLocals.find(key);
		} catch (_:NotFound) {
			try {
				/* 1. Variable */
				return getVariable(env.envInfo.captureInfos, env.envDebug.scopes, s, env);
			} catch (_:NotFound) {
				try {
					/* 2. Instance */
					if (env.envInfo.isStatic) throw NotFound.raise();
					function loop(env:Env):Env {
						return switch env.envInfo.kind {
							case EKLocalFunction(_):
								switch env.envParent {
									case null: Globals.die("", "evalDebugMisc.ml");
									case env: loop(env);
								}
							case EKMethod(_): env;
							case EKMacro(_): env;
							case EKEntrypoint:
								/* This can happen due to threads. Have to check what we can do here... */
								throw NotFound.raise();
						}
					}
					var env = loop(env);
					var v = env.envLocals[0];
					return EvalField.fieldRaise(v, key);
				} catch (_:NotFound) {
					try {
						/* 3. Static */
						switch env.envInfo.kind {
							case EKMethod(i1, _):
								var proto = EvalContext.getStaticPrototypeRaise(ctx, i1);
								return EvalField.protoFieldRaise(proto, key);
							case _:
								throw NotFound.raise();
						}
					} catch (_:NotFound) {
						try {
							/* 4. Type */
							return VPrototype(EvalContext.getStaticPrototypeRaise(ctx, key));
						} catch (_:NotFound) {
							try {
								/* 5. Toplevel */
								return EvalField.fieldRaise(ctx.toplevel, key);
							} catch (_:NotFound) {
								return VNull;
							}
						}
					}
				}
			}
		}
	}

	public static function findEnumFieldByName(ve:VenumValue, name:Int):Int {
		return switch (EvalContext.getStaticPrototypeRaise(EvalContext.getCtx(), ve.epath)).pkind {
			case PEnum(names):
				var fields = names[ve.eindex].params;
				var i = 0;
				for (field in fields) {
					if (field == name) return i;
					i++;
				}
				throw NotFound.raise();
			case _:
				throw NotFound.raise();
		}
	}

	public static function safeCall<A, R>(eval:Eval, f:A->R, a:A):R {
		var old = eval.debugState;
		eval.debugState = DbgRunning;
		try {
			var r = f(a);
			eval.debugState = old;
			return r;
		} catch (exc:Dynamic) {
			eval.debugState = old;
			throw exc;
		}
	}

	// port: OCaml's Int32.of_string
	static function int32OfString(s:String):Int {
		var i = Std.parseInt(s);
		if (i == null) throw new core.ds.Failure("Int32.of_string");
		return i;
	}

	static function arrayGet(a:haxe.ds.Vector<Value>, i:Int):Value {
		if (i < 0 || i >= a.length) throw new core.ds.InvalidArgument("index out of bounds");
		return a[i];
	}

	static function arraySet(a:haxe.ds.Vector<Value>, i:Int, v:Value):Void {
		if (i < 0 || i >= a.length) throw new core.ds.InvalidArgument("index out of bounds");
		a[i] = v;
	}

	public static function exprToValue(ctx:Context, env:Env, e:Expr):Value {
		function loop(e:Expr):Value {
			switch e.expr {
				case EConst(cst):
					return switch cst {
						case String(s, _): EvalString.createUnknown(s);
						case Int(s, _): VInt32(int32OfString(s));
						case Float(s, _): VFloat(core.Numeric.parseFloat(s));
						case Ident("true"): VTrue;
						case Ident("false"): VFalse;
						case Ident("null"): VNull;
						case Ident(s):
							var value = resolveIdent(ctx, env, s);
							value;
						case _: throw new NoValueExpr();
					}
				case EArray(e1, eidx):
					var v1 = loop(e1);
					var vidx = loop(eidx);
					var idx = switch vidx {
						case VInt32(i): i;
						case _: throw new NoValueExpr();
					}
					return switch v1 {
						case VArray(va): EvalArray.get(va, idx);
						case VVector(vv): arrayGet(vv, idx);
						case VEnumValue(ev): arrayGet(ev.eargs, idx);
						case _: throw new NoValueExpr();
					}
				case EField(e1, s, _):
					var v1 = loop(e1);
					var s2 = EvalHash.hash(s);
					switch v1 {
						case VEnumValue(ve):
							try {
								var i = findEnumFieldByName(ve, s2);
								return ve.eargs[i];
							} catch (_:NotFound) {
								return VNull;
							}
						case _:
							var v = try {
								EvalField.fieldRaise(v1, s2);
							} catch (_:NotFound) {
								try {
									/* Maybe we have a getter? (#8599) */
									var vf = EvalField.field(v1, EvalHash.hash("get_" + s));
									safeCall(env.envEval, EvalPrinting.callValueOn.bind(v1, vf), []);
								} catch (_:Dynamic) {
									VNull;
								}
							}
							return v;
					}
				case EArrayDecl(el):
					var vl = el.mapToArray(loop);
					return EvalEncode.encodeArray(vl);
				case EObjectDecl(fl):
					var fl = fl.mapToArray(f -> {name: f.key.name, value: loop(f.expr)});
					return EvalEncode.encodeObjS(fl);
				case EBinop(op, e1, e2):
					switch op {
						case OpAssign:
							var v2 = loop(e2);
							return writeExpr(ctx, env, e1, v2);
						case OpAssignOp(op):
							throw new NoValueExpr();
						case OpBoolAnd:
							return if (EvalMisc.isTrue(loop(e1))) loop(e2) else VFalse;
						case OpBoolOr:
							return if (EvalMisc.isTrue(loop(e1))) VTrue else loop(e2);
						case OpInterval | OpArrow | OpIn | OpNullCoal:
							throw new NoValueExpr();
						case _:
							var v1 = loop(e1);
							var v2 = loop(e2);
							var p = e.pos;
							return (EvalMisc.getBinopFun(op, p))(v1, v2);
					}
				case EUnop(op, flag, e1):
					switch op {
						case Not:
							return switch loop(e1) {
								case VNull | VFalse: VTrue;
								case _: VFalse;
							}
						case Neg:
							return switch loop(e1) {
								case VFloat(f): VFloat(-f);
								case VInt32(i): EvalValueTools.vint32(-i);
								case _: throw new NoValueExpr();
							}
						case NegBits:
							return EvalMisc.opSub(e.pos, EvalValueTools.vint32(-1), loop(e1));
						case Increment | Decrement | Spread:
							throw new NoValueExpr();
					}
				case ECall(e1, el):
					switch e1.expr {
						case EField(ethis, s, _):
							var vthis = loop(ethis);
							var v1 = EvalField.field(vthis, EvalHash.hash(s));
							var vl = el.mapToArray(loop);
							return safeCall(env.envEval, EvalPrinting.callValueOn.bind(vthis, v1), vl);
						case _:
							var v1 = loop(e1);
							var vl = el.mapToArray(loop);
							return safeCall(env.envEval, EvalMisc.callValue.bind(v1), vl);
					}
				case EBlock(el):
					function loop2(el:Vector<Expr>, i:Int):Value {
						return if (i >= el.length) VNull else if (i == el.length - 1) loop(el[i]) else {
							loop(el[i]);
							loop2(el, i + 1);
						}
					}
					return loop2(el, 0);
				case EIf(e1, e2, eo):
					var v1 = loop(e1);
					return if (EvalMisc.isTrue(v1)) loop(e2) else (eo == null ? VNull : loop(eo));
				case ETernary(e1, e2, e3):
					var v1 = loop(e1);
					return if (EvalMisc.isTrue(v1)) loop(e2) else loop(e3);
				case EParenthesis(e1) | EMeta(_, e1) | EUntyped(e1) | ECast(e1, null) | ECheckType(e1, _):
					return loop(e1);
				case EReturn(e1):
					var v1 = e1 == null ? VNull : loop(e1);
					throw core.ds.FastThrow.of(new Return(v1));
				case EContinue:
					throw Continue.raise();
				case EBreak:
					throw Break.raise();
				case EThrow(e1):
					var v1 = loop(e1);
					return EvalContext.throwValue(v1, e.pos);
				case EVars(vl):
					for (v in vl) {
						switch v.evExpr {
							case null:
							case e:
								env.envExtraLocals = env.envExtraLocals.add(EvalHash.hash(v.evName.name), loop(e));
						}
					}
					return VNull;
				case EWhile(e1, e2, flag):
					function loop2():Void {
						while (EvalMisc.isTrue(loop(e1))) {
							loop(e2);
						}
					}
					if (flag == DoWhile) loop(e2);
					loop2();
					return VNull;
				case ENew(ptp, el):
					function loop2(v:Value, sl:Array<String>):Value {
						for (s in sl) v = EvalField.field(v, EvalHash.hash(s));
						return v;
					}
					var tp = ptp.path;
					var v1 = loop2(ctx.toplevel, tp.tpackage);
					var v1 = loop2(v1, [switch tp.tsub {
						case null: tp.tname;
						case s: s;
					}]);
					var vl = el.mapToArray(loop);
					var vc = loop2(ctx.toplevel, ["Type", "createInstance"]);
					return safeCall(env.envEval, EvalMisc.callValue.bind(vc), [v1, EvalEncode.encodeArray(vl)]);
				case ETry(_) | ESwitch(_) | EFunction(_) | EFor(_) | EDisplay(_) | ECast(_, _) | EIs(_):
					throw new NoValueExpr();
			}
		}
		return loop(e);
	}

	public static function writeExpr(ctx:Context, env:Env, expr:Expr, value:Value):Value {
		switch expr.expr {
			case EField(e1, s, _):
				var s2 = EvalHash.hash(s);
				var v1 = exprToValue(ctx, env, e1);
				switch v1 {
					case VEnumValue(ve):
						try {
							var i = findEnumFieldByName(ve, s2);
							ve.eargs[i] = value;
							return value;
						} catch (_:NotFound) {
							return value;
						}
					case _:
						try {
							EvalMisc.setField(v1, s2, value);
							return value;
						} catch (_:NotFound) {
							try {
								var vf = EvalField.field(v1, EvalHash.hash("set_" + s));
								return safeCall(env.envEval, EvalPrinting.callValueOn.bind(v1, vf), [value]);
							} catch (_:Dynamic) {
								return value;
							}
						}
				}
			case EConst(Ident(s)):
				try {
					var slot = getVarSlotByName(env, false, env.envDebug.scopes, s);
					env.envLocals[slot] = value;
					return value;
				} catch (_:NotFound) {
					throw new NoValueExpr();
				}
			case EArray(e1, e2):
				var v1 = exprToValue(ctx, env, e1);
				var vidx = exprToValue(ctx, env, e2);
				var idx = switch vidx {
					case VInt32(i): i;
					case _: throw new NoValueExpr();
				}
				switch v1 {
					case VArray(va): EvalArray.set(va, idx, value);
					case VVector(vv): arraySet(vv, idx, value);
					case VEnumValue(ev): arraySet(ev.eargs, idx, value);
					case _: throw new NoValueExpr();
				}
				return value;
			case _:
				throw new NoValueExpr();
		}
	}

	public static function exprToValueSafe(ctx:Context, env:Env, e:Expr):Value {
		return try exprToValue(ctx, env, e) catch (_:NoValueExpr) VNull;
	}
}
