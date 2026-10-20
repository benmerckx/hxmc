package typing;

import core.Ast.*;
import core.Error;
import core.Error.*;
import core.Texpr;
import core.Texpr.Texpr.mapExpr;
import core.Define;
import core.DisplayTypes.DisplayModeValue;
import core.ds.NotFound;
import core.ds.Exit;
import context.Common;
import typing.TyperBase;
import typing.TyperBase.*;

using Lambda;
using core.ds.ArrayTools;

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
import typing.Fields.*;
import typing.Calls.*;

typedef UnrollParameters = {var expressionWeight:Int; var forceUnroll:Bool;}

enum IteratorKind {
	IteratorIntConst(from:TExpr, to:TExpr, ascending:Bool); // ascending?
	IteratorIntUnroll(offset:Int, length:Int, ascending:Bool);
	IteratorInt(from:TExpr, to:TExpr);
	IteratorArrayDecl(el:Array<TExpr>);
	IteratorArray;
	IteratorGenericStack(c:TClass);
	IteratorIterator;
	IteratorCustom(get:TExpr->TExpr->T->Pos->TExpr, length:TExpr->Pos->TExpr);
	IteratorHasNextNext(v:TVar, next:TExpr, hasNext:TExpr);
	IteratorDynamic;
}

typedef IteratorData = {var itKind:IteratorKind; var itType:T; var itExpr:TExpr;}
typedef IterationIdent = {var name:String; var pos:Pos; var display:Null<DisplayKind>;}
typedef ForLoopDisplay = (Typer, Expr, DisplayKind, AccessMode, WithTypeValue) -> TExpr;

enum IterationKindData {
	IKNormal(ident:IterationIdent);
	IKKeyValue(key:IterationIdent, value:IterationIdent);
}

enum ForLoopUnroll {
	NoForcedUnroll;
	ForcedUnroll;
}

class IterationKind {
	public static var typeFieldConfig:Fields.TypeFieldConfig = makeTypeFieldConfig();

	static function makeTypeFieldConfig():Fields.TypeFieldConfig {
		var cfg = Fields.TypeFieldConfig.create(true);
		cfg.allowResolve = false;
		cfg.allowDynamic = false;
		cfg.allowOpenMono = false;
		return cfg;
	}

	static function isUnificationError(e:Dynamic):Bool return switch e {
		case(core.ds.ExceptionTools.typing(_) => Some({errMessage: Unify(_)})): true;
		case _: false;
	};

	public static function tryIteratorUnification(ctx:Typer, e:TExpr):Null<{e:TExpr, t:T}> {
		switch core.Abstract.followWithAbstracts(e.etype) {
			case TDynamic(_) | TMono(_):
				// Unification from these always succeeds, so let's reject it.
				return null;
			case _:
		}
		var pt = spawnMonomorph(ctx, e.epos);
		try {
			return {e: context.AbstractCast.castOrUnifyRaise(ctx, ctx.t.titerator(pt), e, e.epos), t: pt};
		} catch (ex:Dynamic) {
			if (isUnificationError(ex)) return null;
			throw ex;
		}
	}

	public static function tryIteratorField(ctx:Typer, e:TExpr, s:String):Null<{e:TExpr, t:T}> {
		var pt = spawnMonomorph(ctx, e.epos);
		var t = ctx.t.titerator(pt);
		try {
			var acc = Fields.typeField(typeFieldConfig, ctx, e, s, e.epos, MCall([]), WithTypeTools.withType(t));
			var call = Calls.buildCall(ctx, acc, [], WithTypeTools.value, e.epos);
			unifyRaise(call.etype, t, call.epos);
			return {e: call, t: pt};
		} catch (ex:Dynamic) {
			if (isUnificationError(ex) || Std.isOfType(ex, NotFound)) return null;
			throw ex;
		}
	}

