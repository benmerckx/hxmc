package core;

import core.Ast;
import core.Define;
import core.Meta;
import core.MetaList.StrictMeta as MetaTag;
import core.TType;

// Which types are hxmc's scoped code (docs/plans/lowlevel.md, "Syntax"): the
// typer's part (a scoped class is made from an object literal, as a
// @:structInit one) and the lowering's (hxmc.ir) ask the same. Scoped: a
// class or enum with @:hxmc.scoped; a module's level fields (Haxe's module
// statics) when the module's type of its own name is scoped; every class and
// enum of the packages -D hxmc.scoped-packages=a.b,c lists (and their
// subpackages). @:hxmc.gc keeps one of those GC code (a main, say).
class HxmcScoped {
	static var packagesFrom:Null<String> = null;
	static var packages:Array<String> = [];

	// the define's packages, read again when it changes (the compilation server)
	public static function configure(defines:DefineContext) {
		var v = Define.rawDefinedValueSafe(defines, "hxmc.scoped_packages", "");
		if (v == packagesFrom) return;
		packagesFrom = v;
		packages = [for (p in v.split(",")) if (StringTools.trim(p) != "") StringTools.trim(p)];
	}

	static inline function marked(ml:Metadata):Bool
		return ml.length > 0 && core.Meta.has(MetaTag.Custom(":hxmc.scoped"), ml);

	static inline function optedOut(ml:Metadata):Bool
		return ml.length > 0 && core.Meta.has(MetaTag.Custom(":hxmc.gc"), ml);

	static function inPackage(pack:Array<String>):Bool {
		if (packages.length == 0) return false;
		var s = pack.join(".");
		for (p in packages)
			if (s == p || StringTools.startsWith(s, p + ".")) return true;
		return false;
	}

	public static function isClass(c:TClass):Bool {
		if (marked(c.clMeta)) return true;
		if (optedOut(c.clMeta) || c.clKind.match(KAbstractImpl(_))) return false;
		switch c.clKind {
			case KModuleFields(m):
				// (the module's type of its own name)
				var name = m.mPath.name;
				for (t in m.mTypes)
					switch t {
						case TClassDecl(o) if (o != c && o.clPath.name == name && marked(o.clMeta)): return true;
						case TEnumDecl(e) if (e.ePath.name == name && marked(e.eMeta)): return true;
						case _:
					}
			case _:
		}
		return inPackage(c.clPath.pack);
	}

	public static function isEnum(e:TEnum):Bool
		return marked(e.eMeta) || !optedOut(e.eMeta) && inPackage(e.ePath.pack);

	// a typedef whose structures are struct values (typing.HxmcValues): as a
	// class, by its metadata, its module's type of its own name, its package
	public static function isTypedef(t:TDef):Bool {
		if (marked(t.tMeta)) return true;
		if (optedOut(t.tMeta)) return false;
		var name = t.tModule.mPath.name;
		for (o in t.tModule.mTypes)
			switch o {
				case TClassDecl(c) if (c.clPath.name == name && marked(c.clMeta)): return true;
				case TEnumDecl(e) if (e.ePath.name == name && marked(e.eMeta)): return true;
				case _:
			}
		return inPackage(t.tPath.pack);
	}

	// a scoped class with instance variables: an object literal makes one
	// (Typer.typeObjectDecl), as for @:structInit
	public static function structInit(c:TClass):Bool {
		if (!isClass(c)) return false;
		for (cf in c.clOrderedFields)
			if (cf.cfKind.match(Var(_))) return true;
		return false;
	}
}
