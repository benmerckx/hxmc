package hxmc.es;

import haxe.ds.StringMap;
import core.Globals;
import core.TType;
import core.TFunctions.*;
import core.Meta;
import core.Texpr;
import generators.Gctx;

// -D hxmc.js.minify.fields: short names for the program's fields, classes' and structures' alike, but for the names
// something outside the program reads (a name, not a field: a name kept is kept everywhere, so whatever unifies with
// what, the names agree).
//
// Kept, as the code shows them: the externs' fields (those of an extern ancestor too), a field read off `Dynamic`, the
// structure an unchecked cast makes (`(cast x).name`), a constant name given to reflection, the words of untyped code,
// of the runtime and of the included files, rtti's metadata, `@:native` names, an `@:expose`d class's public API, and
// the names JavaScript itself reads (`toString`, `then`, ...).
//
// Shared (its fields' names kept, those of its fields' types too): a type marked `@:shared`, what the program gives an
// extern (an argument, a value of an extern's field: the outside reads it), the structures of the externs' signatures,
// and what goes through std's reflection by name (haxe.Json, Reflect, Type's fields, haxe.Serializer). Nothing else is:
// a value of a type that goes into `Dynamic` and is read by name otherwise needs `@:shared`.
class FieldNames {
	static final KEEP = [
		// (what JavaScript reads by name)
		"constructor", "prototype", "toString", "valueOf", "toJSON", "then", "length", "name"
	];

	static final SHARED = core.MetaList.StrictMeta.Custom(":shared");

	// what reads a value's fields all the way down (its fields' values' fields), not its own keys only
	static final DEEP = [
		"haxe.Json.stringify" => true, "haxe.format.JsonPrinter.print" => true, "JSON.stringify" => true, "haxe.Serializer.run" => true,
		"haxe.Serializer.serialize" => true, "haxe.Template.execute" => true
	];

	// reflection by name, std's (haxe.Json, an extern on JavaScript) and JavaScript's: the arguments whose types it
	// reads the fields of (a class's: of its instances), its own keys (but DEEP's)
	static final READS:Map<String, Array<Int>> = [
		"haxe.Json.stringify" => [0], "haxe.format.JsonPrinter.print" => [0], "Reflect.fields" => [0], "Reflect.field" => [0],
		"Reflect.setField" => [0, 2], "Reflect.getProperty" => [0], "Reflect.setProperty" => [0, 2], "Reflect.hasField" => [0],
		"Reflect.deleteField" => [0], "Reflect.copy" => [0], "Type.getInstanceFields" => [0], "Type.getClassFields" => [0],
		"haxe.Serializer.run" => [0], "haxe.Serializer.serialize" => [0], "haxe.Template.execute" => [0, 1],
		// (JavaScript's, by the native path an std extern has: haxe.Json is `JSON`)
		"JSON.stringify" => [0], "Object.keys" => [0], "Object.values" => [0], "Object.entries" => [0], "Object.assign" => [0, 1],
		"Object.getOwnPropertyNames" => [0], "Object.fromEntries" => [0],
		"js.lib.Object.keys" => [0], "js.lib.Object.values" => [0], "js.lib.Object.entries" => [0], "js.lib.Object.assign" => [0, 1],
		"js.lib.Object.getOwnPropertyNames" => [0], "js.lib.Object.fromEntries" => [0]
	];

	// the short name of each renamed field name
	public final rename = new StringMap<String>();
	// (-D hxmc.js.minify.fields_report) what kept a name, by name
	public final kept = new StringMap<String>();

	final com:Gctx;
	final uses = new StringMap<Int>();
	final kids = new Map<TClass, Array<TClass>>();
	final sharedClasses = new Map<TClass, Bool>();
	final sharedAnons = new Map<TAnon, Int>();
	final sharedEnums = new Map<TEnum, Int>();
	final sharedAbstracts = new Map<TAbstract, Int>();
	final sharedDefs = new Map<TDef, Int>();
	var why = "";
	// the type parameters (their classes) whose values the outside reads; generic calls, instances (finish)
	final escaping = new Map<TClass, Int>();
	var escapes = 0;
	// (those whose values reflection reads the own keys of)
	final escapingOwn = new Map<TClass, Int>();
	final calls:Array<{f:TClassField, args:Array<T>, ret:T}> = [];
	final instanceTypes:Array<T> = [];
	// the string constants (a name passed around as one: kept, -D hxmc.js.minify.fields=strings)
	final strings = new StringMap<Bool>();
	// (the report: which reflection fires, where)
	final hits = new StringMap<Bool>();

