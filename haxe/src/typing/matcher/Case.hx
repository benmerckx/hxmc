package typing.matcher;

import core.WithType as WithTypeTools;
import core.WithType.WithTypeValue;
import core.TType;
import core.Ast;
import core.Ast.Expr;
import core.Globals;
import core.Globals.Pos;
import core.TFunctions.*;
import core.TOther.*;
import core.TOther;
import core.TUnification.Monomorph;
import core.Error.*;
import core.Error;
import core.WithType;
import context.Typecore.*;
import context.Typecore;
import context.AbstractCast;
import typing.matcher.Pattern;
import typing.matcher.Bind;
import core.ds.VectorTools.vector;

using core.ds.VectorTools;

@:structInit class CaseData {
	public var caseGuard:Null<TExpr>;
	public var caseExpr:Null<TExpr>;
	public var casePos:Pos;

	public inline function new(caseGuard:Null<TExpr>, caseExpr:Null<TExpr>, casePos:Pos) {
		this.caseGuard = caseGuard;
		this.caseExpr = caseExpr;
		this.casePos = casePos;
	}

	public inline function clone():CaseData return new CaseData(caseGuard, caseExpr, casePos);
}

@:structInit class CaseRow {
	public var caseData:CaseData;
	public var bindings:core.ds.MlList<Bind>;
	public var patterns:core.ds.MlList<PatternData>;

	public inline function new(caseData:CaseData, bindings:core.ds.MlList<Bind>, patterns:core.ds.MlList<PatternData>) {
		this.caseData = caseData;
		this.bindings = bindings;
		this.patterns = patterns;
	}

	public inline function clone():CaseRow return new CaseRow(caseData, bindings, patterns);
}

/*
	Switch-level type parameter refinement.

	Two kinds of type variables participate:
	1. Formal type parameters from ctx.type_params (TInst with KTypeParameter).
	2. Free (unbound) monomorphisms in the type arguments of the top-level
	   enum / enum-abstract subject types (or tuple elements thereof).

	The analysis of *which* free monomorphisms are eligible for substitution is
	done once per switch by collect_free_monos, before any cases are examined.
	Per-case, make_subst creates fresh copies so that each case can independently
	refine the type through pattern matching.
*/

class Case {
	// Collect free (unbound) monomorphisms from the type arguments of direct
	// enum / enum-abstract subjects. Only top-level positions are examined:
	// for a single subject, its enum-abstract or enum type args; for a tuple
	// subject (TFun(args, fake_tuple_type)), each element independently.
	// Nested field types (e.g. in a structural match) are NOT traversed.
	public static function collectFreeMonos(t:T):Array<TMono> {
		var acc:Array<TMono> = [];
		function walk(ty:T):Void {
			switch ty {
				case TMono(m):
					if (m.tmType != null) walk(m.tmType);
					else if (!core.ds.ArrayTools.exists(acc, function(other) return m == other)) acc.unshift(m);
				case TEnum(_, tl) | TInst(_, tl) | TAbstract(_, tl):
					for (t in tl) walk(t);
				case TType(t, tl):
					walk(applyTypedef(t, tl));
				case TFun(s):
					for (arg in s.args) walk(arg.type);
					walk(s.ret);
				case TAnon(a):
					var names = [for (name in a.aFields.keys()) name];
					names.sort(core.ds.Key.compareStrings);
					for (name in names) walk(a.aFields.get(name).cfType);
				case TLazy(f):
					walk(lazyType(f));
				case TDynamic(t):
					if (t != null) walk(t);
			}
		}
		function collectOne(ty:T):Void switch ty {
			case TAbstract(a, tl) if (a.aEnum):
				for (t in tl) walk(t);
			case TEnum(_, tl):
				for (t in tl) walk(t);
			case TMono(m):
				if (m.tmType != null) collectOne(m.tmType);
			case TType(t, tl):
				collectOne(applyTypedef(t, tl));
			case _:
		};
		function collectTop(ty:T):Void switch ty {
			case TFun(s) if (s.ret == ExprToPattern.fakeTupleType):
				for (arg in s.args) collectOne(follow(arg.type));
			case TMono(m):
				if (m.tmType != null) collectTop(m.tmType);
			case TType(t, tl):
				collectTop(applyTypedef(t, tl));
			case _:
				collectOne(ty);
		};
		collectTop(follow(t));
		return acc;
	}

