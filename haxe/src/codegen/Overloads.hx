package codegen;

import core.TType;
import core.TFunctions;
import core.TUnification;
import core.Meta as CoreMeta;
import core.MetaList.StrictMeta;
import core.Abstract;
import core.TOther.ExtType;
import core.TFunctions.NotFound;
import core.Globals;
import typing.FieldCallCandidate;
import core.TFunctions.*;
import core.TUnification.*;
import haxe.ds.Vector;
import core.ds.VectorTools.vector;

using core.ds.VectorTools;

class Overloads {
	// port: inline: see core.ds.List
	extern overload public static inline function allPairs<A>(f:A->A->Bool, a:Array<A>, b:Array<A>):Bool {
		var r = a.length == b.length;
		if (r) for (i in 0...a.length) if (!f(a[i], b[i])) {
			r = false;
			break;
		}
		return r;
	}
	extern overload public static inline function allPairs<A>(f:A->A->Bool, a:Vector<A>, b:Vector<A>):Bool {
		var r = a.length == b.length;
		if (r) for (i in 0...a.length) if (!f(a[i], b[i])) {
			r = false;
			break;
		}
		return r;
	}

	public static function sameOverloadArgs(t1:T, t2:T, f1:TClassField, f2:TClassField, ?getVmtype:T->T):Bool {
		var transform = getVmtype == null ? function(t) return t : getVmtype;
		var eq = function(a, b) return typeIseq(transform(a), transform(b));
		if (f1.cfParams.length != f2.cfParams.length) return false;
		for (i in 0...f1.cfParams.length) {
			var p1 = f1.cfParams[i], p2 = f2.cfParams[i];
			// port: preserves upstream's comparison of the second parameter's constraints to itself.
			if (p1.ttpName != p2.ttpName || !allPairs(eq, getConstraints(p2), getConstraints(p2))) return false;
		}
		function arguments(a:Vector<{name:String, optional:Bool, type:T}>, b:Vector<{name:String, optional:Bool, type:T}>):Bool {
			if (a.length != b.length) return false;
			// TODO: do we want to compare n and o here?
			for (i in 0...a.length) if (!eq(a[i].type, b[i].type)) return false;
			return true;
		}
		t1 = follow(applyParams(f1.cfParams, extractParamTypes(f2.cfParams), t1));
		return switch [followWithCoro(t1), followWithCoro(t2)] {
			case [NotCoro(TFun(s1)), NotCoro(TFun(s2))]: arguments(s1.args, s2.args);
			case [Coro(s1), Coro(s2)]: arguments(s1.args, s2.args);
			case _: false;
		}
	}

	public static function collectOverloads(map:T->T, c:TClass, name:String):Array<{type:T, field:TClassField}> {
		var acc:Array<{type:T, field:TClassField}> = [];
		function loop(map:T->T, c:TClass):Void {
			inline function add(cf:TClassField):Void {
				var t = map(cf.cfType);
				if (!core.ds.ArrayTools.exists(acc,
					function(v) return sameOverloadArgs(t, v.type, cf, v.field))) acc.unshift({type: t, field: cf});
			}
			try {
				var cf = c.clFields.get(name);
				if (cf == null) throw NotFound.raise();
				switch cf.cfKind {
					case Var(_):
					case Method(_):
						add(cf);
						for (f in cf.cfOverloads) add(f);
				}
			} catch (_:NotFound) {}
			if (c.clSuper != null) {
				var s = c.clSuper, tl = s.params.map(map);
				loop(function(t) return applyParams(s.cls.clParams, tl, map(t)), s.cls);
			} else if (hasClassFlag(c, CInterface)) for (s in c.clImplements) {
				var tl = s.params.map(map);
				loop(function(t) return applyParams(s.cls.clParams, tl, map(t)), s.cls);
			}
		}
		loop(map, c);
		acc.reverse();
		return acc;
	}
}

@:structInit class ConversionRate {
	public var conversions:Int;
	public var params:Int;

	public inline function new(conversions:Int, params:Int) {
		this.conversions = conversions;
		this.params = params;
	}

	public inline function clone():ConversionRate return new ConversionRate(conversions, params);
}

/** Overload resolution **/
class Resolution {
	static function nullAbstract(a:TAbstract):Bool return a.aPath.pack.length == 0 && a.aPath.name == "Null";

