package typing;

import core.TType;
import core.TUnification;
import core.TUnification.TUnification.*;
import core.TUnification.Unify_error;
import core.TOther.ExtType;
import core.ds.Hashtbl;
import core.ds.NotFound;
import core.MetaList.StrictMeta;
import core.TFunctions.*;
import core.TOther.*;
import core.TOther;
import core.Globals.*;

typedef PathFieldMapping<A> = {var pfmPath:core.Globals.GlobalTypePath; var pfmParams:TypeParams; var pfmFields:TypeMap<TClassField>; var pfmConverted:Null<Array<{name:String, value:A}>>; var pfmArity:Int;}

class AnonIdMode {
	public static var defaultMode:UnificationContext = core.ds.Record.withFields(defaultUnificationContext(),
		{nullFollowMode: NeverFollow});
	public static var strict:UnificationContext = {
		allowTransitiveCast: false,
		allowAbstractCast: false,
		allowDynamicToCast: false,
		allowArgNameMismatch: false,
		allowOptionalMismatch: false,
		equalityKind: EqStricter,
		equalityUnderlying: false,
		strictFieldKind: true,
		opaqueFieldParams: false,
		allowFinalInvariance: false,
		typeParamMode: TpDefault,
		nullFollowMode: NeverFollow,
		unifyStack: newRecStack(),
		eqStack: newRecStack(),
		varianceStack: newRecStack(),
		abstractCastStack: newRecStack(),
		unifyNewMonos: newRecStack(),
		applyParamsStack: {
			value: []
		}
	};
}

class TanonIdentification<A> {
	// port: OCaml Hashtbl order: genjvm iterates this table.
	var pfms:core.ds.OcamlHashtbl<core.Globals.GlobalTypePath, PathFieldMapping<A>> = new core.ds.OcamlHashtbl(core.ds.OcamlHash.hashPath,
		context.Common.samePath);
	var pfmMutex = new sys.thread.Mutex();
	var pfmByArity:Array<Array<PathFieldMapping<A>>> = [];
	var addPfmMutex = new sys.thread.Mutex();
	var num = 0;

	public function new() {}

	public static function replaceMono(asDynamic:Bool, t:T):T {
		var visited = [];
		function loop(t:T):T return switch t {
			case TMono({tmType: null}): asDynamic ? tDynamic : t;
			case TAnon(an): if (visited.indexOf(an) >= 0) t; else {
					visited.unshift(an);
					map(loop, t);
				}
			case _: map(loop, t);
		};
		return loop(t);
	}

	public static function countFields(pm:TypeMap<TClassField>):Int {
		var i = 0;
		for (_ in pm.keys()) i++;
		return i;
	}

	public static function pfmOfTypedef<A>(td:TDef):PathFieldMapping<A> return switch follow(td.tType) {
		case TAnon(an): {
				pfmPath: td.tPath,
				pfmParams: td.tParams,
				pfmFields: an.aFields,
				pfmConverted: null,
				pfmArity: countFields(an.aFields)
			};
		case _: throw "assert";
	};

	public function getPfms():core.ds.OcamlHashtbl<core.Globals.GlobalTypePath, PathFieldMapping<A>> return pfms;

	public function addPfm(path:core.Globals.GlobalTypePath, pfm:PathFieldMapping<A>):Void {
		addPfmMutex.acquire();
		while (pfmByArity.length <= pfm.pfmArity) pfmByArity.push([]);
		pfmByArity[pfm.pfmArity].push(pfm);
		pfms.replace(path, pfm);
		addPfmMutex.release();
	}

	public function unify(uctx:UnificationContext, tc:T, pfm:PathFieldMapping<A>):Void {
		inline function pairs(fields:TypeMap<TClassField>):Array<{cf:TClassField, other:TClassField}> {
			var acc = [];
			var names = [for (n in pfm.pfmFields.keys()) n];
			names.sort(core.ds.Key.compareStrings);
			for (n in names) {
				var cf = pfm.pfmFields.get(n);
				var other = fields.get(cf.cfName);
				if (other == null) throw NotFound.raise();
				acc.unshift({cf: cf, other: other});
			}
			return acc;
		}
		inline function fieldType(cf:TClassField):T return uctx.opaqueFieldParams ? cf.cfType : monomorphs(cf.cfParams, cf.cfType);
		try {
			var monos:Array<T> = switch follow(tc) {
				case TInst(c, tl):
					var ps = pairs(c.clFields);
					var ms = pfm.pfmParams.map(function(_) return mkMono());
					for (pair in ps) {
						if (!unifyKind(uctx, pair.other.cfKind, pair.cf.cfKind)) throw new Unify_error([UnifyCustom("kind mismatch")]);
						core.TUnification.unify(applyParams(c.clParams, tl, fieldType(pair.other)),
							applyParams(pfm.pfmParams, ms, fieldType(pair.cf)));
					}
					ms;
				case TAnon(an):
					var fields = an.aFields.copy();
					var ps = pairs(an.aFields);
					var ms = pfm.pfmParams.map(function(_) return mkMono());
					for (pair in ps) {
						if (!uctx.allowOptionalMismatch
							&& core.Meta.has(StrictMeta.Optional,
								pair.cf.cfMeta) != core.Meta.has(StrictMeta.Optional,
								pair.other.cfMeta)) throw new Unify_error([UnifyCustom("optional mismatch")]);
						if (!unifyKind(uctx, pair.other.cfKind, pair.cf.cfKind)) throw new Unify_error([UnifyCustom("kind mismatch")]);
						fields.remove(pair.cf.cfName);
						typeEqCustom(uctx, fieldType(pair.other), applyParams(pfm.pfmParams, ms, fieldType(pair.cf)));
					}
					if (countFields(fields) > 0) throw new Unify_error([UnifyCustom("not enough fields")]);
					ms;
				case _: throw new Unify_error([UnifyCustom("bad type")]);
			};
			// Check if we applied Void to a return type parameter... (#3463)
			for (t in monos) switch follow(t) {
				case TMono(r):
					Monomorph.bind(r, tDynamic);
				case t:
					if (ExtType.isVoid(t)) throw new Unify_error([UnifyCustom("return mono")]);
			}
		} catch (e:NotFound) {
			throw new Unify_error([]);
		}
	}