	public function new(com:Gctx) {
		this.com = com;
		families();
		for (k in KEEP) keep(k, "JavaScript reads it");
		for (p in Runtime.PARTS) words(p.code, "the runtime's code");
		for (f in com.includeFiles) words(sys.io.File.getContent(f.file), "an included file");
		for (t in com.types) switch t {
			case TClassDecl(c):
				if (c.clSuper != null) kidsOf(c.clSuper.cls).push(c);
				for (i in c.clImplements) kidsOf(i.cls).push(c);
			case _:
		}
		for (t in com.types) switch t {
			case TClassDecl(c) if (hasClassFlag(c, CExtern)):
				why = "an extern's field";
				for (f in c.clFields) keepField(f);
				for (f in c.clStatics) keepField(f);
				why = "in an extern's signature";
				for (f in c.clFields) shareData(f.cfType);
				for (f in c.clStatics) shareData(f.cfType);
				if (c.clConstructor != null) shareData(c.clConstructor.cfType);
			case TClassDecl(c):
				// (what an extern ancestor has: its code reads it)
				var up = c.clSuper;
				while (up != null) {
					if (hasClassFlag(up.cls, CExtern)) {
						why = "an extern's field";
						for (f in up.cls.clFields) keepField(f);
					}
					up = up.cls.clSuper;
				}
				for (st in [false, true]) for (f in (st ? c.clStatics : c.clFields)) {
					countIn(st ? staticNs(c) : instanceNs(c), f.cfName);
					if (Meta.has(Meta.Native, f.cfMeta)) keep(f.cfName, "@:native");
				}
				meta(t);
				if (Meta.has(Meta.Expose, c.clMeta)) {
					why = "@:expose";
					shareExposed(c);
				}
				for (f in c.clStatics) if (Meta.has(Meta.Expose, f.cfMeta)) keep(f.cfName, "@:expose");
				if (Meta.has(SHARED, c.clMeta)) {
					why = "@:shared";
					shareClass(c);
				}
			case TEnumDecl(en):
				meta(t);
				for (f in en.eConstrs) enumOfCtor.set(f, en);
				if (!hasEnumFlag(en, EnExtern)) for (f in en.eConstrs) {
					countIn(enumCtorNs(en), f.efName);
					switch follow(f.efType) {
						case TFun(s): for (a in s.args) countIn(enumParamNs(en), a.name);
						case _:
					}
				}
				if (Meta.has(SHARED, en.eMeta)) {
					why = "@:shared";
					for (f in en.eConstrs) share(f.efType);
				}
			case TTypeDecl(d) if (Meta.has(SHARED, d.tMeta)):
				why = "@:shared";
				share(d.tType);
			case TAbstractDecl(a) if (Meta.has(SHARED, a.aMeta)):
				why = "@:shared";
				share(a.aThis);
			case _:
		}
	}

	// after the lowering (Lower.prepare: visit): the short names, the most used the shortest
	public function finish() {
		// (a name passed around as a string, to reflection somewhere: kept)
		for (k in strings.keys()) if (hxmc.es.Es.EsTools.validIdent(k)) keep(k, "a string constant");
		// (what the generic code lets out: what its calls and instances give it, until no more does)
		why = "given to generic code that lets it out";
		var n = -1;
		while (escapes != n) {
			n = escapes;
			for (c in calls) callOf(c);
			for (t in instanceTypes) instancesOf(t);
		}
		// (a namespace's names that are not its own: the global namespace's)
		var locals = [for (_ in nsUses) new Array<String>()];
		for (ns in 0...nsUses.length) for (k => c in nsUses[ns]) if (local(ns, k)) locals[ns].push(k) else uses.set(k, (uses.exists(k) ? uses.get(k) : 0) + c);
		var names = [for (k in uses.keys()) if (!kept.exists(k) && hxmc.es.Es.EsTools.validIdent(k)) k];
		inline function byUse(m:StringMap<Int>) return (a:String, b:String) -> {
			var d = m.get(b) - m.get(a);
			d != 0 ? d : Reflect.compare(a, b);
		}
		names.sort(byUse(uses));
		// (-D hxmc.js.minify.fields=debug: `name_`, readable)
		var debug = Gctx.definedValueSafe(com, "hxmc.js.minify.fields") == "debug";
		function assign(l:Array<String>, into:StringMap<String>, avoid:String->Bool, ns = -1) {
			var i = 0;
			for (k in l) {
				var s;
				if (debug) {
					// (a namespace's: `name_<ns>`)
					s = k + "_" + (ns < 0 ? "" : Std.string(ns));
					while (kept.exists(s) || uses.exists(s)) s += "_";
				} else do s = Chunk.shortName(i++) while (kept.exists(s) || hxmc.es.Es.EsTools.RESERVED.exists(s) || avoid(s));
				into.set(k, s);
			}
		}
		assign(names, rename, _ -> false);
		// (each namespace: from `a` again, but for what its global names are, what an ES function object has)
		for (ns in 0...nsUses.length) if (locals[ns].length > 0) {
			var taken = new StringMap<Bool>();
			for (k in nsUses[ns].keys()) switch rename.get(k) {
				case null:
				case s: taken.set(s, true);
			}
			var l = locals[ns];
			l.sort(byUse(nsUses[ns]));
			var st = nsStatic[ns];
			assign(l, nsRename[ns], s -> taken.exists(s) || st && FUNCTION.exists(s), ns);
			localRenames += l.length;
		}
	}

	var localRenames = 0;

	public function report(names:Bool):String {
		var b = new StringBuf();
		var byReason = new StringMap<Int>();
		for (k => r in kept) if (used(k)) byReason.set(r, (byReason.exists(r) ? byReason.get(r) : 0) + 1);
		b.add('fields: ${Lambda.count(rename)} names renamed globally, $localRenames in their families, ${Lambda.count(uses) - Lambda.count(rename)} kept\n');
		for (r => c in byReason) b.add('  kept, $r: $c\n');
		for (k in hits.keys()) b.add("  reflection: " + k + "\n");
		for (c => l in escaping) b.add("  escaping: " + c.clModule.mPath.pack.join(".") + "." + c.clModule.mPath.name + " " + c.clPath.name + " (" + l + ")\n");
		if (names) {
			var l = [for (k => r in kept) if (used(k)) k + ": " + r];
			l.sort(Reflect.compare);
			for (s in l) b.add("    " + s + "\n");
		}
		return b.toString();
	}

