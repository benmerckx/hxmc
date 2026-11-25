package hxmc.es;

import haxe.ds.ObjectMap;
import haxe.ds.StringMap;
import core.TType;
import core.TFunctions.*;
import core.Meta;

// Properties that JavaScript sees as properties (docs/js.md): a Haxe property whose reads and writes are each `get`,
// `set` or `never` is a JS accessor of its name (`get x() {...}`, `set x(v) {...}`), and its accessors' calls `o.x` and
// `o.x = v`; its storage (@:isVar) the class's #private field (`#x`), where only the class's code uses it and reflection
// does not (stored, reflected, storageNamed).
//
// A property and its accessors form a family with the ones that override or implement them: subclasses' accessors, the
// interfaces' declarations. The code that reads `o.x` reads whichever class's accessor is behind `o`, so a family takes
// the new form as a whole or not at all (any extern member, or a member property of another shape, keeps it as it is).
//
// A family's getters, or its setters, stay methods (`get_x`, `set_x`, which the JS accessor calls) where something
// needs one of them as a method: a setter whose call's value is used (`a = o.x = v`: JS's `o.x = v` is `v`, the
// method's result may be another), an accessor taken as a value, named dynamically (through a structure, Dynamic,
// untyped code, a string), dynamic, kept (@:keep) or exposed (@:expose).
//
// The families come from the types; what the code does with the accessors, from the lowerings (Chunk.Lowering notes it,
// the replay tells it here); `decide` settles it before anything is assembled or printed, which then only asks.
// (Reflect.getProperty and setProperty find the JS accessor by the property's name: such properties are not in
// `$hx.properties`.)
class Properties {
	public final families:Array<Family> = [];

	// accessor field to its family (the families that change: those that may, until `decide`)
	final byAccessor = new ObjectMap<TClassField, Family>();
	// the properties that change (decide)
	final changed = new ObjectMap<TClassField, Bool>();
	// the properties with storage (@:isVar), their classes, their families: the storage a #private field of the class,
	// which only its code reads (`#x` is the class body's)
	final owners = new ObjectMap<TClassField, TClass>();
	final storage = new ObjectMap<TClassField, Family>();
	// what the code names dynamically (`'` + a string constant's), of that what it reads but through a structure, untyped
	// code's words
	final names = new StringMap<Bool>();
	final unstructured = new StringMap<Bool>();
	final words = new StringMap<Bool>();