	// Builds an IteratorHasNextNext for an expression whose type exposes hasNext/next fields.
	// The optional [check] callback is called with (acc_next, acc_hasNext) after type_field
	// succeeds and before build_call; raise Not_found there to reject the iterator.
	public static function mkHasNextNext(ctx:Typer, e:TExpr, p:Pos, ?check:AccessKind->AccessKind->Void):IteratorData {
		var v = genLocal(ctx, e.etype, e.epos);
		var tmp = Texpr.Builder.makeLocal(v, v.vPos);
		var hasNext = Fields.typeField(typeFieldConfig, ctx, tmp, "hasNext", p, MCall([]), WithTypeTools.withType(ctx.t.tbool));
		var next = Fields.typeField(typeFieldConfig, ctx, tmp, "next", p, MCall([]), WithTypeTools.value);
		if (check != null) check(next, hasNext);
		var eh = Calls.buildCall(ctx, hasNext, [], WithTypeTools.withType(ctx.t.tbool), tmp.epos);
		var en = Calls.buildCall(ctx, next, [], WithTypeTools.value, tmp.epos);
		return {itKind: IteratorHasNextNext(v, en, eh), itExpr: e, itType: en.etype};
	}

	// Try to build an IteratorHasNextNext kind for an async iterator expression.
	// Raises Not_found if e cannot be resolved to an AsyncIterator<T> (directly or via e.s()).
	static function tryAsyncIteratorKind(ctx:Typer, e:TExpr, s:String, p:Pos):IteratorData {
		if (!TyperManager.isCoroutineContext(ctx)) throw NotFound.raise();
		inline function asyncType(t:T):T return ctx.t.tcoro.tasyncIterator.force()(t);
		// First, try direct unification with AsyncIterator<T>
		inline function direct():IteratorData {
			switch core.Abstract.followWithAbstracts(e.etype) {
				case TDynamic(_) | TMono(_):
					throw NotFound.raise();
				case _:
			}
			var pt = spawnMonomorph(ctx, e.epos);
			try {
				return mkHasNextNext(ctx, context.AbstractCast.castOrUnifyRaise(ctx, asyncType(pt), e, e.epos), p);
			} catch (ex:Dynamic) {
				if (isUnificationError(ex)) throw NotFound.raise();
				throw ex;
			}
		}
		try {
			return direct();
		} catch (ex:NotFound) {}
		// Then, try e.s() returning AsyncIterator<T>
		var pt = spawnMonomorph(ctx, e.epos);
		var t = asyncType(pt);
		try {
			var acc = Fields.typeField(typeFieldConfig, ctx, e, s, e.epos, MCall([]), WithTypeTools.withType(t));
			var call = Calls.buildCall(ctx, acc, [], WithTypeTools.value, e.epos);
			unifyRaise(call.etype, t, call.epos);
			return mkHasNextNext(ctx, call, p);
		} catch (ex:Dynamic) {
			if (isUnificationError(ex) || Std.isOfType(ex, NotFound)) throw NotFound.raise();
			throw ex;
		}
	}

	public static function cannotIterateOn(com:Dynamic, e:TExpr):{e:TExpr, t:T} {
		Common.displayError(com, "Cannot iterate on " + core.TPrinting.sType(core.TPrinting.printContext(), e.etype), e.epos);
		return {e: mk(TConst(TNull), tDynamic, e.epos), t: tDynamic};
	}

	public static function trySyncIterator(ctx:Typer, s:String, e:TExpr, resume:Bool = false):{e:TExpr, t:T} {
		var r = tryIteratorUnification(ctx, e);
		if (r != null) return r;
		r = tryIteratorField(ctx, e, s);
		if (r != null) return r;
		if (resume) throw NotFound.raise();
		return cannotIterateOn(ctx.com, e);
	}

	static function ofTexprByArrayAccess(ctx:Typer, e:TExpr, p:Pos):IteratorData {
		var aa = TyperBase.getArrayAccess(ctx, e.etype, p);
		return {itKind: IteratorCustom(aa.aaGet, aa.aaLength), itExpr: e, itType: aa.aaType};
	}

	static function mapUnrollParams(ctx:Typer, params:Null<UnrollParameters>, i:Int):Null<UnrollParameters> {
		if (params == null || params.forceUnroll) return params;
		var max:Int;
		try {
			max = Std.parseInt(Common.definedValue(ctx.com, Define.LoopUnrollMaxCost));
		} catch (e:NotFound) {
			max = 250;
		}
		return i * params.expressionWeight <= max ? params : null;
	}

