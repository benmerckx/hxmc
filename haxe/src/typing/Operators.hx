package typing;

import core.DisplayTypes.DisplayModeValue;
import core.Error;
import core.Error.*;
import core.TPrinting.Printer;
import core.Texpr;
import core.TUnification.Monomorph;
import core.TUnification.Unify_error as UnificationFailure;
import core.TUnification.EqKind;
import core.Message.WarningCode;
import core.ds.NotFound;
import context.Common;
import context.SafeCom;
import typing.TyperBase.*;
import typing.TyperBase;
import typing.FieldAccess.*;
import typing.FieldAccess as FieldAccessTools;
import optimization.Optimizer;
import core.Ast.*;

using Lambda;
using core.ds.ArrayTools;
using core.ds.VectorTools;

import core.WithType as WithTypeTools;
import core.WithType.WithTypeValue;
import core.MetaList.StrictMeta as MetaTag;
import core.Globals.Pos;
import core.TType;
import core.Ast;
import core.Globals.*;
import core.TFunctions.*;
import core.TOther.*;
import core.TOther;
import core.WithType;
import context.Typecore.*;
import context.Typecore;
import typing.Calls.*;
import core.ds.VectorTools.vector;
import haxe.ds.Vector;
import typing.Fields.*;

typedef NormalBinop = {var binopOp:Binop; var binopLhs:TExpr; var binopRhs:TExpr; var binopType:T; var binopNeedsAssign:Bool; var binopSwapped:Bool; var binopPos:Pos;}

enum BinopResultData {
	BinopNormal(data:NormalBinop);
	BinopSpecial(e:TExpr, needsAssign:Bool);
}

class BinopResult {
	public static function toString(br:BinopResultData):String {
		function st(t:T):String return core.TPrinting.sType(core.TPrinting.printContext(), t);
		inline function se(e:TExpr):String return core.TPrinting.sExprPretty(false, "", false, st, e);
		return switch br {
			case BinopNormal(b): Printer.sRecordFields("", [
					{name: "binop_op", value: sBinop(b.binopOp)},
					{name: "binop_lhs", value: se(b.binopLhs)},
					{name: "binop_rhs", value: se(b.binopRhs)},
					{name: "binop_type", value: st(b.binopType)},
					{name: "binop_needs_assign", value: Std.string(b.binopNeedsAssign)},
					{name: "binop_swapped", value: Std.string(b.binopSwapped)},
					{name: "binop_pos", value: Printer.sPos(b.binopPos)}
				]);
			case BinopSpecial(e, assign): 'BinopSpecial(${se(e)},$assign)';
		};
	}

	public static function createNormal(op:Binop, e1:TExpr, e2:TExpr, t:T, needs:Bool, swapped:Bool,
			p:Pos):BinopResultData return BinopNormal({
			binopOp: op,
			binopLhs: e1,
			binopRhs: e2,
			binopType: t,
			binopNeedsAssign: needs,
			binopSwapped: swapped,
			binopPos: p
		});

	public static function createSpecial(e:TExpr, needs:Bool):BinopResultData return BinopSpecial(e, needs);

	public static function toTexpr(vr:ValueReference, br:BinopResultData, assign:TExpr->TExpr):TExpr return switch br {
		case BinopNormal(b):
			var lhs = b.binopLhs, rhs = b.binopRhs;
			if (b.binopSwapped) {
				var first = vr.asVar("lhs", rhs);
				var second = vr.asVar("rhs", lhs);
				lhs = second;
				rhs = first;
			}
			var e = mk(TBinop(b.binopOp, lhs, rhs), b.binopType, b.binopPos);
			b.binopNeedsAssign ? assign(e) : e;
		case BinopSpecial(e, needs): needs ? assign(e) : e;
	};

	public static function getType(br:BinopResultData):T return switch br {
		case BinopNormal(b): b.binopType;
		case BinopSpecial(e, _): e.etype;
	};

	public static function needsAssign(br:BinopResultData):Bool return switch br {
		case BinopNormal(_): true;
		case BinopSpecial(_, needs): needs;
	};
}

enum TypeClass {
	KInt;
	KFloat;
	KString;
	KUnk;
	KDyn;
	KOther;
	KNumParam(t:T);
	KStrParam(t:T);
	KAbstract(a:TAbstract, tl:core.TType.TParams);
}

typedef AssignOpApi<A> = {
	var aknoFallback:Void->TExpr;
	var typeRhs:TExpr->Expr->A;
	var toTexpr:ValueReference->A->(TExpr->TExpr)->TExpr;
	var generate:ValueReference->TExpr->TExpr->TExpr;
	var assign:ValueReference->TExpr->A->TExpr;
}

class Operators {
	public static function checkError(ctx:Typer, err:CompilerError):Void {
		switch err.errMessage {
			case ModuleNotFound({pack: [], name: name}) if (context.display.Diagnostics.errorInDiagnosticsRun(ctx.com, err.errPos)):
				context.display.DisplayToplevel.handleUnresolvedIdentifier(ctx, name, err.errPos, true);
			case _:
				raiseOrDisplayError(ctx, err);
		}
	}

	public static function checkAssign(ctx:Typer, e:TExpr):Void switch e.eexpr {
		case TLocal(v) if (hasVarFlag(v, VFinal) && !Common.ignoreError(ctx.com)):
			Error.raiseTypingError("Cannot assign to final", e.epos);
		case TLocal({vExtra: null}) | TArray(_, _) | TField(_, _) | TIdent(_):
		case TConst(TThis) | TTypeExpr(_) if (ctx.f.isUntyped):
		case _:
			if (!Common.ignoreError(ctx.com)) invalidAssign(e.epos);
	};

