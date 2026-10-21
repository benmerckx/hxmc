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

package optimization;

import core.Ast;
import core.TType;
import core.TFunctions as TypeOps;
import core.Globals;
import core.Texpr;
import context.SafeCom;
import core.Abstract;
import core.Error;
import optimization.OptimizerTexpr;
import optimization.Inline;
import filters.safe.Sanitize;
import core.ds.VectorTools.vector;

// ----------------------------------------------------------------------
// REDUCE

class Optimizer {
	public static function checkEnumConstructionArgs(el:haxe.ds.Vector<TExpr>, index:Int):Bool {
		var result = true;
		for (i in 0...el.length) result = result && (i == index || !OptimizerTexpr.hasSideEffect(el[i]));
		return result;
	}

	public static function extractConstantValue(e:TExpr):Null<TExpr> {
		return switch e.eexpr {
			case TConst(TInt(_) | TFloat(_) | TString(_) | TBool(_) | TNull): e;
			case TConst(TThis | TSuper): null;
			// Don't care about inline, if we know the value it makes no difference.
			case TField(_, FStatic(_, cf = {cfKind: Var({vWrite: AccNever})})): cf.cfExpr == null ? null : extractConstantValue(cf.cfExpr);
			case TField(_, FEnum(_, _)): e;
			case TParenthesis(e1): extractConstantValue(e1);
			case _: null;
		};
	}

	public static function checkConstantSwitch(sw:TSwitch):Null<TExpr> {
		inline function isEmpty(e:TExpr):Bool return switch e.eexpr {
			case TBlock([]): true;
			case _: false;
		};
		var subject = Texpr.skip(sw.switchSubject);
		switch subject.eexpr {
			case TConst(ct) if (ct != TSuper && ct != TThis):
				for (c in sw.switchCases) {
					// Map everything first so that we find unknown things eagerly.
					var patterns = [];
					for (e2 in c.casePatterns) {
						var e2 = extractConstantValue(e2);
						if (e2 == null) return null;
						patterns.push(e2);
					}
					if (core.ds.ArrayTools.exists(patterns, e2 -> Texpr.equal(subject, e2))) return c.caseExpr;
				}
				return sw.switchDefault;
			case _:
				return core.ds.ArrayTools.foreach(sw.switchCases, c -> isEmpty(c.caseExpr))
					&& (sw.switchDefault == null || isEmpty(sw.switchDefault)) ? sw.switchSubject : null;
		}
	}

	public static function reduceControlFlow(scom:context.SafeCom.SafeContext, e:TExpr):TExpr {
		return switch e.eexpr {
			case TIf({eexpr: TConst(TBool(t))}, e1, e2): t ? e1 : e2 == null ? TypeOps.mk(TBlock(vector()), e.etype, e.epos) : e2;
			case TWhile({eexpr: TConst(TBool(false))}, sub, flag): flag == NormalWhile ? TypeOps.mk(TBlock(vector()), e.etype, e.epos) /* erase sub */ : e; // we cant remove while since sub can contain continue/break
			case TSwitch(sw):
				var reduced = checkConstantSwitch(sw);
				reduced == null ? e : reduced;
			case TBinop(op, e1, e2): OptimizerTexpr.optimizeBinop(scom, e, op, e1, e2);
			case TUnop(op, flag, esub): OptimizerTexpr.optimizeUnop(e, op, flag, esub);
			case TCall(f = {eexpr: TField(o, FClosure(c, cf))}, el):
				var mode = c == null ? FAnon(cf) : FInstance(c.cls, c.params, cf);
				TypeOps.mk(TCall(TypeOps.mk(TField(o, mode), f.etype, f.epos), el), e.etype, e.epos);
			case TEnumParameter({eexpr: TCall({eexpr: TField(_, FEnum(_, ef1))}, el)}, ef2, i) |
				TEnumParameter({eexpr: TParenthesis({eexpr: TCall({eexpr: TField(_, FEnum(_, ef1))}, el)})}, ef2, i)
				if (ef1 == ef2 && checkEnumConstructionArgs(el, i)): i >= 0 && i < el.length ? el[i] : e;
			case TCast(_, null):
				// TODO: figure out what's wrong with these targets
				var requireCast = switch scom.platform {
					case Cpp | Flash | Jvm: true;
					case _: false;
				};
				Texpr.reduceUnsafeCasts(e, e.etype, requireCast);
			case _: e;
		};
	}

	// port: the mapping closure is made once per traversal and passed down (one per node otherwise).
	public static function reduceLoop(scom:context.SafeCom.SafeContext, stack:core.TUnification.RecStack<TClassField>, e:TExpr):TExpr {
		var fn:TExpr->TExpr = null;
		fn = x -> reduceLoopWith(scom, stack, fn, x);
		return fn(e);
	}

