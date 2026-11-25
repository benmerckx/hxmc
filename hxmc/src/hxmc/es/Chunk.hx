package hxmc.es;

import haxe.io.Path;
import core.Globals;
import core.Globals.*;
import core.Ast;
import core.TType;
import core.TFunctions.*;
import core.Meta;
import core.Error;
import core.Texpr;
import generators.Gctx;
import generators.Genjs;
import hxmc.es.Splits;
import hxmc.es.Es;
import hxmc.es.Es.EsTools.*;

using StringTools;

// a type the output has a value of, in the order of initialization (Haxe's: com.types)
private class Item {
	public final t:ModuleType;
	public final index:Int;
	public final sym:Sym;
	public final path:String;
	// the file it is in (0: main, else a split's: Splits)
	public var file = 0;
	// a class's statics with a value (not methods), in source order
	public final statics:Array<TClassField> = [];
	// where each static goes: its class's body (true) or after every class of its file (false)
	public final inBody = new Map<TClassField, Bool>();
	public var initInBody = true;
	// (modules) its `__init__` runs in the entry
	public var initLate = false;
	// its code, lowered (Lowering): a class's declaration, its statics' values, its `__init__`'s, its module's functions
	public var decl:Null<ClassDecl> = null;
	public final values = new Map<TClassField, Ex>();
	public var init:Null<Array<St>> = null;
	public final fns = new Map<TClassField, Fn>();
	// (a class) the field of each of its declaration's members that is a method's (Properties)
	public final memberFields:Array<Null<TClassField>> = [];

	public function new(t, index, sym, path) {
		this.t = t;
		this.index = index;
		this.sym = sym;
		this.path = path;
	}

	public var cls(get, never):Null<TClass>;

	function get_cls() return switch t {
		case TClassDecl(c): c;
		case _: null;
	}
}

// (TypeScript) what code names as types: other files' bindings (by their files), the runtime's `EnumValue`
private class TypeNames {
	public final needs = new Map<Sym, Int>();
	public var enumValue = false;

	public function new() {}

	public function addTo(n:TypeNames) {
		for (s => from in needs) n.needs.set(s, from);
		if (enumValue) n.enumValue = true;
	}
}

// an output file: main, or a split's (its Splits.SplitChunk)
private class OutFile {
	public final id:Int;
	public final chunk:Splits.SplitChunk;
	public final items:Array<Item> = [];
	// the bindings of other files it uses (by the files they are in)
	public final needs = new Map<Sym, Int>();
	// (TypeScript) what its code names as types (those of other files it does not use as values: imported as types)
	public final names = new TypeNames();
	// its split initializers, in the order of their indexes
	public final inits:Array<Fn> = [];
	public var file:Null<String>;
	// (modules: its path in the output, the files it imports in their order)
	public var path:Null<String>;
	public var deps:Array<Int> = [];
	// the source map of its text (Chunk.newMaps)
	public var smap:Null<SourceMap> = null;

	public function new(id, chunk) {
		this.id = id;
		this.chunk = chunk;
	}
}

// a file's statements as a printer takes them (one; several, which tight output declares together; a blank line):
// assembled one file after the other, printed in parallel (Chunk.print)
private enum Piece {
	POne(s:St);
	PMany(l:Array<St>);
	PBlank;
}

private class Doc {
	public final pieces:Array<Piece> = [];

	public function new() {}

	public function statement(s:St) pieces.push(POne(s));

	public function statements(l:Array<St>) pieces.push(PMany(l));

	public function blank() pieces.push(PBlank);
}

// what a lowering used of the program (Lower.Resolve's calls), in its order; `file`: the file its code is in
private enum Use {
	// (a field's code begins: what it tells of the fields' names, -D hxmc.js.minify.fields)
	UScope(fields:Null<FieldNames.FieldLog>);
	UDeclare(s:Sym);
	UType(t:ModuleType, p:Pos, file:Int);
	UPath(path:String, file:Int);
	UIdent(name:String, file:Int);
	UModuleField(m:ModuleDef, f:TClassField, file:Int);
	// (a module-level function's name: its binding)
	UFnName(fn:Fn, m:ModuleDef, f:TClassField, file:Int);
	URt(name:String, file:Int);
	UIndex(file:Int);
	URaw(text:String, file:Int);
	URefer(path:String);
	// (modules) a split's code lowered where it is called, back in the caller's file
	USplitDone(split:Int, caller:Int);
	// a Lower's locals' names
	ULocals(names:Array<String>);
	// (Properties) what the code does with accessors, the names it reads dynamically, its string constants
	UAccessorCall(a:TClassField, args:Int, discarded:Bool);
	UAccessorTaken(a:TClassField);
	UDynamicName(n:String);
	UString(s:String);
}

// A lowering of a part of the program (a type's code, the main code, ...): it changes nothing it shares with others,
// so they run in parallel. What it uses of the program it notes (Use); its references (Ref) the printers resolve. Chunk
// replays the notes of all in the program's order (replay): the files' imports, the runtime's parts, the names in use
// are those of one lowering after the other.
@:access(hxmc.es.Chunk)
private class Lowering implements Lower.Resolve {
	final chunk:Chunk;
	// the file the code is in (modules: a split's, while its code is lowered where it is called)
	var file:Int;
	public final uses:Array<Use> = [];
	final features = new Map<String, Bool>();
	public final run:Null<Lowering->Void>;

	public function new(chunk, file, run) {
		this.chunk = chunk;
		this.file = file;
		this.run = run;
	}

	public function lower():Lower return new Lower(chunk.com, this);

	// a Lower is done: its locals' names are taken
	public function done(l:Lower) uses.push(ULocals(l.localNames()));

	public function fnName(fn:Fn, m:ModuleDef, f:TClassField) uses.push(UFnName(fn, m, f, file));

	public function type(t:ModuleType, p:Pos):Ex {
		uses.push(UType(t, p, file));
		return ex(ERef(RType(t)), p);
	}

	public function typeByPath(pack:Array<String>, name:String, p:Pos):Ex {
		var path = Chunk.dot({pack: pack, name: name});
		if (!chunk.byPath.exists(path)) Error.abort("es: " + path + " is not in the program", p);
		uses.push(UPath(path, file));
		return ex(ERef(RPath(path)));
	}

	public function moduleField(m:ModuleDef, f:TClassField, p:Pos):Ex {
		uses.push(UModuleField(m, f, file));
		return ex(ERef(RModuleField(m, f)), p);
	}

	public function rt(name:String):Ex {
		uses.push(URt(name, file));
		return Chunk.rtEx(name);
	}

	public function index():Ex {
		if (!chunk.tsOut) return rt("index");
		uses.push(UIndex(file));
		return ex(ERef(RIndex));
	}

	public function ident(name:String):Ex {
		var l = Chunk.LEGACY.get(name);
		if (l != null) return ex(ERaw([RText(rawText(l))]));
		uses.push(UIdent(name, file));
		return ex(ERef(RIdent(name)));
	}

	public function rawText(code:String):String {
		var out = Chunk.legacyText(code);
		uses.push(URaw(out, file));
		return out;
	}

	public function feature(f:String):Bool {
		var v = features.get(f);
		if (v == null) features.set(f, v = chunk.feature(f));
		return v;
	}

	public function refer(path:String):Void uses.push(URefer(path));

	public function stdExtern(c:TClass):Bool return chunk.stdExtern(c);

	public function split(e:TExpr):Null<SplitPoint> return chunk.split(e);

	public function splitKey(name:String):Ex return ex(ERef(RSplitKey(name)));

	public function inSplit<R>(s:SplitPoint, f:Int->R):R {
		var id = chunk.fileOfSplit(s), caller = file;
		file = id;
		var r = f(id);
		file = caller;
		uses.push(USplitDone(id, caller));
		return r;
	}

	public function splitsInline():Bool return chunk.modules;

	// (FieldNames.isDyn's memo, the lowering's own)
	final dyn = new Map<TAbstract, Int>();

	public function enterScope(e:TExpr):Void uses.push(UScope(chunk.fieldNames == null ? null : FieldNames.FieldLog.of(e, dyn)));

	public function declare(s:Sym):Void uses.push(UDeclare(s));

	public function ts():Bool return chunk.tsOut;

	public function accessorCall(a:TClassField, args:Int, discarded:Bool) if (chunk.propsOn) uses.push(UAccessorCall(a, args, discarded));

	public function accessorTaken(a:TClassField) if (chunk.propsOn) uses.push(UAccessorTaken(a));

	public function dynamicName(n:String) if (chunk.propsOn) uses.push(UDynamicName(n));

	public function stringConst(s:String) if (chunk.propsOn) uses.push(UString(s));
}

// The bundled output (-D hxmc.js=es): the program in one file, and a file per split (js.Bundle.split).
//
// The main file is a classic script as much as a module (`"use strict";` and a block, so nothing is a global): a
// page may load it either way. A split's file is a module whose default export takes the bindings it uses from
// the files loaded before it (by name: `$hx.scope`), defines its types, adds those later files use to the scope
// and returns its initializers; `$hx.load(name)` loads it once (js.Bundle.import, relative to js.Bundle.base or
// the main file).
//
// Classes are classes with their statics in their bodies, where the code that initializes them can run there (the
// types it reaches are declared and initialized before); the others, and the `__init__`s that cannot run in a
// `static {}` block, run after every type of the file is declared, in Haxe's order (docs/plans/esgen.md,
// "Statics").
class Chunk {
	final com:Gctx;
	final splits:Splits;
	final files:Array<OutFile> = [];
	final items:Array<Item> = [];
	final byPath = new Map<String, Item>();
	final byFlat = new Map<String, Item>();
	// the externs with an `__init__`, and its code
	final externInits:Array<TClass> = [];
	final externInitCode = new Map<TClass, Array<St>>();
	final moduleFields = new Map<String, Sym>();
	final moduleFieldOwner = new Map<String, Item>();
	final globals = new Map<String, Sym>();
	final rtUsed = new Map<String, Bool>();
	final refs = new Map<String, Bool>();
	final rawWords = new Map<String, Bool>();
	final localNames = new Map<String, Bool>();
	// the interfaces the code takes as values (instanceof)
	var interfaceValues = false;
	// externs with @:jsRequire
	final requires = new Map<String, {sym:Sym, module:String, path:Null<String>}>();
	var mainCode:Array<St> = [];
	// types whose code a deferred `__init__` reaches: not initialized before it runs
	final tainted = new Map<Int, Bool>();
	final kids = new Map<TClass, Array<TClass>>();
	final splitCalls = new haxe.ds.ObjectMap<TExpr, SplitPoint>();
	// the file being lowered
	var current = 0;
	// -D hxmc.js=es-modules: an ES module per Haxe module (else the bundled output)
	final modules:Bool;
	final moduleFiles = new Map<String, Int>();
	// (modules: the order in which the files run, simulated; the files that use the runtime)
	final finished = new Map<Int, Int>();
	final rtFiles = new Map<Int, Bool>();
	// (modules) the `__init__`s the entry runs
	final lateInits:Array<St> = [];
	// TypeScript (es-modules, an output named `.ts`): the files are `.ts`, with types (Ts)
	final tsOut:Bool;
	final ext:String;

	public function new(com:Gctx) {
		this.com = com;
		splits = new Splits(com);
		modules = Gctx.definedValueSafe(com, "hxmc.js") == "es-modules";
		tsOut = modules && StringTools.endsWith(com.file, ".ts");
		ext = tsOut ? ".ts" : ".js";
		if (!modules && StringTools.endsWith(com.file, ".ts")) Error.abort("hxmc.js=es: TypeScript output is es-modules's", core.Globals.nullPos);
		// (the fields' names: the program's whole, which modules others may import are not)
		if (modules && Gctx.rawDefined(com, "hxmc.js.minify.fields"))
			Error.abort("hxmc.js.minify.fields: the bundled output's (hxmc.js=es), not es-modules's: what imports a module reads its fields by their names", core.Globals.nullPos);
		for (c in splits.chunks) files.push(new OutFile(files.length, c));
		// (modules: the entry is the main module's file, when they have one path)
		if (modules) files[0].path = Path.withoutDirectory(com.file);
		for (s in splits.splits) {
			splitCalls.set(s.call, s);
			if (!splitKeys.exists(s.name)) splitKeys.set(s.name, new Sym(SRuntime, Printer.quote(s.name)));
		}
		stdPaths = [for (p in com.classPaths.filter(p -> p.isStdPath() || p.scope == StdTarget)) core.Path.getFullPath(p.path)];
	}

	public static function generate(com:Gctx) {
		SuperFirst.run(com);
		filters.ES6Ctors.rewriteCtors(com);
		var c = new Chunk(com);
		if (com.debug || Gctx.defined(com, core.Define.JsSourceMap) || Gctx.defined(com, core.Define.SourceMap)) c.maps = true;
		inline function phase(name:String, f:Void->Void) {
			var stop = core.Timer.startTimer(com.timerCtx, ["generate", "js", name]);
			f();
			stop();
		}
		phase("collect", () -> {
			c.collect();
			if (c.modules) c.breakCycles();
		});
		phase("lower", () -> c.lowerAll());
		phase("place", () -> {
			if (c.modules) c.order();
			c.place();
			c.name();
		});
		phase("write", () -> c.write());
	}

	// ------------------------------------------------------------------ the types

	// a split's name as a file's: letters, digits, `-` and `_`, the rest `_`
	static function fileName(name:String):String {
		var b = new StringBuf();
		for (i in 0...name.length) {
			var c = StringTools.fastCodeAt(name, i);
			b.addChar(if ((c >= "a".code && c <= "z".code) || (c >= "A".code && c <= "Z".code) || (c >= "0".code && c <= "9".code) || c == "-".code || c == "_".code) c else "_".code);
		}
		var s = b.toString();
		return s == "" ? "split" : s;
	}

	static function dot(p:GlobalTypePath):String return Genjs.dotPath(p);

	// the module of a class of module-level fields (Haxe 5's, or a class without a name: its statics at the top level)
	static function fieldsModule(c:TClass):Null<ModuleDef> return switch c.clKind {
		case KModuleFields(m): m;
		case _ if (c.clPath.pack.length == 0 && c.clPath.name == ""): c.clModule;
		case _: null;
	}