	function kidsOf(c:TClass):Array<TClass> {
		var l = kids.get(c);
		if (l == null) kids.set(c, l = []);
		return l;
	}

	inline function count(n:String) uses.set(n, (uses.exists(n) ? uses.get(n) : 0) + 1);

	function keep(n:String, reason:String) if (!kept.exists(n)) kept.set(n, reason);

	function keepField(f:TClassField) {
		keep(f.cfName, why);
		for (o in f.cfOverloads) keep(o.cfName, why);
	}

	// the identifiers in code (untyped code, the runtime's, included files), as words
	static function identifiers(js:String, into:StringMap<Bool>) {
		inline function isStart(c:Int) return (c >= "a".code && c <= "z".code) || (c >= "A".code && c <= "Z".code) || c == "_".code || c == "$".code;
		inline function isDigit(c:Int) return c >= "0".code && c <= "9".code;
		var i = 0, n = js.length;
		while (i < n) {
			var c = StringTools.fastCodeAt(js, i);
			if (isStart(c)) {
				var s = i;
				while (i < n && (isStart(StringTools.fastCodeAt(js, i)) || isDigit(StringTools.fastCodeAt(js, i)))) i++;
				into.set(js.substring(s, i), true);
			} else if (isDigit(c)) {
				while (i < n && (isStart(StringTools.fastCodeAt(js, i)) || isDigit(StringTools.fastCodeAt(js, i)))) i++;
			} else i++;
		}
	}

	function words(code:String, reason:String) {
		var w = new StringMap<Bool>();
		identifiers(code, w);
		for (k in w.keys()) keep(k, reason);
	}

	// rtti's `__meta__` (Chunk: Texpr.buildMetadata): its names, those of the fields it describes, read by name
	function meta(t:ModuleType) {
		function keys(e:TExpr) {
			switch e.eexpr {
				case TObjectDecl(fields): for (f in fields) keep(f.key.name, "runtime metadata");
				case _:
			}
			Texpr.iter(keys, e);
		}
		switch Texpr.buildMetadata(com.basic, t) {
			case null:
			case m: keys(m);
		}
	}

	// ---- namespaces
	//
	// A class's instances' fields are named in its family's (its ancestors', descendants', interfaces', implementations':
	// dynamic dispatch stays within one), its statics in another of the family (an ES class inherits its ancestors'
	// statics): short names start again in each (`Shrink`'s). But a name a field of the family is unified with a
	// structure under (CfMaybeUsed, the typer's: it may be read structurally), and any kept, is the global namespace's,
	// as are structures' fields. A family's names avoid the global short names of its own global ones.

	final familyOf = new Map<TClass, TClass>();
	final instanceNsOf = new Map<TClass, Int>();
	final staticNsOf = new Map<TClass, Int>();
	final byPath = new StringMap<TClass>();
	// per namespace: its names' uses, its classes, statics' or not, its short names
	final nsUses:Array<StringMap<Int>> = [];
	final nsClasses:Array<Array<TClass>> = [];
	final nsStatic:Array<Bool> = [];
	final nsRename:Array<StringMap<String>> = [];

	function root(c:TClass):TClass {
		var r = c;
		while (familyOf.exists(r) && familyOf.get(r) != r) r = familyOf.get(r);
		return r;
	}

	function union(a:TClass, b:TClass) {
		var ra = root(a), rb = root(b);
		if (ra != rb) familyOf.set(rb, ra);
	}

	function families() {
		for (t in com.types) switch t {
			case TClassDecl(c):
				if (!familyOf.exists(c)) familyOf.set(c, c);
				byPath.set(generators.Genjs.dotPath(c.clPath), c);
				if (c.clSuper != null) {
					if (!familyOf.exists(c.clSuper.cls)) familyOf.set(c.clSuper.cls, c.clSuper.cls);
					union(c.clSuper.cls, c);
				}
				for (i in c.clImplements) {
					if (!familyOf.exists(i.cls)) familyOf.set(i.cls, i.cls);
					union(i.cls, c);
				}
			case _:
		}
		var rootNs = new Map<TClass, {i:Int, s:Int}>();
		for (c in familyOf.keys()) {
			var r = root(c);
			var ids = rootNs.get(r);
			if (ids == null) {
				rootNs.set(r, ids = {i: nsUses.length, s: nsUses.length + 1});
				for (st in [false, true]) newNs(st, false);
			}
			instanceNsOf.set(c, ids.i);
			staticNsOf.set(c, ids.s);
			nsClasses[ids.i].push(c);
			nsClasses[ids.s].push(c);
		}
	}

	// an enum's constructors' namespace (its object's keys), its values' parameters' (their fields): only theirs, but
	// for what is kept (a string constant naming one); -1: an extern's
	final enumNsOf = new Map<TEnum, Int>();
	final nsEnum:Array<Bool> = [];
	// whether the program reads an enum's constructors' names (`js.Hx.constructs`: Std.string, Type.enumConstructor),
	// which Chunk gives `declareEnum` apart then
	public var constructsRead(default, null) = false;

	function newNs(st:Bool, en:Bool):Int {
		nsUses.push(new StringMap());
		nsClasses.push([]);
		nsStatic.push(st);
		nsEnum.push(en);
		nsRename.push(new StringMap());
		return nsUses.length - 1;
	}

	public function enumCtorNs(e:TEnum):Int {
		if (hasEnumFlag(e, EnExtern)) return -1;
		var n = enumNsOf.get(e);
		if (n == null) {
			enumNsOf.set(e, n = newNs(false, true));
			newNs(false, true);
		}
		return n;
	}

