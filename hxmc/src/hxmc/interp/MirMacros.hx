package hxmc.interp;

#if hxmc.jit
import core.TType;
import hxmc.Obj;
import hxmc.ir.Ir;
import hxmc.unsafe.LibC;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Ptr;
import macros.MacroApi.CompilerApi;

// -D hxmc.mir-macros, in a compiler built with -D hxmc.jit: macros on the Mir
// interpreter, without Eval. The macro context is typed for hxmc
// (MacroContext.macroPlatformHook: hxmc's std, the hxmc custom target,
// `macro` defined), its functions are lowered as macros call them (one
// Lower, grown call by call), compiled for the interpreter and linked into
// the running compiler (macro.Loader: a bundle per step, sharing the earlier
// ones' numbers, globals and functions), and called directly. Its values are
// the compiler's own Haxe values (MacroApi.MacroNativeValues); Context's API
// is the compiler's (hxmc.MacroHost: hxmc_mir_macro_load, exported here).
@:access(hxmc.Driver)
@:access(hxmc.DataGen)
@:access(hxmc.ir.Facts)
@:access(hxmc.ir.Lower)
@:access(hxmc.macro.Guest)
@:access(hxmc.macro.Loader)
@:access(hxmc.rt.Interp)
@:access(hxmc.interp.MirRun)
@:access(macros.MacroApi.MacroApiImpl)
class MirMacros implements macros.MacroEngine.IMacroEngine {
	static var self:Null<MirMacros> = null;
	static var hxmcStd:Null<String> = null;

	// where the macro code's calls are (hxmc.ir.Lower.callSites): the site of
	// the call being made, and the site of the function making it (as Eval's
	// env_leave_pmin/pmax: get_api_call_pos); sites by id (0: none)
	@:hxmc.export("hxmc_mir_macro_pending") static var pending:Int;
	@:hxmc.export("hxmc_mir_macro_current") static var current:Int;
	static var sites:Array<core.Globals.Pos> = [core.Globals.nullPos];
	static var siteIds = new Map<String, Int>();

	static function site(p:core.Globals.Pos):Int {
		var k = p.pmin + ":" + p.pmax + ":" + p.pfile;
		var id = siteIds.get(k);
		if (id == null) {
			id = sites.length;
			sites.push(p);
			siteIds.set(k, id);
		}
		return id;
	}

	// the macro context, the API of the call being made, the API's functions by name
	var com:Null<context.Common.CommonContext> = null;
	var api:Null<CompilerApi> = null;
	var apiTable = new Map<String, Dynamic>();
	var apiWrapped = new Map<String, Dynamic>();
	// the macro context's types given their filters (ready), by path
	var processed = new Map<String, ModuleType>();
	// their modules' ids: a type typed again in another compilation starts a new generation
	var mIds = new Map<String, Int>();
	// a compilation began (doReuse) and no generation began since
	var reused = false;
	// the static initializers of the classes loaded, in order (run again by doReuse)
	var inits:Array<Ptr> = [];
	// (the types whose runtime implementations the lowering knows: Lower.findHosts, once each)
	var scanned = new Map<String, Bool>();
	var l:Null<hxmc.ir.Lower> = null;
	var opts:Null<Options> = null;
	var compiled = new Map<FuncInfo, Bool>();
	// the std's functions the compiler has alike: its native code runs them (MirRun.hostFunctions)
	var native = new Map<FuncInfo, Bool>();
	// the std's class paths
	var stdRoots:Array<String> = [];
	var lastPrep:Null<Prep> = null;
	// the macro functions called so far: their function and descriptor, by pack.Class.f
	var entries = new Map<String, {fi:FuncInfo, desc:Ptr}>();
	var stats = Sys.getEnv("HXMC_MACRO_STATS") == "1";
	// a compilation error was reported: no more macro calls (as Eval's had_error)
	var hadError = false;
	var tCompile = 0.0;
	var steps = 0;

	public function new() {}

	// whether the command line selects it: -D hxmc.mir-macros
	public static function selected(args:Array<String>):Bool {
		for (i in 0...args.length - 1)
			if ((args[i] == "-D" || args[i] == "--define") && (args[i + 1] == "hxmc.mir-macros" || args[i + 1] == "hxmc.mir_macros")) return true;
		return false;
	}