	function isRequire(c:TClass):Bool return hasClassFlag(c, CExtern) && Meta.has(Meta.JsRequire, c.clMeta);

	function collect() {
		// (what an instance's call may run: the classes extending a class, and those implementing an interface, or an
		// interface extending it; reaches)
		function kid(parent:TClass, c:TClass) {
			var l = kids.get(parent);
			if (l == null) kids.set(parent, l = []);
			l.push(c);
		}
		for (t in com.types) switch t {
			case TClassDecl(c):
				if (c.clSuper != null) kid(c.clSuper.cls, c);
				for (i in c.clImplements) kid(i.cls, c);
			case _:
		}
		for (t in com.types) switch t {
			case TClassDecl(c) if (isRequire(c)):
				var m = Meta.get(Meta.JsRequire, c.clMeta);
				var p = c.clPath;
				var s = new Sym(SType(t), p.name);
				switch m.exprs {
					case [{expr: EConst(String(mod, _))}]: requires.set(dot(p), {sym: s, module: mod, path: null});
					case [{expr: EConst(String(mod, _))}, {expr: EConst(String(sub, _))}]: requires.set(dot(p), {sym: s, module: mod, path: sub});
					case _: Error.abort("Unsupported @:jsRequire format", m.pos);
				}
			// (an extern's `__init__`: run, as Genjs does)
			case TClassDecl(c) if (hasClassFlag(c, CExtern)):
				if (c.clInit != null && c.clInit.cfExpr != null) externInits.push(c);
			case TClassDecl(c) if (c.clPath.pack.length == 0 && c.clPath.name == "Std" && c.clStatics.length == 0):
			case TClassDecl(c):
				var m = fieldsModule(c);
				var item = add(t, m == null ? c.clPath : m.mPath);
				if (m != null) for (f in c.clStatics) moduleFieldOwner.set(dot(m.mPath) + "." + f.cfName, item);
			case TEnumDecl(e) if (!hasEnumFlag(e, EnExtern)):
				add(t, e.ePath);
			case _:
		}
	}

	function add(t:ModuleType, p:GlobalTypePath):Item {
		// (an abstract's implementation: the abstract's name, which has no value of its own)
		var hint = switch t {
			case TClassDecl({clKind: KAbstractImpl(a)}): a.aPath.name;
			case _: p.name;
		}
		var item = new Item(t, items.length, new Sym(SType(t), hint), dot(p));
		// (modules: a @:generic class's instance in its class's module, whose classes it extends and they it)
		var m = switch t {
			case TClassDecl({clKind: KGenericInstance(c, _)}): c.clModule;
			case _: tInfos(t).mtModule;
		}
		if (modules) item.file = moduleFile(m.mPath) else if (splits.hasSplits()) {
			var info = splits.info(t);
			if (info != null && info.chunk != null) item.file = info.chunk.id;
		}
		items.push(item);
		files[item.file].items.push(item);
		byPath.set(dot(tPath(t)), item);
		byFlat.set(core.Path.flatPath(tPath(t)), item);
		return item;
	}

	// ------------------------------------------------------------------ the program's bindings
	//
	// What the lowerings used (Lowering), replayed in the program's order (replay), and what the assembly of the files
	// uses as it goes: what each file imports, the runtime's parts, the names in use. Their references (Ref) as the
	// output has them (refEx), which the printers ask for and which changes nothing.

	// a binding of file `file` the file being lowered uses
	function use(s:Sym, file:Int):Ex {
		useCount.set(s, (useCount.exists(s) ? useCount.get(s) : 0) + 1);
		if (scope != null) scope.uses.set(s, true);
		if (file != current) files[current].needs.set(s, file);
		return ex(EId(s));
	}

	public function type(t:ModuleType, p:Pos):Ex {
		switch t {
			case TClassDecl(c) if (isRequire(c)):
				return use(requires.get(dot(c.clPath)).sym, modules ? -1 : 0);
			// (an extern of a class the program has, by its @:native path: that class)
			case TClassDecl(c) if (hasClassFlag(c, CExtern)):
				var item = byPath.get(dot(c.clPath));
				return item != null ? use(item.sym, item.file) : globalPath(dot(c.clPath), p);
			case TClassDecl(c) if (hasClassFlag(c, CInterface)):
				interfaceValues = true;
			case TAbstractDecl(a):
				var n = dot(a.aPath);
				return switch n {
					case "Int" | "Float" | "Bool" | "Dynamic" | "Class" | "Enum": rt(n);
					case _: globalPath(n, p);
				}
			case TEnumDecl(e) if (hasEnumFlag(e, EnExtern)):
				return globalPath(dot(e.ePath), p);
			case _:
		}
		var item = byPath.get(dot(tPath(t)));
		if (item == null) return globalPath(dot(tPath(t)), p);
		return use(item.sym, item.file);
	}

	// (what `type` gives, changing nothing)
	function typeValue(t:ModuleType, p:Null<Pos>):Ex {
		switch t {
			case TClassDecl(c) if (isRequire(c)):
				return ex(EId(requires.get(dot(c.clPath)).sym));
			case TClassDecl(c) if (hasClassFlag(c, CExtern)):
				var item = byPath.get(dot(c.clPath));
				return item != null ? ex(EId(item.sym)) : pathEx(dot(c.clPath), p);
			case TAbstractDecl(a):
				var n = dot(a.aPath);
				return switch n {
					case "Int" | "Float" | "Bool" | "Dynamic" | "Class" | "Enum": rtEx(n);
					case _: pathEx(n, p);
				}
			case TEnumDecl(e) if (hasEnumFlag(e, EnExtern)):
				return pathEx(dot(e.ePath), p);
			case _:
		}
		var item = byPath.get(dot(tPath(t)));
		return item == null ? pathEx(dot(tPath(t)), p) : ex(EId(item.sym));
	}

	public function typeByPath(pack:Array<String>, name:String, p:Pos):Ex {
		var item = byPath.get(dot({pack: pack, name: name}));
		if (item == null) Error.abort("es: " + dot({pack: pack, name: name}) + " is not in the program", p);
		return use(item.sym, item.file);
	}

	static function moduleFieldKey(m:ModuleDef, f:TClassField):String return dot(m.mPath) + "." + f.cfName;

	public function moduleField(m:ModuleDef, f:TClassField):Sym {
		var k = moduleFieldKey(m, f);
		var s = moduleFields.get(k);
		if (s == null) moduleFields.set(k, s = new Sym(SLocal, f.cfName));
		var owner = moduleFieldOwner.get(k);
		if (owner != null) use(s, owner.file);
		return s;
	}

	public function rt(name:String):Ex {
		rtUsed.set(name, true);
		rtFiles.set(current, true);
		return ex(EMember(ex(EId(global("$hx"))), name));
	}

	// (`$hx.<name>`, of a binding of its own)
	static function rtEx(name:String):Ex return ex(EMember(ex(EId(new Sym(SGlobal, "$hx"))), name));

	// (TypeScript: a binding of its own, which TypeScript narrows `x[index]` by, imported from the runtime)
	final enumIndex = new Sym(SLocal, "index");
	final indexFiles = new Map<Int, Bool>();

	// an enum value's index's key
	public function index():Ex {
		if (!tsOut) return rt("index");
		rtUsed.set("index", true);
		rtFiles.set(current, true);
		indexFiles.set(current, true);
		return ex(EId(enumIndex));
	}

	// (TypeScript) Haxe's `EnumValue`, the base of an enum's values' types, imported from the runtime as a type
	final enumValueType = new Sym(SLocal, "EnumValue");
	final enumValueFiles = new Map<Int, Bool>();

	// (code names it: TypeNames.enumValue, which its file's imports take)
	function enumValueRef(names:TypeNames):String {
		names.enumValue = true;
		return enumValueType.name;
	}

	function global(name:String):Sym {
		var s = globals.get(name);
		if (s == null) globals.set(name, s = new Sym(SGlobal, name));
		return s;
	}

	function globalPath(path:String, p:Pos):Ex {
		global(path.split(".")[0]);
		return pathEx(path, p);
	}

	// (a global's binding: of its name, which no binding of the program takes)
	static function pathEx(path:String, p:Null<Pos>):Ex {
		var parts = path.split(".");
		var e = ex(EId(new Sym(SGlobal, parts[0])), p);
		for (i in 1...parts.length) e = Lower.member(e, parts[i], p);
		return e;
	}

	// Genjs's runtime names, where untyped code still uses them
	static final LEGACY = [
		"$global" => "globalThis",
		"$hxClasses" => "$hx.classes",
		"$hxEnums" => "$hx.enums",
		"$hx_exports" => "globalThis",
	];

	public function ident(name:String):Ex {
		var l = LEGACY.get(name);
		if (l != null) return ex(ERaw([RText(rawText(l))]));
		// (a type by Genjs's name for it, flat)
		var item = byFlat.get(name);
		if (item != null) {
			rawWords.set(name, true);
			return use(item.sym, item.file);
		}
		return globalPath(name, null);
	}

	public function rawText(code:String):String {
		var out = legacyText(code);
		rawUses(out);
		return out;
	}

	// (Genjs's runtime names replaced by the runtime's)
	static function legacyText(code:String):String return ~/\$[A-Za-z_]+/g.map(code, r -> {
		var l = LEGACY.get(r.matched(0));
		l == null ? r.matched(0) : l;
	});

	// what untyped code uses: the runtime's parts it names, the types it names by Genjs's names; its words, which no
	// binding takes
	function rawUses(out:String) {
		~/\$hx\.([A-Za-z_]+)/g.map(out, r -> {
			rtUsed.set(r.matched(1), true);
			rtFiles.set(current, true);
			r.matched(0);
		});
		~/[A-Za-z_$][A-Za-z0-9_$]*/g.map(out, r -> {
			var w = r.matched(0);
			rawWords.set(w, true);
			// (a type untyped code names, by Genjs's name: needed where the code is)
			var item = byFlat.get(w);
			if (item != null) use(item.sym, item.file);
			w;
		});
	}

	public function feature(f:String):Bool return Gctx.hasFeature(com, f);

	// a reference as the output has it (the printers': changes nothing)
	function refEx(r:Ref, p:Null<Pos>):Ex return switch r {
		case RType(t): typeValue(t, p);
		case RPath(path): ex(EId(byPath.get(path).sym));
		case RIdent(name):
			var item = byFlat.get(name);
			item != null ? ex(EId(item.sym)) : pathEx(name, null);
		case RModuleField(m, f): ex(EId(moduleFields.get(moduleFieldKey(m, f))), p);
		case RSplitKey(name): ex(EId(splitKeys.get(name)));
		case RIndex: ex(EId(enumIndex));
	}

	// what a lowering used, as if it happened now (the file being lowered: its file's)
	function replay(u:Lowering) {
		var was = current;
		for (x in u.uses) switch x {
			case UScope(log):
				enterScope();
				if (log != null) log.replay(fieldNames);
			case UDeclare(s):
				declare(s);
			case UType(t, p, file):
				current = file;
				type(t, p);
			case UPath(path, file):
				current = file;
				var item = byPath.get(path);
				use(item.sym, item.file);
			case UIdent(name, file):
				current = file;
				ident(name);
			case UModuleField(m, f, file):
				current = file;
				moduleField(m, f);
			case UFnName(fn, m, f, file):
				current = file;
				fn.name = moduleField(m, f);
			case URt(name, file):
				current = file;
				rt(name);
			case UIndex(file):
				current = file;
				index();
			case URaw(text, file):
				current = file;
				rawUses(text);
				if (props != null) props.raw(text);
			case UAccessorCall(a, args, discarded):
				props.called(a, args, discarded);
			case UAccessorTaken(a):
				props.taken(a);
			case UDynamicName(n):
				props.named(n);
			case UString(s):
				props.string(s);
			case URefer(path):
				refs.set(path, true);
			case USplitDone(split, caller):
				// (what the split's code uses of the runtime, of npm modules (@:jsRequire): imported by the caller too)
				if (rtFiles.exists(split)) rtFiles.set(caller, true);
				if (indexFiles.exists(split)) indexFiles.set(caller, true);
				if (enumValueFiles.exists(split)) enumValueFiles.set(caller, true);
				for (s => from in files[split].needs) if (from < 0) files[caller].needs.set(s, from);
			case ULocals(names):
				for (n in names) localNames.set(n, true);
		}
		current = was;
	}

	// lowered now, in the file being assembled (`current`); its locals' names taken (`locals`)
	function lowerNow<R>(f:Lower->R, locals = false):R {
		var u = new Lowering(this, current, null);
		var l = u.lower();
		var r = f(l);
		if (locals) u.done(l);
		replay(u);
		return r;
	}


	// (--debug, -D js-source-map, -D source-map) the files' source maps, beside them (`=inline`: in them): each file's
	// own (OutFile.smap), its printers' (they print in parallel)
	var maps = false;

	// each file's source map, for the text printed next
	function newMaps() for (f in files) f.smap = maps ? new SourceMap() : null;

	// a file's text without the source map's markers, and its map's JSON (of the file's name; null: none)
	function finish(text:String, smap:Null<SourceMap>):{code:String, json:Null<String->String>} {
		if (smap == null) return {code: text, json: null};
		var r = smap.finish(text, Gctx.defined(com, core.Define.SourceMapContent));
		return {code: r.code, json: r.json};
	}

	// a file's text, written: without the source map's markers, its map beside it (or in it), named in `written`
	function save(path:String, text:String, smap:Null<SourceMap>, ?written:Array<String>) saveFinished(path, finish(text, smap), written);

	function saveFinished(path:String, r:{code:String, json:Null<String->String>}, ?written:Array<String>) {
		var file = Path.withoutDirectory(path);
		if (r.json == null) {
			sys.io.File.saveContent(path, r.code);
			try sys.FileSystem.deleteFile(path + ".map") catch (_:Dynamic) {}
			return;
		}
		var json = r.json(file);
		var url = if (Gctx.definedValueSafe(com, core.Define.SourceMap) == "inline")
			"data:application/json;charset=utf-8;base64," + haxe.crypto.Base64.encode(haxe.io.Bytes.ofString(json))
		else {
			sys.io.File.saveContent(path + ".map", json);
			if (written != null) written.push(file + ".map");
			core.StringHelper.urlEncodeString(file) + ".map";
		}
		sys.io.File.saveContent(path, r.code + (StringTools.endsWith(r.code, "\n") ? "" : "\n") + "//# sourceMappingURL=" + url + "\n");
	}

