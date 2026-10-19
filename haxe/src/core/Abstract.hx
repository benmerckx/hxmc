package core;

import core.Ast;
import core.TType;
import core.ds.NotFound;
import core.TFunctions.*;
import core.TUnification.*;
import core.TUnification.UnificationContext;
import core.TUnification.RecStack;
import core.TPrinting.*;
import core.MetaList.StrictMeta;
import core.Meta as MetadataTools;

// port: from haxe/src/core/abstract.ml.
class Abstract {
	public static function buildAbstract(a:TAbstract):Void {
		if (a.aImpl != null) a.aImpl.clBuild();
	}

	public static function findCastField<V>(uctx:UnificationContext, find:UnificationContext->Null<V>):V {
		var found:Null<V>;
		try {
			var context = core.ds.Record.copy(uctx);
			context.allowTransitiveCast = false;
			found = find(context);
		} catch (_:NotFound) {
			found = find(uctx);
		}
		if (found == null) throw NotFound.raise();
		return found;
	}

	public static function findFieldFrom(uctx:UnificationContext, a:T, b:T, ab:TAbstract, tl:TParams):CastField {
		for (field in ab.aFromField) if (unifiesFromField(uctx, a, b, ab, tl, field)) return field;
		throw NotFound.raise();
	}

	public static function findFieldTo(uctx:UnificationContext, a:T, b:T, ab:TAbstract, tl:TParams):CastField {
		for (field in ab.aToField) if (unifiesToField(uctx, a, b, ab, tl, field)) return field;
		throw NotFound.raise();
	}

	public static function findToFrom(uctx:UnificationContext, a:T, b:T, a1:TAbstract, tl1:TParams, a2:TAbstract,
			tl2:TParams):AbstractCastField {
		buildAbstract(a1);
		buildAbstract(a2);
		return findCastField(uctx, function(uctx):Null<AbstractCastField> {
			if (unifiesAbstracts(uctx, a, b, a1, tl1, a2, tl2)) return null;
			try return {
				abs: a1,
				params: tl1,
				field: findFieldTo(uctx, a, b, a1, tl1)
			} catch (_:NotFound) return {abs: a2, params: tl2, field: findFieldFrom(uctx, a, b, a2, tl2)};
		});
	}

	public static function findFrom(uctx:UnificationContext, a:T, ab:TAbstract, tl:TParams):CastField {
		buildAbstract(ab);
		if (follow(a) == tDynamic) {
			for (field in ab.aFromField) if (follow(field.type) == tDynamic) return field;
			throw NotFound.raise();
		}
		var b = TAbstract(ab, tl);
		return findCastField(uctx, function(uctx) return unifiesFrom(uctx, a, b, ab, tl) ? null : findFieldFrom(uctx, a, b, ab, tl));
	}

	public static function findTo(uctx:UnificationContext, b:T, ab:TAbstract, tl:TParams):CastField {
		buildAbstract(ab);
		if (follow(b) == tDynamic) {
			for (field in ab.aToField) if (follow(field.type) == tDynamic) return field;
			throw NotFound.raise();
		}
		var a = TAbstract(ab, tl);
		return findCastField(uctx, function(uctx) return unifiesTo(uctx, a, b, ab, tl) ? null : findFieldTo(uctx, a, b, ab, tl));
	}

	/**
		Returns type parameters and the list of types, which should be known at compile time
		to be able to choose multitype specialization.
	**/
	public static function findMultitypeParams(a:TAbstract, pl:TParams):{types:TParams, definitiveTypes:TParams} {
		var meta = MetadataTools.get(MetadataTools.MultiType, a.aMeta);
		if (meta.exprs.length == 0) return {types: pl, definitiveTypes: pl};
		var relevant = new haxe.ds.StringMap<T->T>();
		for (e in meta.exprs) {
			function loop(f:T->T, e:Expr):Void switch e.expr {
				case EConst(Ident(s)):
					relevant.set(s, f);
				case EMeta({meta: Custom(":followWithAbstracts")}, e1):
					loop(followWithAbstracts, e1);
				case _:
					Error.raiseTypingError("Type parameter expected", e.pos);
			};
			loop(function(t) return t, e);
		}
		var definitiveTypes = [];
		if (a.aParams.length != pl.length) throw "List.map2";
		var tl = [
			for (i in 0...pl.length) {
				var t = pl[i];
				var f = relevant.get(a.aParams[i].ttpName);
				if (f != null) {
					t = f(t);
					definitiveTypes.unshift(t);
					t;
				} else if (!hasMono(t)) t else tDynamic;
			}
		];
		return {types: tl, definitiveTypes: definitiveTypes};
	}