	public static function install(std:Null<String>) {
		hxmcStd = std;
		self = new MirMacros();
		macros.MacroEngine.engine = self;
		macros.MacroApi.MacroApiImpl.nativeValues = true;
		typing.MacroContext.macroPlatformHook = setupPlatform;
		var table = macros.MacroApi.MacroApiImpl.macroApi(() -> self.api.getCom(), () -> self.api);
		for (e in table)
			self.apiTable.set(e.name, e.value);
		// (the call site of the function calling the API: EvalMain.get_api_call_pos)
		macros.MacroApi.MacroNativeValues.apiCallPos = () -> current > 0 ? sites[current] : self.api == null ? core.Globals.nullPos : self.api.pos;
		// (the macro context's types by name: the loaded ones, the macro API's loaded on demand,
		// as arguments are encoded before the first macro function is, and even before the
		// macro context hands its types over: macroEnum)
		macros.MacroApi.MacroNativeValues.resolveEnum = name -> {
			var e = Type.resolveEnum(name);
			if (e == null && self.apiTypesPending()) {
				self.build(null);
				e = Type.resolveEnum(name);
			}
			if (e == null && self.macroEnum(name)) e = Type.resolveEnum(name);
			cast e;
		};
		// (the path of a macro context's type in an expression: its module's, then its
		// name when they differ, EvalMain.value_to_expr's make_path)
		macros.MacroApi.MacroNativeValues.typePath = name -> {
			var t = self.processed.get(name);
			if (t == null) return name.split(".");
			var i = core.TFunctions.tInfos(t);
			var m = i.mtModule.mPath;
			m.name == i.mtPath.name && m.pack.join(".") == i.mtPath.pack.join(".") ? m.pack.concat([m.name]) : m.pack.concat([m.name, i.mtPath.name]);
		};
		// (Std.string of a position in macro code: EvalPrinting.s_value's #pos(...))
		hxmc.rt.EvalCompat.classNames = [Type.getClassName(core.Globals.Pos) => "haxe.macro.Position"];
		hxmc.rt.EvalCompat.special = v -> Std.isOfType(v, core.Globals.Pos) ? "#pos(" + syntax.Lexer.getErrorPos((file, line) -> '$file:$line:', v) + ")" : null;
		// (a macro function the compiler calls back: macro code, as Eval shows values: hxmc.rt.EvalCompat)
		macros.MacroApi.MacroNativeValues.callback = call -> {
			var order = hxmc.rt.EvalCompat.on;
			hxmc.rt.EvalCompat.on = true;
			var r:Dynamic = try call() catch (x:Dynamic) {
				hxmc.rt.EvalCompat.on = order;
				throw x;
			}
			hxmc.rt.EvalCompat.on = order;
			r;
		};
		macros.MacroApi.MacroNativeValues.resolveClass = name -> {
			var c = Type.resolveClass(name);
			if (c == null && self.apiTypesPending()) {
				self.build(null);
				c = Type.resolveClass(name);
			}
			cast c;
		};
	}

	// the macro context: hxmc's std in front, the hxmc custom target, the host as its target
	static function setupPlatform(com2:context.Common.CommonContext) {
		if (hxmcStd == null) throw "-D hxmc.mir-macros: hxmc's std is unknown (HXMC_STD)";
		(com2.classPaths : core.ClassPaths).add(new core.ClassPath.DirectoryClassPath(haxe.io.Path.addTrailingSlash(hxmcStd), core.ClassPath.ClassPathScope.User));
		// (the macro context's defines name Eval, Common.adaptDefinesToMacroContext: not this one's platform)
		core.Define.rawUndefine(com2.defines, "eval");
		// (hxmc's runtime needs its inline functions inlined: hxmc has no -D no-inline;
		// the macro context's defines keep it)
		com2.doinline = true;
		com2.platform = core.Globals.Platform.CustomTarget("hxmc");
		// (an hxmc compilation's platform configuration: Common's default, as the
		// custom target keeps it; the macro context is a copy of the target's,
		// whose own may lack sys: -js; but for Eval's padding of omitted
		// arguments, which typing a macro call's arguments counts on:
		// MacroContext.typeMacro, CallUnification)
		var config:Dynamic = core.ds.Record.copy(context.Common.defaultConfig);
		config.pfPadNulls = true;
		com2.config = config;
		context.Common.initPlatform(com2);
		if (!core.Define.rawDefined(com2.defines, "hxmc.target")) core.Define.rawDefineValue(com2.defines, "hxmc.target", "linux-x86_64");
	}