	// a printer of a file's code (its source map, TypeScript's types as it names them, a split's imports from it): of a
	// part of it, printed apart, its part of the source map and what it names (`names`, which the file then takes). What
	// it asks of the program changes nothing (printers run in parallel).
	function printer(f:OutFile, ?smap:SourceMap, ?names:TypeNames):Printer {
		var p = new Printer(tight);
		if (names == null) names = f.names;
		if (tsOut) p.types = new Ts(t -> typeRef(f, names, t), () -> enumValueRef(names));
		if (modules) p.splitImport = id -> splitImport(f.id, id);
		if (fieldNames != null && (tight || fieldsDebug)) p.fieldName = fieldName;
		p.ref = refEx;
		p.accessor = accessorEx;
		p.smap = smap != null ? smap : f.smap;
		return p;
	}

	// The files' statements, printed: each statement apart (and the blank lines after it), all in parallel (a file of most
	// of the program's code as soon as one of a little)
	function printAll(docs:Array<Doc>):Array<String> {
		var parts:Array<{f:OutFile, from:Int, to:Int, smap:Null<SourceMap>, names:Null<TypeNames>}> = [];
		for (f in files) {
			var pieces = docs[f.id].pieces, i = 0;
			while (i < pieces.length) {
				var j = i + 1;
				while (j < pieces.length && pieces[j].match(PBlank)) j++;
				parts.push({
					f: f,
					from: i,
					to: j,
					smap: f.smap == null ? null : f.smap.child(),
					names: tsOut ? new TypeNames() : null
				});
				i = j;
			}
		}
		var texts = [for (_ in parts) ""];
		parallel([for (k in 0...parts.length) k], k -> {
			var x = parts[k];
			var p = printer(x.f, x.smap, x.names);
			for (i in x.from...x.to) switch docs[x.f.id].pieces[i] {
				case POne(s): p.statement(s);
				case PMany(l): p.statements(l);
				case PBlank: p.blank();
			}
			texts[k] = p.toString();
		});
		var out = [for (_ in files) new StringBuf()];
		for (k in 0...parts.length) {
			out[parts[k].f.id].add(texts[k]);
			if (parts[k].names != null) parts[k].names.addTo(parts[k].f.names);
		}
		return [for (b in out) b.toString()];
	}

	// (TypeScript) std's externs of what TypeScript's lib declares alike (es2022), by name
	// (not the buffers: a view's `buffer` is TypeScript's `ArrayBufferLike`, which Haxe's ArrayBuffer would not take)
	static final TS_LIB = ["Int8Array", "Uint8Array", "Uint8ClampedArray", "Int16Array", "Uint16Array",
		"Int32Array", "Uint32Array", "Float32Array", "Float64Array", "BigInt64Array", "BigUint64Array"];

	// (TypeScript) a type's name in file f (null: none, `any`), imported as a type where it is another's (`names`)
	function typeRef(f:OutFile, names:TypeNames, t:ModuleType):Null<String> {
		switch t {
			case TClassDecl(c) if (hasClassFlag(c, CExtern)):
				// (an extern of a class the program has, by its @:native path: that class)
				var item = byPath.get(dot(c.clPath));
				if (item != null) return typeUse(f, names, item);
				// (std's extern of a class TypeScript's lib declares: that one)
				var p = Genjs.getGeneratedClassPath(c);
				// (over an ArrayBuffer, as Haxe has it: TypeScript's (5.7) are generic, `ArrayBufferLike` by default, which a `Blob` does not take)
				return p.pack.length == 0 && TS_LIB.contains(p.name) && StringTools.startsWith(dot(c.clModule.mPath), "js.lib.") ? p.name + "<ArrayBuffer>" : null;
			case TAbstractDecl({aPath: {pack: [], name: "EnumValue"}}):
				return enumValueRef(names);
			case TClassDecl({clKind: KAbstractImpl(_) | KModuleFields(_)}) | TAbstractDecl(_) | TTypeDecl(_):
				return null;
			case _:
		}
		var item = byPath.get(dot(tPath(t)));
		return item == null ? null : typeUse(f, names, item);
	}

	function typeUse(f:OutFile, names:TypeNames, item:Item):String {
		if (item.file != f.id) names.needs.set(item.sym, item.file);
		return item.sym.name;
	}

	public function refer(path:String):Void refs.set(path, true);

	// (the std's class paths, TypeScript's externs)
	var stdPaths:Array<String> = [];

	public function stdExtern(c:TClass):Bool {
		var file = core.Path.UniqueKey.lazyPath(c.clModule.mExtra.mFile);
		return hasClassFlag(c, CExtern) && Lambda.exists(stdPaths, d -> StringTools.startsWith(file, d));
	}

	public function split(e:TExpr):Null<SplitPoint> return splitCalls.get(e);

	// the splits' keys in the runtime's table, by their names
	final splitKeys = new Map<String, Sym>();

	// (modules) the file of a split's code, which is lowered where it is called: what it uses that file's needs, not the
	// caller's; what it uses of the runtime, the caller's, which imports it as it always does (replay)
	function fileOfSplit(s:SplitPoint):Int return Lambda.find(files, x -> isSplit(x) && x.chunk == s.chunk).id;

	// the files files reach through what they import
	function reach(roots:Array<Int>):Map<Int, Bool> {
		var seen = new Map<Int, Bool>();
		var stack = roots.copy();
		while (stack.length > 0) {
			var i = stack.pop();
			if (seen.exists(i)) continue;
			seen.set(i, true);
			for (d in files[i].deps) stack.push(d);
		}
		return seen;
	}

	// (modules) a split's call, printed in file `from`: the modules its code needs (`import()`, of their paths as
	// the file has them) and the bindings of them its code uses, that file does not have (`[{ A, B }, , { C }]`); the
	// modules of the split's types nothing of those imports, for what they run. In order, one after the other, where two
	// are of a cycle (which one runs first decides which defines its classes first); at once otherwise
	function splitImport(current:Int, id:Int):{load:String, pattern:String} {
		var f = files[id], caller = files[current];
		var names = new Map<Int, Array<String>>();
		for (s => from in f.needs) if (from > 0 && from != current && caller.needs.get(s) != from) {
			var l = names.get(from);
			if (l == null) names.set(from, l = []);
			l.push(s.name);
		}
		// (what has run when a split runs: what the entry imports, what the calling module does)
		var before = reach([0, current]);
		var list = [for (k in names.keys()) k];
		list.sort((a, b) -> a - b);
		var loaded = [for (k => v in before) k => v];
		for (k in reach(list).keys()) loaded.set(k, true);
		for (t in f.chunk.types) {
			var item = byPath.get(dot(tPath(t.t)));
			if (item != null && item.file > 0 && !loaded.exists(item.file) && hasValue(files[item.file])) {
				list.push(item.file);
				for (k in reach([item.file]).keys()) loaded.set(k, true);
			}
		}
		if (list.length == 0) return {load: "Promise.resolve()", pattern: ""};
		// (those that have run: only their bindings, at once; the others in the order the entry's are in, first the modules
		// of the classes that would run before their super classes', until none does)
		var ran = list.filter(i -> before.exists(i));
		var fresh = list.filter(i -> !before.exists(i));
		var fixes:Array<Int> = [];
		for (round in 0...20) {
			var late = lateIn(fixes.concat(fresh.filter(i -> !fixes.contains(i))), before);
			var added = false;
			for (i in late) if (!fixes.contains(i)) {
				fixes.push(i);
				added = true;
			}
			if (!added) break;
		}
		fresh = fixes.concat(fresh.filter(i -> !fixes.contains(i)));
		// (one after the other where two are of a cycle, which one runs first deciding which defines its classes first)
		var chain = fixes.length > 0;
		var reaches = [for (i in fresh) i => reach([i])];
		for (a in fresh) for (b in fresh) if (a != b && reaches[a].exists(b) && reaches[b].exists(a)) chain = true;
		var comma = "," + sp(" ");
		var arrow = sp(" ") + "=>" + sp(" ");
		// (`[{ A, B }, , { C }]`: a module of none of them a hole)
		function partsOf(l:Array<Int>):Array<String> return [for (i in l) {
			var n = names.get(i);
			if (n == null) "" else {
				n.sort(Reflect.compare);
				"{" + sp(" ") + n.join(comma) + sp(" ") + "}";
			}
		}];
		function pattern(parts:Array<String>):String {
			parts = parts.copy();
			while (parts.length > 0 && (parts[parts.length - 1] == "" || parts[parts.length - 1] == "[]")) parts.pop();
			return "[" + parts.join(comma) + "]";
		}
		inline function imp(i:Int) return "import(" + Printer.quote(rel(caller.path, files[i].path)) + ")";
		if (!chain) {
			var all = ran.concat(fresh);
			return {load: "Promise.all([" + [for (i in all) imp(i)].join(comma) + "])", pattern: pattern(partsOf(all))};
		}
		// (`import(a).then((m0) => import(b).then((m1) => [m0, m1]))`, beside those that have run)
		var ms = [for (k in 0...fresh.length) "m" + k];
		var seq = "[" + ms.join(comma) + "]" + (tsOut ? " as const" : "");
		var k = fresh.length;
		while (k-- > 0) seq = imp(fresh[k]) + ".then((" + ms[k] + ")" + arrow + seq + ")";
		if (ran.length == 0) return {load: seq, pattern: pattern(partsOf(fresh))};
		return {
			load: "Promise.all([" + [for (i in ran) imp(i)].concat([seq]).join(comma) + "])",
			pattern: pattern(partsOf(ran).concat([pattern(partsOf(fresh))]))
		};
	}

	// (modules) the files of the classes whose super class's file has not run when theirs does, importing order's one
	// after the other, where before's have run
	function lateIn(order:Array<Int>, before:Map<Int, Bool>):Array<Int> {
		var done = [for (k => v in before) k => v];
		var fin = new Map<Int, Int>(), n = 0;
		var started = new Map<Int, Bool>();
		function visit(i:Int) {
			if (started.exists(i) || done.exists(i)) return;
			started.set(i, true);
			for (d in files[i].deps) visit(d);
			done.set(i, true);
			fin.set(i, n++);
		}
		for (i in order) visit(i);
		var out = [];
		for (item in items) if (fin.exists(item.file)) switch item.t {
			case TClassDecl(c = {clSuper: {cls: s}}) if (!hasClassFlag(c, CInterface)):
				var other = byPath.get(dot(s.clPath));
				if (other == null || other.file == item.file || before.exists(other.file)) continue;
				var a = fin.get(other.file);
				if ((a == null || a > fin.get(item.file)) && !out.contains(item.file)) out.push(item.file);
			case _:
		}
		return out;
	}

	inline function sp(s:String):String return tight ? "" : s;

	// the splits, in the order of the runtime's table; their keys in it: their names, their numbers (minified)
	function splitList():Array<OutFile> return [for (f in files) if (isSplit(f)) f];

	function nameSplitKeys() {
		var l = splitList();
		for (i in 0...l.length) {
			var s = splitKeys.get(l[i].chunk.name);
			if (s != null) s.name = tight ? Std.string(i) : Printer.quote(l[i].chunk.name);
		}
	}

	// the runtime's table of the splits' files (without `.js`, which `load` adds): an object by name, an array (minified)
	function splitTable(file:OutFile->String):String {
		var l = splitList();
		inline function f(o:OutFile) return ex(EStr(StringTools.endsWith(file(o), ".js") ? file(o).substr(0, file(o).length - 3) : file(o)));
		return printer(files[0]).expr(tight ? ex(EArray([for (o in l) f(o)])) : ex(EObject([for (o in l) ({key: key(o.chunk.name), value: f(o)} : Prop)])), 1);
	}

	// ------------------------------------------------------------------ lowering

	// (--times: generate/js/write/<name>)
	function timed(name:String, f:Void->Void) {
		var stop = core.Timer.startTimer(com.timerCtx, ["generate", "js", "write", name]);
		f();
		stop();
	}

	// f of each, on the compiler's pool: but with -D disable-parallelism (-D hxmc.js.parallel: even then) or
	// -D hxmc.js.serial, one after the other
	function parallel<A>(l:Array<A>, f:A->Void) {
		if (l.length < 2 || Gctx.rawDefined(com, "hxmc.js.serial")) {
			for (x in l) f(x);
			return;
		}
		var was = context.Parallel.enable;
		if (Gctx.rawDefined(com, "hxmc.js.parallel")) context.Parallel.enable = true;
		try {
			context.Parallel.runWithPool(com.pool, pool -> {
				context.Parallel.ParallelArray.iter(pool, f, l);
				null;
			});
		} catch (e:Dynamic) {
			context.Parallel.enable = was;
			throw e;
		}
		context.Parallel.enable = was;
	}

	// Each type's code, the externs' `__init__`s, the main code, the splits' initializers: lowered in parallel, then what

	// each used, in that order (replay).
	function lowerAll() {
		// (properties as JavaScript's, but with -D hxmc.js.properties=off; not TypeScript's)
		propsOn = !tsOut && Gctx.definedValueSafe(com, "hxmc.js.properties") != "off";
		// (-D hxmc.js.minify.fields: what the lowering tells of the fields, FieldNames)
		if (fieldNames == null && Gctx.rawDefined(com, "hxmc.js.minify.fields")) fieldNames = new FieldNames(com);
		var units:Array<Lowering> = [];
		inline function unit(file:Int, run:Lowering->Void) units.push(new Lowering(this, file, run));
		// (the properties' families: from the types, beside the lowerings)
		if (propsOn) unit(0, _ -> props = new Properties(com));
		for (item in items) unit(item.file, u -> lowerItem(u, item));
		var externCode:Array<Array<St>> = [for (_ in externInits) null];
		for (i in 0...externInits.length) unit(0, u -> {
			var init = externInits[i].clInit.cfExpr;
			var lower = u.lower();
			lower.prepare(init);
			externCode[i] = lower.statements(init);
			u.done(lower);
		});
		if (com.main.mainExpr != null) unit(0, u -> {
			var lower = u.lower();
			lower.prepare(com.main.mainExpr);
			mainCode = lower.statements(com.main.mainExpr);
			u.done(lower);
		});
		// (a split's initializers: functions of their captures, in its file; modules: none, its code is where it is called)
		if (!modules) for (f in files) if (isSplit(f)) unit(f.id, u -> for (s in f.chunk.splits) {
			var lower = u.lower();
			var fn:TFunc = {
				tfArgs: haxe.ds.Vector.fromArrayCopy([for (v in s.captures) {variable: v, defaultValue: (null : TExpr)}]),
				tfType: s.fn.tfType,
				tfExpr: s.fn.tfExpr
			};
			lower.prepare(s.fn.tfExpr);
			f.inits[s.index] = lower.func(fn, true, s.call.epos);
			u.done(lower);
		});
		var stop = core.Timer.startTimer(com.timerCtx, ["generate", "js", "lower", "units"]);
		parallel(units, u -> u.run(u));
		stop();
		for (i in 0...externInits.length) externInitCode.set(externInits[i], externCode[i]);
		stop = core.Timer.startTimer(com.timerCtx, ["generate", "js", "lower", "replay"]);
		for (u in units) replay(u);
		stop();
	}