	// (the program's classes)
	public function new(com:generators.Gctx) {
		var classes = [for (t in com.types) switch t {
			case TClassDecl(c) if (!c.clKind.match(KAbstractImpl(_) | KModuleFields(_))): c;
			case _: continue;
		}];
		var byDecl = new ObjectMap<TClassField, Family>();
		function familyOf(c:TClass, p:TClassField):Family {
			var f = byDecl.get(p);
			if (f == null) {
				f = new Family(realName(p));
				families.push(f);
				byDecl.set(p, f);
			}
			f.decls.push({c: c, p: p});
			return f;
		}
		function family(p:TClassField):Family {
			var f = byDecl.get(p);
			while (f.merged != null) f = f.merged;
			return f;
		}
		function union(a:Family, b:Family) {
			if (a == b) return;
			if (a.excluded == null) a.excluded = b.excluded;
			for (d in b.decls) a.decls.push(d);
			for (x in b.getters) a.getters.push(x);
			for (x in b.setters) a.setters.push(x);
			b.merged = a;
		}

		// the class or interface that declares p for c (its own field, or an ancestor's)
		function decl(c:TClass, name:String):Null<{c:TClass, p:TClassField}> {
			var p = own(c, name);
			if (p != null) return p.cfKind.match(Var(_)) ? {c: c, p: p} : null;
			if (hasClassFlag(c, CInterface)) {
				for (i in c.clImplements) switch decl(i.cls, name) {
					case null:
					case d: return d;
				}
				return null;
			}
			return c.clSuper == null ? null : decl(c.clSuper.cls, name);
		}

		// the declarations
		for (c in classes) for (p in c.clFields) if (isProperty(p)) familyOf(c, p);
		for (c in classes) for (p in c.clStatics) if (isProperty(p)) {
			var f = new Family(realName(p));
			f.statics = true;
			f.decls.push({c: c, p: p});
			families.push(f);
			var statics = ownStatics(c);
			var g = statics.get("get_" + realName(p)), s = statics.get("set_" + realName(p));
			if (g != null) add(f, g, true);
			if (s != null) add(f, s, false);
		}

		// a class's declarations joined to its interfaces'
		function interfaces(c:TClass, into:Array<TClass>) {
			for (i in c.clImplements) if (into.indexOf(i.cls) < 0) {
				into.push(i.cls);
				interfaces(i.cls, into);
			}
		}
		for (c in classes) {
			var is = [];
			interfaces(c, is);
			for (i in is) for (ip in i.clFields) if (byDecl.exists(ip)) {
				var mine = decl(c, realName(ip));
				if (mine == null || !byDecl.exists(mine.p)) {
					// (declared otherwise here: a family that cannot change)
					family(ip).excluded = 'implemented by ${dotPath(c)} as a field of another kind';
					continue;
				}
				union(family(mine.p), family(ip));
			}
		}

		// the accessors, and their overrides
		for (c in classes) for (a in c.clFields) {
			var n = realName(a);
			var getter = StringTools.startsWith(n, "get_");
			if (!getter && !StringTools.startsWith(n, "set_")) continue;
			var d = decl(c, n.substr(4));
			if (d == null || !byDecl.exists(d.p)) continue;
			add(family(d.p), a, getter);
		}

		// (a subclass's field of the name, outside the family: the property redeclared, which a JavaScript accessor of the
		// ancestor's would answer for)
		for (c in classes) for (x in c.clFields) {
			var s = c.clSuper;
			while (s != null) {
				var y = own(s.cls, realName(x));
				if (y != null && byDecl.exists(y)) {
					var f = family(y);
					if (f.excluded == null && !Lambda.exists(f.decls, o -> o.p == x)) f.excluded = 'redeclared by ${dotPath(c)}';
				}
				s = s.cls.clSuper;
			}
		}

		// what each family's members are
		for (f in families) if (f.merged == null && f.excluded == null) {
			var p0 = f.decls[0].p;
			for (d in f.decls) {
				if (hasClassFlag(d.c, CExtern)) f.excluded = 'extern ${dotPath(d.c)}';
				else if (d.p.cfName != p0.cfName) f.excluded = 'named ${p0.cfName} and ${d.p.cfName} in the output';
				else {
					// (an ancestor's field of its name, outside the family; or a native ancestor, whose members the extern
					// may not declare: haxe.Exception's `message` reads js.lib.Error's, which js.lib.Error leaves out)
					var s = d.c.clSuper;
					while (s != null && f.excluded == null) {
						if (hasClassFlag(s.cls, CExtern)) f.excluded = 'extends extern ${dotPath(s.cls)}';
						else switch byName(s.cls).get(p0.cfName) {
							case null:
							case x if (!Lambda.exists(f.decls, o -> o.p == x)): f.excluded = 'shadows ${dotPath(s.cls)}.${x.cfName}';
							case _:
						}
						s = s.cls.clSuper;
					}
				}
			}
			// (names a class has of its own in JavaScript)
			switch p0.cfName {
				case "constructor" | "__proto__" | "prototype": f.excluded = 'named ${p0.cfName}';
				case "name" | "length" | "caller" | "arguments" if (f.statics): f.excluded = 'a static named ${p0.cfName}';
				case _:
			}
			for (a in f.getters.concat(f.setters)) {
				if (a.cfKind.match(Method(MethDynamic))) f.keep(a, "dynamic");
				if (Meta.has(Meta.Keep, a.cfMeta)) f.keep(a, "@:keep");
				if (Meta.has(Meta.Expose, a.cfMeta)) f.keep(a, "@:expose");
			}
		}
		var roots = [for (f in families) if (f.merged == null) f];
		families.resize(0);
		for (f in roots) families.push(f);
		for (f in families) if (f.excluded == null) {
			for (a in f.getters.concat(f.setters)) byAccessor.set(a, f);
			for (d in f.decls) if (isPhysicalField(d.p)) {
				owners.set(d.p, d.c);
				storage.set(d.p, f);
			}
		}
	}

	// ---- what the code does (the lowerings' notes, in the program's order)

	// a call of a method of an accessor's name (args: its arguments; discarded: its value used for nothing)
	public function called(a:TClassField, args:Int, discarded:Bool) {
		var f = byAccessor.get(a);
		if (f == null) return;
		var getter = f.isGetter(a);
		if (getter ? args != 0 : args != 1) f.keep(a, "called with other arguments");
		else if (!getter && !discarded) f.keep(a, "value used");
	}

	// a method taken as a value (a closure)
	public function taken(a:TClassField) {
		var f = byAccessor.get(a);
		if (f != null) f.keep(a, "taken as a value");
	}

	// a field's name read dynamically (structural: a structure's; Dynamic's, js.Syntax.field's)
	public function named(n:String, structural:Bool) {
		names.set(n, true);
		if (!structural) unstructured.set(n, true);
	}

	// a string constant (reflection may name an accessor by it: `"get_x"`, never a name @:native gives it)
	public function string(s:String) names.set("'" + s, true);