	// ---- the API of hxmc.MacroHost

	@:hxmc.export("hxmc_mir_macro_load") static function load(name:String, nargs:Int):Dynamic {
		var w = self.apiWrapped.get(name);
		if (w != null) return w;
		var f = self.apiTable.get(name);
		if (f == null) throw "Could not find macro function \"" + name + "\"";
		w = compilerSide(f, nargs);
		self.apiWrapped.set(name, w);
		return w;
	}

	// an API function, run as the compiler's code (not hxmc.rt.EvalCompat's)
	static function compilerSide(f:Dynamic, nargs:Int):Dynamic {
		inline function run(call:Void->Dynamic):Dynamic {
			var order = hxmc.rt.EvalCompat.on;
			hxmc.rt.EvalCompat.on = false;
			var r:Dynamic = try call() catch (x:Dynamic) {
				hxmc.rt.EvalCompat.on = order;
				throw x;
			}
			hxmc.rt.EvalCompat.on = order;
			return r;
		}
		return switch nargs {
			case 0: () -> run(() -> f());
			case 1: (a:Dynamic) -> run(() -> f(a));
			case 2: (a:Dynamic, b:Dynamic) -> run(() -> f(a, b));
			case 3: (a:Dynamic, b:Dynamic, c:Dynamic) -> run(() -> f(a, b, c));
			case 4: (a:Dynamic, b:Dynamic, c:Dynamic, d:Dynamic) -> run(() -> f(a, b, c, d));
			case 5: (a:Dynamic, b:Dynamic, c:Dynamic, d:Dynamic, e:Dynamic) -> run(() -> f(a, b, c, d, e));
			case _: Reflect.makeVarArgs(args -> run(() -> Reflect.callMethod(null, f, args)));
		}
	}

	@:hxmc.export("hxmc_mir_macro_pos") static function mkPos(file:String, min:Int, max:Int):Dynamic
		return ({pfile: file, pmin: min, pmax: max} : core.Globals.Pos);

	@:hxmc.export("hxmc_mir_macro_program_path") static function programPath():Null<String> {
		// (as Eval's Sys.programPath: EvalStdLibB.StdSys.programPath)
		var file:Null<String> = self.api.getCom().main.mainFile;
		return file == null ? null : core.Path.getFullPath(file);
	}

	// ---- the engine (macros.MacroEngine.IMacroEngine)

	public function create(com:context.Common.CommonContext, api:CompilerApi, isMacro:Bool, args:Array<String>):macros.eval.EvalContext.Context {
		this.com = com;
		this.api = api;
		// (the macro context's handle: only MacroContext keeps it)
		return cast this;
	}

	public function init(ctx:macros.eval.EvalContext.Context):Void {}

	public function addTypes(ctx:macros.eval.EvalContext.Context, types:Array<ModuleType>, ready:ModuleType->Void):Void {
		for (t in types) {
			var k = core.Globals.sTypePath(core.TFunctions.tPath(t));
			var m = core.TFunctions.tInfos(t).mtModule.mId;
			if (processed.exists(k)) {
				if (mIds.get(k) == m) continue;
				// (the first of this compilation: once a compilation)
				if (reused) newGeneration();
				reused = false;
			}
			processed.set(k, t);
			mIds.set(k, m);
			ready(t);
			// (a class's runtime metadata, which Eval's static prototypes carry,
			// EvalPrototype.create_static_prototype: the __meta__ static of the
			// full pipeline, Filters.addMetaField, that hxmc's Meta reads)
			switch t {
				case TClassDecl(c) if (!c.clStatics.exists("__meta__")):
					filters.Filters.addMetaField(com, t);
				case _:
			}
		}
	}

	public function doReuse(ctx:macros.eval.EvalContext.Context, api:CompilerApi, args:Array<String>):Void {
		hadError = false;
		this.api = api;
		reused = true;
		// (the statics' initial values again: EvalMain.doReuse's staticPrototypes.reset)
		var order = hxmc.rt.EvalCompat.on;
		hxmc.rt.EvalCompat.on = true;
		try
			for (p in inits)
				Mem.call0(p)
		catch (x:Dynamic) {
			hxmc.rt.EvalCompat.on = order;
			throw toCompilerError(x, api);
		}
		hxmc.rt.EvalCompat.on = order;
	}