	public static function classify(t:T):TypeClass {
		function num(t:T):Bool return switch classify(t) {
			case KInt | KFloat: true;
			case _: false;
		};
		function str(t:T):Bool return classify(t) == KString;
		return switch follow(t) {
			case TInst({clPath: {pack: [], name: "String"}}, []): KString;
			case TAbstract(a = {aImpl: c}, tl) if (c != null): KAbstract(a, tl);
			case TAbstract({aPath: {pack: [], name: "Int"}}, []): KInt;
			case TAbstract({aPath: {pack: [], name: "Float"}}, []): KFloat;
			case TAbstract(a, []) if (a.aTo.exists(num)): KNumParam(t);
			case TInst({clKind: KTypeParameter(ttp)}, _) if (getConstraints(ttp).exists(num)): KNumParam(t);
			case TAbstract(a, []) if (a.aTo.exists(str)): KStrParam(t);
			case TInst({clKind: KTypeParameter(ttp)}, _) if (getConstraints(ttp).exists(str)): KStrParam(t);
			case TMono(r) if (r.tmType == null): KUnk;
			case TDynamic(_): KDyn;
			case _: KOther;
		};
	}

	/*
		We want to try unifying as an integer and apply side effects.
		However, in case the value is not a normal Monomorph but one issued
		from a Dynamic relaxation, we will instead unify with float since
		we don't want to accidentaly truncate the value
	*/
	public static function unifyInt(ctx:Typer, e:TExpr, k:TypeClass):Bool {
		inline function dyn(t:T):Bool return switch follow(t) {
			case TDynamic(_): true;
			case _: false;
		};
		inline function dynArray(t:T):Bool return switch follow(t) {
			case TInst(_, [p]): dyn(p);
			case _: true;
		};
		inline function dynField(t:T, f:String):Bool return switch follow(t) {
			case TAnon(a): var cf = a.aFields.get(f); cf != null && dyn(cf.cfType);
			case TMono(m): switch Monomorph.classifyDownConstraints(m) {
					case CStructural(fields, _): var cf = fields.get(f); cf != null && dyn(cf.cfType);
					case _: true;
				}
			case TInst(c, tl): try dyn(applyParams(c.clParams, tl, core.TFunctions.classField(c, tl, f)
					.type)) catch (ex:NotFound) false;
			case _: true;
		};
		inline function dynReturn(t:T):Bool return switch follow(t) {
			case TFun(s): dyn(s.ret);
			case _: true;
		};
		var maybe:TExpr->Bool = null;
		inline function recurse(e:TExpr, t:T):Bool return switch follow(t) {
			case TMono(_) | TDynamic(_): maybe(e);
			// we might have inferenced a tmono into a single field
			// TODO: check what this did exactly
			// | TAnon a when !(a.a_status) = Opened -> maybe_dynamic_mono e
			case _: false;
		};
		/*
			This is some quick analysis that matches the most common cases of dynamic-to-mono convertions
		*/
		maybe = function(e) return switch e.eexpr {
			case TLocal(_): dyn(e.etype);
			case TArray(e, _): dynArray(e.etype) || recurse(e, e.etype);
			case TField(e, f): dynField(e.etype, fieldName(f)) || recurse(e, e.etype);
			case TCall(e, _): dynReturn(e.etype) || recurse(e, e.etype);
			case TParenthesis(e) | TMeta(_, e): maybe(e);
			case TIf(_, a, b) if (b != null): maybe(a) || maybe(b);
			case _: false;
		};
		if ((k == KUnk || k == KDyn) && maybe(e)) {
			unify(ctx, e.etype, ctx.t.tfloat, e.epos);
			return false;
		}
		unify(ctx, e.etype, ctx.t.tint, e.epos);
		return true;
	}

	static function unificationError(ex:Dynamic):Bool return switch ex {
		case(core.ds.ExceptionTools.typing(_) => Some({errMessage: Unify(_)})): true;
		case _: false;
	};