	static function reduceLoopWith(scom:context.SafeCom.SafeContext, stack:core.TUnification.RecStack<TClassField>, fn:TExpr->TExpr,
			e:TExpr):TExpr {
		e = core.Texpr.mapExpr(fn, e);
		var reduced:TExpr;
		switch e.eexpr {
			case TCall(e1, el):
				var skipped = Texpr.skip(e1);
				switch skipped.eexpr {
					case TFunction(func):
						var cf = TypeOps.mkField("", skipped.etype, e.epos, Globals.nullPos);
						var ethis = TypeOps.mk(TConst(TThis), TypeOps.tDynamic, e.epos);
						var rt = switch TypeOps.follow(skipped.etype) {
							case TFun(sig): sig.ret;
							case _: throw "optimizer: function type";
						};
						try {
							var inlined = Inline.typeInline(Inline.contextOfScom(scom), cf, func, ethis, el, rt, null, e.epos, false, true);
							reduced = reduceLoop(scom, stack, inlined);
						} catch (err:core.Error.TypingError) {
							switch err.error.errMessage {
								case Custom(_): reduced = Sanitize.reduceExpr(scom, e);
								case _: throw err;
							}
						}
					case TField(ef, FStatic(cl, cf) | FInstance(cl, _, cf))
						if (SafeCom.needsInline(scom, cl, cf) && !core.TUnification.recStackMemq(cf, stack)):
						switch cf.cfExpr {
							case {eexpr: TFunction(tf)}:
								var config = Inline.inlineConfig(cl, cf, el, e.etype);
								var rt = switch Abstract.followWithAbstracts(e1.etype) {
									case TFun(sig): sig.ret;
									case _: throw "optimizer: inline function type";
								};
								try {
									var inlined = Inline.typeInline(Inline.contextOfScom(scom), cf, tf, ef, el, rt, config, e.epos, false);
									reduced = core.TUnification.recStackDefault(stack, cf, cf2 -> cf2 == cf,
										() -> reduceLoop(scom, stack, inlined), inlined);
								} catch (err:core.Error.TypingError) {
									switch err.error.errMessage {
										case Custom(_): reduced = Sanitize.reduceExpr(scom, e);
										case _: throw err;
									}
								}
							case _: reduced = Sanitize.reduceExpr(scom, e);
						}
					case TField({eexpr: TTypeExpr(TClassDecl(c))}, field):
						var inlined = Inline.apiInline(scom, c, TypeOps.fieldName(field), el, e.epos);
						reduced = inlined == null ? Sanitize.reduceExpr(scom, e) : reduceLoop(scom, stack, inlined);
					case _: reduced = Sanitize.reduceExpr(scom, e);
				}
			case _:
				reduced = Sanitize.reduceExpr(scom, reduceControlFlow(scom, e));
		}
		return Sanitize.sanitizeExpr(scom, reduced);
	}

	public static function reduceExpression(scom:context.SafeCom.SafeContext, e:TExpr):TExpr {
		if (!scom.foptimize) return e;
		// We go through rec_stack_default here so that the current field is on inline_stack. This prevents self-recursive
		// inlining (#7569).
		var stack = core.TUnification.newRecStack();
		return core.TUnification.recStackDefault(stack, scom.curfield, cf -> cf == scom.curfield, () -> reduceLoop(scom, stack, e), e);
	}

	public static function makeConstantExpressionWithStack(scom:context.SafeCom.SafeContext,
			stack:core.TUnification.RecStack<TClassField>, e:TExpr, concatStrings:Bool = false):Null<TExpr> {
		e = reduceLoop(scom, stack, e);
		return switch e.eexpr {
			case TConst(_): e;
			case TField({eexpr: TTypeExpr(_)}, FEnum(_, _)): e;
			case TBinop(op = OpAdd | OpSub | OpMult | OpDiv | OpMod | OpShl | OpShr | OpUShr | OpOr | OpAnd | OpXor, e1, e2):
				var c1 = makeConstantExpressionWithStack(scom, stack, e1);
				var c2 = makeConstantExpressionWithStack(scom, stack, e2);
				if (c1 == null || c2 == null) null; else switch [c1.eexpr, c2.eexpr] {
					case [TConst(TString(s1)), TConst(TString(s2))] if (concatStrings): TypeOps.mk(TConst(TString(s1 + s2)),
							scom.basic.tstring, core.Ast.punion(e1.epos, e2.epos));
					case _: TypeOps.mk(TBinop(op, c1, c2), e.etype, e.epos);
				}
			case TUnop(op = Neg | NegBits, Prefix, e1):
				var c1 = makeConstantExpressionWithStack(scom, stack, e1);
				c1 == null ? null : TypeOps.mk(TUnop(op, Prefix, c1), e.etype, e.epos);
			case TCast(e1, null):
				var c1 = makeConstantExpressionWithStack(scom, stack, e1);
				c1 == null ? null : TypeOps.mk(TCast(c1, null), e.etype, e.epos);
			case TParenthesis(e1):
				var c1 = makeConstantExpressionWithStack(scom, stack, e1, concatStrings);
				c1 == null ? null : TypeOps.mk(TParenthesis(c1), e.etype, e.epos);
			case TMeta(m, e1):
				var c1 = makeConstantExpressionWithStack(scom, stack, e1, concatStrings);
				c1 == null ? null : TypeOps.mk(TMeta(m, c1), e.etype, e.epos);
			case TTypeExpr(_): e;
			// try to inline static function calls
			// Disabled for now, see #4254.
			/* 	| TCall ({ etype = TFun(_,ret); eexpr = TField (_,FStatic (c,cf)) },el) ->
				(try
					let func = match cf.cf_expr with Some ({eexpr = TFunction func}) -> func | _ -> raise Not_found in
					let ethis = mk (TConst TThis) t_dynamic e.epos in
					let inl = (try type_inline ctx cf func ethis el ret None e.epos false with Error (Custom _,_) -> None) in
					(match inl with
					| None -> None
					| Some e -> make_constant_expression ctx e)
				with Not_found -> None) */
			case _: null;
		};
	}

	public static function makeConstantExpression(ctx:context.SafeCom.SafeContext, e:TExpr, concatStrings:Bool = false):Null<TExpr> {
		return makeConstantExpressionWithStack(ctx, core.TUnification.newRecStack(), e, concatStrings);
	}
}
