package optimization;

import core.Ast;
import core.TType;
import core.TFunctions as TypeOps;
import core.Numeric;
import core.Error;
import context.PurityState.PurityStateTools as PurityState;
import haxe.ds.IntMap;
import haxe.Int64;
import core.ds.VectorTools.vector;

using core.ds.VectorTools;

class OptimizerTexpr {
	// tells if an expression causes side effects. This does not account for potential null accesses (fields/arrays/ops)
	public static function hasSideEffect(e:TExpr):Bool {
		return switch e.eexpr {
			case TConst(_) | TLocal(_) | TTypeExpr(_) | TFunction(_) | TIdent(_): false;
			case TCall({eexpr: TField(e1, fa)}, el) if (PurityState.isPureFieldAccess(fa)): hasSideEffect(e1) || core.ds.ArrayTools.exists(el,
					hasSideEffect);
			case TNew(c, _,
				el) if (c.clConstructor != null && PurityState.isPure(c, c.clConstructor)): core.ds.ArrayTools.exists(el, hasSideEffect);
			case TField(_, fa) if (PurityState.isExplicitlyImpure(fa)): true;
			case TNew(_, _, _) | TCall(_, _) | TBinop(OpAssignOp(_) | OpAssign, _, _) | TUnop(Increment | Decrement, _, _): true;
			case TReturn(_) | TBreak | TContinue | TThrow(_): true;
			case TCast(_, mt) if (mt != null): true;
			case _: core.Texpr.checkExpr(hasSideEffect, e);
		};
	}

	public static function isReadOnlyFieldAccess(e:TExpr, fa:TFieldAccess):Bool {
		return switch fa {
			case FEnum(_, _): true;
			case FDynamic(_): false;
			case FAnon({cfKind: Var({vWrite: AccNo})}) if (switch e.eexpr {
					case TIdent(_): true;
					case _: false;
				}): true;
			case FInstance(c, _, cf) | FStatic(c, cf) | FClosure({cls: c}, cf):
				switch cf.cfKind {
					case Method(MethDynamic): false;
					case Method(_): true;
					case Var({vWrite: AccNever}) if (!TypeOps.hasClassFlag(c, CInterface)): true;
					case _: false;
				}
			case FAnon(cf) | FClosure(null, cf): switch cf.cfKind {
					case Method(MethDynamic): false;
					case Method(_): true;
					case _: false;
				}
		};
	}

	public static function createAffectionChecker():{mightBeAffected:TExpr->Bool, collectModifiedLocals:TExpr->Void} {
		var modifiedLocals = new IntMap<Bool>();
		function mightBeAffected(e:TExpr):Bool return switch e.eexpr {
			case TConst(_) | TFunction(_) | TTypeExpr(_): false;
			case TLocal(v) if (TypeOps.hasVarFlag(v, VCaptured)): true;
			case TLocal(v) if (modifiedLocals.exists(v.vId)): true;
			case TField(e1, fa) if (!isReadOnlyFieldAccess(e1, fa)): true;
			case TCall(_, _) | TNew(_, _, _): true;
			case _: core.Texpr.checkExpr(mightBeAffected, e);
		};
		function collectModifiedLocals(e:TExpr):Void switch e.eexpr {
			case TUnop(Increment | Decrement, _, {eexpr: TLocal(v)}):
				modifiedLocals.set(v.vId, true);
			case TBinop(OpAssign | OpAssignOp(_), {eexpr: TLocal(v)}, e2):
				collectModifiedLocals(e2);
				modifiedLocals.set(v.vId, true);
			case _:
				core.Texpr.iter(collectModifiedLocals, e);
		}
		return {mightBeAffected: mightBeAffected, collectModifiedLocals: collectModifiedLocals};
	}