	public static function ofTexpr(ctx:Typer, e:TExpr, unroll:Null<UnrollParameters>, p:Pos, resume:Bool = false):IteratorData {
		function checkIterator():IteratorData {
			try {
				var r = trySyncIterator(ctx, "iterator", e, true);
				return {itKind: IteratorIterator, itExpr: r.e, itType: r.t};
			} catch (ex:NotFound) {}
			try {
				return tryAsyncIteratorKind(ctx, e, "iterator", p);
			} catch (ex:NotFound) {}
			try {
				return ofTexprByArrayAccess(ctx, e, p);
			} catch (ex:NotFound) {}
			if (resume) throw NotFound.raise();
			var r = cannotIterateOn(ctx.com, e);
			return {itKind: IteratorIterator, itExpr: r.e, itType: r.t};
		}
		inline function cannotForce():Void if (unroll != null && unroll.forceUnroll) Common.displayError(ctx.com,
			"Could not force inlining on this loop", p);
		inline function forwardArray():IteratorData return switch follow(e.etype) {
			case TAbstract(a = {aThis: arrayType = TInst({clPath: {pack: [], name: "Array"}}, [_])}, params):
				var meta = core.Meta.get(MetaTag.Forward, a.aMeta);
				var forwards = meta.exprs.length == 0 || meta.exprs.exists(function(e) return switch e.expr {
					case EConst(Ident("iterator")): true;
					case _: false;
				});
				if (!forwards) throw NotFound.raise();
				switch applyParams(a.aParams, params, arrayType) {
					case t = TInst({clPath: {pack: [], name: "Array"}},
						[pt]): {itKind: IteratorArray, itExpr: mkCast(e, t, e.epos), itType: pt};
					case _: throw NotFound.raise();
				}
			case _: throw NotFound.raise();
		};
		return switch [e.eexpr, follow(e.etype)] {
			case [TNew({clPath: {pack: [], name: "IntIterator"}}, [], [a, b]), _]:
				var kind = switch [a.eexpr, b.eexpr] {
					case [TConst(TInt(a)), TConst(TInt(b))]:
						var diff = a - b;
						var length = Std.int(Math.abs(diff));
						mapUnrollParams(ctx, unroll,
							length) != null ? IteratorIntUnroll(a, length, diff <= 0) : IteratorIntConst(switch e.eexpr {
							case TNew(_, _, [a, _]): a;
							case _: throw "assert";
						}, switch e.eexpr {
							case TNew(_, _, [_, b]): b;
							case _: throw "assert";
						}, diff <= 0);
					case _:
						cannotForce();
						var b = switch follow(b.etype) {
							case TAbstract({aPath: {pack: [], name: "Int"}}, []): b;
							case _: core.ds.Record.withFields(b, {eexpr: TCast(b, null), etype: ctx.t.tint});
						};
						IteratorInt(a, b);
				};
				{itKind: kind, itExpr: e, itType: ctx.t.tint};
			case [TArrayDecl(el), TInst({clPath: {pack: [], name: "Array"}}, [pt])]: {
					itKind: mapUnrollParams(ctx, unroll, el.length) != null ? IteratorArrayDecl(el) : IteratorArray,
					itExpr: e,
					itType: pt
				};
			case [_, TInst({clPath: {pack: [], name: "Array"}}, [pt])] | [_, TInst({clPath: {pack: ["flash"], name: "Vector"}}, [pt])]:
				cannotForce();
				{itKind: IteratorArray, itExpr: e, itType: pt};
			case [_, TAbstract({aImpl: c}, _)] if (c != null):
				cannotForce();
				try {
					mkHasNextNext(ctx, e, p, function(next, hasNext) {
						switch [next, hasNext] {
							case [AKExpr({eexpr: TField(_, FDynamic(_))}), _] | [_, AKExpr({eexpr: TField(_, FDynamic(_))})]:
								throw NotFound.raise();
							case _:
						}
					});
				} catch (ex:NotFound) {
					try forwardArray()
					catch (ex:NotFound) checkIterator();
				}
			case [_, TAbstract(_, _)]:
				cannotForce();
				try forwardArray() catch (ex:NotFound) checkIterator();
			case [
				_,
				TInst(c = {clKind: KGenericInstance({clPath: {pack: ["haxe", "ds"], name: "GenericStack"}}, [pt])}, [])
			]:
				cannotForce();
				{itKind: IteratorGenericStack(c), itExpr: e, itType: pt};
			case [_, TMono(_) | TDynamic(_)]:
				var r = cannotIterateOn(ctx.com, e);
				{itKind: IteratorDynamic, itExpr: r.e, itType: tDynamic};
			case _:
				cannotForce();
				checkIterator();
		};
	}