	public function enumParamNs(e:TEnum):Int {
		var n = enumCtorNs(e);
		return n < 0 ? -1 : n + 1;
	}

	// (a constructor's enum: by the constructor, not by the type of what a parameter is read off)
	final enumOfCtor = new Map<TEnumField, TEnum>();

	public function ctorParamNs(ef:TEnumField):Int {
		var e = enumOfCtor.get(ef);
		return e == null ? -1 : enumParamNs(e);
	}

	public function instanceNs(c:TClass):Int {
		var n = instanceNsOf.get(c);
		return n == null ? -1 : n;
	}

	public function staticNs(c:TClass):Int {
		var n = staticNsOf.get(c);
		return n == null ? -1 : n;
	}

	public function staticNsByPath(path:String):Int {
		var c = byPath.get(path);
		return c == null ? -1 : staticNs(c);
	}

	// a field's name as printed in namespace ns (-1: the global one)
	public function lookup(name:String, ns:Int):String {
		if (ns >= 0) {
			var s = nsRename[ns].get(name);
			if (s != null) return s;
		}
		var s = rename.get(name);
		return s == null ? name : s;
	}

	// (the report: whether the program has a field of that name)
	function used(k:String):Bool {
		if (uses.exists(k)) return true;
		for (m in nsUses) if (m.exists(k)) return true;
		return false;
	}

	inline function countIn(ns:Int, n:String) {
		if (ns < 0) count(n) else {
			var m = nsUses[ns];
			m.set(n, (m.exists(n) ? m.get(n) : 0) + 1);
		}
	}

	// whether name is one of namespace ns's own: no field of it is unified with a structure, nor is it kept
	function local(ns:Int, name:String):Bool {
		if (nsEnum[ns]) return !kept.exists(name) && hxmc.es.Es.EsTools.validIdent(name);
		// (read as a structure's anywhere, `(untyped x).name` too, which the typer does not unify: maybe a class's)
		if (accessed.exists(name)) return false;
		if (kept.exists(name) || !hxmc.es.Es.EsTools.validIdent(name)) return false;
		var g = nsGlobal[ns];
		if (g == null) {
			// (its names unified with structures, an extern's: once per namespace)
			nsGlobal[ns] = g = new StringMap();
			for (c in nsClasses[ns]) for (f in (nsStatic[ns] ? c.clStatics : c.clFields))
				if (hasClassFlag(c, CExtern) || hasClassFieldFlag(f, CfMaybeUsed)) g.set(f.cfName, true);
		}
		return !g.exists(name);
	}

	final nsGlobal:Array<Null<StringMap<Bool>>> = [];
	// the names the code reads as a structure's field (FAnon, a closure of one)
	final accessed = new StringMap<Bool>();

	// (what an ES function object has: a class's statics are on one)
	static final FUNCTION = ["name" => true, "length" => true, "prototype" => true, "caller" => true, "arguments" => true, "call" => true,
		"apply" => true, "bind" => true];

	// ---- shared types

	// full (reflection, @:shared): a class's instances too; else (the outside: externs, raw code, @:expose) the data
	// alone (structures, enums, what type parameters take), a class's instance being what the outside only calls the
	// methods of that its externs declare (kept)
	var full = true;
	// (sharing a type's own fields, whose type parameters its arguments bind)
	var bound = 0;

	inline function level():Int return full ? 2 : 1;

	function shareData(t:T) {
		var old = full;
		full = false;
		share(t);
		full = old;
	}

	function shareFull(t:T) {
		var old = full;
		full = true;
		share(t);
		full = old;
	}

	// (memoized by the level: data, then full, shares again)
	inline function first<K:{}>(m:Map<K, Int>, k:K):Bool {
		var l = m.get(k);
		return if (l != null && l >= level()) false else {
			m.set(k, level());
			true;
		}
	}

	function share(t:T) switch t {
		case TMono(m):
			if (m.tmType != null) share(m.tmType);
		case TLazy(l):
			share(lazyType(l));
		case TType(d, ps):
			for (p in ps) share(p);
			// (a typedef of itself, `typedef F = Int -> F`: once)
			if (first(sharedDefs, d)) share(follow(t));
		case TInst(c, ps):
			for (p in ps) share(p);
			// (a type parameter: what the calls and instances of its generic code give it, finish; not one a shared type's
			// own fields mention, which its arguments, shared too, bind)
			if (c.clKind.match(KTypeParameter(_))) {
				if (bound == 0) {
					var l = escaping.get(c);
					if (l == null || l < level()) {
						escaping.set(c, level());
						escapes++;
					}
				}
			} else if (full) shareClass(c);
		case TAnon(a):
			if (first(sharedAnons, a)) {
				switch a.aStatus {
					// (a class as a value: its statics, and its instances' fields, reflection may read)
					case ClassStatics(c) if (full): shareClass(c);
					case _:
				}
				for (f in a.aFields) {
					count(f.cfName);
					keep(f.cfName, why);
					share(f.cfType);
				}
			}
		case TFun(s):
			for (a in s.args) share(a.type);
			share(s.ret);
		case TDynamic(inner):
			if (inner != null) share(inner);
		case TAbstract(a, ps):
			for (p in ps) share(p);
			if (!Meta.has(Meta.CoreType, a.aMeta) && first(sharedAbstracts, a)) share(core.Abstract.getUnderlyingType(a, ps));
		case TEnum(en, ps):
			for (p in ps) share(p);
			if (first(sharedEnums, en)) {
				bound++;
				for (f in en.eConstrs) share(f.efType);
				bound--;
			}
	}