	public static function optimizeBinop(scom:context.SafeCom.SafeContext, e:TExpr, op:Binop, e1:TExpr, e2:TExpr):TExpr {
		inline function isFloat(t:T):Bool return switch TypeOps.follow(t) {
			case TAbstract({aPath: {pack: [], name: "Float"}}, _): true;
			case _: false;
		};
		inline function isNumeric(t:T):Bool return switch TypeOps.follow(t) {
			case TAbstract({aPath: {pack: [], name: "Float" | "Int"}}, _): true;
			case _: false;
		};
		function constant(c:TConstant):TExpr return TypeOps.mk(TConst(c), e.etype, e.epos);
		inline function checkFloat(fn:Float->Float->Float, f1:Float, f2:Float):TExpr {
			var f = fn(f1, f2);
			var fstr = Numeric.floatRepres(f);
			return Math.isFinite(f) && core.ds.OcamlFloat.ofString(fstr) == f ? constant(TFloat(fstr)) : e;
		}
		inline function comparison(a:Float, b:Float):TExpr {
			// port: OCaml compare gives NaN a total ordering; preserve that distinction from IEEE comparisons.
			var cmp = Math.isNaN(a) ? (Math.isNaN(b) ? 0 : -1) : Math.isNaN(b) ? 1 : a < b ? -1 : a > b ? 1 : 0;
			return switch op {
				case OpEq: constant(TBool(cmp == 0));
				case OpNotEq: constant(TBool(cmp != 0));
				case OpGt: constant(TBool(cmp > 0));
				case OpGte: constant(TBool(cmp >= 0));
				case OpLt: constant(TBool(cmp < 0));
				case OpLte: constant(TBool(cmp <= 0));
				case _: e;
			};
		}
		return switch [e1.eexpr, e2.eexpr] {
			case [TConst(TInt(0)), _] if (op == OpAdd && isNumeric(e2.etype)): e2;
			case [TConst(TInt(1)), _] if (op == OpMult): e2;
			case [TConst(TFloat(v)), _] if (op == OpAdd && core.ds.OcamlFloat.ofString(v) == 0 && isFloat(e2.etype)): e2;
			case [TConst(TFloat(v)), _] if (op == OpMult && core.ds.OcamlFloat.ofString(v) == 1 && isFloat(e2.etype)): e2;
			case [_, TConst(TInt(0))] if (switch op {
					case OpAdd: isNumeric(e1.etype);
					case OpSub | OpShr | OpShl: true;
					case _: false;
				}): e1; // bits operations might cause overflow
			case [_, TConst(TInt(1))] if (op == OpMult): e1;
			case [_, TConst(TFloat(v))] if ((op == OpAdd || op == OpSub) && core.ds.OcamlFloat.ofString(v) == 0 && isFloat(e1.etype)): e1; // bits operations might cause overflow
			case [_, TConst(TFloat(v))] if (op == OpMult && core.ds.OcamlFloat.ofString(v) == 1 && isFloat(e1.etype)): e1;
			case [TConst(TNull), TConst(TNull)]: switch op {
					case OpEq: constant(TBool(true));
					case OpNotEq: constant(TBool(false));
					case _: e;
				}
			case [TFunction(_), TConst(TNull)] | [TConst(TNull), TFunction(_)]: switch op {
					case OpEq: constant(TBool(false));
					case OpNotEq: constant(TBool(true));
					case _: e;
				}
			case [TConst(TInt(a)), TConst(TInt(b))]:
				inline function checkOverflow(fn:Int64->Int64->Int64):TExpr {
					var value = fn(Int64.ofInt(a), Int64.ofInt(b));
					var iv = value.low;
					return Int64.compare(Int64.ofInt(iv), value) == 0 ? constant(TInt(iv)) : e;
				}
				switch op {
					case OpAdd: checkOverflow((a, b) -> a + b);
					case OpSub: checkOverflow((a, b) -> a - b);
					case OpMult: checkOverflow((a, b) -> a * b);
					case OpDiv: checkFloat((a, b) -> a / b, a, b);
					case OpAnd: constant(TInt(a & b));
					case OpOr: constant(TInt(a | b));
					case OpXor: constant(TInt(a ^ b));
					case OpShl if (isNumeric(e.etype)): constant(TInt(a << (b & 31)));
					case OpShr if (isNumeric(e.etype)): constant(TInt(a >> (b & 31)));
					case OpUShr if (isNumeric(e.etype)): constant(TInt(a >>> (b & 31)));
					case OpEq | OpNotEq | OpGt | OpGte | OpLt | OpLte: comparison(a, b);
					case _: e;
				}
			case [TConst(ca = TFloat(_) | TInt(_)), TConst(cb = TFloat(_) | TInt(_))]:
				inline function number(c:TConstant):Float return switch c {
					case TFloat(f): core.ds.OcamlFloat.ofString(f);
					case TInt(i): i;
					case _: throw "optimizerTexpr: numeric constant";
				};
				var a = number(ca);
				var b = number(cb);
				switch op {
					case OpAdd: checkFloat((a, b) -> a + b, a, b);
					case OpDiv: checkFloat((a, b) -> a / b, a, b);
					case OpSub: checkFloat((a, b) -> a - b, a, b);
					case OpMult: checkFloat((a, b) -> a * b, a, b);
					case OpEq | OpNotEq | OpGt | OpGte | OpLt | OpLte: comparison(a, b);
					case _: e;
				}
			case [TConst(TString("")), TConst(TString(s))] | [TConst(TString(s)), TConst(TString(""))] if (op == OpAdd): constant(TString(s));
			case [TConst(TBool(a)), TConst(TBool(b))]: switch op {
					case OpEq: constant(TBool(a == b));
					case OpNotEq: constant(TBool(a != b));
					case OpBoolAnd: constant(TBool(a && b));
					case OpBoolOr: constant(TBool(a || b));
					case _: e;
				}
			case [TConst(a), TConst(b)] if (op == OpEq || op == OpNotEq):
				var result = switch [a, b] {
					case [TInt(a), TFloat(b)] | [TFloat(b), TInt(a)]: a == core.ds.OcamlFloat.ofString(b);
					case [TNull, TInt(_) | TFloat(_) | TBool(_)] | [TInt(_) | TFloat(_) | TBool(_), TNull]
						if (scom.platformConfig.pfStatic): return e;
					case _: Type.enumEq(a, b);
				};
				constant(TBool(op == OpEq ? result : !result));
			case [TConst(TBool(a)), _]: switch op {
					case OpBoolAnd: a ? e2 : constant(TBool(false));
					case OpBoolOr: a ? constant(TBool(true)) : e2;
					case _: e;
				}
			case [_, TConst(TBool(a))]: switch op {
					case OpBoolAnd if (a): e1;
					case OpBoolOr if (!a): e1;
					case _: e;
				}
			case [TField(_, FEnum(en1, f1)), TField(_, FEnum(en2, f2))] if (en1 == en2): switch op {
					case OpEq: constant(TBool(f1 == f2));
					case OpNotEq: constant(TBool(f1 != f2));
					case _: e;
				}
			case [other, TCall({eexpr: TField(_, FEnum(_, _))}, el)] | [TCall({eexpr: TField(_, FEnum(_, _))}, el), other]:
				switch [op, other] {
					case [OpEq | OpNotEq, TConst(TNull)]: TypeOps.mk(TBlock(el.concat(vector(constant(TBool(op == OpNotEq))))), e.etype, e.epos);
					case [OpAssign, _]: e;
					case _: Error.raiseTypingError("You cannot directly compare enums with arguments. Use either `switch`, `match` or `Type.enumEq`",
							e.epos);
				}
			case _: e;
		};
	}