	public static function simplifyT(t:T):T return switch t {
		case TInst(_, _), TEnum(_, _): t;
		case TAbstract(a, [inner]) if (nullAbstract(a)):
			var st = simplifyT(inner);
			switch st {
				case TAbstract(ab, _) if (CoreMeta.has(CoreType, ab.aMeta)): TAbstract(a, vector(simplifyT(st)));
				case TEnum(_, _): TAbstract(a, vector(simplifyT(st)));
				case _: st;
			}
		case TAbstract(a, _) if (CoreMeta.has(CoreType, a.aMeta)): t;
		case TAbstract(a, tl): simplifyT(Abstract.getUnderlyingType(a, tl));
		case TType(td, tl): simplifyT(applyTypedef(td, tl));
		case TMono(m): m.tmType == null ? tDynamic : simplifyT(m.tmType);
		case TAnon(_): tDynamic;
		case TDynamic(_), TFun(_): t;
		case TLazy(f): simplifyT(lazyType(f));
	}

	// rate type parameters
	public static function rateTp(a:TParams, b:TParams):Int {
		if (a.length != b.length) throw "Invalid_argument: List.iter2";
		var n = 0;
		for (i in 0...a.length) if (!typeIseq(a[i], b[i])) n++;
		return n;
	}

	static function rate(c:Int, p:Int):ConversionRate return {conversions: c, params: p};

	/**
		The rate function returns an ( int * int ) type.
		The smaller the int, the best rated the caller argument is in comparison with the callee.

		The first int refers to how many "conversions" would be necessary to convert from the callee to the caller type, and
		the second refers to the type parameters.
	**/
	// port: max_int is 0x7fffffff, which keeps the ordering of the Dynamic and
	// implicit-cast penalties.
	public static function rateConv(cacc:Int, tfun:T, targ:T):ConversionRate return switch [simplifyT(tfun), simplifyT(targ)] {
		case [TInst(cf, tlf), TInst(ca, tla)] if (hasClassFlag(cf, CInterface)):
			// breadth-first
			var cur = {acc: 0, c: ca, tl: tla}, stack = [cur];
			while (true) {
				if (stack.length == 0) {
					var s = cur.c.clSuper;
					if (s == null) throw NotFound.raise();
					cur = {acc: cur.acc + 1, c: s.cls, tl: s.params.map(function(t) return applyParams(cur.c.clParams, cur.tl, t))};
					stack = [cur];
				} else {
					var v = stack.shift();
					if (v.c == cf) return rate(cacc + v.acc, rateTp(tlf, v.tl));
					for (s in v.c.clImplements) stack.push({
						acc: v.acc + 1,
						c: s.cls,
						tl: s.params.map(function(t) return applyParams(v.c.clParams, v.tl, t))
					});
				}
			}
			throw NotFound.raise();
		case [TInst(cf, tlf), TInst(ca, tla)]:
			var acc = 0;
			while (cf != ca) {
				var s = ca.clSuper;
				if (s == null) throw NotFound.raise();
				tla = s.params.map(function(t) return applyParams(ca.clParams, tla, t));
				ca = s.cls;
				acc++;
			}
			rate(cacc + acc, rateTp(tlf, tla));
		case [TEnum(ef, tlf), TEnum(ea, tla)]:
			if (ef != ea) throw NotFound.raise();
			rate(cacc, rateTp(tlf, tla));
		case [TDynamic(_), TDynamic(_)]: rate(cacc, 0);
		case [TDynamic(_), _]: rate(0x7fffffff, 0); // a function with dynamic will always be worst of all
		case [TAbstract(a, _), TDynamic(_)] if (CoreMeta.has(CoreType, a.aMeta) && !nullAbstract(a)): rate(cacc + 2, 0); // a dynamic to a basic type will have an "unboxing" penalty
		case [_, TDynamic(_)]: rate(cacc + 1, 0);
		case [TAbstract(a, [tf]), TAbstract(b, [ta])] if (nullAbstract(a) && nullAbstract(b)): rateConv(cacc, tf, ta);
		case [TAbstract(a, [tf]), ta] if (nullAbstract(a)): rateConv(cacc + 1, tf, ta);
		case [tf, TAbstract(a, [ta])] if (nullAbstract(a)): rateConv(cacc + 1, tf, ta);
		case [TAbstract(af, tlf), TAbstract(aa, tla)]:
			if (af == aa) rate(cacc, rateTp(tlf, tla)); else {
				for (t in af.aFrom) try {
					return rateConv(cacc + 1, applyParams(af.aParams, tlf, t), targ);
				} catch (_:NotFound) {}
				for (t in aa.aTo) try {
					return rateConv(cacc + 1, tfun, applyParams(aa.aParams, tla, t));
				} catch (_:NotFound) {}
				throw NotFound.raise();
			}
		case [TFun(_), TFun(_)]: rate(cacc, 0); // unify will make sure they are compatible
		// SAM conversion: lambda passed where a functional-interface class is
		// expected. Rate by how closely the lambda's signature matches the SAM
		// method's signature so specificity ordering still works between two
		// SAM-parametered overloads.
		case [TInst(cf, tlf), TFun(_)] if (hasClassFlag(cf, CFunctionalInterface)):
			var sam = core.TOther.TClassTools.getSingularInterfaceField(cf.clOrderedFields);
			if (sam == null) throw NotFound.raise();
			rateConv(cacc + 1, applyParams(cf.clParams, tlf, sam.cfType), targ);
		case _: throw NotFound.raise();
	}