	// a value of class (or interface) c: of it or of a subclass, an implementation, with what they inherit
	function shareClass(c:TClass) {
		if (sharedClasses.exists(c)) return;
		sharedClasses.set(c, true);
		shareFields(c);
		var up = c.clSuper;
		while (up != null) {
			shareFields(up.cls);
			up = up.cls.clSuper;
		}
		var l = kids.get(c);
		if (l != null) for (k in l) shareClass(k);
	}

	// (the interfaces c implements: their fields are c's)
	function shareFields(c:TClass) {
		if (hasClassFlag(c, CExtern)) return;
		for (f in c.clFields) {
			keep(f.cfName, why);
			if (!f.cfKind.match(Method(_))) {
				bound++;
				share(f.cfType);
				bound--;
			}
		}
		for (f in c.clStatics) keep(f.cfName, why);
	}

	// an @:expose'd class: its public API, and what crosses it
	function shareExposed(c:TClass) {
		for (l in [c.clFields, c.clStatics]) for (f in l) if (hasClassFieldFlag(f, CfPublic)) {
			keep(f.cfName, why);
			shareData(f.cfType);
		}
		if (c.clConstructor != null) shareData(c.clConstructor.cfType);
	}

	static inline function isExtern(c:TClass, f:TClassField):Bool return hasClassFlag(c, CExtern) || hasClassFieldFlag(f, CfExtern);

	// ---- the code

	// an expression of the code lowered (Lower.prepare, each once)
	public function visit(e:TExpr, ret:Null<T>) {
		if (e.eexpr.match(TField(_, FStatic({clPath: {pack: [], name: "$hx"} | {pack: ["js"], name: "Hx"}}, {cfName: "constructs"})))) constructsRead = true;
		remember(e);
		fromDynamic(e, ret);
		switch e.eexpr {
			case TCall(callee, el):
				switch callee.eexpr {
					// (the outside: raw code's, an extern's)
					case TField(_, FStatic({clPath: {pack: ["js"], name: "Syntax"}}, {cfName: "code" | "plainCode"})) | TIdent("__js__"):
						if (el.length > 0) switch el[0].eexpr {
							case TConst(TString(s)): words(s, "untyped code");
							case _:
						}
						why = "given to untyped code";
						for (i in 1...el.length) shareValue(el[i], false);
					// (reflection by name, std's and JavaScript's: before the externs, some of it is)
					case TField(_, FStatic(c, f) | FInstance(c, _, f)) if (READS.exists(generators.Genjs.dotPath(c.clPath) + "." + f.cfName)):
						why = "read by reflection";
						var k = generators.Genjs.dotPath(c.clPath) + "." + f.cfName;
						hits.set(k + " @ " + Std.string(e.epos.pfile).split("/").pop() + (DEEP.exists(k) ? " : " + [for (i in READS.get(k)) if (i < el.length) shortType(Texpr.skip(el[i]).etype)].join(", ") : ""), true);
						for (i in READS.get(generators.Genjs.dotPath(c.clPath) + "." + f.cfName)) if (i < el.length) {
							if (DEEP.exists(k)) shareValue(el[i], true) else ownValue(el[i]);
						}
						constants(el);
					case TField(_, FStatic(c, f) | FInstance(c, _, f)) if (isExtern(c, f)):
						why = "given to an extern";
						declared(f.cfType, el);
					case TField(_, FStatic({clPath: {name: "Reflect" | "Type"}}, _)):
						constants(el);
					case _:
				}
			case TNew(c, _, el) if (hasClassFlag(c, CExtern)):
				why = "given to an extern";
				if (c.clConstructor != null) declared(c.clConstructor.cfType, el) else for (a in el) shareValue(a, false);
			// (a value of an extern's field: the outside reads it)
			case TBinop(OpAssign, {eexpr: TField(_, FInstance(c, _, f) | FStatic(c, f))}, v) if (isExtern(c, f)):
				why = "given to an extern";
				shareDeclared(v.etype, f.cfType);
			// (a value from the outside, `haxe.Json.parse`'s (inline: `JSON.parse`'s): of the type it is taken as)
			case TVar(v, init) if (init != null && fromOutside(init) != null):
				why = "taken from an extern";
				shareDeclared(v.vType, fromOutside(init));
			case TBinop(OpAssign, a, b) if (fromOutside(b) != null):
				why = "taken from an extern";
				shareDeclared(a.etype, fromOutside(b));
			// (an unchecked cast to a structure, `(cast this).x`: its names are whatever the value has, as they are)
			case TCast(x, null):
				switch [follow(x.etype), follow(e.etype)] {
					case [TAnon(a), TAnon(b)] if (a == b):
					// (a type check, `(literal : Attributes)`, a TCast too: what has the fields it names, our own, as named)
					case [from, TAnon(b)] if (hasFields(from, b)):
					case [_, TAnon(b)]:
						for (g in b.aFields) {
							count(g.cfName);
							keep(g.cfName, "an unchecked cast's structure");
						}
					case _:
				}
			case TObjectDecl(fields):
				for (f in fields) count(f.key.name);
			case TField(_, FDynamic(n)):
				keep(n, "read off Dynamic");
			// (an extern's, whether or not the program lists the extern)
			case TField(_, FInstance(c, _, f) | FStatic(c, f)) if (isExtern(c, f)):
				keep(f.cfName, "an extern's field");
			case TField(_, FClosure(c, f)) if (c != null && hasClassFlag(c.cls, CExtern)):
				keep(f.cfName, "an extern's field");
			case TField(_, FInstance(c, _, f)):
				countIn(instanceNs(c), f.cfName);
			case TField(_, FStatic(c, f)):
				countIn(staticNs(c), f.cfName);
			case TField(_, FClosure(c, f)):
				if (c == null) accessed.set(f.cfName, true);
				countIn(c == null ? -1 : instanceNs(c.cls), f.cfName);
			case TField(_, FEnum(en, ef)):
				countIn(enumCtorNs(en), ef.efName);
			case TEnumParameter(x, ef, i):
				switch follow(ef.efType) {
					case TFun(s) if (i < s.args.length): countIn(ctorParamNs(ef), s.args[i].name);
					case _:
				}
			case TField(_, FAnon(f)):
				accessed.set(f.cfName, true);
				count(f.cfName);
			case TIdent(s):
				keep(s, "untyped code");
			case TConst(TString(s)) if (s.length > 0 && s.length < 64):
				strings.set(s, true);
			case _:
		}
	}