	public static function optimizeUnop(e:TExpr, op:Unop, flag:UnopFlag, esub:TExpr):TExpr {
		inline function isInt(t:T):Bool return switch TypeOps.follow(t) {
			case TAbstract({aPath: {pack: [], name: "Int"}}, _): true;
			case _: false;
		};
		return switch [op, esub.eexpr] {
			case [Not, _]:
				function transform(e:TExpr, esub:TExpr):TExpr return switch esub.eexpr {
					case TConst(TBool(f)): TypeOps.mk(TConst(TBool(!f)), e.etype, e.epos);
					case TBinop(op, e1, e2):
						var integers = isInt(e1.etype) && isInt(e2.etype);
						var newOp = switch op {
							case OpGt if (integers): OpLte;
							case OpGte if (integers): OpLt;
							case OpLt if (integers): OpGte;
							case OpLte if (integers): OpGt;
							case OpEq: OpNotEq;
							case OpNotEq: OpEq;
							case _: null;
						};
						newOp == null ? e : TypeOps.mk(TBinop(newOp, e1, e2), e.etype, e.epos);
					case TParenthesis(e1): transform(e, e1);
					case TMeta(m,
						e1): TypeOps.mk(TMeta(m, transform(TypeOps.mk(TUnop(op, flag, e1), e1.etype, e1.epos), e1)), e.etype, e.epos);
					case _: e;
				};
				transform(e, esub);
			case [Neg, TConst(TInt(i))]: TypeOps.mk(TConst(TInt((-i) | 0)), e.etype, e.epos); // port: Int32.neg wraps
			case [NegBits, TConst(TInt(i))]: TypeOps.mk(TConst(TInt(~i)), e.etype, e.epos);
			case [Neg, TConst(TFloat(f))]:
				var v = 0.0 - core.ds.OcamlFloat.ofString(f);
				var str = Numeric.floatRepres(v);
				core.ds.OcamlFloat.ofString(str) == v ? TypeOps.mk(TConst(TFloat(str)), e.etype, e.epos) : e;
			case _: e;
		};
	}
}