	public static function makeBinop(ctx:Typer, op:Binop, e1:TExpr, e2:TExpr, isAssign:Bool, p:Pos):BinopResultData {
		var tint = ctx.t.tint, tfloat = ctx.t.tfloat, tstring = ctx.t.tstring;
		function toString(e:TExpr):TExpr {
			function loop(t:T):TExpr return switch classify(t) {
				case KAbstract({aImpl: c}, _) if (c != null && c.clStatics.exists("toString")): Calls.callToString(ctx, e);
				case KInt | KFloat | KString: e;
				case KUnk | KDyn | KNumParam(_) | KStrParam(_) | KOther: Texpr.Builder.resolveAndMakeStaticCall(ctx.com.std, "string",
						vector(e), e.epos);
				case KAbstract(a, tl): try context.AbstractCast.castOrUnifyRaise(ctx, tstring, e, p) catch (ex:Dynamic) {
						if (!unificationError(ex)) throw ex;
						loop(core.Abstract.getUnderlyingType(a, tl));
					}
			};
			return loop(e.etype);
		}
		inline function mkOp(a:TExpr, b:TExpr, t:T):BinopResultData {
			if (op == OpAdd && classify(t) == KString) {
				a = toString(a);
				b = toString(b);
			}
			return BinopResult.createNormal(op, a, b, t, isAssign, false, p);
		}
		inline function cannot(action:String):Dynamic {
			var pr = core.TPrinting.printContext();
			return Error.raiseTypingError('Cannot $action ${core.TPrinting.sType(pr, e1.etype)} and ${core.TPrinting.sType(pr, e2.etype)}',
				p);
		}
		return switch op {
			case OpAdd:
				var t = switch [classify(e1.etype), classify(e2.etype)] {
					case [KInt, KInt]: tint;
					case [KFloat, KInt] | [KInt, KFloat] | [KFloat, KFloat]: tfloat;
					case [KUnk, KInt]: unifyInt(ctx, e1, KUnk) ? tint : tfloat;
					case [KUnk, KFloat] | [KUnk, KString]: e2.etype;
					case [KInt, KUnk]: unifyInt(ctx, e2, KUnk) ? tint : tfloat;
					case [KFloat, KUnk] | [KString, KUnk]: e1.etype;
					case [_, KString] | [KString, _]: tstring;
					case [_, KDyn]: e2.etype;
					case [KDyn, _]: e1.etype;
					case [KUnk, KUnk]: var a = unifyInt(ctx, e1, KUnk); var b = unifyInt(ctx, e2, KUnk); a && b ? tint : tfloat;
					case [KNumParam(a), KNumParam(b)] if (core.TUnification.typeIseq(a, b)): a;
					case [KNumParam(t), KInt] | [KInt, KNumParam(t)]: t;
					case [KNumParam(_), KFloat] | [KFloat, KNumParam(_)] | [KNumParam(_), KNumParam(_)]: tfloat;
					case [KNumParam(_), KUnk]:
						unify(ctx, e2.etype, tfloat, e2.epos);
						tfloat;
					case [KUnk, KNumParam(_)]:
						unify(ctx, e1.etype, tfloat, e1.epos);
						tfloat;
					case [KStrParam(_), _] | [_, KStrParam(_)]: tstring;
					case [KAbstract(_, _), KFloat]:
						unify(ctx, e1.etype, tfloat, e1.epos);
						tfloat;
					case [KFloat, KAbstract(_, _)]:
						unify(ctx, e2.etype, tfloat, e2.epos);
						tfloat;
					case [KAbstract(_, _), KInt]:
						unify(ctx, e1.etype, tint, e1.epos);
						tint;
					case [KInt, KAbstract(_, _)]:
						unify(ctx, e2.etype, tint, e2.epos);
						tint;
					case _: cannot("add");
				};
				mkOp(e1, e2, t);
			case OpAnd | OpOr | OpXor | OpShl | OpShr | OpUShr:
				unify(ctx, e1.etype, tint, e1.epos);
				unify(ctx, e2.etype, tint, e2.epos);
				mkOp(e1, e2, tint);
			case OpMod | OpMult | OpDiv | OpSub:
				var result = op == OpDiv ? tfloat : tint;
				switch [classify(e1.etype), classify(e2.etype)] {
					case [KFloat, KFloat]: result = tfloat;
					case [KNumParam(a), KNumParam(b)] if (core.TUnification.typeIseq(a, b)): if (op != OpDiv || (switch follow(e1.etype) {
							case TAbstract({aPath: {pack: [], name: "Single"}}, _): true;
							case _: false;
						})) result = a;
					case [KNumParam(_), KNumParam(_)]: result = tfloat;
					case [KNumParam(t), KInt] | [KInt, KNumParam(t)]: if (op != OpDiv) result = t;
					case [KNumParam(_), KFloat] | [KFloat, KNumParam(_)]: result = tfloat;
					case [KFloat, k]:
						unifyInt(ctx, e2, k);
						result = tfloat;
					case [k, KFloat]:
						unifyInt(ctx, e1, k);
						result = tfloat;
					case [a, b]:
						var ok1 = unifyInt(ctx, e1, a);
						var ok2 = unifyInt(ctx, e2, b);
						if (!ok1 || !ok2) result = tfloat;
				}
				mkOp(e1, e2, result);
			case OpEq | OpNotEq:
				try {
					// we only have to check one type here, because unification fails if one is Void and the other is not
					switch follow(e2.etype) {
						case TAbstract({aPath: {pack: [], name: "Void"}}, _): Error.raiseTypingError("Cannot compare Void", p);
						case _:
					}
					e1 = context.AbstractCast.castOrUnifyRaise(ctx, e2.etype, e1, p);
				} catch (ex:Dynamic) {
					if (!unificationError(ex)) throw ex;
					e2 = context.AbstractCast.castOrUnify(ctx, e1.etype, e2, p);
				}
				switch [e1.eexpr, e2.eexpr] {
					case [TConst(TNull), _] | [_, TConst(TNull)]:
					case _: switch [follow(e1.etype), follow(e2.etype)] {
							case [TFun(_), _] | [_, TFun(_)] if (!ctx.com.config.pfSupportsFunctionEquality): warning(ctx,
									WClosureCompare,
									"Comparison of function values is unspecified on this target, use Reflect.compareMethods instead", p);
							case [TEnum(en,
								_), _] | [_, TEnum(en,
									_)]: if (!core.Meta.has(MetaTag.FlatEnum,
									en.eMeta)) warning(ctx, WUnsafeEnumEquality,
										"Equality operations on this enum might lead to unexpected results because some constructors have arguments",
										p);
							case _:
						}
				}
				mkOp(e1, e2, ctx.t.tbool);
			case OpGt | OpGte | OpLt | OpLte:
				switch [classify(e1.etype), classify(e2.etype)] {
					case [KInt, KInt] | [KInt, KFloat] | [KFloat, KInt] | [KFloat, KFloat] | [KString, KString]:
					case [KInt, KUnk]: unifyInt(ctx, e2, KUnk);
					case [KFloat, KUnk] | [KString, KUnk]: unify(ctx, e2.etype, e1.etype, e2.epos);
					case [KUnk, KInt]: unifyInt(ctx, e1, KUnk);
					case [KUnk, KFloat] | [KUnk, KString]: unify(ctx, e1.etype, e2.etype, e1.epos);
					case [KUnk, KUnk]:
						unifyInt(ctx, e1, KUnk);
						unifyInt(ctx, e2, KUnk);
					case [KDyn, KInt | KFloat | KString] | [KInt | KFloat | KString, KDyn] | [KDyn, KDyn]:
					case [KNumParam(_), KInt | KFloat | KNumParam(_) | KDyn | KUnk] | [KInt | KFloat | KDyn | KUnk, KNumParam(_)]:
					case [KStrParam(_), KString | KStrParam(_) | KUnk | KDyn] | [KString | KUnk | KDyn, KStrParam(_)]:
					case _: cannot("compare");
				}
				mkOp(e1, e2, ctx.t.tbool);
			case OpBoolAnd | OpBoolOr:
				unify(ctx, e1.etype, ctx.t.tbool, p);
				unify(ctx, e2.etype, ctx.t.tbool, p);
				mkOp(e1, e2, ctx.t.tbool);
			case OpInterval:
				var t = Typeload.loadInstance(ctx, makePtp(mkTypePath(["std"], "IntIterator"), nullPos), ParamNormal, LoadNormal);
				e1 = context.AbstractCast.castOrUnifyRaise(ctx, tint, e1, e1.epos);
				e2 = context.AbstractCast.castOrUnifyRaise(ctx, tint, e2, e2.epos);
				var c = switch t {
					case TInst(c, []): c;
					case _: throw "assert";
				};
				BinopSpecial(mk(TNew(c, vector(), vector(e1, e2)), t, p), false);
			case OpArrow: Error.raiseTypingError("Unexpected =>", p);
			case OpIn: Error.raiseTypingError("Unexpected in", p);
			case OpNullCoal | OpAssign | OpAssignOp(_): throw "assert";
		};
	}