	public static function toTexpr(ctx:Typer, v:TVar, iterator:IteratorData, e2:TExpr, p:Pos):TExpr {
		var e1 = iterator.itExpr, pt = iterator.itType;
		var tv = ctx.t.tvoid, ti = ctx.t.tint;
		function field(e:TExpr, n:String):TExprDef {
			var fa;
			try {
				fa = quickField(e.etype, n);
			} catch (ex:NotFound) {
				return Error.raiseMsg('Could not find field $n on ${core.TPrinting.sTypeKind(e.etype)}', e.epos);
			}
			return TField(e, fa);
		}
		inline function genIntIter(e1:TExpr, pt:T, get:TExpr->TExpr->T->Pos->TExpr, len:TExpr->Pos->TExpr):TExpr {
			var index = genLocal(ctx, ti, v.vPos);
			index.vMeta.unshift({meta: MetaTag.ForLoopVariable, exprs: [], pos: nullPos});
			var arr = e1;
			var avar = null;
			switch e1.eexpr {
				case TLocal(_):
				case _:
					var tmp = genLocal(ctx, e1.etype, e1.epos);
					arr = mk(TLocal(tmp), e1.etype, e1.epos);
					avar = mk(TVar(tmp, e1), tv, p);
			}
			var ie = mk(TLocal(index), ti, p);
			var get = mk(TVar(v, get(arr, ie, pt, p)), tv, v.vPos);
			var inc = mk(TUnop(Increment, Prefix, ie), ti, p);
			var block = switch e2.eexpr {
				case TBlock(el): mk(TBlock([get, inc].concat(el)), tv, e2.epos);
				case _: mk(TBlock([get, inc, e2]), tv, p);
			};
			var init = mk(TVar(index, mk(TConst(TInt(0)), ti, p)), tv, p);
			var elength = len(arr, p);
			var el = [
				mk(TWhile(mk(TBinop(OpLt, ie, elength), ctx.t.tbool, p), block, NormalWhile), tv, p)
			];
			if (avar != null) el.unshift(avar);
			el.unshift(init);
			return mk(TBlock(el), tv, p);
		}
		return switch iterator.itKind {
			case IteratorIntUnroll(offset, n, ascending):
				if (!ascending) Error.raiseTypingError("Cannot iterate backwards", p);
				var acc = [];
				for (i in 0...n) {
					var ei = Texpr.Builder.makeInt(ctx.t, ascending ? i + offset : offset - i, p);
					var locals = [];
					function replace(e:TExpr):TExpr return switch e.eexpr {
						case TLocal(other) if (v == other): core.ds.Record.withFields(ei, {epos: e.epos});
						case TUnop(Decrement | Increment, _, {eexpr: TLocal(other)}) if (v == other): throw Exit.raise();
						case TBinop(OpAssign | OpAssignOp(_), {eexpr: TLocal(other)}, _) if (v == other): throw Exit.raise();
						case TVar(local, eo) if (hasVarFlag(local, VStatic)):
							if (acc.length == 0) locals.unshift(core.ds.Record.withFields(e, {eexpr: TVar(local, eo)}));
							mk(TConst(TNull), tDynamic, nullPos);
						case _: mapExpr(replace, e);
					};
					var body;
					try {
						body = replace(e2);
					} catch (ex:Exit) {
						var el = switch e2.eexpr {
							case TBlock(el): el;
							case _: [e2];
						};
						body = core.ds.Record.withFields(e2, {eexpr: TBlock([mk(TVar(v, ei), tv, p)].concat(el))});
					}
					acc = acc.concat(locals);
					acc.unshift(Texpr.duplicateTvars(function(e) return e, body));
				}
				acc.reverse();
				mk(TBlock(acc), tv, p);
			case IteratorIntConst(a, b, ascending):
				if (!ascending) Error.raiseTypingError("Cannot iterate backwards", p);
				var index = genLocal(ctx, ti, a.epos);
				var init = mk(TVar(index, a), tv, a.epos);
				var local = Texpr.Builder.makeLocal(index, index.vPos);
				var cond = Texpr.Builder.binop(ascending ? OpLt : OpGt, local, b, ctx.t.tbool, punion(v.vPos, b.epos));
				var inc = mk(TUnop(ascending ? Increment : Decrement, Postfix, local), ti, punion(a.epos, b.epos));
				var initVar = mk(TVar(v, inc), tv, punion(v.vPos, a.epos));
				mk(TBlock([init, mk(TWhile(cond, concat(initVar, e2), NormalWhile), tv, p)]), tv, p);
			case IteratorInt(a, b):
				var index = genLocal(ctx, ti, a.epos);
				var init = mk(TVar(index, a), tv, a.epos);
				var local = Texpr.Builder.makeLocal(index, index.vPos);
				var vb = genLocal(ctx, b.etype, b.epos);
				var initB = mk(TVar(vb, b), tv, b.epos);
				var eb = Texpr.Builder.makeLocal(vb, b.epos);
				var cond = Texpr.Builder.binop(OpLt, local, eb, ctx.t.tbool, punion(v.vPos, b.epos));
				var inc = mk(TUnop(Increment, Postfix, local), ti, punion(a.epos, b.epos));
				var initVar = mk(TVar(v, inc), tv, punion(v.vPos, a.epos));
				mk(TBlock([init, initB, mk(TWhile(cond, concat(initVar, e2), NormalWhile), tv, p)]), tv, p);
			case IteratorArrayDecl(el): mk(TBlock(el.map(function(e) return Texpr.duplicateTvars(function(e) return e,
					concat(mk(TVar(v, e), tv, e.epos), e2)))), tv,
					p);
			case IteratorArray: genIntIter(e1, pt, getNextArrayElement, getArrayLength.bind(ctx));
			case IteratorCustom(get, len): genIntIter(e1, pt, get, len);
			case IteratorIterator: try ForLoop.optimizeForLoopIterator(ctx, v, e1, e2,
					p) catch (ex:Exit) Texpr.forRemap(ctx.t, v, ctx.t.titerator(pt), e1, e2, p);
			case IteratorGenericStack(c):
				var head = c.clFields.get("head");
				if (head == null) throw "assert";
				var tcell = head.cfType;
				var cell = genLocal(ctx, tcell, p);
				var ce = mk(TLocal(cell), tcell, p);
				var initVar = mk(TVar(v, mk(field(ce, "elt"), pt, p)), tv, v.vPos);
				var next = mk(TBinop(OpAssign, ce, mk(field(ce, "next"), tcell, p)), tcell, p);
				var block = switch e2.eexpr {
					case TBlock(el): mk(TBlock([initVar, next].concat(el)), tv, e2.epos);
					case _: mk(TBlock([initVar, next, e2]), tv, p);
				};
				mk(TBlock([
					mk(TVar(cell, mk(field(e1, "head"), tcell, p)), tv, p),
					mk(TWhile(mk(TBinop(OpNotEq, ce, mk(TConst(TNull), tcell, p)), ctx.t.tbool, p), block, NormalWhile), tv, p)
				]), tv, p);
			case IteratorHasNextNext(tmp, next, hasNext):
				var init = mk(TVar(v, next), tv, p);
				mk(TBlock([
					mk(TVar(tmp, e1), tv, p),
					mk(TWhile(hasNext, concat(init, e2), NormalWhile), tv, p)
				]), tv, p);
			case IteratorDynamic: mk(TBlock([]), tv, p);
		};
	}
}