	// the macro context typed again (another compilation: --next, the compilation
	// server), as EvalPrototype.addTypes drops the prototypes of a type whose module
	// is another: what was compiled is dropped, compiled again as it is needed
	function newGeneration() {
		hxmc.macro.Loader.newGeneration();
		l = null;
		opts = null;
		compiled = new Map();
		native = new Map();
		entries = new Map();
		scanned = new Map();
		lastPrep = null;
		stdRoots = [];
		inits = [];
		macros.MacroApi.MacroNativeValues.reset();
	}

	public function setError(ctx:macros.eval.EvalContext.Context, b:Bool):Void
		hadError = b;

	public function setApi(ctx:macros.eval.EvalContext.Context, api:CompilerApi):Void
		this.api = api;

	public function callPath(ctx:macros.eval.EvalContext.Context, path:Array<String>, f:String, vl:Array<macros.eval.EvalValue.Value>, api:CompilerApi):haxe.ds.Option<macros.eval.EvalValue.Value> {
		if (hadError) return None;
		var prev = this.api;
		this.api = api;
		var e = entry(path, f);
		var args:Array<Dynamic> = cast vl;
		try {
			var r = call(e.fi, e.desc, args, api);
			this.api = prev;
			return Some(r);
		} catch (x:Dynamic) {
			this.api = prev;
			throw toCompilerError(x, api);
		}
	}

	// an exception the macro code did not catch: its haxe.macro.Error as the
	// compiler's error, anything else as an uncaught exception (as Eval reports them)
	function toCompilerError(x:Dynamic, api:CompilerApi):Dynamic {
		if (Std.isOfType(x, core.Error.TypingError) || Std.isOfType(x, core.Error.FatalError) || Std.isOfType(x, macros.MacroApi.Abort)) return x;
		var c = macros.MacroApi.MacroNativeValues.resolveClass("haxe.macro.Error");
		if (c != null && Std.isOfType(x, c)) {
			var msg:String = Reflect.field(x, "message");
			var pos:core.Globals.Pos = Reflect.field(x, "pos");
			return new core.Error.TypingError(core.Error.makeError(Custom(msg), pos == null ? api.pos : pos));
		}
		return new core.Error.TypingError(core.Error.makeError(Custom("Uncaught exception " + Std.string(x)), api.pos));
	}

	// ---- compiling and loading

	function findClass(path:Array<String>):TClass {
		var name = path.join(".");
		var t = processed.get(name);
		if (t == null)
			for (x in com.types)
				if (core.Globals.sTypePath(core.TFunctions.tPath(x)) == name) t = x;
		return switch t {
			case TClassDecl(c): c;
			case _: throw "-D hxmc.mir-macros: no class " + name + " in the macro context";
		}
	}

	function entry(path:Array<String>, f:String):{fi:FuncInfo, desc:Ptr} {
		var key = path.join(".") + "." + f;
		var e = entries.get(key);
		if (e != null) return e;
		var c = findClass(path);
		var cf = c.clStatics.get(f);
		if (cf == null) throw "-D hxmc.mir-macros: no static " + key;
		var t0 = haxe.Timer.stamp();
		if (l == null) start();
		hxmc.ir.Lower.basic = com.basic;
		var fi = l.staticFunc(c, cf);
		build(c);
		var d = hxmc.macro.Loader.xb.get(InterpGen.DESC + lastPrep.funcSym(fi));
		if (d == null) throw "-D hxmc.mir-macros: " + key + " was not loaded";
		e = {fi: fi, desc: Ptr.ofI64((d.v : I64))};
		entries.set(key, e);
		tCompile += haxe.Timer.stamp() - t0;
		return e;
	}

	// whether the macro context has types of the macro API not loaded yet
	function apiTypesPending():Bool {
		for (k => t in processed)
			if (!scanned.exists(k) && apiType(t)) return true;
		return false;
	}

	// an enum of the macro API that the macro context has typed but not handed
	// over (addTypes) yet, loaded: values of it are made while the macro context
	// finalizes, as loading a macro types code calling another (an enum is its
	// declaration: no filters to wait for)
	function macroEnum(name:String):Bool {
		var parts = name.split(".");
		var path = new core.Globals.GlobalTypePath(parts.slice(0, parts.length - 1), parts[parts.length - 1]);
		var m = try com.moduleLut.findByType(path) catch (_:core.ds.NotFound) null;
		if (m == null) return false;
		for (t in m.mTypes)
			switch t {
				case TEnumDecl(en) if (core.Globals.sTypePath(en.ePath) == name):
					if (l == null) start();
					l.enumInfo(en);
					build(null);
					return true;
				case _:
			}
		return false;
	}