	public static function findAbstractBinopOverload(ctx:Typer, op:Binop, e1:TExpr, e2:TExpr, a:TAbstract, c:TClass, tl:core.TType.TParams,
			left:Bool, isAssign:Bool, p:Pos):BinopResultData {
		inline function mapA(t:T):T return applyParams(a.aParams, tl, t);
		inline function make(opCf:Binop, cf:TClassField, e1:TExpr, e2:TExpr, ret:T, needs:Bool, swapped:Bool):BinopResultData {
			if (cf.cfExpr == null && !hasClassFieldFlag(cf, CfExtern)) {
				if (!core.Meta.has(MetaTag.NoExpr, cf.cfMeta)) Common.displayError(ctx.com, "Recursive operator method", p);
				if (!core.Meta.has(MetaTag.CoreType, a.aMeta)) {
					// for non core-types we require that the return type is compatible to the native result type
					var result = makeBinop(ctx, op, core.ds.Record.withFields(e1, {etype: core.Abstract.followWithAbstracts(e1.etype)}),
						core.ds.Record.withFields(e1, {etype: core.Abstract.followWithAbstracts(e2.etype)}), isAssign, p);
					var expected = BinopResult.getType(result);
					try {
						unifyRaise(ret, expected, p);
					} catch (ex:Dynamic) {
						if (!unificationError(ex)) throw ex;
						var compatible = switch follow(ret) {
							case TAbstract(a, tl): core.TUnification.typeIseq(core.Abstract.getUnderlyingType(a, tl), expected);
							case _: false;
						};
						if (!compatible)
							Error.raiseTypingError('The result of this operation (${core.TPrinting.sType(core.TPrinting.printContext(), expected)}) is not compatible with declared return type ${core.TPrinting.sType(core.TPrinting.printContext(), ret)}',
								p);
					}
				}
				/*
					If the `@:op`-field has no expr, then user wants the semantics of an underlying type.
					which is supposed to make an assignment for AssignOp's.
					Hence we use `is_assign_op` here instead of `needs_assign`.
				*/
				return BinopResult.createNormal(op, e1, e2, ret, isAssign, swapped, p);
			}
			if (swapped) {
				var vr = new TyperBase.ValueReference(ctx);
				var e2 = vr.asVar("lhs", e2);
				var e1 = vr.asVar("rhs", e1);
				var e = CallUnification.makeStaticCallBetter(ctx, c, cf, tl, vector(e1, e2), ret, p);
				return BinopResult.createSpecial(vr.toTexpr(e), needs);
			}
			return BinopResult.createSpecial(CallUnification.makeStaticCallBetter(ctx, c, cf, tl, vector(e1, e2), ret, p), needs);
		}
		// special case for == and !=: if the second type is a monomorph, assume that we want to unify
		// it with the first type to preserve comparison semantics.
		var eq = op == OpEq || op == OpNotEq;
		if (eq) switch [follow(e1.etype), follow(e2.etype)] {
			case [TMono(_), _] | [_, TMono(_)]:
				try core.TUnification.unify(e1.etype, e2.etype)
				catch (ex:UnificationFailure) {} // this will fail later again
			case _:
		}
		function loop(findOp:Binop, ops:Array<{op:Binop, field:TClassField}>):BinopResultData {
			for (entry in ops) {
				var opCf:Binop = entry.op;
				var cf:TClassField = entry.field;
				if (!Type.enumEq(opCf, findOp)) continue;
				var impl = hasClassFieldFlag(cf, CfImpl);
				var sig = switch follow(cf.cfType) {
					case TFun(s): s;
					case _: throw "assert";
				};
				if (sig.args.length < 2) throw "assert";
				if (sig.args.length > 2 && !(sig.args.length == 3 && sig.args[2].optional && isPosInfos(sig.args[2].type)))
					throw 'Unexpected arguments list of function ${cf.cfName}';
				function check(e1:TExpr, e2:TExpr, swapped:Bool):BinopResultData {
					var monos = Monomorph.spawnConstrainedMonos(function(t) return t, cf.cfParams);
					function mapper(t:T):T return mapA(applyParams(cf.cfParams, monos, t));
					var t1 = mapper(sig.args[0].type),
						t2 = mapper(sig.args[1].type),
						ret = mapper(sig.ret);
					if (impl) t1 = core.Abstract.followWithAbstracts(t1);
					if (left || !left && swapped) {
						core.TUnification.typeEq(EqStrict, impl ? core.Abstract.followWithAbstracts(e1.etype) : e1.etype, t1);
						e2 = context.AbstractCast.castOrUnifyRaise(ctx, t2, e2, p);
					} else {
						core.TUnification.typeEq(EqStrict, e2.etype, t2);
						e1 = context.AbstractCast.castOrUnifyRaise(ctx, t1, e1, p);
					}
					function checkNull(e:TExpr, t:T):Void if (eq) switch e.eexpr {
						case TConst(TNull) if (!isExplicitNull(t)):
							throw new UnificationFailure([]);
						case _:
					}
					// If either expression is `null` we only allow operator resolving if the argument type
					// is explicitly Null<T> (issue #3376)
					if (eq) {
						checkNull(e2, t2);
						checkNull(e1, t1);
					}
					return make(opCf, cf, e1, e2, ret, isAssign && Type.enumEq(opCf, op), swapped);
				}
				try {
					return check(e1, e2, false);
				} catch (_:UnificationFailure) {} catch (ex:Dynamic) {
					if (!unificationError(ex)) throw ex;
				}
				try {
					if (!core.Meta.has(MetaTag.Commutative, cf.cfMeta)) throw NotFound.raise();
					return check(e2, e1, true);
				} catch (_:NotFound) {} catch (_:UnificationFailure) {} catch (ex:Dynamic) {
					if (!unificationError(ex)) throw ex;
				}
			}
			throw NotFound.raise();
		}
		var ops = left ? a.aOps : a.aOps.filter(function(o) return !hasClassFieldFlag(o.field, CfImpl)
			|| core.Meta.has(MetaTag.Commutative, o.field.cfMeta));
		if (isAssign) try {
			return loop(OpAssignOp(op), ops);
		} catch (ex:NotFound) {}
		return loop(op, ops);
	}