	// Create a per-case substitution from pre-collected free monomorphs and
	// the formal type parameters. Returns (subst, rebind_unrefined, unsubst).
	public static function makeSubst(ctx:Typer, freeMonos:Array<TMono>):{subst:T->T, rebindUnrefined:Void->Void, unsubst:T->T} {
		var params:TypeParams = ctx.typeParams;
		var tpClasses = params.map(function(ttp) return ttp.ttpClass);
		var tpMemo:Array<{original:TClass, mono:TMono}> = [];
		var fmMemo:Array<{original:TMono, mono:TMono}> = [];
		function getOrCreateTp(c:TClass):TMono {
			for (entry in tpMemo) if (entry.original == c) return entry.mono;
			var m = Monomorph.create();
			tpMemo.unshift({original: c, mono: m});
			return m;
		}
		function getOrCreateFree(original:TMono):TMono {
			for (entry in fmMemo) if (entry.original == original) return entry.mono;
			var m = Monomorph.create();
			fmMemo.unshift({original: original, mono: m});
			return m;
		}
		// subst: replaces formal type params everywhere, and replaces
		// collected free monos wherever they appear.
		function subst(ty:T):T return switch ty {
			case TMono(m):
				if (m.tmType != null) subst(m.tmType); else
					// Only substitute free monos that were pre-collected from
					// top-level enum/enum-abstract subject type arguments.
					if (core.ds.ArrayTools.exists(freeMonos,
					function(other) return m == other)) TMono(getOrCreateFree(m)); else ty;
			case TInst(c = {clKind: KTypeParameter(_)},
				[]) if (core.ds.ArrayTools.exists(tpClasses, function(other) return c == other)): TMono(getOrCreateTp(c));
			case _: map(subst, ty);
		};
		function rebindUnrefined():Void {
			for (entry in tpMemo) if (entry.mono.tmType == null) Monomorph.doBind(entry.mono, TInst(entry.original, vector()));
		}
		function unsubst(ty:T):T {
			return switch ty {
				case TMono(m):
					if (m.tmType != null) unsubst(m.tmType) else {
						// Physical equality (==) for monomorph identity
						var original:Null<T> = null;
						for (entry in tpMemo) if (m == entry.mono) {
							original = TInst(entry.original, vector());
							break;
						}
						if (original == null) for (entry in fmMemo) if (m == entry.mono) {
							original = TMono(entry.original);
							break;
						}
						original == null ? ty : original;
					}
				case _: map(unsubst, ty);
			};
		}
		return {subst: subst, rebindUnrefined: rebindUnrefined, unsubst: unsubst};
	}

	public static function make(ctx:Typer, t:T, freeMonos:Array<TMono>, el:haxe.ds.Vector<Expr>, eg:Null<Expr>, eoAst:Null<Expr>,
			withType:WithTypeValue, postfixMatch:Bool, p:Pos):{
		caseData:CaseData,
		bindings:Array<Bind>,
		pattern:PatternData
	} {
		// port: `e :: el` folded from the end (upstream recurses on the tail): `a | (b | c)`
		function collapseCase(values:haxe.ds.Vector<Expr>):Expr {
			if (values.length == 0) return raiseTypingError("case without pattern", p);
			var e2 = values[values.length - 1];
			var i = values.length - 1;
			while (i-- > 0) {
				var e = values[i];
				e2 = {expr: EBinop(OpOr, e, e2), pos: core.Ast.punion(e.pos, e2.pos)};
			}
			return e2;
		}
		var e = collapseCase(el);
		var substitution = makeSubst(ctx, freeMonos),
			subst = substitution.subst;
		var save = saveLocals(ctx);
		var locals:core.ds.PersistentMap<String, TVar> = ctx.f.locals;
		var names = [for (name in locals.keys()) name];
		names.sort(core.ds.Key.compareStrings);
		// port: `(v, t_old) :: acc` as a push: oldTypes is read from the end
		var oldTypes:Array<{variable:TVar, type:T}> = [];
		for (name in names) {
			var v = locals.find(name), old = v.vType;
			v.vType = subst(v.vType);
			oldTypes.push({variable: v, type: old});
		}
		var oldRet = ctx.e.ret;
		ctx.e.ret = subst(ctx.e.ret);
		var pctx = {
			ctx: ctx,
			currentLocals: new haxe.ds.StringMap<{v:TVar, p:Pos}>(),
			ctxLocals: ctx.f.locals,
			orLocals: null,
			inReification: false,
			isPostfixMatch: postfixMatch,
			unsubst: substitution.unsubst
		};
		var pat = ExprToPattern.make(pctx, true, subst(t), e);
		// For any type-param mono not refined by the pattern, rebind it to T
		substitution.rebindUnrefined();
		var guard = if (eg == null) null else {
			var e = typeExpr(ctx, eg, WithTypeTools.value);
			AbstractCast.castOrUnify(ctx, ctx.t.tbool, e, e.epos);
		};
		var body = switch [eoAst, withType] {
			case [null, WithType(t, _)]:
				unify(ctx, ctx.t.tvoid, t, e.pos);
				null;
			case [null, _]: null;
			case [e, WithType(t, _)]:
				var e = typeExpr(ctx, e, WithTypeTools.withType(subst(t)));
				AbstractCast.castOrUnify(ctx, subst(t), e, e.epos);
			case [e, _]: typeExpr(ctx, e, withType);
		};
		ctx.e.ret = oldRet;
		var i = oldTypes.length;
		while (i > 0) {
			var old = oldTypes[--i];
			old.variable.vType = old.type;
		}
		save();
		return {caseData: {caseGuard: guard, caseExpr: body, casePos: p}, bindings: [], pattern: pat};
	}
}