	// a value the outside reads: of the type it has before any cast (`Dynamic`'s, an inline function's argument's)
	function shareValue(e:TExpr, all:Bool) {
		var old = full;
		full = all;
		share(e.etype);
		var x = e;
		while (true) switch x.eexpr {
			case TCast(y, _) | TParenthesis(y) | TMeta(_, y):
				x = y;
				share(x.etype);
			case _:
				break;
		}
		full = old;
	}

	// a value reflection reads the own keys of (Reflect.fields, Object.keys): their names, not those of their values'
	// types; of the type it has before any cast too
	function ownValue(e:TExpr) {
		var x = e;
		own(x.etype);
		while (true) switch x.eexpr {
			case TCast(y, _) | TParenthesis(y) | TMeta(_, y):
				x = y;
				own(x.etype);
			case _:
				break;
		}
	}

	final ownAnons = new Map<TAnon, Bool>();
	final ownClasses = new Map<TClass, Bool>();
	final ownAbstracts = new Map<TAbstract, Bool>();

	function own(t:T) switch t {
		case TMono(m):
			if (m.tmType != null) own(m.tmType);
		case TLazy(l):
			own(lazyType(l));
		case TType(_, _):
			own(follow(t));
		case TAbstract({aPath: {pack: [], name: "Null"}}, [p]):
			own(p);
		case TAbstract(a, ps) if (!Meta.has(Meta.CoreType, a.aMeta)):
			if (!ownAbstracts.exists(a)) {
				ownAbstracts.set(a, true);
				own(core.Abstract.getUnderlyingType(a, ps));
			}
		case TAnon(a):
			if (!ownAnons.exists(a)) {
				ownAnons.set(a, true);
				switch a.aStatus {
					// (a class as a value: its statics, its instances' fields, Type.getInstanceFields')
					case ClassStatics(c): ownClass(c);
					case _:
				}
				for (f in a.aFields) {
					count(f.cfName);
					keep(f.cfName, why);
				}
			}
		case TInst(c, _):
			if (c.clKind.match(KTypeParameter(_))) {
				if (!escapingOwn.exists(c)) {
					escapingOwn.set(c, 1);
					escapes++;
				}
			} else if (!hasClassFlag(c, CExtern)) ownClass(c);
		case _:
	}

	// (an instance of c: of it or of a subclass, with what they inherit)
	function ownClass(c:TClass) {
		if (ownClasses.exists(c)) return;
		ownClasses.set(c, true);
		var up:Null<ClassAndParams> = {cls: c, params: null};
		while (up != null) {
			if (!hasClassFlag(up.cls, CExtern)) {
				for (f in up.cls.clFields) keep(f.cfName, why);
				for (f in up.cls.clStatics) keep(f.cfName, why);
			}
			up = up.cls.clSuper;
		}
		var l = kids.get(c);
		if (l != null) for (k in l) ownClass(k);
	}

	// arguments given to an extern of type t (its declared signature): what of them it may read (shareDeclared)
	function declared(t:T, el:haxe.ds.Vector<TExpr>) switch follow(t) {
		case TFun(s) if (s.args.length > 0):
			for (i in 0...el.length) {
				var d = s.args[i < s.args.length ? i : s.args.length - 1].type;
				var x = el[i];
				shareDeclared(x.etype, d);
				while (true) switch x.eexpr {
					case TCast(y, _) | TParenthesis(y) | TMeta(_, y):
						x = y;
						shareDeclared(x.etype, d);
					case _:
						break;
				}
			}
		case _:
			for (a in el) shareValue(a, false);
	}

	// a value of type `actual` where an extern declares `declared`: the data it may read, but where its declaration is
	// a type parameter (`resolve(value:T)`, `push(x:T)`: it hands the value on, it cannot know its fields), and of a
	// structure only the fields it declares
	function shareDeclared(actual:T, declared:T, depth = 0) {
		if (depth > 8) return shareData(actual);
		var d = unwrapNull(declared);
		switch d {
			case TInst({clKind: KTypeParameter(_)}, _):
				return;
			case TAbstract({aPath: {pack: ["haxe"], name: "Rest"}}, [p]):
				return shareDeclared(actual, p, depth + 1);
			case _:
		}
		switch [unwrapNull(actual), d] {
			case [TFun(a), TFun(b)]:
				// (a function it calls: with what it declares it gives, which the function may read)
				for (i in 0...a.args.length) if (i < b.args.length) shareDeclared(a.args[i].type, b.args[i].type, depth + 1);
				shareDeclared(a.ret, b.ret, depth + 1);
			case [TInst(c1, p1), TInst(c2, p2)] if (c1 == c2):
				for (i in 0...p1.length) if (i < p2.length) shareDeclared(p1[i], p2[i], depth + 1);
			case [TAnon(a), TAnon(b)]:
				for (f in b.aFields) {
					var g = a.aFields.get(f.cfName);
					if (g != null) shareDeclared(g.cfType, f.cfType, depth + 1);
				}
			case _:
				shareData(actual);
		}
	}