	public static function tryAbstractBinopOverloads(ctx:Typer, op:Binop, e1:TExpr, e2:TExpr, isAssign:Bool, p:Pos):BinopResultData {
		try {
			return switch follow(e1.etype) {
				case TAbstract(a = {aImpl: c}, tl) if (c != null): findAbstractBinopOverload(ctx, op, e1, e2, a, c, tl, true, isAssign, p);
				case _: throw NotFound.raise();
			};
		} catch (ex:NotFound) {}
		return switch follow(e2.etype) {
			case TAbstract(a = {aImpl: c}, tl) if (c != null): findAbstractBinopOverload(ctx, op, e1, e2, a, c, tl, false, isAssign, p);
			case _: throw NotFound.raise();
		};
	}

	public static function typeBinopRhs(ctx:Typer, op:Binop, e1:TExpr, e2:Expr, isAssign:Bool, wt:WithTypeValue,
			p:Pos):TExpr return typeExpr(ctx, e2, switch op {
			case OpEq | OpNotEq | OpLt | OpLte | OpGt | OpGte: WithTypeTools.withType(e1.etype);
			case _: wt;
		});

	public static function typeBinop2(ctx:Typer, op:Binop, e1:TExpr, e2:Expr, isAssign:Bool, wt:WithTypeValue, p:Pos):BinopResultData {
		var rhs = typeBinopRhs(ctx, op, e1, e2, isAssign, wt, p);
		return try tryAbstractBinopOverloads(ctx, op, e1, rhs, isAssign, p) catch (ex:NotFound) makeBinop(ctx, op, e1, rhs, isAssign, p);
	}

	public static function withTypeOrValue(wt:WithTypeValue):WithTypeValue return wt == NoValue
		// Even if we expect no value, we still want to type the lhs expression as a value.
		? WithTypeTools.value : wt;

	public static function typeAssign(ctx:Typer, e1:Expr, e2:Expr, wt:WithTypeValue, p:Pos):TExpr {
		function rhs(wt:WithTypeValue):TExpr return try typeExpr(ctx, e2, wt) catch (ex:Dynamic) {
			switch ex {
				case(core.ds.ExceptionTools.typing(_) => Some(err)):
					checkError(ctx, err);
					Texpr.Builder.makeNull(tDynamic, e2.pos);
				case _: throw ex;
			}
		};
		inline function assignTo(lhs:TExpr):TExpr {
			var rhs = context.AbstractCast.castOrUnify(ctx, lhs.etype, rhs(WithTypeTools.withType(lhs.etype)), p);
			checkAssign(ctx, lhs);
			switch [lhs.eexpr, rhs.eexpr] {
				case [TLocal(a), TLocal(b)] if (a == b):
					Error.raiseTypingError("Assigning a value to itself", p);
				case [
					TField({eexpr: TConst(TThis)}, FInstance(_, _, a)),
					TField({eexpr: TConst(TThis)}, FInstance(_, _, b))
				] if (a == b):
					Error.raiseTypingError("Assigning a value to itself", p);
				case _:
			}
			return mk(TBinop(OpAssign, lhs, rhs), lhs.etype, p);
		}
		function access(acc:AccessKind):TExpr return switch acc {
			case AKNo(acc,
				p): if (!Common.ignoreError(ctx.com)) Error.raiseTypingError("This expression cannot be accessed for writing",
					p); else access(acc);
			case AKSafeNav(sn): safeNavBranch(ctx, sn, function() return access(sn.snAccess));
			case AKUsingField(_): Error.raiseTypingError("Invalid operation", p);
			case AKExpr({eexpr: TLocal({vKind: VUser(TVOLocalFunction), vName: name})}): Error.raiseTypingError("Cannot access function "
					+ name + " for writing", p);
			case AKField(fa): assignTo(FieldAccessTools.getFieldExpr(fa, FWrite));
			case AKExpr(lhs): assignTo(lhs);
			case AKAccessor(fa): new CallUnification.CallDispatcher(ctx, MSet(e2), wt, p).accessorCall(fa, vector(), vector(e2));
			case AKAccess(a, tl, c, base, key):
				var r = rhs(WithTypeTools.value);
				mkArraySetCall(ctx, context.AbstractCast.findArrayWriteAccess(ctx, a, tl, key, r, p), c, base, p);
			case AKResolve(sea, name):
				var n = Texpr.Builder.makeString(ctx.t, name, nullPos);
				new CallUnification.CallDispatcher(ctx, MCall(vector(e2)), wt, p).fieldCall(sea.seAccess, vector(sea.seThis, n), vector(e2));
			case AKUsingAccessor(sea):
				var set = switch FieldAccessTools.resolveAccessor(sea.seAccess, MSet(e2)) {
					case AccessorFound(fa): fa;
					case _: Error.raiseTypingError("Could not resolve accessor", p);
				};
				new CallUnification.CallDispatcher(ctx, MCall(vector(e2)), wt, p).fieldCall(set, vector(sea.seThis), vector(e2));
		};
		return access(typeAccessRef(ctx, e1.expr, e1.pos, MSet(e2), withTypeOrValue(wt)));
	}