class ForLoop {
	public static function optimizeForLoopIterator(ctx:Typer, v:TVar, e1:TExpr, e2:TExpr, p:Pos):TExpr {
		function getClass(e:TExpr):{c:TClass, tl:TParams}
			return switch follow(e.etype) {
				case TInst(c, pl): {c: c, tl: pl};
				case _: switch e.eexpr {
						case TCast(e, null): getClass(e);
						case TCall({eexpr: TField(_, FInstance(c, pl, cf))}, _): switch follow(applyParams(c.clParams, pl, cf.cfType)) {
								case TFun(s): switch follow(s.ret) {
										case TInst(c, pl): {c: c, tl: pl};
										case _: throw Exit.raise();
									}
								case _: throw Exit.raise();
							}
						case _: throw Exit.raise();
					}
			};
		var cp = getClass(e1);
		var c:TClass = cp.c;
		var tl:Array<T> = cp.tl;
		var hasNext:TClassField;
		try {
			hasNext = rawClassField(function(cf) return applyParams(c.clParams, tl, cf.cfType), c, tl, "hasNext").field;
		} catch (ex:NotFound) {
			throw Exit.raise();
		}
		if (!ctx.allowInline || !hasNext.cfKind.match(Method(MethInline))) throw Exit.raise();
		var it = TInst(c, tl);
		var tmp = genLocal(ctx, it, e1.epos);
		var eit = mk(TLocal(tmp), it, p);
		var eh = makeCall(ctx, mk(TField(eit, FInstance(c, tl, hasNext)), TFun({args: [], ret: ctx.t.tbool}), p), [], ctx.t.tbool, p);
		var next;
		try {
			next = FInstance(c, tl, rawClassField(function(cf) return applyParams(c.clParams, tl, cf.cfType), c, tl, "next").field);
		} catch (ex:NotFound) {
			next = quickFieldDynamic(eit.etype, "next");
		}
		var en = mk(TVar(v, makeCall(ctx, mk(TField(eit, next), TFun({args: [], ret: v.vType}), p), [], v.vType, p)), ctx.t.tvoid, p);
		var block = switch e2.eexpr {
			case TBlock(el): core.ds.Record.withFields(e2, {eexpr: TBlock([en].concat(el))});
			case _: mk(TBlock([en, e2]), ctx.t.tvoid, p);
		};
		return mk(TBlock([
			mk(TVar(tmp, e1), ctx.t.tvoid, p),
			mk(TWhile(eh, block, NormalWhile), ctx.t.tvoid, p)
		]), ctx.t.tvoid, p);
	}