	// the macro API's types the compiler makes values of: haxe.macro's enums, its Error
	static function apiType(t:ModuleType):Bool
		return switch t {
			case TEnumDecl(en): en.ePath.pack.join(".") == "haxe.macro";
			case TClassDecl(k): k.clPath.pack.join(".") == "haxe.macro" && k.clPath.name == "Error";
			case _: false;
		}

	// the functions lowered since the last step and the macro API's new types:
	// compiled and loaded (main: the macro class, if a function of it is called)
	function build(main:Null<TClass>) {
		if (l == null) start();
		hxmc.ir.Lower.basic = com.basic;
		var fresh = [for (k => t in processed) if (!scanned.exists(k)) t];
		for (k in processed.keys())
			scanned.set(k, true);
		for (t in fresh)
			switch t {
				case TEnumDecl(en) if (apiType(t)):
					l.enumInfo(en);
				case TClassDecl(k) if (apiType(t)):
					l.classInfo(k);
				case _:
			}
		l.findHosts(fresh);
		hxmc.ir.Lower.callSites = {site: site, pending: "hxmc_mir_macro_pending", current: "hxmc_mir_macro_current", wants: wantsSites};
		try {
			l.drain();
			l.finish();
		} catch (e:Dynamic) {
			hxmc.ir.Lower.callSites = null;
			throw e;
		}
		hxmc.ir.Lower.callSites = null;
		step(main);
	}

	function start() {
		opts = Options.read(com);
		opts.interp = "1";
		var abi = Abi.get(opts.target);
		hxmc.ir.Lower.targetOs = abi.osCode();
		hxmc.ir.Lower.targetArm = abi.arm ? 1 : 0;
		hxmc.ir.Lower.targetCode = MirBuild.targetCode(abi);
		hxmc.ir.Lower.targetPlatform = abi.platformCode();
		hxmc.ir.Lower.bounds = opts.bounds;
		hxmc.ir.Lower.resources = [];
		hxmc.ir.Lower.basic = com.basic;
		l = new hxmc.ir.Lower();
		for (cp in com.classPaths.asList())
			if (cp.path != "" && (cp.scope == Std || sys.FileSystem.exists(haxe.io.Path.addTrailingSlash(cp.path) + "hxmc/rt/Runtime.hx")))
				stdRoots.push(cp.path);
	}

	// the functions whose calls note their sites (Lower.callSites): not the
	// runtime's, nor the std's but for the macro API's (its own calls of
	// the API: Compiler.keep's addGlobalMetadata), so that the std's may be
	// the compiler's (MirRun.hostFunctions: the same code)
	function wantsSites(f:FuncInfo):Bool {
		if (hxmc.macro.Guest.runtime(f)) return false;
		if (f.pos == null || f.module == null || StringTools.startsWith(f.module, "haxe.macro.")) return true;
		for (r in stdRoots)
			if (StringTools.startsWith(f.pos.pfile, r)) return false;
		return true;
	}

