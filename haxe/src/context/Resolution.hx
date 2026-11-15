package context;

import core.Globals;
import core.Globals.Pos;
import core.TType;
import core.Meta;
import core.TFunctions as TypeOps;
import core.TUnification;
import core.TUnification.Monomorph;
import core.MetaList.StrictMeta;
import core.Meta as MetadataTools;
import core.Texpr;
import core.Warning;
import core.WarningList;
import Type as StdType;

enum ResolutionKind {
	RTypeImport(alias:String, type:ModuleType);
	RClassFieldImport(alias:String, cls:TClass, field:TClassField);
	RAbstractFieldImport(alias:String, abs:TAbstract, cls:TClass, field:TClassField);
	REnumConstructorImport(alias:String, en:TEnum, field:TEnumField);
	RWildcardPackage(pack:Array<String>);
	RClassStatics(cls:TClass);
	REnumStatics(en:TEnum);
	RLazy(f:Void->Null<ResolvedImport>);
}

@:structInit class ResolvedImport {
	public var rKind:ResolutionKind;
	public var rPos:Pos;

	public inline function new(rKind:ResolutionKind, rPos:Pos) {
		this.rKind = rKind;
		this.rPos = rPos;
	}

	public inline function clone():ResolvedImport return new ResolvedImport(rKind, rPos);
}

class Resolution {
	public static function mkResolution(kind:ResolutionKind, p:Pos):ResolvedImport return {rKind: kind, rPos: p};

	public static function lazyResolution(f:Void->Null<ResolvedImport>):ResolvedImport return mkResolution(RLazy(f), Globals.nullPos);

	public static function moduleTypeResolution(mt:ModuleType, alias:Null<String>,
			p:Pos):ResolvedImport return mkResolution(RTypeImport(alias == null ? core.TFunctions.tName(mt) : alias, mt), p);

	public static function staticFieldResolution(c:TClass, cf:TClassField, alias:Null<String>,
			p:Pos):ResolvedImport return mkResolution(RClassFieldImport(alias == null ? cf.cfName : alias, c, cf), p);

	public static function staticAbstractFieldResolution(a:TAbstract, c:TClass, cf:TClassField, alias:Null<String>,
			p:Pos):ResolvedImport return mkResolution(RAbstractFieldImport(alias == null ? cf.cfName : alias, a, c, cf), p);

	public static function enumConstructorResolution(en:TEnum, ef:TEnumField, alias:Null<String>,
			p:Pos):ResolvedImport return mkResolution(REnumConstructorImport(alias == null ? ef.efName : alias, en, ef), p);

	public static function classStaticsResolution(c:TClass, p:Pos):ResolvedImport return mkResolution(RClassStatics(c), p);

	public static function enumStaticsResolution(en:TEnum, p:Pos):ResolvedImport return mkResolution(REnumStatics(en), p);

	public static function wildcardPackageResolution(pack:Array<String>,
			p:Pos):ResolvedImport return mkResolution(RWildcardPackage(pack), p);

	public static function asImportableStatic(c:TClass, cf:TClassField, p:Pos):Null<{name:String, resolution:ResolvedImport}> {
		if (core.TFunctions.hasMeta(StrictMeta.NoImportGlobal, cf.cfMeta)) return null;
		return switch c.clKind {
			case KAbstractImpl(a): a.aEnum && !core.TFunctions.hasClassFieldFlag(cf,
					CfEnum) ? null : {name: cf.cfName, resolution: staticAbstractFieldResolution(a, c, cf, null, p)};
			case _: {name: cf.cfName, resolution: staticFieldResolution(c, cf, null, p)};
		};
	}

	public static function sResolutionKind(kind:ResolutionKind):String return switch kind {
		case RTypeImport(_, mt): "RTypeImport(" + Globals.sTypePath(core.TFunctions.tPath(mt)) + ")";
		case RClassFieldImport(_, c, cf): "RClassFieldImport(" + Globals.sTypePath(c.clPath) + ", " + cf.cfName + ")";
		case RAbstractFieldImport(_, a, _, cf): "RAbstractFieldImport(" + Globals.sTypePath(a.aPath) + ", " + cf.cfName + ")";
		case REnumConstructorImport(_, en, ef): "REnumConstructorImport(" + Globals.sTypePath(en.ePath) + ", " + ef.efName + ")";
		case RWildcardPackage(sl): "RWildcardPackage(" + sl.join(".") + ")";
		case RClassStatics(c): "RClassStatics(" + Globals.sTypePath(c.clPath) + ")";
		case REnumStatics(en): "REnumStatics(" + Globals.sTypePath(en.ePath) + ")";
		case RLazy(_): "RLazy";
	};
}

class ResolutionList {
	final id:Array<String>;
	var list:Array<ResolvedImport> = [];
	var resolvedLazies = true;
	var cachedTypeImports = true;
	var typeImportCache:Map<String, {type:ModuleType, pos:Pos}> = [];

	public function new(id:Array<String>) this.id = id;