	// a value out of `Dynamic` into a typed place (an initialized variable, an assignment, a cast, an argument, a
	// returned value): data
	// from outside (a service the portal gives, a payload), its type the data's, shared
	function fromDynamic(e:TExpr, ret:Null<T>) {
		switch e.eexpr {
			case TReturn(x) if (x != null && ret != null):
				takenExpr(x, ret);
			case TVar(v, init) if (init != null):
				takenExpr(init, v.vType);
			case TBinop(OpAssign, a, b):
				takenExpr(b, a.etype);
			case TCast(x, null):
				takenExpr(x, e.etype);
			case TCall(callee, el):
				switch follow(callee.etype) {
					case TFun(s): for (i in 0...el.length) if (i < s.args.length) takenExpr(el[i], s.args[i].type);
					case _:
				}
			case _:
		}
	}

	// (and of each branch a value comes from: `c ? json.discount : {...}`, a switch's, a block's last)
	function takenExpr(x:TExpr, to:T) {
		taken(x.etype, to);
		switch x.eexpr {
			case TParenthesis(y) | TMeta(_, y):
				takenExpr(y, to);
			case TIf(_, a, b):
				takenExpr(a, to);
				if (b != null) takenExpr(b, to);
			case TBlock(el) if (el.length > 0):
				takenExpr(el[el.length - 1], to);
			case TSwitch(sw):
				for (c in sw.switchCases) takenExpr(c.caseExpr, to);
				if (sw.switchDefault != null) takenExpr(sw.switchDefault, to);
			case TTry(body, catches):
				takenExpr(body, to);
				for (c in catches) takenExpr(c.expr, to);
			case _:
		}
	}

	function taken(from:T, to:T) {
		var df = isDyn(from), dt = isDyn(to);
		if (df && !dt) {
			why = "taken from Dynamic";
			shareData(to);
		} else if (dt && !df) {
			// (and into it: a structure read by name there, `interpolate({rank: 7})`; its data, a class's instance not)
			why = "given to Dynamic";
			shareData(from);
		}
	}

	// `Dynamic`, `Any`, an abstract of either (an abstract's: memoized, but where its underlying type is a parameter of it)
	final dynAbstract = new Map<TAbstract, Int>();

	function isDyn(t:T):Bool return switch unwrapNull(t) {
		case TDynamic(_): true;
		case TMono(m): m.tmType == null;
		case TAbstract({aPath: {pack: [], name: "Any"}}, _): true;
		case TAbstract(a, ps) if (!Meta.has(Meta.CoreType, a.aMeta)):
			var k = dynAbstract.get(a);
			if (k == null) {
				dynAbstract.set(a, 0);
				k = switch unwrapNull(a.aThis) {
					case TInst({clKind: KTypeParameter(_)}, _): 2;
					case u: isDyn(u) ? 1 : 0;
				}
				dynAbstract.set(a, k);
			}
			k == 2 ? isDyn(core.Abstract.getUnderlyingType(a, ps)) : k == 1;
		case _: false;
	}

	static function unwrapNull(t:T):T {
		var t = follow(t);
		return switch t {
			case TAbstract({aPath: {pack: [], name: "Null"}}, [p]): unwrapNull(p);
			case _: t;
		}
	}

	// whether a value of type t, of the program's own (a structure, a class but an extern's), has every field b names
	static function hasFields(t:T, b:TAnon):Bool {
		return switch t {
			case TAnon(a):
				var all = true;
				for (g in b.aFields) if (!a.aFields.exists(g.cfName)) {
					all = false;
					break;
				}
				all;
			case TInst(c, _) if (!hasClassFlag(c, CExtern) && !c.clKind.match(KTypeParameter(_))):
				var all = true;
				for (g in b.aFields) {
					var k = c, found = false;
					while (k != null && !found) {
						if (hasClassFlag(k, CExtern)) break;
						found = k.clFields.exists(g.cfName);
						k = k.clSuper == null ? null : k.clSuper.cls;
					}
					if (!found) {
						all = false;
						break;
					}
				}
				all;
			case _: false;
		}
	}

	function constants(el:haxe.ds.Vector<TExpr>) {
		for (a in el) switch Texpr.skip(a).eexpr {
			case TConst(TString(s)): keep(s, "named by reflection");
			case _:
		}
	}

	// an extern's call's value, a value of an extern's field (but the extern's own types', and plain values)
	// (its declared type: an extern call's return type, an extern field's, shareDeclared; null: not)
	static function fromOutside(e:TExpr):Null<T> return switch e.eexpr {
		case TCast(x, _) | TParenthesis(x) | TMeta(_, x): fromOutside(x);
		case TCall({eexpr: TField(_, FStatic(c, f) | FInstance(c, _, f))}, _) if (isExtern(c, f)): switch follow(f.cfType) {
				case TFun(s): s.ret;
				case _: TDynamic(null);
			}
		case TField(_, FStatic(c, f) | FInstance(c, _, f)) if (isExtern(c, f)): f.cfType;
		case TCall({eexpr: TField(_, FStatic({clPath: {pack: ["haxe"], name: "Json"}}, {cfName: "parse"}))}, _): TDynamic(null);
		case _: null;
	}