	// a type's code (Lowering: its own, which nothing else lowers)
	function lowerItem(u:Lowering, item:Item) {
		var lower = u.lower();
		switch item.t {
			case TClassDecl(c) if (fieldsModule(c) != null):
				var m = fieldsModule(c);
				for (f in c.clStatics) switch f.cfExpr {
					case null:
					case e = {eexpr: TFunction(fn)}:
						lower.prepare(e);
						var l = lower.func(fn, false, e.epos, f.cfType, f.cfParams);
						u.fnName(l, m, f);
						item.fns.set(f, l);
					case e:
						lower.prepare(e);
						item.statics.push(f);
						item.values.set(f, lower.expr(e));
				}
			case TClassDecl(c):
				item.decl = lowerClass(u, item, c, lower);
			case _:
		}
		u.done(lower);
	}


	static function key(name:String):Key return validIdent(name) ? KName(name) : KString(name);

	// a Haxe field's key (its name minified: FieldNames)
	static function fieldKey(name:String, ns:Ns):Key return validIdent(name) ? KField(name, ns) : KString(name);

	// (FieldNames) the namespace of c's instances' fields, of its statics
	static inline function ins(c:TClass):Ns return NInstance(c);

	static inline function sns(c:TClass):Ns return NStatic(c);

	// a method's function; TypeScript: one of several signatures (@:overload) takes and returns anything
	function methodFn(lower:Lower, f:TClassField, fn:TFunc, e:TExpr):Fn {
		var l = lower.func(fn, false, e.epos, f.cfType, f.cfParams);
		if (tsOut && (f.cfOverloads.length > 0 || Meta.has(Meta.Overload, f.cfMeta) || f.cfName == "_hx_constructor")) widen(l);
		return l;
	}

	// (TypeScript) a function of any arguments, returning anything: one of several signatures, a constructor in two
	// steps (filters.ES6Ctors: `_hx_constructor` and the constructor that calls it, which a subclass calls without its
	// arguments)
	static function widen(l:Fn) {
		for (p in l.params) p.type = TDynamic(null);
		if (l.ret != null) l.ret = TDynamic(null);
		l.optFrom = 0;
	}

	// (TypeScript) the first optional argument of a signature, nothing required after it
	static function optFrom(s:TSignature):Null<Int> {
		for (i in 0...s.args.length) if (s.args[i].optional) return i;
		return null;
	}

	// (TypeScript) Haxe's `private`: `protected`
	// (not an accessor method: a property's, which structures and interfaces name)
	static function prot(f:TClassField, m:Member):Member
		return hasClassFieldFlag(f, CfPublic) || ~/^(get|set)_/.match(f.cfName) ? m : MProtected(m);

	function lowerClass(u:Lowering, item:Item, c:TClass, lower:Lower):ClassDecl {
		var members:Array<Member> = [];
		function member(m:Member, ?f:TClassField) {
			members.push(m);
			item.memberFields.push(f);
		}
		if (hasClassFlag(c, CInterface)) return {name: item.sym, superClass: null, members: members};
		lower.cls = c;
		// (TypeScript: its variables declared, its abstract methods)
		if (tsOut) for (f in c.clFields) switch f.cfKind {
			case Var(_) if (isPhysicalField(f)):
				member(prot(f, MDeclare(fieldKey(f.cfName, ins(c)), f.cfType, false)));
			case Method(_) if (f.cfExpr == null && hasClassFlag(c, CAbstract)):
				member(prot(f, MAbstract(fieldKey(f.cfName, ins(c)), f.cfType, f.cfParams)));
			case _:
		}
		switch c.clConstructor == null ? null : c.clConstructor.cfExpr {
			case e = {eexpr: TFunction(f)}:
				lower.prepare(e);
				var l = lower.func(f, false, e.epos, c.clConstructor.cfType);
				if (tsOut && Lambda.exists(c.clFields, x -> x.cfName == "_hx_constructor")) widen(l);
				member(MMethod(KName("constructor"), l, false, MkConstructor));
			case _:
		}
		for (f in c.clFields) switch [f.cfKind, f.cfExpr] {
			case [Method(_), e = {eexpr: TFunction(fn)}]:
				lower.prepare(e);
				member(prot(f, MMethod(fieldKey(f.cfName, ins(c)), methodFn(lower, f, fn, e), false, MkMethod)), f);
			case _:
		}
		for (f in c.clStatics) switch [f.cfKind, f.cfExpr] {
			case [Method(_), e = {eexpr: TFunction(fn)}]:
				lower.prepare(e);
				member(prot(f, MMethod(fieldKey(f.cfName, sns(c)), methodFn(lower, f, fn, e), true, MkMethod)), f);
			// (Type.getClassFields: a variable without a value is a field too)
			case [Var(_), null] if (u.feature("Type.getClassFields") && isPhysicalField(f)):
				item.statics.push(f);
				item.values.set(f, ex(ENull));
			// (TypeScript: declared, as Haxe has it)
			case [Var(_), null] if (tsOut && isPhysicalField(f)):
				member(prot(f, MDeclare(fieldKey(f.cfName, sns(c)), f.cfType, true)));
			case [_, null]:
			case [_, {eexpr: TConst(TNull)}] if (!u.feature("Type.getClassFields")):
				if (tsOut && isPhysicalField(f)) member(prot(f, MDeclare(fieldKey(f.cfName, sns(c)), f.cfType, true)));
			case [_, e]:
				lower.prepare(e);
				item.statics.push(f);
				item.values.set(f, lower.expr(e));
		}
		switch (c.clInit == null ? null : c.clInit.cfExpr) {
			case null:
			case e:
				// (TypeScript: as code outside the class, where it may run)
				lower.cls = null;
				lower.prepare(e);
				item.init = lower.statements(e);
		}
		return {
			name: item.sym,
			superClass: c.clSuper == null ? null : u.type(TClassDecl(c.clSuper.cls), c.clPos),
			members: members,
			tparams: c.clParams,
			superArgs: c.clSuper == null ? null : c.clSuper.params.toArray(),
			isAbstract: hasClassFlag(c, CAbstract)
		};
	}

	// ------------------------------------------------------------------ properties as JavaScript's (Properties)

	// (null: none, TypeScript's output, -D hxmc.js.properties=off; propsOn: as the lowerings run, which make it)
	var props:Null<Properties> = null;
	var propsOn = false;

	// an accessor's call as its family is: the property (`o.x`; `o.x = v`, its value used for nothing), else the call
	// (and through `super`, where the family keeps its methods)
	function accessorEx(a:TClassField, call:Ex, discarded:Bool):Ex {
		var f = props == null ? null : props.familyOf(a);
		if (f == null) return call;
		var getter = f.isGetter(a);
		return switch call.def {
			case ECall({def: EField(o, _, ns), pos: p}, args) if ((getter ? args.length == 0 : discarded && args.length == 1)
				&& !(o.def.match(ESuper) && f.keeps(getter))):
				var prop = Lower.field(o, f.property.cfName, ns, p);
				getter ? prop : ex(EAssign("=", prop, args[0]), call.pos);
			case _: call;
		}
	}

	// a class's members, its accessors of properties that change as JS accessors: the accessor itself, or (its family keeps
	// them as methods) the method and, after the class's first accessor of the family, the JS accessors that call it, or
	// the ancestor's through `super` where the class has only one of the pair (a JS accessor hides its ancestors' pair)
	function accessorMembers(item:Item, c:TClass, members:Array<Member>):Array<Member> {
		if (props == null) return members;
		var out:Array<Member> = [];
		for (i in 0...members.length) {
			var cf = item.memberFields[i];
			var fam = cf == null ? null : props.familyOf(cf);
			if (fam == null) {
				out.push(members[i]);
				continue;
			}
			var getter = fam.isGetter(cf);
			switch members[i] {
				case MMethod(_, fn, isStatic, MkMethod) if (!fam.keeps(getter)):
					out.push(MMethod(fieldKey(fam.property.cfName, isStatic ? sns(c) : ins(c)), fn, isStatic, getter ? MkGet : MkSet));
				case m:
					out.push(m);
			}
			if (firstAccessor(item, cf, fam)) for (m in jsAccessors(c, fam)) out.push(m);
		}
		return out;
	}

	static function firstAccessor(item:Item, cf:TClassField, fam:Properties.Family):Bool {
		for (x in item.memberFields) if (x != null && (fam.isGetter(x) || fam.setters.indexOf(x) >= 0)) return x == cf;
		return false;
	}

	// (a property in `$hx.properties`: one JavaScript does not have as its own)
	function reflected(p:TClassField):Bool return props == null || props.unchanged(p);

	// (c's own accessor of the list, its code in the output)
	static function ownAccessor(c:TClass, l:Array<TClassField>, isStatic:Bool):Null<TClassField> {
		for (x in (isStatic ? c.clStatics : c.clFields))
			if (x.cfKind.match(Method(_)) && x.cfExpr != null && x.cfExpr.eexpr.match(TFunction(_)) && l.indexOf(x) >= 0) return x;
		return null;
	}

	static function inheritedAccessor(c:TClass, l:Array<TClassField>):Bool {
		var s = c.clSuper;
		while (s != null) {
			if (ownAccessor(s.cls, l, false) != null) return true;
			s = s.cls.clSuper;
		}
		return false;
	}

	// the JS accessors c needs besides its accessors that are JS accessors themselves: none unless c has one of fam's; then
	// one calling c's accessor that stays a method, or the ancestor's through `super`
	function jsAccessors(c:TClass, fam:Properties.Family):Array<Member> {
		var isStatic = fam.statics;
		var halves = [for (getter in [true, false]) {
			var l = getter ? fam.getters : fam.setters;
			if (l.length == 0) continue;
			{getter: getter, own: ownAccessor(c, l, isStatic), inherited: !isStatic && inheritedAccessor(c, l)};
		}];
		var out:Array<Member> = [];
		if (!Lambda.exists(halves, h -> h.own != null && (!fam.keeps(h.getter) || !h.inherited))) return out;
		var ns = isStatic ? sns(c) : ins(c), name = fam.property.cfName;
		for (h in halves) {
			if (h.own != null && !fam.keeps(h.getter)) continue;
			if (h.own == null && !h.inherited) continue;
			var on = ex(h.own != null ? EThis : ESuper);
			var v = new Sym(SLocal, "v");
			var body = if (h.getter)
				[st(SReturn(h.own != null ? ex(ECall(Lower.field(on, h.own.cfName, ns), [])) : Lower.field(on, name, ns)))]
			else
				[st(SExpr(h.own != null ? ex(ECall(Lower.field(on, h.own.cfName, ns), [ex(EId(v))])) : ex(EAssign("=", Lower.field(on, name, ns), ex(EId(v))))))];
			out.push(MMethod(fieldKey(name, ns), {params: h.getter ? [] : [v], rest: false, arrow: false, body: body}, isStatic, h.getter ? MkGet : MkSet));
		}
		return out;
	}

	// ------------------------------------------------------------------ where statics go

	// the types (indexes of items) e reaches as it runs: those it names, and through the code of the statics,
	// constructors and methods it calls (all the implementations of an instance's method); a function literal
	// only where it is called or passed on (it may run then)
	function reaches(e:TExpr):Map<Int, Bool> {
		var out = new Map<Int, Bool>(), seen = new Map<TClassField, Bool>();
		function need(t:ModuleType) {
			var i = byPath.get(dot(tPath(t)));
			if (i != null) out.set(i.index, true);
		}
		var walk:(TExpr, Bool) -> Void = null;
		function field(cf:TClassField) {
			if (seen.exists(cf)) return;
			seen.set(cf, true);
			switch cf.cfExpr {
				case null:
				case {eexpr: TFunction(f)}: walk(f.tfExpr, true);
				case e: walk(e, true);
			}
		}
		function ctor(c:TClass) {
			while (c != null) {
				need(TClassDecl(c));
				if (c.clConstructor != null) field(c.clConstructor);
				// (filters.ES6Ctors: the constructor's code in a method, which it calls untyped)
				var moved = Lambda.find(c.clFields, x -> x.cfName == "_hx_constructor");
				if (moved != null) field(moved);
				for (f in c.clFields) if (f.cfExpr != null && !f.cfKind.match(Method(_))) field(f);
				c = c.clSuper == null ? null : c.clSuper.cls;
			}
		}
		function method(c:TClass, name:String) {
			var up = c;
			while (up != null) {
				var f = Lambda.find(up.clFields, x -> x.cfName == name);
				if (f != null) {
					field(f);
					break;
				}
				up = up.clSuper == null ? null : up.clSuper.cls;
			}
			var stack = [c], visited = new Map<TClass, Bool>();
			while (stack.length > 0) {
				var k = stack.pop();
				if (visited.exists(k)) continue;
				visited.set(k, true);
				var f = Lambda.find(k.clFields, x -> x.cfName == name);
				if (f != null) field(f);
				var l = kids.get(k);
				if (l != null) for (x in l) stack.push(x);
			}
		}
		walk = (e, runs) -> {
			// (a split's call: its code runs once its file is loaded, later)
			if (splitCalls.exists(e)) return;
			switch e.eexpr {
				case TFunction(f):
					if (runs) walk(f.tfExpr, true);
					return;
				// (what runs, in parentheses: runs)
				case TParenthesis(x) | TMeta(_, x) | TCast(x, _):
					walk(x, runs);
					return;
				// (a local function: called where it is, most likely)
				case TVar(_, {eexpr: TFunction(f)}):
					walk(f.tfExpr, true);
					return;
				case TCall(f, args):
					walk(f, true);
					for (a in args) walk(a, true);
					return;
				case TNew(c, _, args):
					ctor(c);
					for (a in args) walk(a, true);
					return;
				case TTypeExpr(t): need(t);
				case TField(_, FStatic(c, cf)):
					need(TClassDecl(c));
					field(cf);
				case TField(_, FInstance(c, _, cf)) | TField(_, FClosure({cls: c}, cf)):
					method(c, cf.cfName);
				case TField(_, FEnum(en, _)): need(TEnumDecl(en));
				case _:
			}
			Texpr.iter(x -> walk(x, false), e);
		};
		walk(e, false);
		return out;
	}