	static final fieldWords = ~/(?:\.\s*|["'])([A-Za-z_$][A-Za-z0-9_$]*)/;

	// untyped code (the names it uses as fields: `.name`, or quoted)
	public function raw(code:String) {
		var rest = code;
		while (fieldWords.match(rest)) {
			words.set(fieldWords.matched(1), true);
			rest = fieldWords.matchedRight();
		}
	}

	// a property's storage read or written by the code of class `by` (null: code outside any class's body: an `__init__`, a
	// split's initializer)
	public function stored(p:TClassField, by:Null<TClass>) {
		var c = owners.get(p);
		if (c != null && c != by) exclude(p, by == null ? "storage used outside a class" : 'storage used by ${dotPath(by)}');
	}

	// the classes whose instances reflection reads the fields of (Reflect.fields, JSON.stringify), of a value of their type
	final reflectedClasses = new ObjectMap<TClass, Bool>();

	public function reflected(t:T) switch follow(t) {
		case TAbstract({aPath: {pack: [], name: "Null"}}, [p]): reflected(p);
		case TInst(c, _) if (!c.clKind.match(KTypeParameter(_))): reflectedClasses.set(c, true);
		case _:
	}

	// whether reflection reads the fields of c's instances: as c's, an ancestor's, an interface's
	function readByReflection(c:TClass):Bool {
		if (reflectedClasses.exists(c)) return true;
		for (i in c.clImplements) if (readByReflection(i.cls)) return true;
		return c.clSuper != null && readByReflection(c.clSuper.cls);
	}

	// a property's family that cannot change (its storage where the class cannot have it: a static's value set after the class)
	public function exclude(p:TClassField, why:String) {
		var f = storage.get(p);
		if (f != null && f.excluded == null) f.excluded = why;
	}

	// whether a property has storage its family may give a #private field (Chunk asks before `decide`)
	public inline function mayBack(p:TClassField):Bool return storage.exists(p);

	// what the families are, once all the code has told
	public function decide() {
		for (f in families) {
			for (a in f.getters.concat(f.setters)) switch namedHow(a) {
				case null:
				case why: f.keep(a, why);
			}
			// (storage that reflection may read by the property's name, as Haxe has it: a field, not a #private one)
			if (f.excluded == null) for (d in f.decls) if (owners.exists(d.p)) switch storageNamed(d.p) {
				case null:
				case why: f.excluded = "storage " + why;
			}
			if (f.excluded != null) for (a in f.getters.concat(f.setters)) byAccessor.remove(a);
			if (f.excluded == null && f.getters.length + f.setters.length > 0) for (d in f.decls) changed.set(d.p, true);
		}
	}

	// whether a property's storage is a #private field (of its class)
	public inline function backed(p:TClassField):Bool return changed.exists(p) && owners.exists(p);

	// (a structure reads a class's property where its field unified with the structure's, as the typer marks it: not by name)
	function storageNamed(p:TClassField):Null<String> {
		var c = owners.get(p);
		if (c != null && readByReflection(c)) return "read by reflection";
		if (hasClassFieldFlag(p, CfStructurallyUsed)) return "unified with a structure";
		if (unstructured.exists(p.cfName) || unstructured.exists(realName(p))) return "named dynamically";
		if (names.exists("'" + realName(p))) return "named in a string";
		if (words.exists(p.cfName) || words.exists(realName(p))) return "named in untyped code";
		return null;
	}

	function namedHow(a:TClassField):Null<String> {
		if (names.exists(a.cfName) || names.exists(realName(a))) return "named dynamically";
		if (names.exists("'" + realName(a))) return "named in a string";
		if (words.exists(a.cfName) || words.exists(realName(a))) return "named in untyped code";
		return null;
	}

	// ---- the output's (decided: asked in parallel)

	// the family of an accessor that changes, if it is one
	public inline function familyOf(a:TClassField):Null<Family> return byAccessor.get(a);

	// whether a property keeps Haxe's form (and its place in `$hx.properties`)
	public inline function unchanged(p:TClassField):Bool return !changed.exists(p);

	// a field's name in the code (@:native renames it in the output, and its accessors are `get_<name>` by this one)
	public static function realName(cf:TClassField):String {
		for (m in cf.cfMeta) if (m.meta == Meta.RealPath) switch m.exprs[0].expr {
			case EConst(String(s, _)): return s;
			case _:
		}
		return cf.cfName;
	}

	// whether a method has an accessor's name (Lower notes its calls)
	public static function accessorNamed(cf:TClassField):Bool {
		if (!cf.cfKind.match(Method(_))) return false;
		inline function is(n:String) return StringTools.startsWith(n, "get_") || StringTools.startsWith(n, "set_");
		return is(cf.cfName) || is(realName(cf));
	}

	final owns = new ObjectMap<TClass, StringMap<TClassField>>();

	// c's own instance field of this real name
	function own(c:TClass, name:String):Null<TClassField> {
		var m = owns.get(c);
		if (m == null) {
			m = new StringMap();
			for (cf in c.clFields) m.set(realName(cf), cf);
			owns.set(c, m);
		}
		return m.get(name);
	}

	final statics = new ObjectMap<TClass, StringMap<TClassField>>();
	final fieldsByName = new ObjectMap<TClass, StringMap<TClassField>>();

	// c's statics by their real names
	function ownStatics(c:TClass):StringMap<TClassField> {
		var m = statics.get(c);
		if (m == null) {
			m = new StringMap();
			for (cf in c.clStatics) m.set(realName(cf), cf);
			statics.set(c, m);
		}
		return m;
	}

	// c's own instance fields by their names in the output
	function byName(c:TClass):StringMap<TClassField> {
		var m = fieldsByName.get(c);
		if (m == null) {
			m = new StringMap();
			for (cf in c.clFields) m.set(cf.cfName, cf);
			fieldsByName.set(c, m);
		}
		return m;
	}

	function add(f:Family, a:TClassField, getter:Bool) {
		// (an extern accessor is always inlined: none in the output)
		if (hasClassFieldFlag(a, CfExtern)) return;
		if (getter) f.getters.push(a) else f.setters.push(a);
	}

	// `(get|never, set|never)`, at least one of them a call (@:isVar: with storage, which the output has as a #private field)
	public static function isProperty(p:TClassField):Bool return switch p.cfKind {
		case Var({vRead: r, vWrite: w}):
			(r.match(AccCall | AccNever) && w.match(AccCall | AccNever) && (r == AccCall || w == AccCall));
		case _: false;
	}

	// what became of each (-D hxmc.js.properties_report)
	public function report():String {
		var b = new StringBuf();
		var pure = 0, keeps = 0, excluded = 0, statics = 0, none = 0;
		var reasons = new StringMap<Int>(), excl = new StringMap<Int>();
		var details = [];
		inline function where(f:Family) return [for (d in f.decls) dotPath(d.c)].join(" ") + "." + f.name;
		for (f in families) {
			if (f.getters.length + f.setters.length == 0) {
				// (its accessors inlined or removed: nothing to generate)
				none++;
				continue;
			}
			if (f.statics) statics++;
			if (f.excluded != null) {
				details.push('unchanged ${where(f)}: ${f.excluded}');
				excluded++;
				var k = StringTools.startsWith(f.excluded, "extern") ? "extern member" : f.excluded.indexOf("has storage") >= 0 ? "a member has storage" : StringTools.startsWith(f.excluded, "implemented") ? "implemented by a field of another kind" : f.excluded;
				excl.set(k, (excl.exists(k) ? excl.get(k) : 0) + 1);
				continue;
			}
			for (a => r in f.kept) details.push('methods ${where(f)} (${a.cfName}): $r');
			if (f.kept.keys().hasNext()) {
				keeps++;
				var seen = new StringMap<Bool>();
				for (r in f.kept) if (!seen.exists(r)) {
					seen.set(r, true);
					reasons.set(r, (reasons.exists(r) ? reasons.get(r) : 0) + 1);
				}
			} else pure++;
		}
		b.add('properties: ${families.length} families (${statics} static)\n');
		b.add('  JS accessors only:      $pure\n');
		b.add('  JS accessors + methods: $keeps\n');
		for (r => n in reasons) b.add('    $r: $n\n');
		b.add('  unchanged:              $excluded\n');
		for (r => n in excl) b.add('    $r: $n\n');
		b.add('  no accessor left (inlined, or removed): $none\n');
		details.sort(Reflect.compare);
		for (d in details) b.add('    $d\n');
		return b.toString();
	}

	static function dotPath(c:TClass):String return generators.Genjs.dotPath(c.clPath);
}

class Family {
	public final name:String;
	public final decls:Array<{c:TClass, p:TClassField}> = [];
	public final getters:Array<TClassField> = [];
	public final setters:Array<TClassField> = [];
	public var statics = false;
	public var merged:Null<Family>;
	// why it keeps its form, if it does
	public var excluded:Null<String>;
	// the accessors that something needs as methods, and why
	public final kept = new ObjectMap<TClassField, String>();
	// whether its getters, its setters stay methods (all of them: a call of one may reach another)
	public var keepGetters = false;
	public var keepSetters = false;

	public function new(name) this.name = name;

	// the property, as the output names it
	public var property(get, never):TClassField;

	inline function get_property() return decls[0].p;

	public inline function isGetter(a:TClassField):Bool return getters.indexOf(a) >= 0;

	public inline function keeps(getter:Bool):Bool return getter ? keepGetters : keepSetters;

	public function keep(a:TClassField, why:String) {
		if (!kept.exists(a)) kept.set(a, why);
		if (isGetter(a)) keepGetters = true else keepSetters = true;
	}
}