	// ---- generic code

	function remember(e:TExpr) {
		switch follow(e.etype) {
			case TInst(c, ps) if (ps.length > 0 && !hasClassFlag(c, CExtern)): instanceTypes.push(e.etype);
			case _:
		}
		switch e.eexpr {
			case TCall({eexpr: TField(_, FStatic(c, cf) | FInstance(c, _, cf))}, el) if (!hasClassFlag(c, CExtern) && (cf.cfParams.length > 0 || c.clParams.length > 0)):
				calls.push({f: cf, args: [for (a in el) a.etype], ret: e.etype});
			case _:
		}
	}

	function callOf(c:{f:TClassField, args:Array<T>, ret:T}) switch follow(c.f.cfType) {
		case TFun(s):
			for (i in 0...c.args.length) if (i < s.args.length) atParams(c.args[i], s.args[i].type);
			atParams(c.ret, s.ret);
		case _:
	}

	// a value of type `actual` where generic code declares `declared`: what it has where the declaration has an
	// escaping type parameter (`makeState<T>(initial:T):State<T>`: the `T` of a `State<Float>`, Float, not the State)
	function atParams(actual:T, declared:T, depth = 0) {
		if (depth > 8) return;
		var d = unwrapNull(declared);
		switch d {
			case TInst(c = {clKind: KTypeParameter(_)}, _):
				switch escaping.get(c) {
					case null:
					case l: shareAt(actual, l);
				}
				if (escapingOwn.exists(c)) own(actual);
				return;
			case _:
		}
		switch [unwrapNull(actual), d] {
			case [TFun(a), TFun(b)]:
				for (i in 0...a.args.length) if (i < b.args.length) atParams(a.args[i].type, b.args[i].type, depth + 1);
				atParams(a.ret, b.ret, depth + 1);
			case [TInst(c1, p1), TInst(c2, p2)] if (c1 == c2):
				for (i in 0...p1.length) if (i < p2.length) atParams(p1[i], p2[i], depth + 1);
			case [TAbstract(a1, p1), TAbstract(a2, p2)] if (a1 == a2):
				for (i in 0...p1.length) if (i < p2.length) atParams(p1[i], p2[i], depth + 1);
			case [TEnum(e1, p1), TEnum(e2, p2)] if (e1 == e2):
				for (i in 0...p1.length) if (i < p2.length) atParams(p1[i], p2[i], depth + 1);
			case [TAnon(a), TAnon(b)]:
				for (f in b.aFields) {
					var g = a.aFields.get(f.cfName);
					if (g != null) atParams(g.cfType, f.cfType, depth + 1);
				}
			// (where the shapes part, `T` in a type that is not the same: all of what mentions it)
			case _:
				shareAt(actual, mentions(declared, escaping));
				if (mentions(declared, escapingOwn) > 0) own(actual);
		}
	}

	function instancesOf(t:T) switch follow(t) {
		case TInst(c, ps):
			for (i in 0...c.clParams.length) if (i < ps.length) switch escaping.get(c.clParams[i].ttpClass) {
				case null:
				case l: shareAt(ps[i], l);
			}
			for (i in 0...c.clParams.length) if (i < ps.length && escapingOwn.exists(c.clParams[i].ttpClass)) own(ps[i]);
		case _:
	}

	// (l: a level, 0: not at all)
	function shareAt(t:T, l:Int) {
		if (l == 2) shareFull(t) else if (l == 1) shareData(t);
	}

	// the highest level of the escaping type parameters t mentions (0: none)
	function mentions(t:T, esc:Map<TClass, Int>, depth = 0):Int {
		if (depth > 8) return 0;
		inline function any(ps:TParams):Int {
			var l = 0;
			for (p in ps) l = max(l, mentions(p, esc, depth + 1));
			return l;
		}
		return switch t {
			case TMono(m): m.tmType == null ? 0 : mentions(m.tmType, esc, depth + 1);
			case TLazy(l): mentions(lazyType(l), esc, depth + 1);
			case TInst(c, ps):
				var own = esc.get(c);
				max(own == null ? 0 : own, any(ps));
			case TType(_, ps): max(any(ps), mentions(follow(t), esc, depth + 1));
			case TAbstract(_, ps) | TEnum(_, ps): any(ps);
			case TFun(s):
				var l = mentions(s.ret, esc, depth + 1);
				for (a in s.args) l = max(l, mentions(a.type, esc, depth + 1));
				l;
			case TAnon(a):
				var l = 0;
				for (f in a.aFields) l = max(l, mentions(f.cfType, esc, depth + 1));
				l;
			case TDynamic(inner): inner == null ? 0 : mentions(inner, esc, depth + 1);
		}
	}

	static function shortType(t:T):String return switch t {
		case TInst(c, _): c.clPath.name;
		case TType(d, _): d.tPath.name;
		case TAbstract(a, _): a.aPath.name;
		case TEnum(e, _): e.ePath.name;
		case TAnon(_): "{...}";
		case TDynamic(_): "Dynamic";
		case TMono(m): m.tmType == null ? "?" : shortType(m.tmType);
		case _: "other";
	}

	static inline function max(a:Int, b:Int):Int return a > b ? a : b;
}