	// whether what e reaches is declared and initialized before `item` (or is item); another file's types are
	// those of files loaded before (main, a split's parents), all initialized
	function ready(item:Item, e:TExpr):Bool {
		for (i in reached.get(e).keys()) {
			if (i == item.index) continue;
			var other = items[i];
			// (modules: another file's, which runs before; bundled: a file loaded before)
			if (other.file != item.file) {
				if (!modules) continue;
				var a = finished.get(other.file), b = finished.get(item.file);
				if (a == null || b == null || a >= b) return false;
				continue;
			}
			if (i > item.index || tainted.exists(i)) return false;
			if (!other.initInBody) return false;
			for (f in other.statics) if (!other.inBody.get(f)) return false;
		}
		return true;
	}

	// what each `__init__` and static's value reaches (place asks again as it goes): computed once, in parallel
	final reached = new haxe.ds.ObjectMap<TExpr, Map<Int, Bool>>();

	function reachAll() {
		var l:Array<TExpr> = [];
		for (item in items) {
			var c = item.cls;
			if (c != null && c.clInit != null && c.clInit.cfExpr != null) l.push(c.clInit.cfExpr);
			for (f in item.statics) if (f.cfExpr != null && !f.cfExpr.eexpr.match(TFunction(_))) l.push(f.cfExpr);
		}
		var r:Array<Map<Int, Bool>> = [for (_ in l) null];
		parallel([for (i in 0...l.length) i], i -> r[i] = reaches(l[i]));
		for (i in 0...l.length) reached.set(l[i], r[i]);
	}

	function place() {
		reachAll();
		var changed = true;
		while (changed) {
			changed = false;
			for (item in items) {
				var c = item.cls;
				var init = c == null ? null : (c.clInit == null ? null : c.clInit.cfExpr);
				// (untyped code: what it declares at the top level, as Genjs has it, so not in a block)
				item.initInBody = init == null || (!hasRaw(init) && ready(item, init));
				// (modules: one that cannot run as its module does runs in the entry, before the main code)
				if (modules && init != null && !item.initInBody) item.initLate = !ready(item, init);
				// (bundled: the statics after one that waits, wait too, in their order; modules: each is lazy or not)
				var deferred = !item.initInBody && !modules;
				for (f in item.statics) {
					// (a function: runs nothing, in the class, as Genjs has it; one without a value: declared, before `__init__`)
					if (f.cfExpr == null || f.cfExpr.eexpr.match(TFunction(_))) {
						item.inBody.set(f, true);
						continue;
					}
					if (modules) {
						item.inBody.set(f, ready(item, f.cfExpr));
						continue;
					}
					if (!deferred && !ready(item, f.cfExpr)) deferred = true;
					item.inBody.set(f, !deferred);
				}
			}
			if (!modules) 			for (item in items) {
				var c = item.cls;
				var init = c == null ? null : (c.clInit == null ? null : c.clInit.cfExpr);
				if (init != null && !item.initInBody) for (i in reached.get(init).keys()) if (!tainted.exists(i)) {
					tainted.set(i, true);
					changed = true;
				}
			}
		}
		// (modules: the `__init__`s that run in the entry, lowered as its code)
		if (modules) for (item in items) if (item.initLate) {
			current = 0;
			var init = item.cls.clInit.cfExpr;
			lateInits.push(st(SComment(item.path + ".__init__")));
			for (s in initStatements(lowerNow(lower -> {
				lower.prepare(init);
				lower.statements(init);
			}, true)))
				lateInits.push(s);
		}
		current = 0;
		if (Gctx.rawDefined(com, "hxmc.js.order_report")) {
			for (item in items) {
				if (!item.initInBody) Sys.println("es: " + item.path + ".__init__ after the types");
				for (f in item.statics) if (!item.inBody.get(f)) Sys.println("es: " + item.path + "." + f.cfName + " after the types");
			}
		}
	}

	// ------------------------------------------------------------------ modules: the files, their order

	// (modules) A class's module runs before the modules of the classes extending it, or they fail to define
	// theirs (`class B extends A` reads A). Modules extending each other's classes (`Left`'s LeftChild extends
	// `Right`'s Right, which extends Left) have no such order: such a class moves to a file of its own,
	// `<module>.<Class>.js`, which the code that uses it imports, until no such cycle is left. Of a cycle's classes,
	// a module's secondary class moves, else the one of the module with the most.
	function breakCycles() {
		// the files a file's classes' super classes are in (but its own)
		function supers(i:Int):Array<{item:Item, to:Int}> {
			var r = [];
			for (item in files[i].items) switch item.t {
				case TClassDecl({clSuper: {cls: s}}):
					var other = byPath.get(dot(s.clPath));
					if (other != null && other.file != i) r.push({item: item, to: other.file});
				case _:
			}
			return r;
		}
		// a cycle of files, by their super classes: its edges (the class, the file it extends one of), or null
		function cycle():Null<Array<{item:Item, to:Int}>> {
			// (stack: the files being visited; via[j]: the edge from stack[j] to stack[j + 1])
			var state = new Map<Int, Int>(), stack:Array<Int> = [], via:Array<{item:Item, to:Int}> = [];
			function dfs(i:Int):Null<Array<{item:Item, to:Int}>> {
				state.set(i, 1);
				stack.push(i);
				for (e in supers(i)) {
					var s = state.get(e.to);
					if (s == 1) {
						var r = via.slice(stack.indexOf(e.to));
						r.push(e);
						return r;
					}
					if (s == null) {
						via.push(e);
						var r = dfs(e.to);
						if (r != null) return r;
						via.pop();
					}
				}
				stack.pop();
				state.set(i, 2);
				return null;
			}
			for (f in files) if (!state.exists(f.id)) {
				var r = dfs(f.id);
				if (r != null) return r;
			}
			return null;
		}
		for (round in 0...items.length) {
			var c = cycle();
			if (c == null) return;
			// (a class that is not its module's own, in a file with others; else the file's with the most)
			var movable = c.filter(e -> files[e.item.file].items.length > 1);
			if (movable.length == 0) return;
			var pick = Lambda.find(movable, e -> !isModuleType(e.item));
			if (pick == null) {
				movable.sort((a, b) -> files[b.item.file].items.length - files[a.item.file].items.length);
				pick = movable[0];
			}
			var item = pick.item, from = files[item.file];
			from.items.remove(item);
			var f = new OutFile(files.length, null);
			f.path = Path.withoutExtension(from.path) + "." + tPath(item.t).name + ext;
			files.push(f);
			item.file = f.id;
			f.items.push(item);
			if (Gctx.rawDefined(com, "hxmc.js.order_report")) Sys.println("es-modules: " + item.path + " in a file of its own (" + f.path + "): its module and its super class's extend each other's classes");
		}
	}

	// (a module's own type: of its name)
	function isModuleType(item:Item):Bool return tPath(item.t).name == tInfos(item.t).mtModule.mPath.name;

	// the file of a Haxe module (modules)
	function moduleFile(p:GlobalTypePath):Int {
		var k = dot(p);
		var i = moduleFiles.get(k);
		if (i == null) {
			if (p.pack.concat([p.name + ext]).join("/") == files[0].path) {
				moduleFiles.set(k, 0);
				return 0;
			}
			i = files.length;
			var f = new OutFile(i, null);
			f.path = p.pack.concat([p.name + ext]).join("/");
			files.push(f);
			moduleFiles.set(k, i);
		}
		return i;
	}

	// whether a file defines anything (an interface without a value does not)
	function hasValue(f:OutFile):Bool {
		for (item in f.items) switch item.t {
			case TClassDecl(c) if (hasClassFlag(c, CInterface) && !runtimeInterfaces):
			case _: return true;
		}
		return false;
	}

	final rank = new Map<Int, Int>();

	// 1 + the highest of the files of its classes' super classes (0: none): imported first, the more derived
	function rankOf(i:Int):Int {
		var r = rank.get(i);
		if (r != null) return r;
		rank.set(i, 0);
		var best = 0;
		for (item in files[i].items) switch item.t {
			case TClassDecl({clSuper: {cls: s}}):
				var other = byPath.get(dot(s.clPath));
				if (other != null && other.file != i) best = Std.int(Math.max(best, rankOf(other.file) + 1));
			case _:
		}
		rank.set(i, best);
		return best;
	}

	function sortDeps(l:Array<Int>):Array<Int> {
		l.sort((a, b) -> rankOf(b) != rankOf(a) ? rankOf(b) - rankOf(a) : Reflect.compare(files[a].path ?? "", files[b].path ?? ""));
		return l;
	}

	function isSplit(f:OutFile):Bool return f.id != 0 && f.chunk != null;

	// The order the files run in: each after what it imports, in the order of its imports, a split's once its
	// parents' have (ES modules). The entry imports first the modules of the classes whose super classes would
	// run after them, of what the generated code always uses, and the modules nothing imports (their `__init__`,
	// reflection), then what its own code uses.
	function order() {
		flags();
		for (f in files) {
			var l = [];
			for (s => from in f.needs) if (from >= 0 && from != f.id && !l.contains(from) && hasValue(files[from])) l.push(from);
			f.deps = sortDeps(l);
		}
		function closure(roots:Array<Int>, seen:Map<Int, Bool>) {
			var stack = roots.copy();
			while (stack.length > 0) {
				var i = stack.pop();
				if (seen.exists(i)) continue;
				seen.set(i, true);
				for (d in files[i].deps) stack.push(d);
			}
		}
		var always = [];
		for (k in @:privateAccess Splits.ALWAYS_MAIN) {
			var item = byPath.get(k);
			if (item != null && hasValue(files[item.file]) && !always.contains(item.file)) always.push(item.file);
		}
		var reached = new Map<Int, Bool>();
		closure([0].concat(always), reached);
		var unreached = [];
		for (f in files) if (f.path != null && !reached.exists(f.id) && hasValue(f)) {
			var inMain = Lambda.exists(f.items, item -> !splits.hasSplits() || splits.info(item.t) == null || splits.info(item.t).chunk == splits.main);
			if (inMain) {
				unreached.push(f.id);
				closure([f.id], reached);
			}
		}
		// (a split's: the modules of its types nothing it imports loads)
		for (f in files) if (isSplit(f)) {
			var seen = new Map<Int, Bool>();
			closure([f.id], seen);
			for (t in f.chunk.types) {
				var item = byPath.get(dot(tPath(t.t)));
				if (item != null && !seen.exists(item.file) && hasValue(files[item.file]) && !f.deps.contains(item.file)) f.deps.push(item.file);
			}
		}
		var own = files[0].deps;
		var fixes:Array<Int> = [];
		for (round in 0...20) {
			var l = [];
			for (i in fixes.concat(always).concat(unreached).concat(own)) if (!l.contains(i) && i != 0) l.push(i);
			files[0].deps = l;
			simulate();
			var late = lateFiles();
			var added = false;
			for (i in late) if (!fixes.contains(i)) {
				fixes.push(i);
				added = true;
			}
			if (!added) {
				for (i in late) Sys.println("es-modules: " + files[i].path + " defines a class before its super class's module runs (a cycle)");
				break;
			}
		}
		if (Gctx.rawDefined(com, "hxmc.js.order_report"))
			Sys.println("es-modules: " + fixes.length + " modules run first (" + [for (i in fixes) files[i].path].join(", ") + ")");
	}

	// ES modules: a file runs after the files it imports, in their order (but for those already running)
	function simulate() {
		finished.clear();
		var n = 0;
		function run(root:Int, done:Map<Int, Bool>) {
			var started = new Map<Int, Bool>();
			function visit(i:Int) {
				if (started.exists(i) || done.exists(i)) return;
				started.set(i, true);
				for (d in files[i].deps) visit(d);
				done.set(i, true);
				finished.set(i, n++);
			}
			visit(root);
		}
		var doneMain = new Map<Int, Bool>();
		run(0, doneMain);
		var doneOf = new Map<Int, Map<Int, Bool>>();
		doneOf.set(splits.main.id, doneMain);
		var l = [for (f in files) if (isSplit(f)) f];
		l.sort((a, b) -> a.chunk.depth - b.chunk.depth);
		for (f in l) {
			var parent = f.chunk.parent;
			var above = parent == null || !doneOf.exists(parent.id) ? doneMain : doneOf.get(parent.id);
			var done = [for (k => v in above) k => v];
			run(f.id, done);
			doneOf.set(f.chunk.id, done);
		}
	}

	// the files of the classes whose super class's file has not run when theirs does
	function lateFiles():Array<Int> {
		var out = [];
		for (item in items) switch item.t {
			case TClassDecl(c = {clSuper: {cls: s}}) if (!hasClassFlag(c, CInterface)):
				var other = byPath.get(dot(s.clPath));
				if (other == null || other.file == item.file) continue;
				var a = finished.get(other.file), b = finished.get(item.file);
				if (b != null && (a == null || a > b) && !out.contains(item.file)) out.push(item.file);
			case _:
		}
		return out;
	}

	// the path of `to` relative to `from`'s directory, for an import
	static function rel(from:String, to:String):String {
		var a = Path.directory(from).split("/").filter(s -> s != ""), b = to.split("/");
		var i = 0;
		while (i < a.length && i < b.length - 1 && a[i] == b[i]) i++;
		var up = [for (_ in i...a.length) ".."];
		var r = up.concat(b.slice(i)).join("/");
		return up.length == 0 ? "./" + r : r;
	}