	public function findCompatible(uctx:UnificationContext, arity:Int, tc:T):PathFieldMapping<A> {
		if (arity >= pfmByArity.length) throw NotFound.raise();
		for (pfm in pfmByArity[arity]) try {
			unify(uctx, tc, pfm);
			return pfm;
		} catch (e:Unify_error) {}
		throw NotFound.raise();
	}

	public function identifyTypedef(td:TDef):Void {
		function loop(t:T):Void switch t {
			case TAnon(an) if ((an.aStatus == Closed || an.aStatus == Const) && countFields(an.aFields) > 0):
				addPfm(td.tPath, pfmOfTypedef(td));
			case TMono({tmType: t}) if (t != null):
				loop(t);
			case TLazy(f):
				loop(lazyType(f));
			case _:
		};
		loop(td.tType);
	}

	function protect<B>(f:Void->B):B {
		pfmMutex.acquire();
		try {
			var r = f();
			pfmMutex.release();
			return r;
		} catch (e:haxe.Exception) {
			pfmMutex.release();
			throw e;
		}
	}

	public function identifyAnon(uctx:UnificationContext, an:TAnon):PathFieldMapping<A> {
		inline function makePfm(path:core.Globals.GlobalTypePath):PathFieldMapping<A> return {
			pfmPath: path,
			pfmParams: [],
			pfmFields: an.aFields,
			pfmConverted: null,
			pfmArity: countFields(an.aFields)
		};
		var path:Null<core.Globals.GlobalTypePath> = switch an.aStatus {
			case ClassStatics(c): c.clPath;
			case EnumStatics(e): e.ePath;
			case AbstractStatics(a): a.aPath;
			case _: null;
		};
		if (path != null) return protect(function() {
			try {
				return pfms.find(path);
			} catch (e:NotFound) {
				var pfm = makePfm(path);
				addPfm(path, pfm);
				return pfm;
			}
		});
		var arity = 0;
		var fields = an.aFields.copy();
		var names = [for (n in (an.aFields.keys() : Iterator<String>)) n];
		names.sort(core.ds.Key.compareStrings);
		for (n in names) {
			var cf = an.aFields.get(n);
			arity++;
			fields.set(cf.cfName, core.ds.Record.withFields(cf, {cfType: replaceMono(uctx.equalityKind != EqStricter, cf.cfType)})); // TODO: not very robust
		}
		an = core.TType.TAnon.withStatusRef(fields, an.aStatusRef);
		return protect(function() {
			try {
				return findCompatible(uctx, arity, TAnon(an));
			} catch (e:NotFound) {
				var id = num++;
				var path:core.Globals.GlobalTypePath = {pack: ["haxe", "generated"], name: 'Anon$id'};
				var pfm = makePfm(path);
				addPfm(path, pfm);
				return pfm;
			}
		});
	}

	public function identify(uctx:UnificationContext, acceptAnons:Bool, t:T):Null<PathFieldMapping<A>> {
		function loop(t:T):Null<PathFieldMapping<A>> return switch t {
			case TType(td, tl): try {
					protect(function() return pfms.find(td.tPath));
				} catch (e:NotFound) {
					loop(applyTypedef(td, tl));
				}
			case TMono({tmType: t}) if (t != null): loop(t);
			case TAbstract(a, tl) if (!core.Meta.has(StrictMeta.CoreType, a.aMeta)): loop(core.Abstract.getUnderlyingType(a, tl));
			case TAbstract({aPath: {pack: [], name: "Null"}}, [t]): loop(t);
			case TLazy(f): loop(lazyType(f));
			case TAnon(an) if (acceptAnons && countFields(an.aFields) > 0): identifyAnon(uctx, an);
			case _: null;
		};
		return loop(t);
	}
}