	public static function typeNonAssignOp(ctx:Typer, op:Binop, e1:Expr, e2:Expr, isAssign:Bool, abstractOnly:Bool, wt:WithTypeValue,
			p:Pos):TExpr {
		// If the with_type is an abstract which has exactly one applicable @:op method, we can promote it
		// to the individual arguments (issue #2786).
		var promoted = switch wt {
			case WithType(t, _): switch follow(t) {
					case TAbstract(a,
						_): a.aOps.filter(function(o) return Type.enumEq(o.op, OpAssignOp(op)) || Type.enumEq(o.op, op))
							.length == 1 ? wt : WithTypeTools.value;
					case _: WithTypeTools.value;
				}
			case _: WithTypeTools.value;
		};
		var lhs = typeExpr(ctx, e1, promoted);
		switch promoted {
			case WithType(t, _):
				var has = switch follow(lhs.etype) {
					case TAbstract(a, _): a.aOps.exists(function(o) return Type.enumEq(o.op, op));
					case _: false;
				};
				// The operator could be ambiguous, let's not cast (issue #12145).
				if (!has) lhs = context.AbstractCast.castOrUnify(ctx, t, lhs, lhs.epos);
			case _:
		}
		var result = abstractOnly ? tryAbstractBinopOverloads(ctx, op, lhs, typeBinopRhs(ctx, op, lhs, e2, isAssign, wt, p), isAssign,
			p) : typeBinop2(ctx, op, lhs, e2, isAssign, promoted, p);
		var vr = new TyperBase.ValueReference(ctx);
		return vr.toTexpr(BinopResult.toTexpr(vr, result, function(_) throw NotFound.raise()));
	}

	public static function processLhsExpr(ctx:Typer, name:String, e:TExpr):{e:TExpr, vr:ValueReference} {
		var vr = new TyperBase.ValueReference(ctx);
		return {e: vr.getExpr(name, e), vr: vr};
	}

	public static function handleAssignOp<A>(ctx:Typer, api:AssignOpApi<A>, e1:Expr, e2:Expr, wt:WithTypeValue, p:Pos):TExpr {
		inline function fieldRhsName(name:String, ev:TExpr, wt:WithTypeValue):{e:TExpr, r:A} {
			var get = accGet(ctx, typeFieldDefaultCfg(ctx, ev, name, e1.pos, MGet, wt));
			return {e: get, r: api.typeRhs(get, e2)};
		}
		inline function fieldRhs(cf:TClassField, ev:TExpr):{e:TExpr, r:A}
			return fieldRhsName(cf.cfName, ev, WithTypeTools.withType(cf.cfType));
		inline function set(vr:ValueReference, fa:context.Typecore.FieldAccess, lhs:TExpr, r:A, el:Vector<TExpr>):TExpr {
			function assign(rhs:TExpr):TExpr {
				rhs = context.AbstractCast.castOrUnify(ctx, lhs.etype, rhs, p);
				return new CallUnification.CallDispatcher(ctx, MSet(e2), wt, p).accessorCall(fa, el.snoc(rhs), vector());
			}
			return api.generate(vr, lhs, api.toTexpr(vr, r, assign));
		}
		function loop(acc:AccessKind):TExpr return switch acc {
			case AKNo(_,
				p):
				// try abstract operator overloading
				// type_non_assign_op ctx op e1 e2 true true with_type p
				try api.aknoFallback() catch (ex:NotFound) Error.raiseTypingError("This expression cannot be accessed for writing", p);
			case AKSafeNav(sn): safeNavBranch(ctx, sn, function() return loop(sn.snAccess));
			case AKUsingField(_): Error.raiseTypingError("Invalid operation", p);
			case AKExpr(e):
				var lhs = processLhsExpr(ctx, "lhs", e);
				api.assign(lhs.vr, lhs.e, api.typeRhs(lhs.e, e2));
			case AKField(fa):
				var vr = new TyperBase.ValueReference(ctx);
				var ef = vr.getExprPart("fh", fa.faOn);
				var rhs = fieldRhs(fa.faField, ef);
				var lhs = FieldAccessTools.getFieldExpr(core.ds.Record.withFields(fa, {faOn: ef}), FWrite);
				api.assign(vr, lhs, rhs.r);
			case AKAccessor(fa):
				var vr = new TyperBase.ValueReference(ctx);
				var ef = vr.getExprPart("fh", fa.faOn);
				var rhs = fieldRhs(fa.faField, ef);
				set(vr, core.ds.Record.withFields(fa, {faOn: ef}), rhs.e, rhs.r, vector());
			case AKUsingAccessor(sea):
				var lhs = processLhsExpr(ctx, "fh", sea.seThis);
				var rhs = fieldRhs(sea.seAccess.faField, lhs.e);
				set(lhs.vr, sea.seAccess, rhs.e, rhs.r, vector(lhs.e));
			case AKAccess(a, tl, c, base, key):
				var get = context.AbstractCast.findArrayReadAccess(ctx, a, tl, key, p);
				// bind complex keys to a variable so they do not make it into the output twice
				var save = saveLocals(ctx);
				var vr = new TyperBase.ValueReference(ctx);
				inline function temp(name:String, e:TExpr):TExpr {
					var constant = Optimizer.makeConstantExpression(SafeCom.ofTyper(ctx), e);
					return constant == null ? vr.asVar(name, e) : constant;
				}
				base = temp("base", base);
				key = temp("key", get.index);
				var read = mkArrayGetCall(ctx, core.ds.Record.withFields(get, {index: key}), c, base, p);
				var r = api.typeRhs(read, e2);
				var e = api.toTexpr(vr, r, function(e) return e);
				unify(ctx, e.etype, get.ret, p);
				var write = context.AbstractCast.findArrayWriteAccess(ctx, a, tl, key, e, p);
				var et = TyperBase.typeModuleType(ctx, TClassDecl(c), p);
				// | None,None ->
				//	let ea = mk (TArray(ebase,ekey)) r_get p in
				//	mk (TBinop(OpAssignOp op,ea,type_expr ctx e2 (WithType.with_type r_get))) r_set p
				if (write.field.cfExpr == null || get.field.cfExpr == null)
					Error.raiseTypingError("Invalid array access getter/setter combination", p);
				var ef = mk(TField(et, FStatic(c, write.field)), write.type, p);
				var call = makeCall(ctx, ef, vector(base, write.index, write.value), write.ret, p);
				save();
				api.generate(vr, read, call);
			case AKResolve(sea, name):
				var lhs = processLhsExpr(ctx, "fh", sea.seThis);
				var rhs = fieldRhsName(name, lhs.e, WithTypeTools.value);
				function assign(e:TExpr):TExpr return new CallUnification.CallDispatcher(ctx, MCall(vector(e2)), wt,
					p).fieldCall(sea.seAccess, vector(sea.seThis, Texpr.Builder.makeString(ctx.t, name, nullPos), e), vector());
				api.generate(lhs.vr, rhs.e, api.toTexpr(lhs.vr, rhs.r, assign));
		};
		return loop(typeAccessRef(ctx, e1.expr, e1.pos, MSet(e2), withTypeOrValue(wt)));
	}