	var RUNTIME(get, never):String;

	inline function get_RUNTIME() return "_hx" + ext;

	static inline final INCLUDE = "_hx_include.js";

	// (an included file's declaration at its top level, in a line of its own)
	// the names code declares at its top level (a line's start: `var x = …`, `function f() {…}`, `class C {}`)
	static function topLevelNames(code:String, names:Array<String>):Array<String> {
		var re = ~/^(?:var|let|const|function|class)\s+([A-Za-z_$][A-Za-z0-9_$]*)/gm;
		var pos = 0;
		while (re.matchSub(code, pos)) {
			if (!names.contains(re.matched(1))) names.push(re.matched(1));
			var m = re.matchedPos();
			pos = m.pos + m.len;
		}
		return names;
	}

	// (modules) what the included files declare at their top level
	function includeGlobals():Array<String> {
		var names = [];
		if (modules) for (f in com.includeFiles) topLevelNames(sys.io.File.getContent(f.file), names);
		return names;
	}

	// a file's imports: the runtime, then what it needs of the files it imports (in their order, all of them: the
	// order they run in), the @:jsRequire modules
	function imports(f:OutFile, path:String):String {
		var b = new StringBuf();
		function as(s:Sym, n:String) return s.name == n ? n : n + " as " + s.name;
		var rtNames = rtFiles.exists(f.id) ? ["$hx"] : [];
		if (indexFiles.exists(f.id)) rtNames.push(as(enumIndex, "index"));
		if (enumValueFiles.exists(f.id) || f.names.enumValue) rtNames.push((rtNames.length == 0 ? "" : "type ") + as(enumValueType, "EnumValue"));
		if (rtNames.length > 0)
			b.add("import " + (rtFiles.exists(f.id) ? "" : "type ") + "{ " + rtNames.join(", ") + " } from " + Printer.quote(rel(path, RUNTIME)) + ";\n");
		for (d in f.deps) {
			var names = [for (s => from in f.needs) if (from == d) s.name];
			names.sort(Reflect.compare);
			var target = Printer.quote(rel(path, files[d].path));
			b.add(names.length == 0 ? "import " + target + ";\n" : "import { " + names.join(", ") + " } from " + target + ";\n");
		}
		// (TypeScript: the types it names only, which nothing runs)
		var typeFiles = [];
		for (s => from in f.names.needs) if (from != f.id && !f.needs.exists(s) && !typeFiles.contains(from)) typeFiles.push(from);
		typeFiles.sort((a, b) -> Reflect.compare(files[a].path ?? "", files[b].path ?? ""));
		for (d in typeFiles) {
			var names = [for (s => from in f.names.needs) if (from == d && !f.needs.exists(s)) s.name];
			names.sort(Reflect.compare);
			b.add("import type { " + names.join(", ") + " } from " + Printer.quote(rel(path, files[d].path)) + ";\n");
		}
		for (r in requires) if (f.needs.exists(r.sym)) {
			if (r.path == null) b.add("import " + r.sym.name + " from " + Printer.quote(r.module) + ";\n") else {
				b.add("import " + r.sym.name + "$default from " + Printer.quote(r.module) + ";\n");
				b.add("const " + r.sym.name + " = " + r.sym.name + "$default." + r.path + ";\n");
			}
		}
		return b.toString();
	}

	// the modules output: a module per Haxe module, the runtime, the splits', the entry (com.file)
	function writeModules() {
		var dir = Path.directory(com.file);
		if (dir != "") sys.FileSystem.createDirectory(dir);
		tight = Gctx.definedValueSafe(com, "hxmc.js.minify") != "";
		prepareFieldNames();
		nameSplitKeys();
		if (tight) shorten();
		var docs = [for (f in files) {
			current = f.id;
			body(f);
		}];
		current = 0;
		newMaps();
		var decls = printAll(docs);
		// (what the printing found the files use (class heads' interfaces): imported too)
		for (f in files) for (s => from in f.needs) if (from >= 0 && from != f.id && !f.deps.contains(from) && hasValue(files[from])) f.deps.push(from);
		// (the types the runtime names) (`{js.Boot}`): registered by their modules in `$hx.types`)
		if (rtUsed.exists("load")) {
			rtUsed.remove("load");
			rtUsed.set("loadModule", true);
		}
		var registered = new Map<Int, Bool>();
		var rtSource = Runtime.source(rtUsed, n -> {
			var item = byPath.get(n);
			if (item == null) return null;
			registered.set(item.index, true);
			rtFiles.set(item.file, true);
			rtUsed.set("types", true);
			"$hx.types." + item.sym.name;
		});
		var hasStringRec = byPath.exists("js.Boot") && byPath.get("js.Boot").cls.clStatics.exists("__string_rec");
		// (EnumValue's toString, below: js.Boot's __string_rec, registered as the runtime's `{js.Boot}`)
		if (hasStringRec) {
			var boot = byPath.get("js.Boot");
			registered.set(boot.index, true);
			rtFiles.set(boot.file, true);
			rtUsed.set("types", true);
		}
		// (again: with `types`, if registered)
		rtSource = Runtime.source(rtUsed, n -> {
			var item = byPath.get(n);
			item == null ? null : "$hx.types." + item.sym.name;
		});
		if (hasStringRec)
			rtSource = rtSource.replace("EnumValue: class EnumValue {}",
				"EnumValue: class EnumValue {\n\t\ttoString() {\n\t\t\treturn $hx.types." + byPath.get("js.Boot").sym.name + "." + fieldName("__string_rec", NStaticPath("js.Boot")) + "(this, \"\");\n\t\t}\n\t}");
		var written = new Map<String, Bool>();
		var hashLength = Std.parseInt(Gctx.definedValueSafe(com, "hxmc.js.hash_length"));
		if (hashLength == null) hashLength = 8;
		// (the modules, in parallel)
		var head = header();
		var mods = [for (f in files) if (f.id != 0 && f.path != null && (hasValue(f) || tsOut)) f];
		for (f in mods) sys.FileSystem.createDirectory(Path.directory(Path.join([dir, f.path])));
		parallel(mods, f -> {
			var b = new StringBuf();
			b.add(head);
			b.add(imports(f, f.path));
			if (b.length > 0) b.add("\n");
			b.add(decls[f.id]);
			for (item in f.items) if (registered.exists(item.index)) b.add("$hx.types." + item.sym.name + " = " + item.sym.name + ";\n");
			save(Path.join([dir, f.path]), b.toString(), f.smap);
		});
		// (no files of splits: a split's code is where it is called, the modules it needs imported there: splitImport)
		// (the runtime)
		var rt = new StringBuf();
		rt.add(header());
		// (TypeScript: unchecked, its type declared)
		if (tsOut) {
			if (rtSource == "") rtSource = "const $hx = {};\n";
			// (a split's file by its name and the runtime's own extension: `.ts` as it is, `.js` compiled)
			rtSource = rtSource.replace("new URL($hx.files[name] + \".js\", ", "new URL($hx.files[name] + import.meta.url.slice(import.meta.url.lastIndexOf(\".\")), ");
			rt.add("// @ts-nocheck\n" + Runtime.TS + "export " + rtSource.replace("const $hx = {", "const $hx: typeof Hx & { [k: string]: any } = {"));
			// (the index's key as TypeScript narrows by it)
			if (rtUsed.exists("index")) rt.add("export const index: typeof Hx.index = $hx.index;\n");
		} else rt.add("export " + rtSource);
		sys.io.File.saveContent(Path.join([dir, RUNTIME]), rt.toString());
		if (tsOut) externDeclarations(dir);
		// (the entry: the included files first, as they are, a module the entry imports before anything else)
		var entry = Path.withoutDirectory(com.file);
		var b = new StringBuf();
		b.add(header());
		if (com.includeFiles.length > 0) {
			var code = new StringBuf();
			for (f in com.includeFiles) {
				var s = sys.io.File.getBytes(f.file).toString();
				code.add(s);
				if (!StringTools.endsWith(s, "\n")) code.add("\n");
			}
			// (what they declare at their top level, which a module keeps to itself: global, as in Genjs's script)
			for (n in includeGlobals()) code.add("globalThis." + n + " = " + n + ";\n");
			sys.io.File.saveContent(Path.join([dir, INCLUDE]), code.toString());
			b.add("import " + Printer.quote("./" + INCLUDE) + ";\n");
		}
		b.add(imports(files[0], entry));
		b.add("\n");
		b.add(decls[0]);
		for (item in files[0].items) if (registered.exists(item.index)) b.add("$hx.types." + item.sym.name + " = " + item.sym.name + ";\n");
		var p = printer(files[0]);
		p.statements(lateInits);
		p.statements(mainCode);
		b.add(p.toString());
		save(com.file, b.toString(), files[0].smap);
		if (splits.hasSplits()) prune(dir, written);
	}

	// the output's flags, from what the code refers to
	function flags() {
		names = refs.exists("js.Boot.__className");
		resolveClass = refs.exists("Type.resolveClass") || feature("Type.resolveClass");
		resolveEnum = refs.exists("Type.resolveEnum");
		properties = refs.exists("Reflect.accessor");
		runtimeInterfaces = interfaceValues || resolveClass;
		instanceFields = feature("Type.getInstanceFields");
	}

	// ------------------------------------------------------------------ TypeScript: externs