	// the functions lowered since the last step: a bundle, loaded
	function step(main:Null<TClass>) {
		steps++;
		var prog = l.prog;
		var d = new Driver(prog, "", opts);
		d.inlineCandidates();
		var prep = d.prep;
		lastPrep = prep;
		var e = prep.e;
		var host = hxmc.macro.Loader.hostSyms();
		InterpGen.emulatedTls = new Map();
		InterpGen.nativeTls = s -> {
			var h = host.get(s);
			h != null && h.k == "l";
		};
		var funcs = [for (f in prog.funcs) if (!compiled.exists(f) && (!hxmc.macro.Guest.runtime(f) || !host.exists(e.symbol(f)))) f];
		for (f in funcs) {
			var fp = new Fingerprint(prep, null);
			fp.func(f);
			var k = 0;
			while (k < fp.newStrings.length) {
				prep.addStr(fp.newStrings[k], fp.newStrings[k + 1]);
				k += 2;
			}
		}
		// (the types handed over so far: com.types may not have them yet)
		var types = [for (t in processed) t];
		var facts:Dynamic = hxmc.macro.Guest.facts(com, prog, e, l, main, types);
		MirRun.unshare(facts, host, l, e, com, types);
		// (the std's functions the compiler has alike: its native code; HXMC_MIR_HOST=0: all interpreted)
		var ownRuntime = opts.bounds != 0 ? ["hxmc.rt.Dyn" => true, "hxmc.rt.NArray" => true] : new Map<String, Bool>();
		var found = Sys.getEnv("HXMC_MIR_HOST") == "0" ? new Map() : MirRun.hostFunctions(funcs, facts, prep, e, com, ownRuntime, native);
		for (f => _ in found) {
			native.set(f, true);
			compiled.set(f, true);
		}
		funcs = [for (f in funcs) if (!found.exists(f)) f];
		d.interp = new InterpGen.InterpSet(opts.interp, prep, native);
		var abi = Abi.get(opts.target);
		var obj = new Obj();
		var emit = Target.emitter(abi, obj);
		var ras = new Regalloc.Scratch(Target.selector(abi));
		for (f in funcs)
			d.compileFunc(f, obj, emit, ras);
		var dg = new DataGen(prep, abi, obj, mf -> d.compileMir(mf, emit, obj));
		dg.strings();
		for (s in prog.sigs) {
			d.compileMir(dg.dynTrampoline(s), emit, obj);
			d.compileMir(dg.boundTrampoline(s), emit, obj);
		}
		dg.allocStubs([], emit);
		dg.stubs([], emit);
		dg.cstrLiterals([]);
		dg.emptyArrays([]);
		var b = hxmc.macro.Loader.loadObj(obj, facts);
		for (p in b.inits)
			inits.push(p);
		for (f in funcs)
			compiled.set(f, true);
		macros.MacroApi.MacroNativeValues.reset();
		if (stats) Sys.stderr().writeString('hxmc.mir-macros: step $steps: ${funcs.length} functions (${Lambda.count(found)} native), ${b.codeBytes} bytes of code\n');
	}

	// a macro function called with the compiler's values: its arguments as
	// the interpreter's words (hxmc.rt.Interp.enter), its result back
	function call(fi:FuncInfo, desc:Ptr, args:Array<Dynamic>, api:CompilerApi):Dynamic {
		var n = fi.args.length;
		var buf = LibC.malloc(((n > 0 ? n : 1) * 8 : I64));
		for (k in 0...n) {
			var v:Dynamic = k < args.length ? args[k] : null;
			switch fi.args[k].ty {
				case TI32 | TBool:
					Mem.setI64(buf, 8 * k, (v == null ? 0 : v == true ? 1 : v == false ? 0 : (v : Int) : I64));
				case TF64:
					Mem.setF64(buf, 8 * k, v == null ? 0.0 : (v : Float));
				case TI64:
					Mem.setI64(buf, 8 * k, v == null ? (0 : I64) : (v : I64));
				case _:
					Mem.setPtr(buf, 8 * k, Mem.addr(v));
			}
		}
		// (the macro function's site: the macro call's position, as EvalMain.callPath's frame has it)
		pending = site(api.pos);
		// (no collection between the addresses written and the frame taking them;
		// the macro code sees values as Eval shows them: hxmc.rt.EvalCompat)
		var order = hxmc.rt.EvalCompat.on;
		hxmc.rt.EvalCompat.on = true;
		try
			hxmc.rt.Interp.enter(desc, buf)
		catch (x:Dynamic) {
			hxmc.rt.EvalCompat.on = order;
			LibC.free(buf);
			throw x;
		}
		hxmc.rt.EvalCompat.on = order;
		var w = Mem.getI64(buf, 0);
		var r:Dynamic = switch fi.ret {
			case TVoid: null;
			case TI32: (w.toInt() : Dynamic);
			case TBool: (w.toInt() != 0 : Dynamic);
			case TF64: (Mem.bitsF64(w) : Dynamic);
			case TI64: (w : Dynamic);
			case _: Mem.obj(Ptr.ofI64(w));
		}
		LibC.free(buf);
		return r;
	}

	public function report() {
		if (stats && steps > 0) Sys.stderr().writeString('hxmc.mir-macros: ${steps} steps, compile ${Std.int(tCompile * 1000)} ms, spare entries taken ${hxmc.macro.Loader.used()}\n');
	}
}
#end