	public static function getUnrollParams(ctx:Typer, e2:Expr, force:Bool):Null<UnrollParameters> {
		var count = 0;
		function loop(e:Expr):Expr return switch e.expr {
			case EContinue | EBreak: throw Exit.raise();
			case _:
				count++;
				core.Ast.mapExpr(loop, e);
		};
		try {
			if (ctx.com.display.dmsKind != DMNone) throw Exit.raise();
			loop(e2);
			return {expressionWeight: count, forceUnroll: force};
		} catch (ex:Exit) {
			return null;
		}
	}

	static function typeForLoopKind(ctx:Typer, display:ForLoopDisplay, kind:IterationKindData, e1:TExpr, e2:Expr, unroll:ForLoopUnroll,
			p:Pos):TExpr {
		var old = ctx.e.inLoop;
		var restore = saveLocals(ctx);
		ctx.e.inLoop = true;
		e2 = switch e2.expr {
			case EBlock(_): e2;
			case _: {expr: EBlock([e2]), pos: e2.pos};
		};
		inline function check(v:TVar,
				ident:IterationIdent):Void if (ident.display != null) display(ctx, {expr: EConst(Ident(v.vName)), pos: v.vPos},
				ident.display,
				MGet, WithTypeTools.withType(v.vType));
		var force = unroll == ForcedUnroll;
		return switch kind {
			case IKNormal(ident):
				var it = IterationKind.ofTexpr(ctx, e1, getUnrollParams(ctx, e2, force), p);
				var v = addLocalWithOrigin(ctx, TVOForVariable, ident.name, it.itType, ident.pos);
				var body = typeExpr(ctx, e2, NoValue);
				check(v, ident);
				ctx.e.inLoop = old;
				restore();
				IterationKind.toTexpr(ctx, v, it, body, p);
			case IKKeyValue(key, value):
				if (force) Common.displayError(ctx.com, "Cannot force inlining on key => value loops", p);
				var it = IterationKind.trySyncIterator(ctx, "keyValueIterator", e1);
				e1 = it.e;
				var tmp = genLocal(ctx, e1.etype, e1.epos);
				var etmp = Texpr.Builder.makeLocal(tmp, tmp.vPos);
				var hasNext = Calls.buildCall(ctx,
					Fields.typeFieldDefaultCfg(ctx, etmp, "hasNext", etmp.epos, MCall([]), WithTypeTools.withType(ctx.t.tbool)), [],
					WithTypeTools.value, etmp.epos);
				var next = Calls.buildCall(ctx, Fields.typeFieldDefaultCfg(ctx, etmp, "next", etmp.epos, MCall([]), /* WITHTYPETODO */ WithTypeTools.value),
					[], WithTypeTools.value, etmp.epos);
				var v = genLocal(ctx, it.t, e1.epos);
				var ev = Texpr.Builder.makeLocal(v, v.vPos);
				var ek = accGet(ctx, Fields.typeFieldDefaultCfg(ctx, ev, "key", ev.epos, MGet, WithTypeTools.value));
				var evalue = accGet(ctx, Fields.typeFieldDefaultCfg(ctx, ev, "value", ev.epos, MGet, WithTypeTools.value));
				var vk = addLocalWithOrigin(ctx, TVOForVariable, key.name, ek.etype, key.pos);
				var vv = addLocalWithOrigin(ctx, TVOForVariable, value.name, evalue.etype, value.pos);
				var body = typeExpr(ctx, e2, NoValue);
				check(vk, key);
				check(vv, value);
				var block = mk(TBlock([
					mk(TVar(v, next), ctx.t.tvoid, next.epos),
					mk(TVar(vk, ek), ctx.t.tvoid, ek.epos),
					mk(TVar(vv, evalue), ctx.t.tvoid, evalue.epos),
					body
				]), ctx.t.tvoid, body.epos);
				var e = mk(TBlock([
					mk(TVar(tmp, e1), ctx.t.tvoid, e1.epos),
					mk(TWhile(hasNext, block, NormalWhile), ctx.t.tvoid, p)
				]), ctx.t.tvoid, p);
				ctx.e.inLoop = old;
				restore();
				e;
		};
	}