	// _externs.d.ts: the externs the program names by a global path (`React`, `a.b.C`), declared from the externs
	// themselves (Dts), global (a namespace per package), but the std's, whose TypeScript's library has (its own
	// declarations); a path several externs have is `any`, one of `window`'s a property of the Window interface;
	// the program's types they name by their modules (`import("./pack/A.ts").A`)
	function externDeclarations(dir:String) {
		var globals = new Map<TClass, String>();
		for (t in com.types) switch t {
			case TClassDecl(c) if (hasClassFlag(c, CExtern) && c.clKind.match(KNormal | KGeneric) && !isRequire(c) && !byPath.exists(dot(c.clPath))):
				if (stdExtern(c)) continue;
				var p = Genjs.getGeneratedClassPath(c);
				var parts = p.pack.concat([p.name]);
				if (parts.length > 0 && !["window", "globalThis", "self", "global"].contains(parts[0])
					&& Lambda.foreach(parts, s -> validIdent(s) && !RESERVED.exists(s))) globals.set(c, parts.join("."));
			case _:
		}
		var count = new Map<String, Int>();
		for (p in globals) count.set(p, (count.exists(p) ? count.get(p) : 0) + 1);
		var shared:Array<String> = [];
		for (c => p in [for (c => p in globals) c => p]) if (count.get(p) > 1) {
			globals.remove(c);
			if (!shared.contains(p)) shared.push(p);
		}
		function ref(t:ModuleType):Null<String> {
			switch t {
				case TClassDecl(c) if (globals.exists(c)): return globals.get(c);
				case TClassDecl({clKind: KAbstractImpl(_) | KModuleFields(_)}) | TAbstractDecl(_) | TTypeDecl(_): return null;
				case _:
			}
			var item = byPath.get(dot(tPath(t)));
			if (item == null || files[item.file].path == null) return null;
			return "import(" + Printer.quote("./" + files[item.file].path) + ")." + item.sym.name;
		}
		var b = new StringBuf();
		var keys = [for (c => p in globals) {c: c, p: p}];
		keys.sort((a, b) -> Reflect.compare(a.p, b.p));
		// (a class's static of the name of a namespace other externs are in (`chrome.cast`'s `media`): the namespace)
		var namespaces = new Map<String, Bool>();
		for (k in keys) {
			var parts = k.p.split(".");
			for (i in 1...parts.length) namespaces.set(parts.slice(0, i).join("."), true);
		}
		for (k in keys) {
			var parts = k.p.split("."), n = parts.pop();
			var skip = (s:String) -> namespaces.exists(k.p + "." + s);
			if (parts.length == 0) Dts.classDecl(b, k.c, ref, "declare ", n, "", skip);
			else {
				b.add("declare namespace " + parts.join(".") + " {\n");
				Dts.classDecl(b, k.c, ref, "", n, "\t", skip);
				b.add("}\n");
			}
		}
		shared.sort(Reflect.compare);
		for (p in shared) {
			var parts = p.split("."), n = parts.pop();
			b.add(parts.length == 0 ? "declare var " + n + ": any;\n" : "declare namespace " + parts.join(".") + " {\n\tvar " + n + ": any;\n}\n");
		}
		var props = new Map<String, Bool>();
		for (t in com.types) switch t {
			case TClassDecl(c) if (hasClassFlag(c, CExtern)):
				var p = Genjs.getGeneratedClassPath(c);
				var bracket = ~/^window\[["']([A-Za-z_$][A-Za-z0-9_$]*)["']\]/;
				if (bracket.match(p.pack.concat([p.name]).join("."))) props.set(bracket.matched(1), true);
				if (p.pack.length > 1 && p.pack[0] == "window" && validIdent(p.pack[1])) props.set(p.pack[1], true);
				else if (p.pack.length == 1 && p.pack[0] == "window" && validIdent(p.name)) props.set(p.name, true);
			case _:
		}
		var names = [for (k in props.keys()) k];
		names.sort(Reflect.compare);
		if (names.length > 0) b.add("interface Window {\n" + [for (n in names) "\t" + n + ": any;\n"].join("") + "}\n");
		// (what the included files and externs' `__init__`s declare at their top level: made global)
		var raw = includeGlobals();
		for (c in externInits) for (n in rawGlobals(externInitCode.get(c))) if (!raw.contains(n)) raw.push(n);
		raw.sort(Reflect.compare);
		for (n in raw) b.add("declare var " + n + ": any;\n");
		sys.io.File.saveContent(Path.join([dir, "_externs.d.ts"]), b.toString());
	}

	// ------------------------------------------------------------------ names

	function name() {
		var taken = new Map<String, Bool>();
		for (k in RESERVED.keys()) taken.set(k, true);
		for (k in localNames.keys()) taken.set(k, true);
		for (k in globals.keys()) taken.set(k, true);
		for (k in rawWords.keys()) taken.set(k, true);
		taken.set("$hx", true);
		function pick(s:Sym, fallback:String) {
			var n = s.hint;
			if (taken.exists(n)) n = fallback;
			var base = n, i = 1;
			while (taken.exists(n)) n = base + "$" + (i++);
			s.name = n;
			taken.set(n, true);
		}
		// (a type untyped code names, by Genjs's name for it (flat): that name)
		var named = new Map<Int, Bool>();
		for (item in items) {
			var flat = core.Path.flatPath(tPath(item.t));
			if (rawWords.exists(flat) && !localNames.exists(flat) && !globals.exists(flat)) {
				item.sym.name = flat;
				named.set(item.index, true);
			}
		}
		if (tsOut) {
			pick(enumIndex, "index$");
			pick(enumValueType, "EnumValue$");
		}
		for (r in requires) pick(r.sym, r.sym.hint + "$");
		for (item in items) if (!named.exists(item.index)) pick(item.sym, core.Path.flatPath(tPath(item.t)));
		for (k => s in moduleFields) pick(s, k.split(".").join("_"));
	}

	// ------------------------------------------------------------------ the output

	var names = false;
	var resolveClass = false;
	var resolveEnum = false;
	var properties = false;
	var runtimeInterfaces = false;
	var instanceFields = false;

	function write() {
		flags();
		if (props != null) {
			props.decide();
			if (Gctx.rawDefined(com, "hxmc.js.properties_report")) Sys.println(props.report());
		}
		if (modules) {
			writeModules();
			return;
		}
		var dir = Path.directory(com.file);
		if (dir != "") sys.FileSystem.createDirectory(dir);
		var hashLength = Std.parseInt(Gctx.definedValueSafe(com, "hxmc.js.hash_length"));
		if (hashLength == null) hashLength = 8;
		var written = new Map<String, Bool>();
		var minify = Gctx.definedValueSafe(com, "hxmc.js.minify");
		// (-D hxmc.js.minify: the output minified; =aside: also `<output>.min.js`, its splits `<name>_<hash>.min.js`)
		var passes = minify == "aside" ? [false, true] : [minify != ""];
		timed("fields", prepareFieldNames);
		for (min in passes) {
			var suffix = min && minify == "aside" ? ".min.js" : ".js";
			if (min) timed("shorten", shorten);
			tight = min;
			nameSplitKeys();
			// (each file's types: assembled as the file being lowered, what they use of other files its; printed in parallel)
			var docs = [];
			timed("assemble", () -> {
				docs = [for (f in files) {
					current = f.id;
					body(f);
				}];
				current = 0;
			});
			newMaps();
			var decls:Array<String> = [];
			timed("print", () -> decls = printAll(docs));
			// (a binding a file takes from another: the file it is in adds it to the scope)
			var exported = [for (f in files) f.id => new Map<Sym, Bool>()];
			for (f in files) for (s => from in f.needs) exported.get(from).set(s, true);
			var bodies = [for (f in files) decls[f.id] + tail(f, exported.get(f.id))];
			// (the splits first, named by their code's hashes, in parallel: the main file maps their names to their files)
			var splitFiles = [for (f in files) if (isSplit(f)) f];
			var codes = [for (f in splitFiles) splitFile(f, bodies[f.id])];
			var saved:Array<Array<String>> = [for (_ in splitFiles) null];
			timed("splits", () -> parallel([for (i in 0...splitFiles.length) i], i -> {
				var f = splitFiles[i], r = finish(codes[i], f.smap);
				f.file = fileName(f.chunk.name) + "_" + haxe.crypto.Md5.encode(r.code).substr(0, hashLength) + suffix;
				var w = [f.file];
				saveFinished(Path.join([dir, f.file]), r, w);
				saved[i] = w;
			}));
			for (w in saved) for (n in w) written.set(n, true);
			timed("main", () -> {
				var main = mainFile(bodies[0]);
				save(suffix == ".js" ? com.file : Path.withoutExtension(com.file) + suffix, main, files[0].smap);
			});
		}
		if (splits.hasSplits()) prune(dir, written);
	}

	var tight = false;

	// (-D hxmc.js.minify.fields: the fields' names too, FieldNames)
	var fieldNames:Null<FieldNames> = null;

	var fieldsDebug = false;

	var fieldsFinished = false;

	// (after the lowering: the names, FieldNames.finish)
	function prepareFieldNames() {
		if (fieldNames == null || fieldsFinished) return;
		fieldsFinished = true;
		fieldsDebug = Gctx.definedValueSafe(com, "hxmc.js.minify.fields") == "debug";
		fieldNames.finish();
		if (Gctx.rawDefined(com, "hxmc.js.minify.fields_report")) Sys.println(fieldNames.report(Gctx.definedValueSafe(com, "hxmc.js.minify.fields_report") == "names"));
	}

	public function fieldName(name:String, ns:Ns):String {
		if (fieldNames == null || !tight && !fieldsDebug) return name;
		return fieldNames.lookup(name, fieldNames.nsIndex(ns));
	}

	// short names (minified): the types and module-level fields by how often the code uses them, the shortest to the
	// most used; then each field's locals (a scope: its code and its closures), from the shortest names again but for
	// those of the types and fields it uses. A name untyped code mentions is kept, and no name is one it mentions or
	// a global.
	function shorten() {
		prepareFieldNames();
		var avoid = new Map<String, Bool>();
		for (k in RESERVED.keys()) avoid.set(k, true);
		for (k in globals.keys()) avoid.set(k, true);
		for (k in rawWords.keys()) avoid.set(k, true);
		avoid.set("$hx", true);
		inline function keep(s:Sym) return rawWords.exists(s.name);
		var tops:Array<Sym> = [for (r in requires) r.sym];
		for (item in items) tops.push(item.sym);
		for (s in moduleFields) tops.push(s);
		inline function count(s:Sym) return useCount.exists(s) ? useCount.get(s) : 0;
		tops.sort((a, b) -> count(b) - count(a));
		var top = new Map<String, Bool>();
		for (s in tops) if (keep(s)) top.set(s.name, true);
		var n = 0;
		for (s in tops) if (!keep(s)) {
			var name;
			do name = shortName(n++) while (avoid.exists(name) || top.exists(name));
			s.name = name;
			top.set(name, true);
		}
		// (scopes that share a local: named as one)
		var groups = new Map<Int, {locals:Array<Sym>, uses:Map<Sym, Bool>}>();
		for (i in 0...scopes.length) {
			var root = find(i);
			var g = groups.get(root);
			if (g == null) groups.set(root, g = {locals: [], uses: new Map()});
			for (s in scopes[i].locals) g.locals.push(s);
			for (s in scopes[i].uses.keys()) g.uses.set(s, true);
		}
		for (scope in groups) {
			var taken = new Map<String, Bool>();
			for (s in scope.uses.keys()) taken.set(s.name, true);
			for (s in scope.locals) if (keep(s)) taken.set(s.name, true);
			var i = 0;
			for (s in scope.locals) if (!keep(s)) {
				var name;
				do name = shortName(i++) while (avoid.exists(name) || taken.exists(name));
				s.name = name;
				taken.set(name, true);
			}
		}
	}

	// the field being lowered, what it declares and uses (minified names)
	var scope:Null<{locals:Array<Sym>, uses:Map<Sym, Bool>}> = null;
	final scopes:Array<{locals:Array<Sym>, uses:Map<Sym, Bool>}> = [];
	final useCount = new Map<Sym, Int>();

	final symScope = new Map<Sym, Int>();
	final scopeParent:Array<Int> = [];

	function find(i:Int):Int {
		while (scopeParent[i] != i) i = scopeParent[i] = scopeParent[scopeParent[i]];
		return i;
	}

	public function enterScope() {
		scope = {locals: [], uses: new Map()};
		scopeParent.push(scopes.length);
		scopes.push(scope);
	}

	public function declare(s:Sym) {
		if (scope == null) return;
		var cur = scopes.length - 1;
		var owner = symScope.get(s);
		if (owner == null) {
			symScope.set(s, cur);
			scope.locals.push(s);
		} else {
			var a = find(owner), b = find(cur);
			if (a != b) scopeParent[a] = b;
		}
	}

	static final FIRST = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_$";
	static final REST = FIRST + "0123456789";

	public static function shortName(i:Int):String {
		var s = FIRST.charAt(i % FIRST.length);
		i = Std.int(i / FIRST.length);
		while (i > 0) {
			i--;
			s += REST.charAt(i % REST.length);
			i = Std.int(i / REST.length);
		}
		return s;
	}

	// the files of an earlier build's splits of these names, removed (a split's file changes its name with its code)
	function prune(dir:String, current:Map<String, Bool>) {
		var names = new Map<String, Bool>();
		for (f in files) if (isSplit(f)) names.set(fileName(f.chunk.name), true);
		var re = ~/^(.+)_[0-9a-f]+(\.min)?\.js(\.map)?$/;
		for (f in try sys.FileSystem.readDirectory(dir == "" ? "." : dir) catch (_:Dynamic) [])
			if (!current.exists(f) && re.match(f) && names.exists(re.matched(1))) try sys.FileSystem.deleteFile(Path.join([dir, f])) catch (_:Dynamic) {}
	}

	function header():String {
		var b = new StringBuf();
		Gctx.mapSourceHeader(com.defines, s -> b.add("// " + s + "\n"));
		return b.toString();
	}

	// the main file: the included files (at the top), the runtime, the types, the scope the splits take, the main code
	function mainFile(body:String):String {
		var out = new StringBuf();
		out.add(header());
		// (a directive: before the included files, which a classic script would have it after)
		out.add("\"use strict\";\n");
		for (f in com.includeFiles) if (f.position == "top") out.add(sys.io.File.getBytes(f.file).toString() + "\n;\n");
		out.add("{\n");
		for (f in com.includeFiles) if (f.position != "top") out.add(sys.io.File.getBytes(f.file).toString() + "\n;\n");
		for (r in requires) {
			var req = "require(" + Printer.quote(r.module) + ")" + (r.path == null ? "" : "." + r.path);
			out.add("const " + r.sym.name + " = " + req + ";\n");
		}
		if (splits.hasSplits()) {
			rtUsed.set("load", true);
			rtUsed.set("scope", true);
		}
		var hasStringRec = byPath.exists("js.Boot") && byPath.get("js.Boot").cls.clStatics.exists("__string_rec");
		// (the splits' files by name, where the main file is: in `$hx` as it is declared)
		var values = new Map<String, String>();
		if (splits.hasSplits()) {
			values.set("files", splitTable(f -> f.file));
			var base = Gctx.definedValueSafe(com, "hxmc.js.chunk_base");
			if (base == "")
				base = "typeof document != \"undefined\" && document.currentScript && document.currentScript.src || typeof __filename != \"undefined\" && require(\"url\").pathToFileURL(__filename).href || (/(?:https?|file):\\/\\/[^\\s)]*?(?=:\\d+:\\d+)/.exec(new Error().stack) || [\"\"])[0]";
			values.set("base", base);
		}
		var rtSource = Runtime.source(rtUsed, n -> {
			var i = byPath.get(n);
			i == null ? null : i.sym.name;
		}, values);
		if (hasStringRec && rtSource != "")
			rtSource = rtSource.replace("EnumValue: class EnumValue {}",
				"EnumValue: class EnumValue {\n\t\ttoString() {\n\t\t\treturn " + byPath.get("js.Boot").sym.name + "." + fieldName("__string_rec", NStaticPath("js.Boot")) + "(this, \"\");\n\t\t}\n\t}");
		out.add(rtSource);
		if (rtSource != "") out.add("\n");
		out.add(body);
		out.add("}\n");
		return out.toString();
	}

	// a split's file: a module whose default export takes the bindings it uses, defines its types and returns its
	// initializers
	function splitFile(f:OutFile, body:String):String {
		var out = new StringBuf();
		out.add(header());
		var params:Array<Prop> = [];
		var names = [for (s in f.needs.keys()) s];
		names.sort((a, b) -> Reflect.compare(a.name, b.name));
		for (s in names) params.push({key: KName(s.name), value: ex(EId(s))});
		out.add("export default ($hx) => {\n");
		var p = printer(f);
		if (params.length > 0) p.statement(st(SVar(VConst, [{name: new Sym(SLocal, "{ " + [for (s in names) s.name].join(", ") + " }"), init: rt("scope")}])));
		out.add(p.toString());
		out.add(body);
		var inits = printer(f);
		inits.statement(st(SReturn(ex(EArray([for (fn in f.inits) ex(EFn(fn))])))));
		out.add(inits.toString());
		out.add("};\n");
		return out.toString();
	}

	// a file's types and the code that runs after them (assembled: Chunk.print prints them)
	function body(file:OutFile):Doc {
		var body = new Doc();
		var after:Array<St> = [];
		var deferredStatics:Array<St> = [];
		var exposed:Array<St> = [];
		// (the externs' `__init__`s: first, where they reach none of the types, as untyped code declaring globals does)
		if (file.id == 0) for (c in externInits) {
			var code = initStatements(externInitCode.get(c));
			code = code.concat(globalized(externInitCode.get(c)));
			if (reaches(c.clInit.cfExpr).keys().hasNext()) {
				after.push(st(SComment(dot(c.clPath) + ".__init__")));
				for (s in code) after.push(s);
			} else body.statements(code);
		}
		// (the interfaces first: their values are what classes list)
		var anyInterface = false;
		if (runtimeInterfaces) for (item in file.items) switch item.t {
			case TClassDecl(c) if (hasClassFlag(c, CInterface)):
				anyInterface = true;
				var supers = [for (i in c.clImplements) type(TClassDecl(i.cls), c.clPos)];
				var args = [ex(EStr(item.path))];
				if (supers.length > 0 || instanceFields) args.push(supers.length == 0 ? ex(ENull) : ex(EFn({params: [], rest: false, arrow: true, body: [st(SReturn(ex(EArray(supers))))]})));
				if (instanceFields) args.push(ex(EArray([for (f in c.clFields) if (isPhysicalField(f)) ex(EFieldName(f.cfName, ins(c)))])));
				body.statement(exp(st(SVar(VConst, [{name: item.sym, init: ex(ECall(rt("interface"), args))}]))));
				if (resolveClass) body.statement(st(SExpr(ex(EAssign("=", ex(EIndex(rt("classes"), ex(EStr(item.path)))), ex(EId(item.sym)))))));
				switch Texpr.buildMetadata(com.basic, item.t) {
					case null:
					case m: body.statement(st(SExpr(ex(EAssign("=", Lower.member(ex(EId(item.sym)), "__meta__"), lowerNow(l -> l.expr(m)))))));
				}
			case _:
		}
		if (anyInterface) body.blank();
		for (item in file.items) {
			switch item.t {
				case TClassDecl(c) if (fieldsModule(c) != null):
					moduleFieldsDecl(body, item, c, deferredStatics);
				case TClassDecl(c) if (hasClassFlag(c, CInterface)):
					if (tsOut) body.statement(exp(st(SInterface(item.sym, c))));
					continue;
				case TClassDecl(c):
					var d = item.decl;
					var head:Array<Member> = [];
					if (names && !c.clKind.match(KAbstractImpl(_))) head.push(MField(KComputed(rt("name")), ex(EStr(item.path)), true, null));
					if (runtimeInterfaces && c.clImplements.length > 0)
						// (a getter: the interfaces may be defined later, a module of a cycle)
						head.push(MMethod(KComputed(rt("interfaces")), {params: [], rest: false, arrow: false, body: [st(SReturn(ex(EArray([for (i in c.clImplements) type(TClassDecl(i.cls), c.clPos)]))))]}, true, MkGet));
					if (properties) {
						var a = codegen.Codegen.getProperties(c.clFields.toArray().filter(reflected));
						if (a.length > 0) head.push(MField(KComputed(rt("properties")), ex(EObject([for (x in a) ({key: key(x.name), value: ex(EStr(x.field))} : Prop)])), true, TDynamic(null)));
						var s = codegen.Codegen.getProperties(c.clStatics.toArray().filter(reflected));
						if (s.length > 0) head.push(MField(KComputed(rt("staticProperties")), ex(EObject([for (x in s) ({key: key(x.name), value: ex(EStr(x.field))} : Prop)])), true, TDynamic(null)));
					}
					switch Texpr.buildMetadata(com.basic, item.t) {
						case null:
						// (not where the class has it already, Haxe's filters')
						case m if (!c.clStatics.exists("__meta__")): head.push(MField(KName("__meta__"), lowerNow(l -> l.expr(m)), true, TDynamic(null)));
						case _:
					}
					// (the statics assigned later, and those without a value: declared before `__init__`, which may
					// assign them, as Haxe has it)
					var later:Array<Member> = [];
					for (f in item.statics) {
						var v = item.values.get(f);
						if (!item.inBody.get(f) && modules) {
							for (m in lazy(item, f, v)) later.push(m);
						} else if (!item.inBody.get(f)) {
							head.push(prot(f, MField(fieldKey(f.cfName, sns(c)), null, true, f.cfType)));
							// (TypeScript: assigned from outside the class, past `protected`)
							var self = ex(EId(item.sym));
							deferredStatics.push(st(SExpr(ex(EAssign("=", tsOut && !hasClassFieldFlag(f, CfPublic) ? ex(EFriend(self, f.cfName)) : Lower.field(self, f.cfName, sns(c)), v)))));
						} else if (f.cfExpr == null || f.cfExpr.eexpr.match(TFunction(_))) head.push(prot(f, MField(fieldKey(f.cfName, sns(c)), v, true, f.cfType)));
						else later.push(prot(f, MField(fieldKey(f.cfName, sns(c)), v, true, f.cfType)));
					}
					var init = item.init;
					if (init != null && item.initInBody) head.push(MStaticBlock(init));
					else if (init != null && !item.initLate) {
						after.push(st(SComment(item.path + ".__init__")));
						for (s in initStatements(init)) after.push(s);
					}
					// (TypeScript: a static of an ancestor's name, which Haxe lets differ and TypeScript's class checks as its own)
					if (tsOut && staticClash(c)) body.statement(st(SRaw("// @ts-ignore")));
					body.statement(exp(st(SClass({
							name: d.name,
							superClass: d.superClass,
							members: head.concat(later).concat(accessorMembers(item, c, d.members)),
							tparams: d.tparams,
							superArgs: d.superArgs,
							isAbstract: d.isAbstract
						}))));
					// (Type.getInstanceFields: the variables on the prototype, `null` until an instance has its own, as Genjs has them)
					if (instanceFields) {
						var vars:Array<Prop> = [
							for (f in c.clFields)
								if (isPhysicalVarField(f) && !hasClassFieldFlag(f, CfExtern)) ({key: fieldKey(f.cfName, ins(c)), value: ex(ENull)} : Prop)
						];
						if (vars.length > 0)
							body.statement(st(SExpr(ex(ECall(ex(EMember(ex(EId(global("Object"))), "assign")), [ex(EMember(ex(EId(item.sym)), "prototype")), ex(EObject(vars))])))));
					}
					if (resolveClass && !c.clKind.match(KAbstractImpl(_)))
						body.statement(st(SExpr(ex(EAssign("=", ex(EIndex(rt("classes"), ex(EStr(item.path)))), ex(EId(item.sym)))))));
					expose(body, exposed, c, item);
				case TEnumDecl(e):
					enumDecl(body, item, e, names || refs.exists("Type.getEnumName"));
					if (resolveEnum) body.statement(st(SExpr(ex(EAssign("=", ex(EIndex(rt("enums"), ex(EStr(item.path)))), ex(EId(item.sym)))))));
				case _:
			}
			body.blank();
		}
		if (after.length > 0 || deferredStatics.length > 0 || exposed.length > 0) {
			body.statements(after);
			body.statements(deferredStatics);
			body.statements(exposed);
			body.blank();
		}
		return body;
	}

	// the bindings later files take from the file (`exported`), then main's code
	function tail(file:OutFile, exported:Map<Sym, Bool>):String {
		var body = printer(file);
		if (exported.iterator().hasNext()) {
			var syms = [for (s in exported.keys()) s];
			syms.sort((a, b) -> Reflect.compare(a.name, b.name));
			body.statement(st(SExpr(ex(ECall(ex(EMember(ex(EId(global("Object"))), "assign")),
				[rt("scope"), ex(EObject([for (s in syms) ({key: KName(s.name), value: ex(EId(s))} : Prop)]))])))));
		}
		if (file.id == 0) body.statements(mainCode);
		return body.toString();
	}

	// a top-level declaration, exported (modules)
	function exp(s:St):St return modules ? st(SExport(s)) : s;

	// a static its module cannot initialize as it runs (modules): initialized when first read, its value in a
	// #private field
	//   static #x; static #x_ready = false;
	//   static get x() { if (!C.#x_ready) { C.#x_ready = true; C.#x = <value>; } return C.#x; }
	//   static set x(v) { C.#x_ready = true; C.#x = v; }
	function lazy(item:Item, f:TClassField, v:Ex):Array<Member> {
		var n = ~/[^A-Za-z0-9_$]/g.replace(f.cfName, "_");
		var self = ex(EId(item.sym));
		var value = ex(EPrivate(self, n)), ready = ex(EPrivate(self, n + "_ready"));
		var param = new Sym(SLocal, "value");
		param.type = f.cfType;
		return [
			MField(KPrivate(n), null, true, f.cfType),
			MField(KPrivate(n + "_ready"), ex(EBool(false)), true, null),
			MMethod(fieldKey(f.cfName, switch item.t {
				case TClassDecl(c): sns(c);
				case _: NGlobal;
			}), {
				params: [],
				rest: false,
				arrow: false,
				body: [
					st(SIf(ex(EUnary("!", ready)), [st(SExpr(ex(EAssign("=", ready, ex(EBool(true)))))), st(SExpr(ex(EAssign("=", value, v))))], null)),
					st(SReturn(value))
				]
			}, true, MkGet),
			MMethod(fieldKey(f.cfName, switch item.t {
				case TClassDecl(c): sns(c);
				case _: NGlobal;
			}), {
				params: [param],
				rest: false,
				arrow: false,
				body: [st(SExpr(ex(EAssign("=", ready, ex(EBool(true)))))), st(SExpr(ex(EAssign("=", value, ex(EId(param))))))]
			}, true, MkSet)
		];
	}

	// an `__init__` after the types: in a block of its own where it declares, but not where untyped code may declare too
	// (modules) the names untyped code of an extern's `__init__` declares at its top level (`var x = …`, `function f() {…}`),
	// which a module keeps to itself: Genjs's script makes them global
	function rawGlobals(init:Array<St>):Array<String> {
		var names = [];
		if (!modules) return names;
		for (s in init) {
			var code = switch s.def {
				case SExpr({def: ERaw(parts)}): [for (p in parts) switch p {
					case RText(t): t;
					case RValue(_): "";
				}].join("");
				case SRaw(code): code;
				case _: continue;
			}
			topLevelNames(code, names);
		}
		return names;
	}

	// (modules) `globalThis.x = x` for those names
	function globalized(init:Array<St>):Array<St> {
		return [for (n in rawGlobals(init)) st(SRaw((tsOut ? "(globalThis as any)." : "globalThis.") + n + " = " + n + ";"))];
	}

	static function staticClash(c:TClass):Bool {
		var s = c.clSuper;
		while (s != null) {
			for (f in c.clStatics) if (s.cls.clStatics.exists(f.cfName)) return true;
			s = s.cls.clSuper;
		}
		return false;
	}

	static function initStatements(init:Array<St>):Array<St> {
		var declares = false, raw = false;
		for (s in init) switch s.def {
			case SVar(_) | SFunction(_) | SClass(_): declares = true;
			case SExpr({def: ERaw(_)}) | SRaw(_): raw = true;
			case _:
		}
		return declares && !raw ? [st(SBlock(init))] : init;
	}

	// whether e has untyped code (js.Syntax.code, untyped names)
	static function hasRaw(e:TExpr):Bool {
		var found = false;
		function walk(e:TExpr) {
			if (found) return;
			switch e.eexpr {
				case TIdent(_) | TCall({eexpr: TField(_, FStatic({clPath: {pack: ["js"], name: "Syntax"}}, {cfName: "code" | "plainCode"}))}, _): found = true;
				case _: Texpr.iter(walk, e);
			}
		}
		walk(e);
		return found;
	}

	function moduleFieldsDecl(body:Doc, item:Item, c:TClass, deferredStatics:Array<St>) {
		var m = fieldsModule(c);
		for (f in c.clStatics) {
			var fn = item.fns.get(f);
			if (fn != null) {
				body.statement(exp(st(SFunction(fn))));
				continue;
			}
			var v = item.values.get(f);
			if (v == null) continue;
			var s = moduleField(m, f);
			s.type = f.cfType;
			var isFinal = hasClassFieldFlag(f, CfFinal);
			if (item.inBody.get(f)) body.statement(exp(st(SVar(isFinal ? VConst : VLet, [{name: s, init: v}])))) else {
				body.statement(exp(st(SVar(VLet, [{name: s, init: null}]))));
				deferredStatics.push(st(SExpr(ex(EAssign("=", ex(EId(s)), v)))));
			}
		}
	}

	// @:expose: a class, its static methods where it is declared, its static variables once they have their values (`later`)
	function expose(body:Doc, later:Array<St>, c:TClass, item:Item) {
		Genjs.processExpose(c.clMeta, () -> item.path,
			s -> body.statement(st(SExpr(ex(ECall(rt("expose"), [ex(EStr(s)), ex(EId(item.sym))]))))));
		for (f in c.clStatics)
			Genjs.processExpose(f.cfMeta, () -> item.path + "." + f.cfName,
				s -> {
					var e = st(SExpr(ex(ECall(rt("expose"), [ex(EStr(s)), Lower.member(tsOut ? ex(EAs(ex(EId(item.sym)))) : ex(EId(item.sym)), f.cfName)]))));
					if (f.cfKind.match(Method(_))) body.statement(e) else later.push(e);
				});
	}

	// `const E = $hx.declareEnum({ C: function (a, b) { this.a = a; this.b = b; }, D: null, ..., [$hx.name]: path }, meta)`:
	// a constructor of arguments a function `new` constructs, the others `null` (the runtime makes their values); in
	// TypeScript with the enum's declaration and its types (Ts.enumTypes, docs/plans/esgen-enums.md)
	function enumDecl(body:Doc, item:Item, e:TEnum, named:Bool) {
		var names = [for (n in e.eConstrs.names()) n];
		names.sort((a, b) -> e.eConstrs.find(a).efIndex - e.eConstrs.find(b).efIndex);
		// (minified fields: the constructors' keys, the parameters' fields, renamed in the enum's namespaces, FieldNames)
		var cns = fieldNames == null ? -1 : fieldNames.enumCtorNs(e);
		var spec:Array<Prop> = [];
		for (n in names) {
			var f = e.eConstrs.find(n);
			var value = switch follow(f.efType) {
				case TFun(s) if (s.args.length > 0):
					var ps = [for (a in s.args) new Sym(SLocal, RESERVED.exists(a.name) ? "$" + a.name : a.name)];
					var fnBody = [for (i in 0...ps.length) st(SExpr(ex(EAssign("=", Lower.field(ex(EThis), s.args[i].name, NEnumParam(e)), ex(EId(ps[i]))))))];
					ex(EFn({params: ps, rest: false, arrow: false, body: fnBody, thisAny: tsOut ? true : null, ctor: true, contextual: true}));
				case _:
					ex(ENull);
			}
			spec.push({key: cns < 0 ? key(n) : fieldKey(n, NEnumCtor(e)), value: value});
		}
		if (named) spec.push({key: KComputed(rt("name")), value: ex(EStr(item.path))});
		var args = [ex(EObject(spec))];
		switch Texpr.buildMetadata(com.basic, item.t) {
			case null:
			case m: args.push(lowerNow(l -> l.expr(m)));
		}
		// (the constructors' names apart, their keys renamed, where the program reads them: Std.string, Type.enumConstructor)
		if (cns >= 0 && (tight || fieldsDebug) && fieldNames.constructsRead) {
			if (args.length < 2) args.push(ex(ENull));
			args.push(ex(EArray([for (n in names) ex(EStr(n))])));
		}
		if (tsOut) index();
		body.statement(exp(st(SEnum(item.sym, ex(ECall(rt("declareEnum"), args)), e, enumIndex))));
	}
}
