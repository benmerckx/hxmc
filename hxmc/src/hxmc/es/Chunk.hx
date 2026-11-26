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
	// (modules) those not in the body assigned after its file's classes (the others lazy)
	public final atEnd = new Map<TClassField, Bool>();
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
	// (modules) the names it has for the bindings it imports where its own are theirs; the names it has (Chunk.aliases)
	public final alias = new Map<Sym, String>();
	public var taken:Null<Map<String, Bool>> = null;

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
	UAbstract(a:TAbstract, file:Int);
	URaw(text:String, file:Int);
	URefer(path:String);
	// (modules) a split's code lowered where it is called, back in the caller's file
	USplitDone(split:Int, caller:Int);
	// a Lower's locals' names, of its code's file
	ULocals(names:Array<String>, file:Int);
	// (Properties) what the code does with accessors, the names it reads dynamically, its string constants
	UAccessorCall(a:TClassField, args:Int, discarded:Bool);
	UAccessorTaken(a:TClassField);
	UDynamicName(n:String);
	UString(s:String);
	UStorage(p:TClassField, by:Null<TClass>);
	UReflected(t:T);
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
	public function done(l:Lower) uses.push(ULocals(l.localNames(), file));

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

	public function abstractValue(a:TAbstract, p:Pos):Ex {
		uses.push(UAbstract(a, file));
		return ex(ERef(RAbstract(a)), p);
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

	public function storage(p:TClassField, by:Null<TClass>) if (chunk.propsOn) uses.push(UStorage(p, by));

	public function reflected(t:T) if (chunk.propsOn) uses.push(UReflected(t));
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
	// -D hxmc.js.hot (es-modules): the build compared with the program running, a patch of its classes (Hot); the
	// declarations of the files as they were assembled (body), the patch's file
	final hot:Null<Hot>;
	final hotItems:Array<{
		file:OutFile,
		item:Item,
		pieces:Array<Piece>,
		decl:Null<ClassDecl>,
		object:Null<Array<Prop>>,
		enumArgs:Null<Array<Ex>>
	}> = [];
	var hotFile:Null<OutFile> = null;

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
		hot = if (!Gctx.rawDefined(com, "hxmc.js.hot")) null else {
			if (!modules) Error.abort("hxmc.js.hot: es-modules's (-D hxmc.js=es-modules)", core.Globals.nullPos);
			// (a patch is JavaScript the running program imports, which TypeScript's output is not until compiled)
			if (tsOut) Error.abort("hxmc.js.hot: not with TypeScript's output (an output named .ts)", core.Globals.nullPos);
			if (Gctx.definedValueSafe(com, "hxmc.js.minify") != "")
				Error.abort("hxmc.js.hot: not minified (a patch names what the running program has by its names)", core.Globals.nullPos);
			new Hot(Path.directory(com.file));
		}
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
			if (c.modules) {
				c.entryClash();
				c.breakCycles();
				c.collectAbstracts();
			}
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
		case RAbstract(a): ex(EId(abstractTypes.get(a).sym), p);
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
			case UAbstract(a, file):
				current = file;
				var x = abstractTypes.get(a);
				use(x.sym, x.file);
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
			case UStorage(p, by):
				props.stored(p, by);
			case UReflected(t):
				props.reflected(t);
			case URefer(path):
				refs.set(path, true);
			case USplitDone(split, caller):
				// (what the split's code uses of the runtime, of npm modules (@:jsRequire): imported by the caller too)
				if (rtFiles.exists(split)) rtFiles.set(caller, true);
				if (indexFiles.exists(split)) indexFiles.set(caller, true);
				if (enumValueFiles.exists(split)) enumValueFiles.set(caller, true);
				for (s => from in files[split].needs) if (from < 0) files[caller].needs.set(s, from);
			case ULocals(names, file):
				for (n in names) {
					localNames.set(n, true);
					localsOf(file).set(n, true);
				}
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
		if (tsOut) p.types = new Ts(t -> typeRef(f, names, t), () -> enumValueRef(names), props);
		if (modules) p.splitImport = id -> splitImport(f.id, id);
		if (fieldNames != null && (tight || fieldsDebug)) p.fieldName = fieldName;
		p.ref = refEx;
		if (f.alias.iterator().hasNext()) p.bind = s -> nameIn(f, s);
		p.accessor = accessorEx;
		p.backed = backedEx;
		p.smap = smap != null ? smap : f.smap;
		p.hot = hot != null;
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
			// (an abstract: its type, its module's, imported as a type where it is another's)
			case TAbstractDecl(a) if (Casts.branded(a)):
				var x = abstractTypes.get(a);
				if (x == null) return null;
				return typeName(f, names, x.sym, x.file) + (abstractClasses.exists(a) ? ".Self" : "");
			case TClassDecl({clKind: KAbstractImpl(_) | KModuleFields(_)}) | TAbstractDecl(_) | TTypeDecl(_):
				return null;
			case _:
		}
		var item = byPath.get(dot(tPath(t)));
		return item == null ? null : typeUse(f, names, item);
	}

	function typeUse(f:OutFile, names:TypeNames, item:Item):String return typeName(f, names, item.sym, item.file);

	// (TypeScript) a binding's name as a type in file f: as the file has it (its own, imported as a value, aliased), else
	// imported as a type; by its module (`import("../a/B.ts").B`) where the file has the name or another export does
	function typeName(f:OutFile, names:TypeNames, s:Sym, file:Int):String {
		if (file == f.id) return s.name;
		var a = f.alias.get(s);
		if (a != null) return a;
		if (!f.needs.exists(s) && f.taken != null && files[file].path != null
			&& (f.taken.exists(s.name) || (exportCount != null && exportCount.exists(s.name) && exportCount.get(s.name) > 1)))
			return "import(" + Printer.quote(rel(f.path, files[file].path)) + ")." + s.name;
		names.needs.set(s, file);
		return s.name;
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
		var names = new Map<Int, Array<Sym>>();
		for (s => from in f.needs) if (from > 0 && from != current && caller.needs.get(s) != from) {
			var l = names.get(from);
			if (l == null) names.set(from, l = []);
			l.push(s);
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
		// (`[{ A, B }, , { C }]`: a module of none of them a hole; one the file names otherwise `{ A: A$1 }`)
		function partsOf(l:Array<Int>):Array<String> return [for (i in l) {
			var n = names.get(i);
			if (n == null) "" else {
				var b = [for (s in n) {
					var a = caller.alias.get(s);
					a == null ? s.name : s.name + ":" + sp(" ") + a;
				}];
				b.sort(Reflect.compare);
				"{" + sp(" ") + b.join(comma) + sp(" ") + "}";
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
		propsOn = Gctx.definedValueSafe(com, "hxmc.js.properties") != "off";
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

	// (TypeScript) an abstract's method: its `this` taken as the abstract, as its callers have it, its code's the underlying
	// type, as Haxe has it (`m(self: A) { let this1: V = (self as any); ... }`)
	static function abstractThis(c:TClass, f:TClassField, l:Fn) {
		var a = switch c.clKind {
			case KAbstractImpl(a): a;
			case _: return;
		}
		// (a generic abstract's: its type parameters, a function's own, which its implementation's statics name)
		if (a.aParams.length > 0) {
			var own = l.tparams == null ? [] : l.tparams.toArray();
			var all = [for (p in a.aParams) if (!Lambda.exists(own, x -> x.ttpName == p.ttpName)) p].concat(own);
			l.tparams = haxe.ds.Vector.fromArrayCopy(all);
		}
		if (!hasClassFieldFlag(f, CfImpl) || hasClassFieldFlag(f, CfAbstractConstructor) || l.params.length == 0 || !Casts.branded(a)) return;
		var p0 = l.params[0];
		var self = new Sym(SLocal, p0.hint + "$");
		self.type = TAbstract(a, haxe.ds.Vector.fromArrayCopy([for (p in a.aParams) p.ttpType]));
		l.params[0] = self;
		l.body.unshift(st(SVar(VLet, [{name: p0, init: ex(EAs(ex(EId(self))))}])));
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

	// (TypeScript) a variable only its class's constructor writes (Properties.readonlyVar): `readonly`
	static function readonly(f:TClassField, m:Member):Member return Properties.readonlyVar(f) ? MReadonly(m) : m;

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
				member(prot(f, readonly(f, MDeclare(fieldKey(f.cfName, ins(c)), f.cfType, false))), f);
			case Method(_) if (f.cfExpr == null && hasClassFlag(c, CAbstract)):
				member(prot(f, MAbstract(fieldKey(f.cfName, ins(c)), f.cfType, f.cfParams)));
			case _:
		}
		switch c.clConstructor == null ? null : c.clConstructor.cfExpr {
			case e = {eexpr: TFunction(f)}:
				lower.prepare(e);
				lower.ctorOf = c;
				var l = lower.func(f, false, e.epos, c.clConstructor.cfType);
				lower.ctorOf = null;
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
				var l = methodFn(lower, f, fn, e);
				if (tsOut) abstractThis(c, f, l);
				member(prot(f, MMethod(fieldKey(Lower.staticName(modules, c, f), sns(c)), l, true, MkMethod)), f);
			// (Type.getClassFields: a variable without a value is a field too)
			case [Var(_), null] if (u.feature("Type.getClassFields") && isPhysicalField(f)):
				item.statics.push(f);
				item.values.set(f, ex(ENull));
			// (TypeScript: declared, as Haxe has it)
			case [Var(_), null] if (tsOut && isPhysicalField(f)):
				member(prot(f, readonly(f, MDeclare(fieldKey(f.cfName, sns(c)), f.cfType, true))), f);
			case [_, null]:
			case [_, {eexpr: TConst(TNull)}] if (!u.feature("Type.getClassFields")):
				if (tsOut && isPhysicalField(f)) member(prot(f, readonly(f, MDeclare(fieldKey(f.cfName, sns(c)), f.cfType, true))), f);
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

	// (null: none, -D hxmc.js.properties=off; propsOn: as the lowerings run, which make it)
	var props:Null<Properties> = null;
	var propsOn = false;

	// the families decided: what all the code told, and the statics with storage set after their classes (`#x` is the
	// class body's), which cannot change
	function decideProperties() {
		for (item in items) for (f in item.statics) if (props.mayBack(f) && !item.inBody.get(f)) props.exclude(f, "a static set after its class");
		props.decide();
		if (Gctx.rawDefined(com, "hxmc.js.properties_report")) Sys.println(props.report());
	}

	// an accessor's call as its family is: the property (`o.x`; `o.x = v`, its value used for nothing), else the call
	// (and through `super`, where the family keeps its methods); TypeScript's `o["get_x"]()` (protected) `o["x"]`
	function accessorEx(a:TClassField, call:Ex, discarded:Bool):Ex {
		var f = props == null ? null : props.familyOf(a);
		if (f == null) return call;
		var getter = f.isGetter(a);
		return switch call.def {
			case ECall(m = {def: EField(o, _, _) | EFriend(o, _)}, args) if ((getter ? args.length == 0 : discarded && args.length == 1)
				&& !(o.def.match(ESuper) && f.keeps(getter))):
				var prop = switch m.def {
					case EField(_, _, ns): Lower.field(o, f.property.cfName, ns, m.pos);
					case _: ex(EFriend(o, f.property.cfName), m.pos);
				}
				getter ? prop : ex(EAssign("=", prop, args[0]), call.pos);
			case _: call;
		}
	}

	// a property's storage as its family is: the class's #private field (`o.#x`), else the field
	function backedEx(p:TClassField, field:Ex):Ex {
		if (props == null || !props.backed(p)) return field;
		return switch field.def {
			case EField(o, _, _) | EFriend(o, _): ex(EPrivate(o, p.cfName), field.pos);
			case _: field;
		}
	}

	// whether a property's storage is a #private field
	inline function isBacked(f:TClassField):Bool return props != null && props.backed(f);

	// a static's member (its value in the class's body): of a property with storage, the #private field
	function staticMember(c:TClass, f:TClassField, v:Null<Ex>):Member
		return isBacked(f) ? MField(KPrivate(f.cfName), v, true, f.cfType) : prot(f, readonly(f, MField(fieldKey(f.cfName, sns(c)), v, true, f.cfType)));

	// a class's members, its accessors of properties that change as JS accessors: the accessor itself, or (its family keeps
	// them as methods) the method and, after the class's first accessor of the family, the JS accessors that call it, or
	// the ancestor's through `super` where the class has only one of the pair (a JS accessor hides its ancestors' pair);
	// the storage of its properties with storage, #private fields, first (`statics`: those with values in the body)
	function accessorMembers(item:Item, c:TClass, members:Array<Member>):Array<Member> {
		if (props == null) return members;
		var out:Array<Member> = [];
		for (st in [false, true]) for (f in (st ? c.clStatics : c.clFields))
			if (isBacked(f) && !(st && item.statics.contains(f))) out.push(MField(KPrivate(f.cfName), null, st, f.cfType));
		for (i in 0...members.length) {
			var cf = item.memberFields[i];
			// (TypeScript: the storage's declaration, above)
			if (cf != null && isBacked(cf)) continue;
			var fam = cf == null ? null : props.familyOf(cf);
			if (fam == null) {
				out.push(members[i]);
				continue;
			}
			var getter = fam.isGetter(cf);
			switch members[i] {
				case MMethod(_, fn, isStatic, MkMethod) if (!fam.keeps(getter)):
					// (TypeScript: a setter returns nothing)
					var f = getter || !tsOut ? fn : withBody(fn, voidReturns(fn.body));
					out.push(prot(fam.property, MMethod(fieldKey(fam.property.cfName, isStatic ? sns(c) : ins(c)), f, isStatic, getter ? MkGet : MkSet)));
				case m:
					out.push(m);
			}
			if (firstAccessor(item, cf, fam)) for (m in jsAccessors(c, fam)) out.push(prot(fam.property, m));
		}
		return out;
	}

	// a function's copy, of other statements
	static function withBody(f:Fn, body:Array<St>):Fn return {
		params: f.params,
		rest: f.rest,
		body: body,
		arrow: f.arrow,
		name: f.name,
		ret: f.ret,
		tparams: f.tparams,
		optFrom: f.optFrom,
		thisAny: f.thisAny,
		ctor: f.ctor,
		pos: f.pos,
		contextual: f.contextual
	};

	// statements whose `return v` (not a nested function's) are `v; return`
	static function voidReturns(body:Array<St>):Array<St> {
		var out = [];
		for (s in body) switch s.def {
			case SReturn(v) if (v != null):
				out.push(st(SExpr(v), s.pos));
				out.push(st(SReturn(null), s.pos));
			case _:
				out.push(st(switch s.def {
					case SIf(c, a, b): SIf(c, voidReturns(a), b == null ? null : voidReturns(b));
					case SBlock(b): SBlock(voidReturns(b));
					case SWhile(c, b): SWhile(c, voidReturns(b));
					case SDoWhile(b, c): SDoWhile(voidReturns(b), c);
					case SFor(i, t, u, b): SFor(i, t, u, voidReturns(b));
					case SForOf(k, v, o, b): SForOf(k, v, o, voidReturns(b));
					case STry(b, p, h): STry(voidReturns(b), p, voidReturns(h));
					case SSwitch(on, cases): SSwitch(on, [for (c in cases) ({tests: c.tests, body: voidReturns(c.body), comments: c.comments} : Case)]);
					case SLabel(l, b): SLabel(l, voidReturns([b])[0]);
					case d: d;
				}, s.pos));
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
			// (TypeScript: of the property's type)
			v.type = fam.property.cfType;
			var body = if (h.getter)
				[st(SReturn(h.own != null ? ex(ECall(Lower.field(on, h.own.cfName, ns), [])) : Lower.field(on, name, ns)))]
			else
				[st(SExpr(h.own != null ? ex(ECall(Lower.field(on, h.own.cfName, ns), [ex(EId(v))])) : ex(EAssign("=", Lower.field(on, name, ns), ex(EId(v))))))];
			out.push(MMethod(fieldKey(name, ns), {params: h.getter ? [] : [v], rest: false, arrow: false, body: body, ret: h.getter ? fam.property.cfType : null}, isStatic, h.getter ? MkGet : MkSet));
		}
		return out;
	}

	// ------------------------------------------------------------------ where statics go

	// the types (indexes of items) e reaches as it runs: those it names, and through the code of the statics,
	// constructors and methods it calls (all the implementations of an instance's method); a function literal
	// only where it is called or passed on (it may run then); each true where another class's code reaches it
	function reaches(e:TExpr):Map<Int, Bool> {
		var out = new Map<Int, Bool>(), seen = new Map<TClassField, Bool>();
		// (the classes whose code it walks: the code of a class's own fields names it as its body has it, another's
		// as the binding that is the class once its body has run)
		var owners:Array<String> = [];
		function need(t:ModuleType) {
			var path = dot(tPath(t));
			var i = byPath.get(path);
			if (i != null) out.set(i.index, (owners.length > 0 && owners[owners.length - 1] != path) || out.get(i.index) == true);
		}
		var walk:(TExpr, Bool) -> Void = null;
		function field(cf:TClassField, c:TClass) {
			if (seen.exists(cf)) return;
			seen.set(cf, true);
			owners.push(dot(c.clPath));
			switch cf.cfExpr {
				case null:
				case {eexpr: TFunction(f)}: walk(f.tfExpr, true);
				case e: walk(e, true);
			}
			owners.pop();
		}
		function ctor(c:TClass) {
			while (c != null) {
				need(TClassDecl(c));
				if (c.clConstructor != null) field(c.clConstructor, c);
				// (filters.ES6Ctors: the constructor's code in a method, which it calls untyped)
				var moved = Lambda.find(c.clFields, x -> x.cfName == "_hx_constructor");
				if (moved != null) field(moved, c);
				for (f in c.clFields) if (f.cfExpr != null && !f.cfKind.match(Method(_))) field(f, c);
				c = c.clSuper == null ? null : c.clSuper.cls;
			}
		}
		function method(c:TClass, name:String) {
			var up = c;
			while (up != null) {
				var f = Lambda.find(up.clFields, x -> x.cfName == name);
				if (f != null) {
					field(f, up);
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
				if (f != null) field(f, k);
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
					field(cf, c);
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

	// whether what e reaches is declared and initialized before `item` (or is item, but where code outside e reaches
	// it: a class's binding is the class once its body has run); another file's types are those of files loaded before
	// (main, a split's parents), all initialized
	function ready(item:Item, e:TExpr):Bool {
		var r = reached.get(e);
		for (i in r.keys()) {
			if (i == item.index) {
				if (r.get(i)) return false;
				continue;
			}
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

	// (modules, the report) what keeps a static from its class's body: the classes it reaches that are not ready
	function waitsFor(item:Item, e:TExpr):String {
		var out = [];
		for (i in reached.get(e).keys()) if (i != item.index) {
			var other = items[i];
			var a = finished.get(other.file), b = finished.get(item.file);
			if (other.file != item.file ? (a == null || b == null || a >= b) : (i > item.index || !other.initInBody || Lambda.exists(other.statics, f -> !other.inBody.get(f))))
				out.push(other.path + (other.file != item.file ? (a == null ? " (not run)" : " (runs after)") : (i > item.index ? " (declared after)" : " (not ready)")));
		}
		out.sort(Reflect.compare);
		return out.join(", ");
	}

	// (modules) whether what e reaches is initialized once item's file's classes are: another file's that has run, one of
	// its own file's whose statics are in its body, or after it at the end
	function readyAtEnd(item:Item, e:TExpr):Bool {
		for (i in reached.get(e).keys()) {
			if (i == item.index) continue;
			var other = items[i];
			if (other.file != item.file) {
				var a = finished.get(other.file), b = finished.get(item.file);
				if (a == null || b == null || a >= b) return false;
				continue;
			}
			if (!other.initInBody) return false;
			for (f in other.statics) if (!other.inBody.get(f) && !(other.atEnd.exists(f) && i < item.index)) return false;
		}
		return true;
	}

	// what each `__init__` and static's value reaches (place asks again as it goes): computed once, in parallel
	final reached = new haxe.ds.ObjectMap<TExpr, Map<Int, Bool>>();

	function reachAll() {
		if (reached.iterator().hasNext()) return;
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
		// (modules: a static that waits only for its file's classes (a class after its own) assigned after them, in order;
		// lazy otherwise)
		if (modules) for (item in items) for (f in item.statics) if (!item.inBody.get(f) && readyAtEnd(item, f.cfExpr))
			item.atEnd.set(f, true);
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
				for (f in item.statics) if (!item.inBody.get(f))
					Sys.println("es: " + item.path + "." + f.cfName + (!modules ? " after the types" : (item.atEnd.exists(f) ? " after its file's classes" : " lazy") + " (" + waitsFor(item, f.cfExpr) + ")"));
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

	// (modules) a module's file of the entry's name but for case (`main.js`, `Main`'s `Main.js`): one file where file
	// names are case-insensitive, two where they are not; an error either way, at the module's type of its name, else
	// at `main`
	public function entryClash() {
		var entry = files[0].path.toLowerCase();
		for (f in files) if (f.id != 0 && f.path != null && f.path.toLowerCase() == entry) {
			var pos = core.Globals.nullPos;
			var own = Lambda.find(f.items, isModuleType);
			if (own != null) pos = tInfos(own.t).mtNamePos else {
				var m = com.main.mainPath == null ? null : byPath.get(dot(com.main.mainPath));
				var main = m == null || m.cls == null ? null : m.cls.clStatics.get("main");
				if (main != null) pos = main.cfNamePos else if (com.main.mainExpr != null) pos = com.main.mainExpr.epos;
			}
			Error.abort("hxmc.js=es-modules: the output's name, " + files[0].path + ", is this module's file's (" + f.path
				+ ") but for case: name the output otherwise", pos);
		}
	}

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
		// (an enum abstract's values' object)
		for (a in enumObjects) if (abstractTypes.get(a).file == f.id) return true;
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
		reachAll();
		for (round in 0...20) {
			var l = [];
			for (i in fixes.concat(always).concat(unreached).concat(own)) if (!l.contains(i) && i != 0) l.push(i);
			files[0].deps = l;
			simulate();
			var late = lateFiles();
			for (i in lateStatics()) if (!late.contains(i)) late.push(i);
			var added = false;
			for (i in late) if (!fixes.contains(i)) {
				fixes.push(i);
				added = true;
			}
			if (!added) {
				for (i in lateFiles()) Sys.println("es-modules: " + files[i].path + " defines a class before its super class's module runs (a cycle)");
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

	// the files of the statics and `__init__`s that reach a class of a file that has not run when theirs does: imported
	// first by the entry, theirs run before (a cycle of what they reach, which no order has, makes them lazy: place)
	function lateStatics():Array<Int> {
		var out = [];
		for (item in items) {
			var b = finished.get(item.file);
			if (b == null || out.contains(item.file)) continue;
			var c = item.cls;
			var l = [for (f in item.statics) if (f.cfExpr != null && !f.cfExpr.eexpr.match(TFunction(_))) f.cfExpr];
			if (c != null && c.clInit != null && c.clInit.cfExpr != null) l.push(c.clInit.cfExpr);
			var late = false;
			for (e in l) if (!late) for (i in reached.get(e).keys()) {
				var a = finished.get(items[i].file);
				if (items[i].file != item.file && a != null && a > b) {
					late = true;
					break;
				}
			}
			if (late) out.push(item.file);
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
			var syms = [for (s => from in f.needs) if (from == d) s];
			syms.sort((a, b) -> Reflect.compare(a.name, b.name));
			// (as another of its names where the file has that one: aliases)
			var names = [for (s in syms) f.alias.exists(s) ? s.name + " as " + f.alias.get(s) : s.name];
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
		// (hot: the patch's file, before the files' names are settled)
		if (hot != null) hotPatch(docs);
		aliases();
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
		var rtValues = hot == null ? null : ["bind" => Runtime.HOT_BIND];
		var rtSource = Runtime.source(rtUsed, n -> {
			var item = byPath.get(n);
			if (item == null) return null;
			registered.set(item.index, true);
			rtFiles.set(item.file, true);
			rtUsed.set("types", true);
			"$hx.types." + item.sym.name;
		}, rtValues);
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
		}, rtValues);
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
		if (hot != null) {
			hot.runtime([for (k in Runtime.closure(rtUsed).keys()) k]);
			hot.compare(hotFile != null);
			var patch = hotFile != null && hot.reload == null ? hotFile.path : null;
			if (patch != null) {
				sys.FileSystem.createDirectory(Path.join([dir, Hot.DIR]));
				var b = new StringBuf();
				b.add(header());
				b.add(imports(hotFile, patch));
				b.add("\n");
				b.add(decls[hotFile.id]);
				save(Path.join([dir, patch]), b.toString(), hotFile.smap);
			}
			hot.save(patch);
		}
	}

	// (-D hxmc.js.hot) the build's declarations compared with those of the program running (Hot), part by part: where
	// what changed is what a patch can change, a patch's file, which imports the running declarations and changes them
	// with js.Hot's functions, at once:
	//   Hot.apply([Hot.cls(C, class C$hot extends S { ... }, {...}), Hot.enumeration(E, {...}), ...])
	// else the reasons to start again (Hot.restart)
	function hotPatch(docs:Array<Doc>) {
		// (the bindings the files export, by their files)
		var owner = new Map<Sym, Int>();
		for (f in files) for (item in f.items) owner.set(item.sym, f.id);
		for (k => s in moduleFields) {
			var o = moduleFieldOwner.get(k);
			if (o != null) owner.set(s, o.file);
		}
		for (a => x in abstractTypes) owner.set(x.sym, x.file);
		for (r in requires) owner.set(r.sym, -1);
		for (f in files) if (f.path != null) hot.file(f.path, [for (s => file in owner) if (file == f.id) s.name]);
		// (in the files while its code is built, which notes what it uses: Chunk.use)
		var patch = new OutFile(files.length, null);
		files.push(patch);
		var changes:Array<Ex> = [];
		// (the bindings the patch's code names, the files it is of)
		var used = new Map<Sym, Bool>();
		var from = new Map<Int, Bool>();
		var was = current;
		current = patch.id;
		for (h in hotItems) {
			// (what is printed apart, of the declaration's file, and the bindings it names)
			var p = printer(h.file);
			var names = new Map<Sym, Bool>();
			p.bind = s -> {
				names.set(s, true);
				s.name;
			};
			function print(f:() -> String):{text:String, names:Map<Sym, Bool>} {
				names = new Map();
				return {text: f(), names: names};
			}
			// (what the patch takes, the bindings it names)
			function take(x:{names:Map<Sym, Bool>}) {
				for (s in x.names.keys()) used.set(s, true);
				from.set(h.file.id, true);
			}
			var self = ex(EId(h.item.sym));
			var path = h.item.path;
			var change = if (h.decl != null) hotClass(h.item.cls, h.decl, p, print, take, path, self)
				else if (h.object != null) hotObject(h.object, p, print, take, path, self)
				else if (h.enumArgs != null) hotEnum(h.enumArgs, p, print, take, path, self)
				else switch h.item.t {
					case TClassDecl(c) if (fieldsModule(c) != null): hotFunctions(h.item, c, p, print, take, path);
					case _:
						// (anything else: as it is printed)
						var code = print(() -> {
							for (piece in h.pieces) switch piece {
								case POne(s): p.statement(s);
								case PMany(l): p.statements(l);
								case PBlank:
							}
							p.toString();
						});
						if (hot.unit(path, ["code" => Hot.hash(code.text)]) != null) hot.restart(path + ": changed (a patch changes classes, enums, abstracts' implementations and modules' functions)");
						null;
				}
			if (change == null) continue;
			changes.push(change);
			// (a declaration's, but a module's functions', which the patch names by the module's path)
			if (h.decl != null || h.object != null || h.enumArgs != null) used.set(h.item.sym, true);
		}
		current = was;
		if (changes.length == 0 || hot.first) {
			files.pop();
			return;
		}
		current = patch.id;
		var code = st(SExpr(ex(ECall(hotStatic("apply"), [ex(EArray(changes))]))));
		current = was;
		rtFiles.set(patch.id, true);
		patch.path = hot.patchPath();
		for (s in used.keys()) {
			var f = owner.get(s);
			if (f == null) continue;
			patch.needs.set(s, f);
			if (f >= 0 && !patch.deps.contains(f)) patch.deps.push(f);
		}
		patch.deps.sort(Reflect.compare);
		// (its locals' names: those of the files its code is of)
		for (f in from.keys()) for (n in localsOf(f).keys()) localsOf(patch.id).set(n, true);
		var doc = new Doc();
		doc.statement(code);
		docs.push(doc);
		hotFile = patch;
	}

	// (hot) js.Hot, which the program has with -D hxmc.js.hot (JsGen), and its function `name`, used by the file being
	// assembled
	function hotStatic(name:String):Ex {
		var c = byPath.get("js.Hot").cls;
		return Lower.field(type(TClassDecl(c), c.clPos), name, sns(c));
	}

	// (hot) a member's key as a part's name has it
	static function hotKey(p:Printer, k:Key):String return switch k {
		case KName(n) | KField(n, _): n;
		case KString(n): Printer.quote(n);
		case KPrivate(n): "#" + n;
		case KComputed(e): "[" + p.expr(e, 0) + "]";
	}

	// (hot) the key of a member removed, as js.Hot deletes it (null: a computed key's, a symbol's)
	static function hotRemoved(key:String):Null<String> return switch key.charAt(0) {
		case "[" | "#": null;
		case "\"": haxe.Json.parse(key);
		case _: key;
	}

	// (hot) a class's change. Its parts: each method (`m:` its slot: `s`/`i` static or not, `m`/`g`/`s` a method, a getter,
	// a setter, `:`, its key), each variable's name (`f:`), each static's name (`s:`, its value the running class's), its
	// constructor with its fields (`ctor`: what a new instance gets), its super class (`super`). The patch's class has the methods changed (an
	// accessor with the other of its pair: a property is defined with both), the statics added, and where its
	// constructor changed, its constructor and fields, which construct the class's instances from then on; the
	// instances it has get the fields added from the prototype, as they read them (Hot.cls)
	function hotClass(c:TClass, d:ClassDecl, p:Printer, print:(() -> String) -> {text:String, names:Map<Sym, Bool>}, take:{names:Map<Sym, Bool>}->Void,
			path:String, self:Ex):Null<Ex> {
		var parts = new Map<String, String>();
		var members = new Map<String, {m:Member, names:Map<Sym, Bool>}>();
		var ctor:Array<{m:Member, names:Map<Sym, Bool>}> = [];
		var ctorText = new StringBuf();
		inline function one(m:Member) return print(() -> p.classDecl({name: d.name, superClass: null, members: [m]}));
		for (m in d.members) switch m {
			case MMethod(_, _, _, MkConstructor):
				var x = one(m);
				ctor.push({m: m, names: x.names});
				ctorText.add(x.text);
			case MMethod(k, _, isStatic, kind):
				var x = one(m);
				var slot = (isStatic ? "s" : "i") + (switch kind {
					case MkGet: "g";
					case MkSet: "s";
					case _: "m";
				}) + ":" + hotKey(p, k);
				parts.set("m:" + slot, Hot.hash(x.text));
				members.set("m:" + slot, {m: m, names: x.names});
			case MField(_, _, false, _):
				var x = one(m);
				ctor.push({m: m, names: x.names});
				ctorText.add(x.text);
			case MField(k, _, true, _):
				parts.set("s:" + hotKey(p, k), "");
				var x = one(m);
				members.set("s:" + hotKey(p, k), {m: m, names: x.names});
			case _:
		}
		parts.set("ctor", Hot.hash(ctorText.toString()));
		// (the variables, as Haxe has them: their values are set in the constructor)
		var vars = new Map<String, TClassField>();
		for (f in c.clFields) if (isPhysicalVarField(f) && !hasClassFieldFlag(f, CfExtern) && !isBacked(f)) {
			parts.set("f:" + f.cfName, "");
			vars.set("f:" + f.cfName, f);
		}
		var superClass = d.superClass == null ? null : print(() -> p.expr(d.superClass, 0));
		parts.set("super", superClass == null ? "" : Hot.hash(superClass.text));
		var diff = hot.unit(path, parts);
		if (diff == null) return null;
		var fresh:Array<Member> = [];
		function add(part:String) {
			var x = members.get(part);
			if (x == null || fresh.contains(x.m)) return;
			fresh.push(x.m);
			take(x);
		}
		var removed:Array<Ex> = [];
		for (part in diff.added.concat(diff.changed)) switch part.substr(0, 2) {
			case "m:":
				add(part);
				// (`m:ig:x` with `m:is:x`)
				var kind = part.charAt(3);
				if (kind == "g" || kind == "s") add(part.substr(0, 3) + (kind == "g" ? "s" : "g") + part.substr(4));
			case "s:" if (diff.added.contains(part)):
				add(part);
			case _:
		}
		for (part in diff.removed) if (part.startsWith("m:")) {
			var key = part.substr(5);
			// (not where the key has a member still: a method now a getter)
			if (Lambda.exists(fresh, m -> switch m {
				case MMethod(k, _, s, _): (s ? "s" : "i") == part.charAt(2) && hotKey(p, k) == key;
				case _: false;
			})) continue;
			var r = hotRemoved(key);
			if (r != null) removed.push(ex(EStr(part.charAt(2) + ":" + r)));
		}
		var o:Array<Prop> = [];
		if (removed.length > 0) o.push({key: KName("removed"), value: ex(EArray(removed))});
		if (diff.changed.contains("super")) {
			o.push({key: KName("superClass"), value: d.superClass ?? ex(ENull)});
		}
		if (diff.changed.contains("ctor")) {
			o.push({key: KName("ctor"), value: ex(EBool(true))});
			for (x in ctor) {
				fresh.push(x.m);
				take(x);
			}
		}
		// (the variables added with a value: a function of it each, for the instances the class has. Their values are where
		// filters.AddFieldInits put them, the constructor's first statements (`_hx_constructor`'s, where filters.ES6Ctors
		// made one), `this.x = <value>`: not where the value names the constructor's locals)
		var fields:Array<Prop> = [];
		var ctorBody = [];
		for (m in d.members) switch m {
			case MMethod(_, fn, false, MkConstructor): ctorBody = ctorBody.concat(fn.body);
			case MMethod(KName("_hx_constructor") | KField("_hx_constructor", _), fn, false, _): ctorBody = ctorBody.concat(fn.body);
			case _:
		}
		for (part in diff.added) if (part.startsWith("f:")) {
			var f = vars.get(part);
			for (s in ctorBody) switch s.def {
				case SExpr({def: EAssign("=", {def: EField({def: EThis}, n, _)}, v)}) if (n == f.cfName):
					var x = print(() -> p.expr(v, 0));
					if (!Lambda.exists([for (s in x.names.keys()) s], s -> s.kind.match(SLocal))) {
						take(x);
						fields.push({key: fieldKey(f.cfName, ins(c)), value: ex(EFn({params: [], rest: false, arrow: false, body: [st(SReturn(v))]}))});
					}
					break;
				case _:
			}
		}
		if (fields.length > 0) o.push({key: KName("fields"), value: ex(EObject(fields))});
		if (superClass != null) take(superClass);
		return ex(ECall(hotStatic("cls"), [
			self,
			ex(EClass({name: new Sym(SLocal, d.name.name + "$hot"), superClass: d.superClass, members: fresh})),
			ex(EObject(o))
		]));
	}

	// (hot) an abstract's implementation's change: its functions (`m:`, as a class's methods), its values' names (`v:`,
	// added only)
	function hotObject(props:Array<Prop>, p:Printer, print:(() -> String) -> {text:String, names:Map<Sym, Bool>}, take:{names:Map<Sym, Bool>}->Void,
			path:String, self:Ex):Null<Ex> {
		var parts = new Map<String, String>();
		var byPart = new Map<String, {prop:Prop, names:Map<Sym, Bool>}>();
		for (x in props) {
			var key = hotKey(p, x.key);
			var part = switch [x.kind, x.value.def] {
				case [MkGet, _]: "m:g:" + key;
				case [MkSet, _]: "m:s:" + key;
				case [_, EFn(_)]: "m:m:" + key;
				case _: "v:" + key;
			}
			var printed = print(() -> p.expr(ex(EObject([x])), 0));
			parts.set(part, part.startsWith("v:") ? "" : Hot.hash(printed.text));
			byPart.set(part, {prop: x, names: printed.names});
		}
		var diff = hot.unit(path, parts);
		if (diff == null) return null;
		var fresh:Array<Prop> = [];
		function add(part:String) {
			var x = byPart.get(part);
			if (x == null || fresh.contains(x.prop)) return;
			fresh.push(x.prop);
			take(x);
		}
		for (part in diff.added.concat(diff.changed)) {
			if (part.startsWith("v:") && !diff.added.contains(part)) continue;
			add(part);
			if (part.startsWith("m:g:") || part.startsWith("m:s:")) add("m:" + (part.charAt(2) == "g" ? "s" : "g") + part.substr(3));
		}
		var removed:Array<Ex> = [];
		for (part in diff.removed) if (part.startsWith("m:") && !Lambda.exists(fresh, x -> hotKey(p, x.key) == part.substr(4))) {
			var r = hotRemoved(part.substr(4));
			if (r != null) removed.push(ex(EStr(r)));
		}
		return ex(ECall(hotStatic("object"), [self, ex(EObject(fresh)), ex(EArray(removed))]));
	}

	// (hot) an enum's change: its constructors, each by its index, its name and whether it has parameters
	// (`c:<index>:<name>:<f|n>`); one removed or moved: a reason to start again (the program's values have their
	// indexes); else, its constructors as `declareEnum` takes them (Hot.enumeration)
	function hotEnum(args:Array<Ex>, p:Printer, print:(() -> String) -> {text:String, names:Map<Sym, Bool>}, take:{names:Map<Sym, Bool>}->Void,
			path:String, self:Ex):Null<Ex> {
		var parts = new Map<String, String>();
		var spec = switch args[0].def {
			case EObject(l): l;
			case _: throw "assert";
		}
		var i = 0;
		for (x in spec) switch x.key {
			case KComputed(_):
			case k:
				var printed = print(() -> p.expr(x.value, 0));
				parts.set("c:" + (i++) + ":" + hotKey(p, k) + ":" + (x.value.def.match(ENull) ? "n" : "f"), Hot.hash(printed.text));
		}
		var diff = hot.unit(path, parts);
		if (diff == null) return null;
		if (diff.removed.length > 0) {
			hot.restart(path + ": constructors removed or moved");
			return null;
		}
		for (a in args) take(print(() -> p.expr(a, 0)));
		return ex(ECall(hotStatic("enumeration"), [self].concat(args)));
	}

	// (hot) a module's functions' change (`fn:`), its variables' names (`v:`): those added or removed change what it
	// exports (Hot.compare); the functions changed set by the setter the module registered (moduleFieldsDecl)
	function hotFunctions(item:Item, c:TClass, p:Printer, print:(() -> String) -> {text:String, names:Map<Sym, Bool>},
			take:{names:Map<Sym, Bool>}->Void, path:String):Null<Ex> {
		var parts = new Map<String, String>();
		var fns = new Map<String, {fn:Fn, names:Map<Sym, Bool>}>();
		for (f in c.clStatics) {
			var fn = item.fns.get(f);
			if (fn != null) {
				var printed = print(() -> p.expr(ex(EFn(fn)), 0));
				parts.set("fn:" + f.cfName, Hot.hash(printed.text));
				fns.set(f.cfName, {fn: fn, names: printed.names});
			} else if (item.values.exists(f)) parts.set("v:" + f.cfName, "");
		}
		var diff = hot.unit(path, parts);
		if (diff == null) return null;
		var o:Array<Prop> = [];
		for (part in diff.changed) if (part.startsWith("fn:")) {
			var x = fns.get(part.substr(3));
			take(x);
			// (unnamed: its name is the module's binding, which the setter sets)
			var fn:Fn = {params: x.fn.params, rest: x.fn.rest, body: x.fn.body, arrow: false, pos: x.fn.pos};
			o.push({key: KString(part.substr(3)), value: ex(EFn(fn))});
		}
		return o.length == 0 ? null : ex(ECall(hotStatic("functions"), [ex(EStr(path)), ex(EObject(o))]));
	}

	// (hot) a class's members with its constructor first asking js.Hot whether a patch replaced it (one with only that,
	// where the class has none):
	//   if (Hot.patched(C)) return Hot.construct(C, arguments, new.target);
	function hotConstructor(d:ClassDecl, members:Array<Member>):Array<Member> {
		var self = ex(EId(d.name));
		var check = st(SIf(ex(ECall(hotStatic("patched"), [self])), [
			st(SReturn(ex(ECall(hotStatic("construct"), [self, ex(ERaw([RText("arguments")])), ex(ERaw([RText("new.target")]))]))))
		], null));
		var found = false;
		var out = [
			for (m in members) switch m {
				case MMethod(k, f, false, MkConstructor):
					found = true;
					MMethod(k, ({
						params: f.params,
						rest: f.rest,
						body: [check].concat(f.body),
						arrow: f.arrow,
						name: f.name,
						ret: f.ret,
						tparams: f.tparams,
						optFrom: f.optFrom,
						thisAny: f.thisAny,
						ctor: f.ctor,
						pos: f.pos,
						contextual: f.contextual
					} : Fn), false, MkConstructor);
				case _: m;
			}
		];
		if (!found) {
			var args = new Sym(SLocal, "args");
			out.unshift(MMethod(KName("constructor"), {
				params: d.superClass == null ? [] : [args],
				rest: d.superClass != null,
				arrow: false,
				body: d.superClass == null ? [check] : [check, st(SExpr(ex(ECall(ex(ESuper), [ex(ESpread(ex(EId(args))))]))))]
			}, false, MkConstructor));
		}
		return out;
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

	// ------------------------------------------------------------------ the bundle's declarations (-D dts)

	// `<output>.d.ts`: what @:expose puts on the global object, declared (global, a namespace per path): a class, its
	// public API (and its ancestors' that are not exposed themselves), a static function, a static variable (its value
	// when it is exposed); the types they name by the paths they are exposed at, the others `any`
	function writeDts() {
		var exposedAt = new haxe.ds.ObjectMap<TClass, String>();
		var entries:Array<{path:String, c:TClass, f:Null<TClassField>}> = [];
		for (item in items) switch item.t {
			case TClassDecl(c) if (fieldsModule(c) == null && !hasClassFlag(c, CInterface)):
				Genjs.processExpose(c.clMeta, () -> item.path, s -> {
					if (!exposedAt.exists(c)) exposedAt.set(c, s);
					entries.push({path: s, c: c, f: null});
				});
				for (f in c.clStatics) Genjs.processExpose(f.cfMeta, () -> item.path + "." + f.cfName, s -> entries.push({path: s, c: c, f: f}));
			case _:
		}
		// (an abstract: its type, under HxTypes, at its path; the abstracts it names too)
		var abstracts:Array<TAbstract> = [], wanted = new haxe.ds.ObjectMap<TAbstract, Bool>();
		function ref(t:ModuleType):Null<String> return switch t {
			case TClassDecl(c) if (exposedAt.exists(c)): exposedAt.get(c);
			case TAbstractDecl(a) if (Casts.branded(a)):
				if (!wanted.exists(a)) {
					wanted.set(a, true);
					abstracts.push(a);
				}
				"HxTypes." + dot(a.aPath);
			case _: null;
		}
		var b = new StringBuf();
		b.add(header());
		for (e in entries) {
			var parts = e.path.split("."), n = parts.pop();
			if (!Lambda.foreach(parts.concat([n]), s -> validIdent(s) && !RESERVED.exists(s))) {
				b.add("// " + e.path + ": not a path TypeScript declares\n");
				continue;
			}
			var inNs = parts.length > 0, indent = inNs ? "\t" : "", head = inNs ? "" : "declare ";
			if (inNs) b.add("declare namespace " + parts.join(".") + " {\n");
			if (e.f == null) Dts.classDecl(b, e.c, ref, head, n, indent, null, props, true);
			else switch [e.f.cfKind, follow(e.f.cfType)] {
				case [Method(_), TFun(s)]:
					var scope = [for (p in e.f.cfParams) p.ttpName];
					b.add(indent + head + "function " + n + Dts.typeParams(e.f.cfParams, ref, scope) + "(" + Dts.args(s, ref, scope) + "): "
						+ Dts.type(s.ret, ref, scope) + ";\n");
				case _:
					b.add(indent + head + (hasClassFieldFlag(e.f, CfFinal) ? "const " : "let ") + n + ": " + Dts.type(e.f.cfType, ref, []) + ";\n");
			}
			if (inNs) b.add("}\n");
		}
		// (the abstracts: types only, of the brand `HxTypes.brand`)
		var i = 0, branded = false, types = new StringBuf();
		while (i < abstracts.length) {
			var a = abstracts[i++];
			var d = abstractDecl(a, a.aPath.name, (t, scope) -> Dts.type(t, ref, scope), ps -> Dts.typeParams(ps, ref, [for (p in ps) p.ttpName]), "HxTypes.brand");
			if (d.branded) branded = true;
			var parts = a.aPath.pack.copy();
			types.add("declare namespace HxTypes" + [for (p in parts) "." + p].join("") + " {\n" + (d.values == null ? "" : "\t" + d.values + "\n") + "\ttype " + a.aPath.name + d.decl + "\n}\n");
		}
		if (branded) b.add("declare namespace HxTypes {\n\tconst brand: unique symbol;\n}\n");
		b.add(types.toString());
		sys.io.File.saveContent(Path.withoutExtension(com.file) + ".d.ts", b.toString());
	}

	// ------------------------------------------------------------------ abstracts (modules)
	//
	// An abstract's implementation is an object of its functions (`export const A = { f(this1, ...) {...}, ... }`), not a
	// class: its module has, beside it, the abstract as a type of its own of the same name (TypeScript: `export type A`,
	// abstractTypesOf), one import bringing both. A type of no implementation (its functions inline) is its module's still.
	// An implementation an object cannot have (#private statics, a static block: lazy statics, @:isVar's) stays a class,
	// its type `A.Self` (a namespace TypeScript merges with the class).

	// the branded abstracts' types: their names' bindings, their files
	final abstractTypes = new haxe.ds.ObjectMap<TAbstract, {sym:Sym, file:Int}>();
	final typeOnly:Array<Sym> = [];
	// (modules) the enum abstracts of no implementation, whose files have their values' objects
	final enumObjects:Array<TAbstract> = [];

	function collectAbstracts() {
		for (t in com.types) switch t {
			case TAbstractDecl(a) if (Casts.branded(a)):
				var item = a.aImpl == null ? null : byPath.get(dot(a.aImpl.clPath));
				// (an enum abstract of no implementation, its functions inline: its values' object, of its type's name)
				var values = Casts.enumValues(a) != null;
				if (item != null) abstractTypes.set(a, {sym: item.sym, file: item.file}) else if (tsOut || values) {
					var s = new Sym(SType(t), a.aPath.name);
					typeOnly.push(s);
					abstractTypes.set(a, {sym: s, file: moduleFile(a.aModule.mPath)});
					if (values) enumObjects.push(a);
				}
			case _:
		}
	}

	// (TypeScript) a file's abstracts' types: `declare const $brand: unique symbol;` and `export type A<T> = ...;` each
	// (Casts: `A(V) from V to V` V; `A(V) to V` V and the brand; `A(V) from V` the brand or V; `A(V)` the brand; other
	// `from` types' values too; an enum abstract its values' literals), the brand of the abstract's path
	function abstractTypesOf(file:OutFile):Array<St> {
		var out:Array<St> = [];
		var ts = new Ts(t -> typeRef(file, file.names, t), () -> enumValueRef(file.names), props);
		var branded = false;
		for (a => x in abstractTypes) if (x.file == file.id) {
			var d = abstractDecl(a, x.sym.name, (t, scope) -> {
				ts.scope = scope;
				ts.type(t);
			}, ps -> ts.params(ps), "$brand");
			if (d.branded) branded = true;
			if (d.values != null) out.push(st(SRaw("declare " + d.values)));
			// (an implementation that stays a class: of its namespace, `A.Self`, which TypeScript merges with it)
			out.push(st(SRaw(abstractClasses.exists(a) ? "export declare namespace " + x.sym.name + " { type Self" + d.decl + " }" : "export type " + x.sym.name + d.decl)));
		}
		if (branded) out.unshift(st(SRaw("declare const $brand: unique symbol;")));
		return out;
	}

	// an abstract as TypeScript has it (Casts): its type parameters and what it is (`<T> = V & { ... };`), whether it is
	// branded; the brand of the abstract's path and of its underlying type, which tells `A<Int>` from `A<String>` (type: a
	// type's text, of the type parameters in scope; params: the type parameters'; brand: the brand symbol's name). An enum
	// abstract (Casts.enumRep): the union of its values' types, declared before it (`decl`'s `values`, ambient: of no code),
	// `$A` of its name (name)
	static function abstractDecl(a:TAbstract, name:String, type:(T, Array<String>) -> String, params:TypeParams->String,
			brand:String):{decl:String, branded:Bool, values:Null<String>} {
		var scope = [for (p in a.aParams) p.ttpName];
		var v = type(a.aThis, scope);
		var to = Casts.toThis(a), from = Casts.fromThis(a), rep = Casts.enumRep(a);
		var values:Null<String> = null, parts;
		switch rep {
			case null | ELiterals:
				var lits = Casts.enumValues(a);
				var self = lits != null ? (lits.length > 1 ? "(" + lits.join(" | ") + ")" : lits[0]) : (v.indexOf("|") >= 0 || v.indexOf("=>") >= 0 ? "(" + v + ")" : v);
				var tag = "{ readonly [" + brand + "]: { readonly " + Printer.quote(dot(a.aPath)) + ": " + v + " } }";
				parts = [if (to && from) v else if (to) self + " & " + tag else tag];
				if (from && !to) parts.push(v);
			case EEnum:
				values = "enum $" + name + " { " + [for (f in Casts.enumFields(a)) f.name + " = " + Casts.literalOf(f.c)].join(", ") + " }";
				parts = ["$" + name];
				if (from) parts.push(v);
			case ESymbols:
				values = "const $" + name + ": { " + [for (f in Casts.enumFields(a)) "readonly " + f.name + ": unique symbol;"].join(" ") + " };";
				parts = [[for (f in Casts.enumFields(a)) "typeof $" + name + "." + f.name].join(" | ")];
				if (from) parts.push(v);
		}
		for (f in a.aFrom) if (!Casts.isThis(a, f)) parts.push(type(f, scope));
		return {
			decl: params(a.aParams) + " = " + [for (p in parts) parts.length > 1 && p.indexOf("=>") >= 0 ? "(" + p + ")" : p].join(" | ") + ";",
			branded: rep == null && !(to && from) || rep == ELiterals && !(to && from),
			values: values
		};
	}

	// (TypeScript, modules) an enum abstract's value in its object: its literal as its own type (`0 as $A.X`, a declared enum's
	// member; `0 as unknown as typeof $A.X`, a unique symbol), or itself (Casts.ELiterals); null where it is no enum abstract's
	// value (name: the abstract's, field: the value's)
	static function enumValueEx(a:TAbstract, f:TClassField, name:String):Null<Ex> {
		var c = Casts.enumConst(f);
		return c == null ? null : enumConstEx(a, c, name, f.cfName);
	}

	static function enumConstEx(a:TAbstract, c:TConstant, name:String, field:String):Ex {
		var lit = ex(switch c {
			case TInt(i): ENum(Std.string(i));
			case TFloat(s): ENum(s);
			case TString(s): EStr(s);
			case TBool(b): EBool(b);
			case _: ENull;
		});
		return switch Casts.enumRep(a) {
			case EEnum: ex(EAsType(lit, "$" + name + "." + field));
			case ESymbols: ex(EAsType(ex(EAsType(lit, "unknown")), "typeof $" + name + "." + field));
			case _: lit;
		}
	}

	// the abstracts whose implementations stay classes (their types `A.Self`)
	final abstractClasses = new haxe.ds.ObjectMap<TAbstract, Bool>();

	// an implementation's members as an object's properties, or null: one an object cannot have; its statics' values but
	// constants assigned after it (`after`: a value may call its functions, as a class's static initializer may), in order
	static function objectOf(members:Array<Member>, after:Array<Prop>, ?consts:Map<String, Ex>):Null<Array<Prop>> {
		var out:Array<Prop> = [];
		for (m in members) {
			while (m.match(MProtected(_) | MReadonly(_))) m = switch m {
				case MProtected(x) | MReadonly(x): x;
				case _: m;
			}
			switch m {
				case MComment(_):
				case MMethod(KPrivate(_), _, _, _) | MField(KPrivate(_), _, _, _): return null;
				case MMethod(k, f, true, MkMethod): out.push({key: k, value: ex(EFn(f))});
				case MMethod(k, f, true, kind = MkGet | MkSet): out.push({key: k, value: ex(EFn(f)), kind: kind});
				case MField(k = KField(n, _) | KName(n), _, true, _) if (consts != null && consts.exists(n)): out.push({key: k, value: consts.get(n)});
				case MField(k, v, true, _) if (v != null && v.def.match(ENum(_) | EStr(_) | EBool(_))): out.push({key: k, value: v});
				case MField(k, v, true, _):
					out.push({key: k, value: ex(EAs(ex(EUndefined)))});
					if (v != null) after.push({key: k, value: v});
				case MDeclare(k, _, true): out.push({key: k, value: ex(EAs(ex(EUndefined)))});
				case _: return null;
			}
		}
		return out;
	}

	// ------------------------------------------------------------------ names

	function name() {
		var taken = new Map<String, Bool>();
		for (k in RESERVED.keys()) taken.set(k, true);
		// (modules: a file's names are its own, its code's locals only; the bundle's one scope, all of them)
		if (!modules) for (k in localNames.keys()) taken.set(k, true);
		for (k in globals.keys()) taken.set(k, true);
		for (k in rawWords.keys()) taken.set(k, true);
		taken.set("$hx", true);
		function pick(s:Sym, fallback:String, into:Map<String, Bool>) {
			var n = s.hint;
			if (into.exists(n)) n = fallback;
			var base = n, i = 1;
			while (into.exists(n)) n = base + "$" + (i++);
			s.name = n;
			into.set(n, true);
		}
		// (a type untyped code names, by Genjs's name for it (flat): that name)
		var named = new Map<Int, Bool>();
		for (item in items) {
			var flat = core.Path.flatPath(tPath(item.t));
			if (rawWords.exists(flat) && !localNames.exists(flat) && !globals.exists(flat)) {
				item.sym.name = flat;
				named.set(item.index, true);
				taken.set(flat, true);
			}
		}
		if (tsOut) {
			pick(enumIndex, "index$", taken);
			pick(enumValueType, "EnumValue$", taken);
		}
		for (r in requires) pick(r.sym, r.sym.hint + "$", taken);
		if (!modules) {
			for (s in typeOnly) pick(s, s.hint + "$", taken);
			for (item in items) if (!named.exists(item.index)) pick(item.sym, core.Path.flatPath(tPath(item.t)), taken);
			for (k => s in moduleFields) pick(s, k.split(".").join("_"), taken);
			return;
		}
		// (modules: each file's declarations named apart from what it has, its locals; another's imported by its name, as
		// another of its names where the file has that one: imports)
		nameBase = [for (k => v in taken) k => v];
		var fileTaken = [for (f in files) [for (k => v in taken) k => v]];
		for (f in files) for (k in localsOf(f.id).keys()) fileTaken[f.id].set(k, true);
		for (item in items) if (!named.exists(item.index)) pick(item.sym, core.Path.flatPath(tPath(item.t)), fileTaken[item.file]);
		for (s in typeOnly) {
			var file = 0;
			for (a => x in abstractTypes) if (x.sym == s) file = x.file;
			pick(s, s.hint + "$", fileTaken[file]);
		}
		for (k => s in moduleFields) {
			var owner = moduleFieldOwner.get(k);
			pick(s, k.split(".").join("_"), owner == null ? taken : fileTaken[owner.file]);
		}
	}

	// (modules) the names every file has (reserved words, globals, untyped code's words, the runtime's)
	var nameBase:Null<Map<String, Bool>> = null;

	final fileLocals = new Map<Int, Map<String, Bool>>();

	function localsOf(file:Int):Map<String, Bool> {
		var m = fileLocals.get(file);
		if (m == null) fileLocals.set(file, m = new Map());
		return m;
	}

	// (modules, but minified, whose names are the program's: shorten) the names a file has for the bindings it imports
	// where its own are theirs (`import { A as A$1 }`), and the names it has, which a type it imports only (TypeScript,
	// found as it prints) may not be: aliases
	function aliases() {
		if (nameBase == null || tight) return;
		var exported = new Map<String, Int>();
		for (f in files) for (item in f.items) exported.set(item.sym.name, (exported.exists(item.sym.name) ? exported.get(item.sym.name) : 0) + 1);
		for (s in typeOnly) exported.set(s.name, (exported.exists(s.name) ? exported.get(s.name) : 0) + 1);
		for (k => s in moduleFields) exported.set(s.name, (exported.exists(s.name) ? exported.get(s.name) : 0) + 1);
		exportCount = exported;
		for (f in files) {
			var used = [for (k => v in nameBase) k => v];
			for (k in localsOf(f.id).keys()) used.set(k, true);
			var ownNames = new Map<String, Bool>();
			for (item in f.items) {
				used.set(item.sym.name, true);
				ownNames.set(item.sym.name, true);
			}
			for (s in typeOnly) for (a => x in abstractTypes) if (x.sym == s && x.file == f.id) used.set(s.name, true);
			for (k => s in moduleFields) {
				var owner = moduleFieldOwner.get(k);
				if (owner != null && owner.file == f.id) used.set(s.name, true);
			}
			var imported = [for (s => from in f.needs) if (from >= 0 && from != f.id) s];
			// (and those a split's code takes of the modules it loads, which the file's code names: a split has no file)
			var seen = [for (s in imported) s => true];
			for (g in files) if (g.path == null && g.id != f.id) for (s => from in g.needs) if (from > 0 && from != f.id && !seen.exists(s)) {
				seen.set(s, true);
				imported.push(s);
			}
			imported.sort((a, b) -> Reflect.compare(a.name, b.name));
			for (s in imported) {
				// (its own name where untyped code has it: the binding the code names, Genjs's name for it)
				var n = s.name, i = 1;
				while (used.exists(n) && !(n == s.name && rawWords.exists(n) && !localsOf(f.id).exists(n) && !ownNames.exists(n)))
					n = s.name + "$" + (i++);
				used.set(n, true);
				if (n != s.name) f.alias.set(s, n);
			}
			f.taken = used;
		}
	}

	// (modules) how often a name is a binding's the files export: a type imported only, of a name another has, is named
	// by its module (`import("./a/B.ts").B`)
	var exportCount:Null<Map<String, Int>> = null;

	// a binding's name in a file
	function nameIn(f:OutFile, s:Sym):String {
		var a = f.alias.get(s);
		return a == null ? s.name : a;
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
		if (props != null) decideProperties();
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
		if (Gctx.rawDefined(com, "dts")) writeDts();
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
			var from = body.pieces.length;
			var hotDecl:Null<ClassDecl> = null;
			var hotObject:Null<Array<Prop>> = null;
			var hotEnumArgs:Null<Array<Ex>> = null;
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
						if (!item.inBody.get(f) && modules && !item.atEnd.exists(f)) {
							for (m in lazy(item, f, v)) later.push(m);
						} else if (!item.inBody.get(f)) {
							head.push(prot(f, readonly(f, MField(fieldKey(f.cfName, sns(c)), null, true, f.cfType))));
							// (TypeScript: assigned from outside the class, past `protected` and `readonly`; modules: after the file's
							// classes)
							var self = ex(EId(item.sym));
							var target = !tsOut ? Lower.field(self, f.cfName, sns(c))
								: Properties.readonlyVar(f) ? Lower.field(ex(EAs(self)), f.cfName, sns(c))
								: !hasClassFieldFlag(f, CfPublic) ? ex(EFriend(self, f.cfName))
								: Lower.field(self, f.cfName, sns(c));
							(modules ? after : deferredStatics).push(st(SExpr(ex(EAssign("=", target, v)))));
						} else if (f.cfExpr == null || f.cfExpr.eexpr.match(TFunction(_))) head.push(staticMember(c, f, v));
						else later.push(staticMember(c, f, v));
					}
					var init = item.init;
					if (init != null && item.initInBody) head.push(MStaticBlock(init));
					else if (init != null && !item.initLate) {
						after.push(st(SComment(item.path + ".__init__")));
						for (s in initStatements(init)) after.push(s);
					}
					// (TypeScript: a static of an ancestor's name, which Haxe lets differ and TypeScript's class checks as its own)
					var members = head.concat(later).concat(accessorMembers(item, c, d.members));
					var after:Array<Prop> = [];
					// (modules: an abstract's implementation an object of its functions, where it can be: abstracts)
					var asConst = false;
					var object = switch c.clKind {
						case KAbstractImpl(a) if (modules && abstractTypes.exists(a)):
							// (TypeScript: an enum abstract's values, constants of their own types)
							var consts = new Map<String, Ex>();
							if (tsOut) for (f in c.clStatics) {
								var e = enumValueEx(a, f, d.name.name);
								if (e != null) consts.set(f.cfName, e);
							}
							var o = objectOf(members, after, consts);
							if (o == null) abstractClasses.set(a, true);
							// (an enum abstract's values the program has inline only: its object's still, first)
							if (o != null) {
								var missing = [
									for (v in Casts.enumFields(a))
										if (!Lambda.exists(o, p -> p.key.match(KName(_ == v.name => true) | KField(_ == v.name => true, _))))
											({key: KName(v.name), value: enumConstEx(a, v.c, d.name.name, v.name)} : Prop)
								];
								o = missing.concat(o);
							}
							// (`as const`: where nothing assigns its statics, an enum abstract's: its values' types as they are)
							if (o != null && tsOut && consts.iterator().hasNext() && after.length == 0 && !Lambda.exists(members, m -> switch m {
								case MProtected(MField(KField(n, _) | KName(n), _, true, _)) | MField(KField(n, _) | KName(n), _, true, _): !consts.exists(n);
								case _: false;
							}))
								asConst = true;
							o;
						case _: null;
					}
					if (object != null) {
						hotObject = object;
						var init = ex(EObject(object));
						if (asConst) init = ex(EAsType(init, "const"));
						body.statement(exp(st(SVar(VConst, [{name: d.name, init: init}]))));
						for (p in after) body.statement(st(SExpr(ex(EAssign("=", switch p.key {
							case KField(n, ns): Lower.field(ex(EId(d.name)), n, ns);
							case KName(n): Lower.member(ex(EId(d.name)), n);
							case KString(n): ex(EIndex(ex(EId(d.name)), ex(EStr(n))));
							case KComputed(k): ex(EIndex(ex(EId(d.name)), k));
							case KPrivate(_): throw "assert";
						}, p.value)))));
					} else {
						if (tsOut && staticClash(c)) body.statement(st(SRaw("// @ts-ignore")));
						hotDecl = {
							name: d.name,
							superClass: d.superClass,
							members: members,
							tparams: d.tparams,
							superArgs: d.superArgs,
							isAbstract: d.isAbstract
						};
						// (hot: its constructor asks js.Hot first; but js.Hot's)
						var emitted:ClassDecl = hot == null || item.path == "js.Hot" ? hotDecl : {
							name: hotDecl.name,
							superClass: hotDecl.superClass,
							members: hotConstructor(hotDecl, hotDecl.members)
						};
						body.statement(exp(st(SClass(emitted))));
					}
					// (Type.getInstanceFields: the variables on the prototype, `null` until an instance has its own, as Genjs has them)
					if (instanceFields) {
						var vars:Array<Prop> = [
							for (f in c.clFields)
								if (isPhysicalVarField(f) && !hasClassFieldFlag(f, CfExtern) && !isBacked(f)) ({key: fieldKey(f.cfName, ins(c)), value: ex(ENull)} : Prop)
						];
						if (vars.length > 0)
							body.statement(st(SExpr(ex(ECall(ex(EMember(ex(EId(global("Object"))), "assign")), [ex(EMember(ex(EId(item.sym)), "prototype")), ex(EObject(vars))])))));
					}
					if (resolveClass && !c.clKind.match(KAbstractImpl(_)))
						body.statement(st(SExpr(ex(EAssign("=", ex(EIndex(rt("classes"), ex(EStr(item.path)))), ex(EId(item.sym)))))));
					expose(body, exposed, c, item);
				case TEnumDecl(e):
					hotEnumArgs = enumDecl(body, item, e, names || refs.exists("Type.getEnumName"));
					if (resolveEnum) body.statement(st(SExpr(ex(EAssign("=", ex(EIndex(rt("enums"), ex(EStr(item.path)))), ex(EId(item.sym)))))));
				case _:
			}
			if (hot != null) hotItems.push({
				file: file,
				item: item,
				pieces: body.pieces.slice(from),
				decl: hotDecl,
				object: hotObject,
				enumArgs: hotEnumArgs
			});
			body.blank();
		}
		// (modules: the values of the file's enum abstracts of no implementation, `export const A = { X: ..., Y: ... } as const`)
		for (a in enumObjects) {
			var x = abstractTypes.get(a);
			if (x.file != file.id) continue;
			var o = ex(EObject([for (v in Casts.enumFields(a)) ({key: KName(v.name), value: enumConstEx(a, v.c, x.sym.name, v.name)} : Prop)]));
			body.statement(exp(st(SVar(VConst, [{name: x.sym, init: ex(EAsType(o, "const"))}]))));
			body.blank();
		}
		if (after.length > 0 || deferredStatics.length > 0 || exposed.length > 0) {
			body.statements(after);
			body.statements(deferredStatics);
			body.statements(exposed);
			body.blank();
		}
		// (TypeScript: the file's abstracts' types, first)
		if (tsOut) {
			var types = abstractTypesOf(file);
			for (i in 0...types.length) body.pieces.insert(i, POne(types[i]));
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

	// (hot: the setter of its functions, which a patch sets them by: `Hot.module(path, (n, v) => { switch (n) { case "f": f = v; ...} })`)
	function moduleFieldsDecl(body:Doc, item:Item, c:TClass, deferredStatics:Array<St>) {
		var m = fieldsModule(c);
		if (hot != null) {
			var n = new Sym(SLocal, "name"), v = new Sym(SLocal, "value");
			var cases:Array<Case> = [
				for (f in c.clStatics)
					if (item.fns.exists(f))
						{tests: [ex(EStr(f.cfName))], body: [st(SExpr(ex(EAssign("=", ex(EId(item.fns.get(f).name)), ex(EId(v)))))), st(SBreak(null))]}
			];
			if (cases.length > 0)
				deferredStatics.push(st(SExpr(ex(ECall(hotStatic("module"), [
					ex(EStr(item.path)),
					ex(EFn({params: [n, v], rest: false, arrow: true, body: [st(SSwitch(ex(EId(n)), cases))]}))
				])))));
		}
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
	// (its arguments of `declareEnum`: hot's)
	function enumDecl(body:Doc, item:Item, e:TEnum, named:Bool):Array<Ex> {
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
		return args;
	}
}