	public static function typeForLoop(ctx:Typer, display:ForLoopDisplay, it:Expr, e2:Expr, unroll:ForLoopUnroll, p:Pos):TExpr {
		function ident(dk:Null<DisplayKind>, e:Expr):IterationIdent return switch e.expr {
			case EConst(Ident(i)): {name: i, pos: e.pos, display: dk};
			case EDisplay(e1, dk): ident(dk, e1);
			case _: Error.raiseTypingError("Identifier expected", e.pos);
		};
		function loop(dk:Null<DisplayKind>, e:Expr):{kind:IterationKindData, e:Expr}
			return switch e.expr {
				case EBinop(OpIn, e1, e2):
					var kind = switch e1.expr {
						case EBinop(OpArrow, a, b): IKKeyValue(ident(null, a), ident(null, b));
						case _: IKNormal(ident(dk, e1));
					};
					{kind: kind, e: e2};
				case EDisplay(e1, dk): loop(dk, e1);
				case EBinop(OpArrow, a, {expr: EBinop(OpIn, b, e2)}): {kind: IKKeyValue(ident(null, a), ident(null, b)), e: e2};
				case _:
					if (dk != null) display(ctx, e, dk, MGet, WithTypeTools.value);
					Error.raiseTypingError("For expression should be 'v in expr'", it.pos);
			};
		var parsed = loop(null, it);
		return typeForLoopKind(ctx, display, parsed.kind, typeExpr(ctx, parsed.e, WithTypeTools.value), e2, unroll, p);
	}
}