	public static function typeAssignOp(ctx:Typer, op:Binop, e1:Expr, e2:Expr, wt:WithTypeValue, p:Pos):TExpr {
		var api:AssignOpApi<BinopResultData> = {
			aknoFallback: function() return typeNonAssignOp(ctx, op, e1, e2, true, true, wt, p),
			typeRhs: function(lhs, e) return typeBinop2(ctx, op, lhs, e, true, WithTypeTools.value, p),
			toTexpr: BinopResult.toTexpr,
			generate: function(vr, lhs, e) return vr.toTexpr(e),
			assign: function(vr, lhs, r) {
				function assign(rhs:TExpr):TExpr {
					if (BinopResult.needsAssign(r)) checkAssign(ctx, lhs);
					rhs = context.AbstractCast.castOrUnify(ctx, lhs.etype, rhs, p);
					return switch rhs.eexpr {
						case TBinop(other, a,
							b) if (Type.enumEq(op, other) && Texpr.equal(lhs, a)): mk(TBinop(OpAssignOp(other), a, b), lhs.etype, p);
						case _: mk(TBinop(OpAssign, lhs, rhs), lhs.etype, p);
					};
				}
				return vr.toTexpr(BinopResult.toTexpr(vr, r, assign));
			}
		};
		return handleAssignOp(ctx, api, e1, e2, wt, p);
	}

	public static function typeOpNullCoalAssign(ctx:Typer, e1:Expr, e2:Expr, wt:WithTypeValue, p:Pos):TExpr {
		var hack:TExpr->TExpr = function(e) return e;
		inline function gen(vr:ValueReference, lhs:TExpr, t2:T, assign:TExpr):TExpr {
			var eelse = null;
			var tif = ctx.t.tvoid;
			if (wt != NoValue) {
				lhs = vr.asVar("tmp", lhs);
				tif = isNullable(t2) ? lhs.etype : followWithoutType(lhs.etype);
				eelse = lhs;
			}
			var cond = Texpr.Builder.binop(OpEq, lhs, Texpr.Builder.makeNull(lhs.etype, lhs.epos), ctx.t.tbool, lhs.epos);
			return vr.toTexpr(mk(TIf(cond, assign, eelse), tif, lhs.epos));
		}
		var api:AssignOpApi<TExpr> = {
			aknoFallback: function() throw NotFound.raise(),
			typeRhs: function(lhs, e) return typeExpr(ctx, e, WithType(lhs.etype, null)),
			toTexpr: function(vr, e, assign) {
				hack = assign;
				return e;
			},
			generate: function(vr, lhs, e) return gen(vr, lhs, e.etype, hack(e)),
			assign: function(vr, lhs, rhs) {
				checkAssign(ctx, lhs);
				var casted = context.AbstractCast.castOrUnify(ctx, lhs.etype, rhs, p);
				return gen(vr, lhs, rhs.etype, mk(TBinop(OpAssign, lhs, casted), lhs.etype, p));
			}
		};
		return handleAssignOp(ctx, api, e1, e2, wt, p);
	}

	public static function typeBinop(ctx:Typer, op:Binop, e1:Expr, e2:Expr, isAssign:Bool, wt:WithTypeValue, p:Pos):TExpr return switch op {
		case OpAssign: typeAssign(ctx, e1, e2, wt, p);
		case OpAssignOp(OpBoolAnd | OpBoolOr): Error.raiseTypingError("The operators ||= and &&= are not supported", p);
		case OpAssignOp(op): typeAssignOp(ctx, op, e1, e2, wt, p);
		case _: try typeNonAssignOp(ctx, op, e1, e2, isAssign, false, wt,
				p) catch (ex:NotFound) throw "Failed to type binary operation " + sBinop(isAssign ? OpAssignOp(op) : op);
	};