	public static function findMultitypeSpecializationType(a:TAbstract, pl:TParams):T {
		var uctx = defaultUnificationContext();
		var m = mkMono();
		var result = findMultitypeParams(a, pl);
		findTo(uctx, m, a, result.types);
		for (t in result.definitiveTypes) if (hasMono(t)) throw NotFound.raise();
		return follow(m);
	}

	public static function getUnderlyingTypeWithStack(stack:RecStack<T>, a:TAbstract, pl:TParams, returnFirst:Bool = false):T {
		inline function maybeRecurse(t:T):T {
			function loop(t:T):T return switch t {
				case TMono(r): r.tmType == null ? t : loop(r.tmType);
				case TLazy(f): loop(lazyType(f));
				case TAbstract(a, [t1]) if (a.aPath.pack.length == 0 && a.aPath.name == "Null"): TAbstract(a, [loop(t1)]);
				case TType(t, tl): loop(applyTypedef(t, tl));
				case TAbstract(a, tl) if (!MetadataTools.has(MetadataTools.CoreType, a.aMeta)):
					if (recStackExists(function(t2) return fastEq(t, t2), stack)) {
						var pctx = printContext();
						// (the stack is pushed at its end, oldest first: upstream's List.rev (t :: stack))
						var chain:Array<T> = stack.concat([t]);
						Error.raiseTypingError("Abstract chain detected: " + [for (t in chain) sType(pctx, t)].join(" -> "), a.aPos);
					}
					getUnderlyingTypeWithStack(stack, a, tl);
				case _: t;
			};
			// Even if only the first underlying type was requested
			// keep traversing to detect mutually recursive abstracts
			var result = recStackLoop(stack, TAbstract(a, pl), loop, t);
			return returnFirst ? t : result;
		}
		try {
			if (!MetadataTools.has(MetadataTools.MultiType, a.aMeta)) throw NotFound.raise();
			return findMultitypeSpecializationType(a, pl);
		} catch (_:NotFound) {
			return MetadataTools.has(MetadataTools.CoreType, a.aMeta) ? tDynamic : maybeRecurse(applyParams(a.aParams, pl, a.aThis));
		}
	}

	public static function getUnderlyingType(a:TAbstract, pl:TParams,
			returnFirst:Bool = false):T return getUnderlyingTypeWithStack(newRecStack(), a, pl, returnFirst);

	public static function followWithAbstracts(t:T):T return switch follow(t) {
		case TAbstract(a, tl) if (!MetadataTools.has(MetadataTools.CoreType, a.aMeta)): followWithAbstracts(getUnderlyingType(a, tl));
		case t: t;
	};

	public static function followWithForwardCtor(t:T, build:Bool = false):T return switch follow(t) {
		case TAbstract(a, tl):
			if (build) buildAbstract(a);
			if (MetadataTools.has(MetadataTools.ForwardNew, a.aMeta)
				&& !(a.aImpl != null && a.aConstructor != null)) followWithForwardCtor(getUnderlyingType(a, tl,
					true)) else TAbstract(a, tl);
		case t: t;
	};

	public static function followWithAbstractsWithoutNull(t:T):T return switch followWithoutNull(t) {
		case TAbstract(a, _) if (a.aPath.pack.length == 0 && a.aPath.name == "Null"): t;
		case TAbstract(a,
			tl) if (!MetadataTools.has(MetadataTools.CoreType, a.aMeta)): followWithAbstractsWithoutNull(getUnderlyingType(a, tl));
		case t: t;
	};
}