	public function add(res:ResolvedImport):Void {
		list = [res].concat(list);
		// If we import a type, we automatically want to import all its constructors in case of
		// enums and enum abstracts. We add a RLazy in front of the list so that it takes priority
		// over the type itself. When resolved, it will insert its fields into the resolution list.
		switch res.rKind {
			case RTypeImport(_, mt):
				var expanded = expandEnumConstructors(mt);
				if (expanded != null) list = [expanded].concat(list);
				cachedTypeImports = false;
			case RLazy(_):
				resolvedLazies = false;
			case _:
		}
	}

	public function resolveLazies():Void {
		if (resolvedLazies) return;
		resolvedLazies = true;
		var pending = list.copy();
		var acc:Array<ResolvedImport> = [];
		while (pending.length != 0) {
			var res = pending.shift();
			switch res.rKind {
				case RLazy(f):
					var next = f();
					if (next != null) pending.unshift(next);
				case _:
					acc.push(res);
			}
		}
		list = acc;
	}

	public function resolveUnforced(i:String):ResolvedImport {
		for (res in list) switch res.rKind {
			case RClassStatics(c):
				c.clBuild();
				var cf = c.clStatics.get(i);
				if (cf != null) {
					var found = Resolution.asImportableStatic(c, cf, res.rPos);
					if (found != null) return found.resolution;
				}
			case REnumStatics(en):
				var ef = en.eConstrs.get(i);
				if (ef != null
					&& !core.TFunctions.hasMeta(StrictMeta.NoImportGlobal,
						ef.efMeta)) return Resolution.enumConstructorResolution(en, ef, null, res.rPos);
			case RTypeImport(alias, _), RClassFieldImport(alias, _, _), RAbstractFieldImport(alias, _, _, _),
				REnumConstructorImport(alias, _, _):
				if (core.ds.StrTools.eq(alias, i)) return res;
			case RLazy(_), RWildcardPackage(_):
		}
		throw core.ds.NotFound.raise();
	}

	public function resolve(i:String):ResolvedImport {
		resolveLazies();
		return resolveUnforced(i);
	}

	public function expandEnumConstructors(mt:ModuleType):Null<ResolvedImport> return switch mt {
		case TAbstractDecl(a) if (a.aImpl != null && a.aEnum): Resolution.classStaticsResolution(a.aImpl, Globals.nullPos);
		case TEnumDecl(en): Resolution.enumStaticsResolution(en, Globals.nullPos);
		case TTypeDecl(t):
			resolvedLazies = false;
			Resolution.lazyResolution(function() return switch core.TFunctions.follow(t.tType) {
				case TEnum(e, _): expandEnumConstructors(TEnumDecl(e));
				case TAbstract(a, _) if (a.aEnum): expandEnumConstructors(TAbstractDecl(a));
				case _: null;
			});
		case TClassDecl(_), TAbstractDecl(_): null;
	};

	public function save():Void->Void {
		var savedList = list;
		var savedResolved = resolvedLazies;
		return function() {
			list = savedList;
			resolvedLazies = savedResolved;
		};
	}

	public function getList():Array<ResolvedImport> return list;

	public function setList(value:Array<ResolvedImport>):Void {
		list = value;
		cachedTypeImports = false;
	}

	public function cloneAs(id:Array<String>):ResolutionList {
		resolveLazies();
		var rl = new ResolutionList(id);
		rl.setList(list);
		rl.cacheTypeImports();
		return rl;
	}

	public function cacheTypeImports():Void {
		if (cachedTypeImports) return;
		cachedTypeImports = true;
		typeImportCache = [];
		var index = list.length;
		// loop first to retain correct order
		while (index > 0) {
			var res = list[--index];
			switch res.rKind {
				case RTypeImport(alias, mt):
					typeImportCache.set(alias, {type: mt, pos: res.rPos});
				case _:
			}
		}
	}

	public function findTypeImport(alias:String):{type:ModuleType, pos:Pos} {
		cacheTypeImports();
		if (!typeImportCache.exists(alias)) throw core.ds.NotFound.raise();
		return typeImportCache.get(alias);
	}

	public function extractTypeImports():Array<{type:ModuleType, pos:Pos}> {
		var out = [];
		for (res in list) switch res.rKind {
			case RTypeImport(_, mt):
				out.push({type: mt, pos: res.rPos});
			case _:
		}
		return out;
	}

	public function extractFieldImports():core.ds.PMap<{type:ModuleType, name:String, pos:Pos}> {
		resolveLazies();
		var out = core.ds.PMap.empty();
		for (res in list) switch res.rKind {
			case RClassFieldImport(alias, c, cf):
				out = out.add(alias, {type: TClassDecl(c), name: cf.cfName, pos: res.rPos});
			case RClassStatics(c):
				for (cf in c.clOrderedStatics) {
					var imported = Resolution.asImportableStatic(c, cf, Globals.nullPos);
					if (imported != null) out = out.add(imported.name,
						{type: TClassDecl(c), name: cf.cfName, pos: imported.resolution.rPos});
				}
			case _:
		}
		return out;
	}

	public function extractWildcardPackages():Array<{pack:Array<String>, pos:Pos}> {
		var out = [];
		for (res in list) switch res.rKind {
			case RWildcardPackage(sl):
				out.push({pack: sl, pos: res.rPos});
			case _:
		}
		return out;
	}
}