	public static function typeUnop(ctx:Typer, op:Unop, flag:UnopFlag, e:Expr, wt:WithTypeValue, p:Pos):TExpr {
		inline function findOverload(e:TExpr):TExpr return switch follow(e.etype) {
			case TAbstract(a = {aImpl: c}, tl) if (c != null):
				var fcc:Null<typing.FieldCallCandidate.FieldCallCandidateData<Void->TExpr>> = null;
				for (entry in a.aUnops) {
					if (entry.op != op || entry.flag != flag) continue;
					var cf = entry.field;
					var sea = hasClassFieldFlag(cf,
						CfImpl) ? FieldAccessTools.makeAbstractStaticExtensionAccess(a, tl, c, cf, e, false,
							p) : FieldAccessTools.makeStaticExtensionAccess(c, cf, e, false, p);
					try {
						fcc = CallUnification.unifyFieldCall(ctx, sea.seAccess, vector(sea.seThis), vector(), p, false);
						break;
					} catch (ex:Dynamic) {
						switch ex {
							case(core.ds.ExceptionTools.typing(_) => Some(_)):
							case _: throw ex;
						}
					}
				}
				if (fcc == null) throw NotFound.raise();
				follow(fcc.fcField.cfType);
				fcc.fcField.cfExpr == null ? mk(TUnop(op, flag, e), fcc.fcRet, p) : fcc.fcData();
			case _: throw NotFound.raise();
		};
		inline function spread():Dynamic
			return Error.raiseTypingError("Spread unary operator is only allowed for unpacking the last argument in a call with rest arguments",
				p);
		inline function make(e:TExpr):TExpr {
			inline function checkInt():T return switch classify(e.etype) {
				case KFloat: ctx.t.tfloat;
				case KNumParam(t):
					unify(ctx, e.etype, ctx.t.tfloat, e.epos);
					t;
				case k: unifyInt(ctx, e, k) ? ctx.t.tint : ctx.t.tfloat;
			};
			var t = switch op {
				case Not:
					if (flag == Postfix) Common.displayError(ctx.com, "Postfix ! is not supported", p);
					unify(ctx, e.etype, ctx.t.tbool, e.epos);
					ctx.t.tbool;
				case NegBits:
					unify(ctx, e.etype, ctx.t.tint, e.epos);
					ctx.t.tint;
				case Increment | Decrement:
					checkAssign(ctx, e);
					checkInt();
				case Neg: checkInt();
				case Spread: spread();
			};
			return mk(TUnop(op, flag, e), t, p);
		}
		inline function findOrMake(e:TExpr):TExpr return try findOverload(e) catch (ex:NotFound) make(e);
		switch op {
			case Spread:
				return spread();
			case Not | Neg | NegBits:
				return findOrMake(accGet(ctx, typeAccessRef(ctx, e.expr, e.pos, MGet, /* WITHTYPETODO */ WithTypeTools.value)));
			case Increment | Decrement:
		}
		var binop = op == Increment ? OpAdd : OpSub;
		var one = mk(TConst(TInt(1)), ctx.t.tint, p);
		function postfix(vr:ValueReference, lhs:TExpr):{lhs:TExpr, out:Null<TExpr>} {
			if (flag == Postfix && wt != NoValue) {
				lhs = vr.getExpr("lhs", lhs);
				return {lhs: lhs, out: vr.asVar("postfix", lhs)};
			}
			return {lhs: lhs, out: null};
		}
		inline function readOn(vr:ValueReference, ef:TExpr, fa:context.Typecore.FieldAccess):{lhs:TExpr, out:Null<TExpr>}
			return postfix(vr, accGet(ctx, typeFieldDefaultCfg(ctx, ef, fa.faField.cfName, e.pos, MGet, WithTypeTools.value)));
		inline function generate(vr:ValueReference, out:Null<TExpr>,
				e:TExpr):TExpr return out == null ? vr.toTexpr(e) : vr.toTexprEl([e], out);
		inline function makeOp(vr:ValueReference, a:TExpr,
				b:TExpr):TExpr return BinopResult.toTexpr(vr, makeBinop(ctx, binop, a, b, false, p), function(_) throw NotFound.raise());
		function loop(acc:AccessKind):TExpr return switch acc {
			case AKNo(acc,
				p): try findOverload(accGet(ctx,
					acc)) catch (ex:NotFound) Error.raiseTypingError("This expression cannot be accessed for writing", p);
			case AKExpr(e): findOrMake(e);
			case AKField(fa):
				var vr = new TyperBase.ValueReference(ctx);
				var ef = vr.getExprPart("fh", fa.faOn);
				var access = typeFieldDefaultCfg(ctx, ef, fa.faField.cfName, e.pos, MGet, WithTypeTools.value);
				var result:TExpr;
				var out = null;
				switch access {
					case AKField(_): result = findOrMake(FieldAccessTools.getFieldExpr(core.ds.Record.withFields(fa, {faOn: ef}), FGet));
					case _:
						var set = FieldAccessTools.getFieldExpr(core.ds.Record.withFields(fa, {faOn: ef}), FWrite);
						var r = postfix(vr, accGet(ctx, access));
						out = r.out;
						result = mk(TBinop(OpAssign, set, makeOp(vr, r.lhs, one)), set.etype, p);
				}
				generate(vr, out, result);
			case AKAccessor(fa):
				var vr = new TyperBase.ValueReference(ctx);
				var ef = vr.getExprPart("fh", fa.faOn);
				fa = core.ds.Record.withFields(fa, {faOn: ef});
				var r = readOn(vr, ef, fa);
				var result = new CallUnification.CallDispatcher(ctx, MSet(null), WithTypeTools.value,
					p).accessorCall(fa, vector(makeOp(vr, r.lhs, one)), vector());
				generate(vr, r.out, result);
			case AKUsingAccessor(sea):
				var lhs = processLhsExpr(ctx, "fh", sea.seThis);
				var r = readOn(lhs.vr, lhs.e, sea.seAccess);
				var result = new CallUnification.CallDispatcher(ctx, MSet(null), WithTypeTools.value,
					p).accessorCall(sea.seAccess, vector(lhs.e, makeOp(lhs.vr, r.lhs, one)), vector());
				generate(lhs.vr, r.out, result);
			case AKAccess(a, tl, c, base, key): try {
					var vb = allocVar(VGenerated, "tmp", base.etype, base.epos);
					var initBase = mk(TVar(vb, base), ctx.com.basic.tvoid, base.epos);
					var eb = mk(TLocal(vb), base.etype, base.epos);
					var vk = allocVar(VGenerated, "tmp", key.etype, key.epos);
					var initKey = mk(TVar(vk, key), ctx.com.basic.tvoid, key.epos);
					var ek = mk(TLocal(vk), key.etype, key.epos);
					// get
					var get = mkArrayGetCall(ctx, context.AbstractCast.findArrayReadAccessRaise(ctx, a, tl, ek, p), c, eb, p);
					var vg = allocVar(VGenerated, "tmp", get.etype, get.epos);
					var eg = mk(TLocal(vg), vg.vType, p);
					var initGet = mk(TVar(vg, get), ctx.com.basic.tvoid, p);
					// op
					var operation = mk(TBinop(binop, eg, mk(TConst(TInt(1)), ctx.com.basic.tint, p)), eg.etype, p);
					// set
					var set = mkArraySetCall(ctx, context.AbstractCast.findArrayWriteAccessRaise(ctx, a, tl, ek, operation, p), c, eb, p);
					mk(TBlock(flag == Postfix ? vector(initBase, initKey, initGet, set, eg) : vector(initBase, initKey, initGet, set)), set.etype, p);
				} catch (ex:NotFound) {
					findOrMake(mkArrayGetCall(ctx, context.AbstractCast.findArrayReadAccess(ctx, a, tl, key, p), c, base, p));
				}
			case AKSafeNav(sn): safeNavBranch(ctx, sn, function() return loop(sn.snAccess));
			case AKUsingField(_) | AKResolve(_, _): Error.raiseTypingError("Invalid operation", p);
		};
		return loop(typeAccessRef(ctx, e.expr, e.pos, MSet(null), /* WITHTYPETODO */ WithTypeTools.value));
	}
}