	static function compareRate(a:ConversionRate, b:ConversionRate):Int
		return a.conversions < b.conversions ? -1 : a.conversions > b.conversions ? 1 : a.params < b.params ? -1 : a.params > b.params ? 1 : 0;

	public static function isBest(a:Array<ConversionRate>, b:Array<ConversionRate>):Bool {
		if (!Overloads.allPairs(function(v1, v2) return compareRate(v1, v2) <= 0, a, b)) return false;
		for (i in 0...a.length) if (compareRate(a[i], b[i]) < 0) return true;
		return false;
	}

	public static function rmDuplicates<A>(acc:Array<FieldCallCandidateData<A>>,
			rest:Array<FieldCallCandidateData<A>>):Array<FieldCallCandidateData<A>> {
		for (f in rest) if (!core.ds.ArrayTools.exists(acc, function(g) return typeIseq(f.fcType, g.fcType))) acc.unshift(f);
		return acc;
	}

	public static function countOptionals(t:T):Int return switch follow(t) {
		case TFun(s):
			var n = 0;
			for (a in s.args) if (a.optional) n++;
			n;
		case _: 0;
	}

	public static function fewerOptionals<A>(acc:Array<FieldCallCandidateData<A>>,
			compatible:Array<FieldCallCandidateData<A>>):Array<FieldCallCandidateData<A>> {
		for (f in compatible) if (acc.length == 0) acc = [f];
		else {
			var old = countOptionals(acc[0].fcType),
				next = countOptionals(f.fcType);
			if (old == next) acc.unshift(f);
			else if (old > next) acc = [f];
		}
		return acc;
	}

	public static function reduceCompatible<A>(compatible:Array<FieldCallCandidateData<A>>):Array<FieldCallCandidateData<A>> {
		compatible = fewerOptionals([], rmDuplicates([], compatible));
		if (compatible.length < 2) return compatible;
		inline function rateArg(t:T, e:TExpr):ConversionRate return switch e.eexpr {
			// if the argument is an implicit cast, we need to start with a penalty
			// The penalty should be higher than any other implicit cast - other than Dynamic
			// since Dynamic has a penalty of max_int, we'll impose max_int - 1 to it
			case TMeta(m, _) if (m.meta == core.MetaList.StrictMeta.ImplicitCast): rate(0x7fffffff - 1, 0);
			case _: rateConv(0, t, e.etype);
		}
		// convert compatible into ( rate * compatible_type ) list
		function mkRate(acc:Array<ConversionRate>, el:Vector<TExpr>,
				args:Vector<{name:String, optional:Bool, type:T}>):{rates:Array<ConversionRate>, rest:Bool} {
			if (el.length == 0 && args.length == 0) return {rates: acc, rest: false};
			if (el.length > 0 && args.length > 0 && args[0].optional) return mkRate(acc, el.slice(1), args.slice(1));
			if (args.length == 1 && ExtType.isRest(follow(args[0].type))) {
				var t = switch follow(args[0].type) {
					case TAbstract(a, [t]) if (a.aPath.pack.join(".") == "haxe" && a.aPath.name == "Rest"): t;
					case _: Globals.die("", "overloads.ml");
				};
				return {rates: acc.concat(el.mapToArray(function(e) return rateArg(t, e))), rest: true};
			}
			if (el.length > 0 && args.length > 0) {
				acc.unshift(rateArg(args[0].type, el[0]));
				return mkRate(acc, el.slice(1), args.slice(1));
			}
			// this can happen on pf_pad_nulls = false targets, see #10434
			if (el.length == 0) return {rates: acc, rest: false};
			return Globals.die("", "overloads.ml");
		}
		var best:Null<{rates:Array<ConversionRate>, rest:Bool, list:Array<FieldCallCandidateData<A>>}> = null;
		for (f in compatible) {
			var args = switch follow(f.fcType) {
				case TFun(s): s.args;
				case _: Globals.die("", "overloads.ml");
			};
			try {
				var r = mkRate([], f.fcArgs, args);
				// If it's the first one, assume it's the best
				if (best == null || isBest(r.rates, best.rates)) best = {rates: r.rates, rest: r.rest, list: [f]};
				else if (isBest(best.rates, r.rates)) {}
				// If they are equal, we prefer the one without Rest (issue #10205)
				else if (r.rest && !best.rest) {} else if (!r.rest && best.rest) best = {
					rates: r.rates,
					rest: r.rest,
					list: [f]
				};
				else best.list.unshift(f);
			} catch (_:NotFound) {}
		}
		if (best == null) return [];
		best.list.reverse();
		return best.list;
	}
}
