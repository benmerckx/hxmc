package hxmc.interp;

import core.TType;
import hxmc.Obj;
import hxmc.ir.Ir;
import hxmc.unsafe.LibC;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Ptr;
import macros.MacroApi.CompilerApi;

// -D hxmc.macros=mir, in a native compiler (a Mir host): macros on the Mir
// interpreter, without Eval. The macro context is typed for hxmc
// (MacroContext.macroPlatformHook: hxmc's std, the hxmc custom target,
// `macro` defined), its functions are lowered as macros call them (one
// Lower, grown call by call; the std's bodies typed as it needs them:
// MacroRuntime), linked into the running compiler (macro.Loader: a bundle
// per step, sharing the earlier ones' numbers, globals and functions),
// each compiled for the interpreter the first time it is called
// (compileLazy), and called directly. Its values are
// the compiler's own Haxe values (MacroApi.MacroNativeValues); Context's API
// is the compiler's (hxmc.MacroHost: hxmc_mir_macro_load, exported here).
@:access(hxmc.Driver)
@:access(hxmc.DataGen)
@:access(hxmc.ir.Facts)
@:access(hxmc.ir.Lower)
@:access(hxmc.macro.BundleFacts)
@:access(hxmc.macro.Loader)
@:access(hxmc.rt.Interp)
@:access(hxmc.rt.Gc)
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
	// (an id is a hash of the position, the next free one on a collision: the
	// same in every build whatever is lowered first, so a function's IR and
	// its key in the BundleCache are too)
	static var sites = new Map<Int, core.Globals.Pos>();
	// (by file, then pmin, then pmax; a file's hash)
	static var siteIds = new Map<String, {hash:Int, ids:Map<Int, Map<Int, Int>>}>();

	static function site(p:core.Globals.Pos):Int {
		var f = siteIds.get(p.pfile);
		if (f == null) {
			var h = 0x811c9dc5;
			for (i in 0...p.pfile.length)
				h = (h ^ StringTools.fastCodeAt(p.pfile, i)) * 0x01000193;
			siteIds.set(p.pfile, f = {hash: h, ids: new Map()});
		}
		var byMin = f.ids.get(p.pmin);
		if (byMin == null) f.ids.set(p.pmin, byMin = new Map());
		var id = byMin.get(p.pmax);
		if (id == null) {
			var h = (f.hash ^ p.pmin) * 0x01000193;
			h = (h ^ p.pmax) * 0x01000193;
			id = (h ^ (h >>> 15)) & 0x3fffffff;
			while (id == 0 || sites.exists(id))
				id = (id + 1) & 0x3fffffff;
			sites.set(id, p);
			byMin.set(p.pmax, id);
		}
		return id;
	}

	// the macro context, the API of the call being made, the API's functions by name
	var com:Null<context.Common.CommonContext> = null;
	var api:Null<CompilerApi> = null;
	var apiTable = new Map<String, Dynamic>();
	// the compilation's arguments (Sys.args in macros: EvalContext.args)
	var args:Array<String> = [];
	// the macro context's types given their filters (ready), by path
	var processed = new Map<String, ModuleType>();
	// their modules' ids: a type typed again in another compilation starts a new generation
	var mIds = new Map<String, Int>();
	// a compilation began (doReuse) and no generation began since
	var reused = false;
	// the types this compilation handed over so far (a new generation keeps
	// those; the others are handed over again if the compilation has them)
	var delivered = new Map<String, Bool>();
	// the static initializers of the classes loaded, by class path (run again by
	// doReuse, as EvalMain.doReuse resets the static prototypes): a class's from
	// the generation that loaded it last, while its module is the same (a new
	// generation carries its statics over: Loader, facts.globals' keep), as
	// Eval keeps the prototype of a type not typed again
	var inits = new Map<String, {p:Ptr, key:Int, mId:Int}>();
	// the classes whose statics a bundle has, with their modules' ids (a new
	// generation keeps them while the module is the same: Loader, facts.globals' keep)
	var withStatics = new Map<String, Int>();
	// (the initializers of no class: Lower.reflectEnum's, this generation's)
	var plainInits:Array<Ptr> = [];
	// the order the types were handed over in (EvalPrototype.addTypes initializes
	// a batch's classes in it): a bundle's static initializers run in it
	var deliveredAt = new Map<String, Int>();
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
	// the compiled functions kept across builds (null: off)
	var cache:Null<BundleCache> = null;
	var cacheOpened = false;
	// the size of a function's IR (its Fingerprint's words) above which it is
	// compiled without the optimizer: the giant functions macros that write
	// code are made of (json2object's DataBuilder: 9,000 to 73,000 words, run
	// a few times each) cost their compilation most, and the optimizer gains
	// them nothing measurable; the functions of compute-bound macros are far
	// below (json's, mandelbrot's: under 3,000). HXMC_MIR_COLD=<words>, 0:
	// every function optimized
	static var coldWords:Int = {
		var n = Std.parseInt(Sys.getEnv("HXMC_MIR_COLD") ?? "");
		n == null ? COLD_WORDS : n;
	}
	static inline var COLD_WORDS = 8000;
	// a function is compiled the first time it is called (a bundle has a stub
	// of it, InterpGen.stub, LAZY k: compileLazy), but for the static
	// initializers, which its load runs; most functions a bundle reaches never
	// run (the formatter's macros: 65 of 212). HXMC_MIR_LAZY=0: every
	// function compiled with its bundle
	static var lazyOn = Sys.getEnv("HXMC_MIR_LAZY") != "0";
	// the functions not compiled yet, by stub number, with their bundle's step
	var lazies:Array<{f:FuncInfo, key:Null<String>, cold:Bool, step:StepState}> = [];
	// (the native tier compiles with the same steps: one lock)
	static final lazyLock = Tier.lock;
	// (the generation's latest step: what compiles its functions later)
	var lineage:Null<{latest:StepState}> = null;
	var lazyCompiled = 0;
	// a compilation error was reported: no more macro calls (as Eval's had_error)
	var hadError = false;
	var tCompile = 0.0;
	// (HXMC_MACRO_STATS: seconds by phase)
	var phases = new Map<String, Float>();
	var tPhase = 0.0;

	inline function phase(name:String) {
		if (stats) {
			var t = haxe.Timer.stamp();
			if (tPhase > 0) phases.set(name, (phases.exists(name) ? phases.get(name) : 0.0) + t - tPhase);
			tPhase = t;
		}
	}
	var steps = 0;

	public function new() {}

	public static function install(std:Null<String>) {
		hxmcStd = std;
		self = new MirMacros();
		macros.MacroEngine.engine = self;
		macros.MacroApi.MacroApiImpl.nativeValues = true;
		typing.MacroContext.macroPlatformHook = setupPlatform;
		// (the runtime's functions the compiler has: not typed, MacroRuntime)
		MacroRuntime.install();
		var table = macros.MacroApi.MacroApiImpl.macroApi(() -> self.api.getCom(), () -> self.api);
		for (e in table)
			self.apiTable.set(e.name, e.value);
		// (the call site of the function calling the API: EvalMain.get_api_call_pos)
		macros.MacroApi.MacroNativeValues.apiCallPos = () -> current > 0 && sites.exists(current) ? sites.get(current) : self.api == null ? core.Globals.nullPos : self.api.pos;
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
		// (the API's functions: the compiler's own code, not hxmc.rt.EvalCompat's)
		macros.MacroApi.MacroNativeValues.apiCall = call -> {
			var order = hxmc.rt.EvalCompat.on;
			hxmc.rt.EvalCompat.on = false;
			var r:Dynamic = try call() catch (x:Dynamic) {
				hxmc.rt.EvalCompat.on = order;
				// (no handler of the macro code catches the compiler's own exceptions)
				if (self.compilerOwn(x)) hxmc.rt.Interp.uncatchable = x;
				// (its stack: from here, the macro code's call, hxmc.rt.Stacks.recordThrow)
				throw x;
			}
			hxmc.rt.EvalCompat.on = order;
			r;
		};
		// (a macro function the compiler calls back: macro code, as Eval shows values: hxmc.rt.EvalCompat)
		macros.MacroApi.MacroNativeValues.callback = call -> {
			var order = hxmc.rt.EvalCompat.on;
			hxmc.rt.EvalCompat.on = true;
			var r:Dynamic = try call() catch (x:Dynamic) {
				hxmc.rt.EvalCompat.on = order;
				// (Context.error's: no value, EvalMisc.prepare_callback's catch_exceptions)
				if (Std.isOfType(x, macros.MacroApi.Abort)) return null;
				// (an exception of the macro code: a compiler error there, with no macro call's position)
				throw self.toCompilerError(x, null);
			}
			hxmc.rt.EvalCompat.on = order;
			r;
		};
		hxmc.rt.Interp.lazyHook = (k, desc, regs) -> self.compileLazy(k, desc, regs);
		// (hot functions compiled to native code: interp.Tier)
		Tier.install();
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
		if (hxmcStd == null) throw "-D hxmc.macros=mir: hxmc's std is unknown (HXMC_STD)";
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
		// (the compiler's own target: the macro code runs in it, with its layouts and convention)
		if (!core.Define.rawDefined(com2.defines, "hxmc.target")) {
			core.Define.rawDefineValue(com2.defines, "hxmc.target", Options.host());
			var t = Mem.target();
			if ((t == 7 || t == 8) && !core.Define.rawDefined(com2.defines, "hxmc.libc")) core.Define.rawDefineValue(com2.defines, "hxmc.libc", "glibc");
		}
	}

	// ---- the API of hxmc.MacroHost

	@:hxmc.export("hxmc_mir_macro_load") static function load(name:String, nargs:Int):Dynamic {
		var f = self.apiTable.get(name);
		if (f == null) throw "Could not find macro function \"" + name + "\"";
		return f;
	}

	@:hxmc.export("hxmc_mir_macro_pos") static function mkPos(file:String, min:Int, max:Int):Dynamic
		return ({pfile: file, pmin: min, pmax: max} : core.Globals.Pos);

	// Sys in macro code as Eval's (EvalStdLibB.StdSys): the request's streams, the
	// compilation's arguments, its commands (com.runCommand), its end (SysExit);
	// the process's own when another engine (Eval) runs the macro code
	static function io():Null<compiler.io.CompilerIo.CompilerIoData>
		return self == null || self.api == null || macros.MacroEngine.engine != self ? null : self.api.getCom().requestScope.io;

	@:hxmc.export("hxmc_mir_macro_stdout") static function stdout():haxe.io.Output {
		var io = io();
		return io == null ? Sys.stdout() : compiler.io.CompilerIo.getStdout(io);
	}

	@:hxmc.export("hxmc_mir_macro_stderr") static function stderr():haxe.io.Output {
		var io = io();
		return io == null ? Sys.stderr() : compiler.io.CompilerIo.getStderr(io);
	}

	@:hxmc.export("hxmc_mir_macro_stdin") static function stdin():haxe.io.Input {
		var io = io();
		return io == null ? Sys.stdin() : compiler.io.CompilerIo.getStdin(io);
	}

	@:hxmc.export("hxmc_mir_macro_print") static function print(s:String):Void {
		var io = io();
		if (io == null) Sys.print(s) else compiler.io.CompilerIo.writeOut(io, s);
	}

	@:hxmc.export("hxmc_mir_macro_get_char") static function getChar(echo:Bool):Int {
		var io = io();
		return io == null ? Sys.getChar(echo) : compiler.io.CompilerIo.getch(io, echo);
	}

	@:hxmc.export("hxmc_mir_macro_args") static function sysArgs():Array<String>
		return io() == null ? Sys.args() : self.args.copy();

	@:hxmc.export("hxmc_mir_macro_command") static function command(cmd:String):Int
		return io() == null ? Sys.command(cmd) : self.api.getCom().runCommand(cmd);

	@:hxmc.export("hxmc_mir_macro_exit") static function exit(code:Int):Void {
		if (io() == null) Sys.exit(code);
		throw new macros.eval.EvalTypes.SysExit(code);
	}

	@:hxmc.export("hxmc_mir_macro_program_path") static function programPath():Null<String> {
		// (as Eval's Sys.programPath: EvalStdLibB.StdSys.programPath)
		var file:Null<String> = self.api.getCom().main.mainFile;
		return file == null ? null : core.Path.getFullPath(file);
	}

	// ---- the engine (macros.MacroEngine.IMacroEngine)

	public function create(com:context.Common.CommonContext, api:CompilerApi, isMacro:Bool, args:Array<String>):macros.eval.EvalContext.Context {
		this.com = com;
		this.api = api;
		this.args = args;
		// (a new interpreter, as Eval's context is new: what the previous ones
		// compiled is dropped, their types handed over again)
		if (processed.keys().hasNext()) {
			newGeneration();
			processed = new Map();
			mIds = new Map();
			inits = new Map();
			withStatics = new Map();
		}
		reused = false;
		delivered = new Map();
		// (the macro context's handle: only MacroContext keeps it)
		return cast this;
	}

	public function init(ctx:macros.eval.EvalContext.Context):Void {}

	public function addTypes(ctx:macros.eval.EvalContext.Context, types:Array<ModuleType>, ready:ModuleType->Void):Void {
		for (t in types) {
			var k = core.Globals.sTypePath(core.TFunctions.tPath(t));
			var m = core.TFunctions.tInfos(t).mtModule.mId;
			delivered.set(k, true);
			if (processed.exists(k)) {
				if (mIds.get(k) == m) continue;
				// (the first of this compilation: once a compilation)
				if (reused) newGeneration();
				reused = false;
			}
			// (a class typed again: its statics start again, EvalPrototype.addTypes' static_prototypes#remove)
			var x = inits.get(k);
			if (x != null && x.mId != m) inits.remove(k);
			if (withStatics.exists(k) && withStatics.get(k) != m) withStatics.remove(k);
			processed.set(k, t);
			mIds.set(k, m);
			deliveredAt.set(k, nDelivered++);
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

	var nDelivered = 0;

	public function doReuse(ctx:macros.eval.EvalContext.Context, api:CompilerApi, args:Array<String>):Void {
		hadError = false;
		this.api = api;
		this.args = args;
		reused = true;
		delivered = new Map();
		// (the statics' initial values again: EvalMain.doReuse's staticPrototypes.reset)
		var order = hxmc.rt.EvalCompat.on;
		hxmc.rt.EvalCompat.on = true;
		// (in the order of the paths' hashes, descending: static_prototypes#reset walks an IntMap, Globals.IntMap)
		var resets = [for (x in inits) x];
		resets.sort((a, b) -> a.key > b.key ? -1 : a.key < b.key ? 1 : 0);
		try {
			for (p in plainInits)
				hxmc.macro.Loader.run0(p);
			for (x in resets)
				hxmc.macro.Loader.run0(x.p);
		} catch (x:Dynamic) {
			hxmc.rt.EvalCompat.on = order;
			throw toCompilerError(x, api);
		}
		hxmc.rt.EvalCompat.on = order;
	}

	// the macro context typed again (another compilation: --next, the compilation
	// server), as EvalPrototype.addTypes drops the prototypes of a type whose module
	// is another: what was compiled is dropped, compiled again as it is needed
	function newGeneration() {
		if (stats) Sys.stderr().writeString("hxmc.macros=mir: new generation, spare entries taken " + hxmc.macro.Loader.used() + ", globals " + @:privateAccess hxmc.rt.Gc.nglobals + " of " + @:privateAccess hxmc.rt.Gc.globalsCap + "\n");
		hxmc.macro.Loader.newGeneration();
		// (the types of earlier compilations this one has not handed over: not lowered
		// in the new generation, unless the compilation hands them over again)
		for (k in [for (k in processed.keys()) k])
			if (!delivered.exists(k)) {
				processed.remove(k);
				mIds.remove(k);
			}
		l = null;
		opts = null;
		lineage = null;
		compiled = new Map();
		native = new Map();
		entries = new Map();
		scanned = new Map();
		lastPrep = null;
		stdRoots = [];
		plainInits = [];
		macros.MacroApi.MacroNativeValues.reset();
		macros.MacroApi.MacroNativeValues.dropValues();
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
			// (Context.error's: reported, the call has no value, EvalExceptions.catch_exceptions)
			if (Std.isOfType(x, macros.MacroApi.Abort)) return None;
			throw toCompilerError(x, api);
		}
	}

	// an exception of the compiler's own, of a class the macro context does not
	// know: as Eval's OCaml exceptions, no macro code catches it and the
	// compiler gets it as it is (Sedlexing.MalFormed from Context.parse)
	function compilerOwn(x:Dynamic):Bool
		return Reflect.isObject(x) && Type.getClass(x) != null && !processed.exists(Type.getClassName(Type.getClass(x)));

	// an exception of the macro code, uncaught: a haxe.macro.Error as the
	// compiler's error at its position (with its child errors), anything else
	// as an uncaught exception at the line of its innermost frame of macro
	// code, then where each caller of that frame was, the macro call last
	// (hxmc.rt.Stacks: the last throw's stack, the interpreter's frames in it)
	function toCompilerError(x:Dynamic, api:Null<CompilerApi>):Dynamic {
		if (Std.isOfType(x, core.Error.TypingError) || Std.isOfType(x, core.Error.FatalError) || Std.isOfType(x, macros.MacroApi.Abort) || Std.isOfType(x, macros.eval.EvalTypes.SysExit) || compilerOwn(x)) return x;
		var at = api != null ? api.pos : core.Globals.nullPos;
		var c = macros.MacroApi.MacroNativeValues.resolveClass("haxe.macro.Error");
		if (c != null && Std.isOfType(x, c)) {
			var pos:core.Globals.Pos = Reflect.field(x, "pos");
			var children:Null<Array<Dynamic>> = Reflect.field(x, "childErrors");
			var sub = children == null ? [] : [
				for (e in children)
					core.Error.makeError(Custom(exceptionMessage(e)), Reflect.field(e, "pos"))
			];
			return new core.Error.TypingError(core.Error.makeError(Custom(exceptionMessage(x)), pos == null ? at : pos, sub));
		}
		var frames = thrownFrames();
		// (the callers, outermost first: the compiler shows a sub-error list from
		// its end; a frame repeated, once with its count)
		var sub = frames.length > 0 && api != null ? [core.Error.makeError(Custom("Called from here"), at)] : [];
		var k = frames.length - 1;
		while (k >= 1) {
			var f = frames[k], n = 1;
			while (k - n >= 1 && frames[k - n].name == f.name && frames[k - n].pos.pmin == f.pos.pmin && frames[k - n].pos.pfile == f.pos.pfile)
				n++;
			sub.push(core.Error.makeError(Custom("Called from " + f.name + (n > 1 ? ' ($n times)' : "")), f.pos));
			k -= n;
		}
		return new core.Error.TypingError(core.Error.makeError(Custom("Uncaught exception " + Std.string(x)), frames.length > 0 ? frames[0].pos : at, sub));
	}

	// (hxmc's haxe.Exception keeps it in a field, `message` its getter)
	static function exceptionMessage(x:Dynamic):String {
		var m:Null<String> = Reflect.field(x, "__exceptionMessage");
		return m != null ? m : Std.string(Reflect.field(x, "message"));
	}

	// the last throw's frames of macro code (the interpreted ones: the
	// compiler's are its own), innermost first, each at its line
	static function thrownFrames():Array<{name:String, pos:core.Globals.Pos}> {
		var b = hxmc.rt.Stacks.lastThrow();
		var r = [];
		var k = 0;
		while (k < b.length >> 3) {
			// (interpreted, or compiled by the native tier: the same frames, interp.Tier)
			var loaded = hxmc.rt.Stacks.loaded(b, k);
			var d = hxmc.rt.Stacks.frame(b, k);
			k = hxmc.rt.Stacks.frameEnd(b, k);
			if (!loaded || d == null || d.file == null || hxmc.rt.Stacks.internal(d.name)) continue;
			r.push({name: d.name, pos: linePos(d.file, d.line)});
		}
		return r;
	}

	// line `line` of a file, from its start to its end
	static function linePos(file:String, line:Int):core.Globals.Pos {
		var lines = syntax.Lexer.findFile(file).llines;
		for (k in 0...lines.length)
			if (lines[k].line == line) return new core.Globals.Pos(file, lines[k].offset, k + 1 < lines.length ? lines[k + 1].offset - 1 : lines[k].offset);
		return new core.Globals.Pos(file, 0, 0);
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
			case _: throw "-D hxmc.macros=mir: no class " + name + " in the macro context";
		}
	}

	function entry(path:Array<String>, f:String):{fi:FuncInfo, desc:Ptr} {
		var key = path.join(".") + "." + f;
		var e = entries.get(key);
		if (e != null) return e;
		var c = findClass(path);
		var cf = c.clStatics.get(f);
		if (cf == null) throw "-D hxmc.macros=mir: no static " + key;
		var t0 = haxe.Timer.stamp();
		if (l == null) start();
		hxmc.ir.Lower.basic = com.basic;
		var fi = l.staticFunc(c, cf);
		build(c);
		var d = hxmc.macro.Loader.xb.get(InterpGen.DESC + lastPrep.funcSym(fi));
		if (d == null) throw "-D hxmc.macros=mir: " + key + " was not loaded";
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
		if (typingBodies) throw "-D hxmc.macros=mir: a macro called while the macro context types the std's bodies Mir macros lower (hxmc.interp.MacroRuntime; HXMC_MIR_LAZY_BODIES=0 types them all first)";
		hxmc.ir.Lower.basic = com.basic;
		scan();
		hxmc.ir.Lower.callSites = {site: site, pending: "hxmc_mir_macro_pending", current: "hxmc_mir_macro_current", wants: wantsSites};
		// (the lines of the code, as a native build's: hxmc.rt.Stacks names an interpreted frame by them)
		hxmc.ir.Lower.lines = true;
		hxmc.ir.Lower.bodyReady = MacroRuntime.ready;
		hxmc.ir.Lower.classSpans = false;
		phase("before lowering");
		try {
			l.drain();
			// (the std's bodies the macro context has not typed: typed, the types
			// they load handed over, then lowered with what they reach)
			while (l.deferred.length > 0) {
				rounds++;
				phase("lowering");
				typingBodies = true;
				MacroRuntime.typeBodies([for (d in l.deferred) d.cf]);
				typingBodies = false;
				phase("typing the std's bodies");
				scan();
				l.resume();
				l.drain();
			}
			l.finish();
			phase("lowering");
		} catch (e:Dynamic) {
			typingBodies = false;
			hxmc.ir.Lower.callSites = null;
			hxmc.ir.Lower.bodyReady = null;
			hxmc.ir.Lower.classSpans = true;
			throw e;
		}
		hxmc.ir.Lower.callSites = null;
		hxmc.ir.Lower.bodyReady = null;
		hxmc.ir.Lower.classSpans = true;
		step(main);
	}

	// (MacroRuntime.typeBodies running: what macro code it would call finds bodies not lowered)
	var typingBodies = false;
	// (HXMC_MACRO_STATS: the bodies' typings between drains)
	var rounds = 0;

	// the types handed over since the last scan: the macro API's (its enums,
	// Error's constructor), the runtime's implementations (Lower.findHosts)
	function scan() {
		var fresh = [for (k => t in processed) if (!scanned.exists(k)) t];
		for (k in processed.keys())
			scanned.set(k, true);
		for (t in fresh)
			switch t {
				case TEnumDecl(en) if (apiType(t)):
					l.enumInfo(en);
				case TClassDecl(k) if (apiType(t)):
					l.classInfo(k);
					// (its constructor's entry: the compiler makes the errors it raises into
					// macro code with Type.createInstance, MacroNativeValues.compilerError)
					@:privateAccess l.maker(k);
				case _:
			}
		l.findHosts(fresh);
	}

	function start() {
		opts = Options.read(com);
		opts.interp = "1";
		var abi = Abi.get(opts.target);
		hxmc.ir.Lower.targetOs = abi.osCode();
		hxmc.ir.Lower.targetArm = abi.arm ? 1 : 0;
		hxmc.ir.Lower.targetCode = MirBuild.targetCode(abi);
		hxmc.ir.Lower.targetPlatform = abi.platformCode();
		hxmc.ir.Lower.mirHost = 0; // (a bundle: code loaded, not a loader)
		hxmc.ir.Lower.bounds = opts.bounds;
		hxmc.ir.Lower.resources = [];
		hxmc.ir.Lower.basic = com.basic;
		l = new hxmc.ir.Lower();
		// (each compilation hands over the types of a module not typed again as other objects)
		l.samePaths = true;
		if (hxmc.ir.Lower.hostOverrides == null) hxmc.ir.Lower.hostOverrides = hxmc.macro.Loader.hostOverrides();
		for (cp in com.classPaths.asList())
			if (cp.path != "" && (cp.scope == Std || sys.FileSystem.exists(haxe.io.Path.addTrailingSlash(cp.path) + "hxmc/rt/Runtime.hx")))
				stdRoots.push(cp.path);
	}

	// the functions whose calls note their sites (Lower.callSites): not the
	// runtime's, nor the std's but for the macro API's (its own calls of
	// the API: Compiler.keep's addGlobalMetadata), so that the std's may be
	// the compiler's (MirRun.hostFunctions: the same code)
	function wantsSites(f:FuncInfo):Bool {
		if (hxmc.macro.BundleFacts.runtime(f)) return false;
		if (f.pos == null || f.module == null || StringTools.startsWith(f.module, "haxe.macro.")) return true;
		for (r in stdRoots)
			if (StringTools.startsWith(f.pos.pfile, r)) return false;
		return true;
	}

	// the functions lowered since the last step: a bundle, loaded
	function step(main:Null<TClass>) {
		steps++;
		var prog = l.prog;
		phase("step start");
		var d = new Driver(prog, "", opts);
		phase("driver (Prep)");
		d.inlineCandidates();
		phase("inline candidates");
		var prep = d.prep;
		lastPrep = prep;
		var e = prep.e;
		var host = hxmc.macro.Loader.hostSyms();
		InterpGen.emulatedTls = new Map();
		InterpGen.nativeTls = s -> {
			var h = host.get(s);
			h != null && h.k == "l";
		};
		var funcs = [for (f in prog.funcs) if (!compiled.exists(f) && (!hxmc.macro.BundleFacts.runtime(f) || !host.exists(e.symbol(f)))) f];
		// (the keys of the functions' objects, BundleCache: with the digests of the callees they may inline)
		if (cache == null && !cacheOpened) {
			cacheOpened = true;
			cache = BundleCache.open(com, Abi.get(opts.target).arm);
		}
		var inlined:Null<Fingerprint.Inlined> = null;
		if (cache != null && MirBuild.inlineCands != null) {
			var cands = MirBuild.inlineCands;
			inlined = new Fingerprint.Inlined(prep, haxe.ds.Vector.fromArrayCopy([for (f in prog.funcs) if (cands.exists(f)) f]));
			var dd = Inline.DEPTH;
			while (dd >= 1) {
				for (k in 0...inlined.funcs.length)
					inlined.compute(dd, k);
				dd--;
			}
		}
		var tk = cache == null ? null : d.toolKey() + "mir-bundle|opt=" + (opts.opt ? 1 : 0) + "|bounds=" + opts.bounds + "|";
		var keys = new Map<FuncInfo, String>();
		// (the functions compiled without the optimizer: COLD_WORDS)
		var cold = new Map<FuncInfo, Bool>();
		for (f in funcs) {
			var fp = new Fingerprint(prep, inlined);
			if (tk != null) fp.text(tk);
			fp.func(f);
			// (the size of its own IR, without the inlined callees' digests nor
			// its lines, Lower.lines: a statement's file would count again)
			var own = new Fingerprint(prep, null, false);
			own.func(f);
			var size = @:privateAccess own.words;
			if (opts.opt && coldWords > 0 && size > coldWords) {
				cold.set(f, true);
				fp.text("|cold");
			}
			if (tk != null) keys.set(f, fp.key());
			var k = 0;
			while (k < fp.newStrings.length) {
				prep.addStr(fp.newStrings[k], fp.newStrings[k + 1]);
				k += 2;
			}
		}
		// (the types handed over so far: com.types may not have them yet)
		phase("fingerprints");
		var types = [for (t in processed) t];
		// (the static initializers in the order their classes were handed over)
		var at = new Map<FuncInfo, Int>();
		for (i in 0...prog.inits.length)
			at.set(prog.inits[i], i);
		var rank = (f:FuncInfo) -> {
			var c = l.initOf.get(f);
			var d = c == null ? null : deliveredAt.get(core.Globals.sTypePath(c.clPath));
			c == null ? -1 : d == null ? nDelivered : d;
		};
		prog.inits.sort((a, b) -> {
			var x = rank(a), y = rank(b);
			x != y ? x - y : at.get(a) - at.get(b);
		});
		// (a class whose statics an earlier generation has, its module the same: kept)
		var kept = (c:TClass) -> withStatics.get(core.Globals.sTypePath(c.clPath)) == c.clModule.mId;
		var facts:Dynamic = hxmc.macro.BundleFacts.facts(com, prog, e, l, main, types, kept);
		MirRun.unshare(facts, host, l, e, com, types);
		// (the std's functions the compiler has alike: its native code; HXMC_MIR_HOST=0: all interpreted)
		phase("facts");
		var ownRuntime = opts.bounds != 0 ? ["hxmc.rt.Dyn" => true, "hxmc.rt.NArray" => true] : new Map<String, Bool>();
		var found = Sys.getEnv("HXMC_MIR_HOST") == "0" ? new Map() : MirRun.hostFunctions(funcs, facts, prep, e, com, ownRuntime, native);
		for (f => _ in found) {
			native.set(f, true);
			compiled.set(f, true);
		}
		funcs = [for (f in funcs) if (!found.exists(f)) f];
		phase("host functions");
		d.interp = new InterpGen.InterpSet(opts.interp, prep, MirRun.notHere(prog, funcs, compiled, native), true);
		var abi = Abi.get(opts.target);
		var obj = new Obj();
		var st = new StepState(d, abi, opts, cache);
		if (lineage == null) lineage = {latest: st};
		lineage.latest = st;
		st.lineage = lineage;
		// (compiled with the bundle: the static initializers, which run as it
		// loads, and the functions whose calls are no GC point, Facts.GcPoints:
		// their callers keep references in registers across them, which a
		// collection while compiling would leave pointing at what it moved)
		var initFns = new Map<FuncInfo, Bool>();
		for (f in prog.inits)
			initFns.set(f, true);
		var stubs = 0;
		for (f in funcs) {
			var key = keys.get(f);
			var sym = prep.funcSym(f);
			if (lazyOn && !initFns.exists(f) && !(f.noGc && !f.blocks) && InterpGen.stub(obj, abi, f, sym, lazies.length)) {
				lazies.push({f: f, key: key, cold: cold.exists(f), step: st});
				// (kept in the store's list: a later build may call it)
				if (key != null) cache.keep(key);
				stubs++;
				continue;
			}
			st.compile(f, sym, key, cold.exists(f), obj);
		}
		if (cache != null) {
			cache.record();
			// (a server build has no end where ModuleCache.finish settles the store)
			if (Driver.resident) CacheDir.settle();
		}
		phase("functions");
		// (no native code: the signatures' trampolines interpreted too, the allocations' slow paths and the
		// expansions the interpreter's own, InterpGen)
		var dg = new DataGen(prep, abi, obj, mf -> d.compileInterp(mf, obj));
		for (s in prog.sigs) {
			d.compileInterp(dg.dynTrampoline(s), obj);
			d.compileInterp(dg.boundTrampoline(s), obj);
		}
		dg.stringsUsed();
		dg.cstrLiterals([]);
		dg.emptyArrays([]);
		dg.resources([]);
		phase("data, trampolines");
		st.gen = hxmc.macro.Loader.gen();
		var b = hxmc.macro.Loader.loadObj(obj, facts);
		phase("load");
		codeBytes += b.codeBytes;
		dataBytes += b.dataBytes;
		for (i in 0...b.inits.length) {
			var path = b.initPaths[i];
			if (path == null) plainInits.push(b.inits[i]) else inits.set(path, {p: b.inits[i], key: b.initKeys[i], mId: b.initMods[i]});
		}
		for (_ => c in l.globalOwner)
			withStatics.set(core.Globals.sTypePath(c.clPath), c.clModule.mId);
		for (f in funcs)
			compiled.set(f, true);
		// (each may be compiled to native code once it is called often: interp.Tier)
		if (Tier.on()) {
			var site = new MacroSite(st);
			for (f in funcs) {
				var x = hxmc.macro.Loader.xb.get(InterpGen.DESC + prep.funcSym(f));
				if (x != null && !initFns.exists(f)) Tier.add(Ptr.ofI64(x.v), f, site, !cold.exists(f));
			}
			Tier.loaded();
		}
		macros.MacroApi.MacroNativeValues.reset();
		if (stats) Sys.stderr().writeString('hxmc.macros=mir: step $steps: ${funcs.length} functions (${Lambda.count(found)} native, $stubs compiled when first called), ${b.codeBytes} bytes of code, ${b.dataBytes} of data\n');
	}

	// (hxmc.rt.Interp.lazyHook) the function of stub k called the first time
	// (its stub desc, its arguments in regs): compiled as its bundle would have
	// (with its generation's latest step: each step's Prep numbers the
	// program's types again, in its objects), loaded (Loader.loadLate) and
	// desc made its descriptor
	function compileLazy(k:Int, desc:Ptr, regs:Ptr) {
		var t0 = haxe.Timer.stamp();
		var p = lazies[k];
		var f = p.f;
		var st = p.step.lineage.latest;
		var sym = st.d.prep.funcSym(f);
		// (the arguments' references, kept across the collections compiling
		// makes: rooted before anything is allocated, which may collect and
		// move them while regs still has their old addresses)
		var refs = Tier.root(f, regs);
		// (macro code's threads: one compiles, the others find it compiled)
		lazyLock.acquire();
		if (!hxmc.rt.Interp.isStub(desc)) {
			lazyLock.release();
			Tier.unroot(f, regs, refs);
			return;
		}
		var order = hxmc.rt.EvalCompat.on;
		hxmc.rt.EvalCompat.on = false;
		try {
			// (HXMC_MIR_TIER=native: to native code instead, the interpreter's when that fails)
			if (!Tier.compileStub(desc, !p.cold)) {
				st.enter();
				var obj = new Obj();
				st.compile(f, sym, p.key, p.cold, obj);
				// (the literals of a kept object: its step's fingerprints named them, in its Prep)
				if (p.step != st)
					for (s in obj.symbols) {
						var lit = s.section == null && !s.abs && !st.d.prep.e.strByName.exists(s.name) ? p.step.d.prep.e.strByName.get(s.name) : null;
						if (lit != null) st.d.prep.addStr(lit, s.name);
					}
				var dg = new DataGen(st.d.prep, st.abi, obj, mf -> st.d.compileInterp(mf, obj));
				dg.stringsUsed();
				dg.cstrLiterals([]);
				dg.emptyArrays([]);
				dg.resources([]);
				hxmc.rt.Interp.become(desc, hxmc.macro.Loader.loadLate(obj, InterpGen.DESC + sym, st.gen));
				st.leave();
			}
		} catch (x:Dynamic) {
			st.leave();
			hxmc.rt.EvalCompat.on = order;
			lazyLock.release();
			// (the compiler's failure: no handler of the macro code catches it)
			hxmc.rt.Interp.uncatchable = x;
			throw x;
		}
		if (st.cache != null && Driver.resident) CacheDir.settle();
		hxmc.rt.EvalCompat.on = order;
		lazyLock.release();
		Tier.unroot(f, regs, refs);
		lazyCompiled++;
		var dt = haxe.Timer.stamp() - t0;
		tCompile += dt;
		if (stats) phases.set("compiled when first called", (phases.exists("compiled when first called") ? phases.get("compiled when first called") : 0.0) + dt);
	}

	// the bytes of the bundles loaded (code: always 0, interp.InterpAbi)
	var codeBytes = 0;
	var dataBytes = 0;

	// a macro function called with the compiler's values: its arguments as
	// the interpreter's words (hxmc.rt.Interp.enter), its result back
	function call(fi:FuncInfo, desc:Ptr, args:Array<Dynamic>, api:CompilerApi):Dynamic {
		var n = fi.args.length;
		// (the macro function's site: the macro call's position, as
		// EvalMain.callPath's frame has it; before the addresses are written,
		// as it may allocate: a collection then would leave them stale)
		pending = site(api.pos);
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
		// (no collection between the addresses written and the frame taking them;
		// the macro code sees values as Eval shows them: hxmc.rt.EvalCompat)
		var order = hxmc.rt.EvalCompat.on;
		hxmc.rt.EvalCompat.on = true;
		try
			hxmc.rt.Interp.enter(desc, buf)
		catch (x:Dynamic) {
			hxmc.rt.EvalCompat.on = order;
			hxmc.rt.Interp.uncatchable = null;
			LibC.free(buf);
			// (passed on: its stack goes on from its throw's, Stacks.rethrowing)
			hxmc.rt.Stacks.rethrowing = true;
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
		if (stats && steps > 0) {
			Sys.stderr().writeString('hxmc.macros=mir: ${steps} steps, compile ${Std.int(tCompile * 1000)} ms, spare entries taken ${hxmc.macro.Loader.used()}\n');
			Sys.stderr().writeString('hxmc.macros=mir: functions compiled when first called: ${lazyCompiled} of ${lazies.length} (${hxmc.macro.Loader.lateBytes} bytes)\n');
			if (Tier.on()) Sys.stderr().writeString('hxmc.macros=mir: ' + Tier.report() + '\n');
			Sys.stderr().writeString('hxmc.macros=mir: the std\'s bodies typed when asked for: ${MacroRuntime.lazyTyped} of ${MacroRuntime.lazyCount} ($rounds rounds)\n');
			if (cache != null) Sys.stderr().writeString('hxmc.macros=mir: functions kept (BundleCache): ${cache.hits} found, ${cache.misses} compiled\n');
			Sys.stderr().writeString('hxmc.macros=mir: bundles: ${codeBytes} bytes of code, ${dataBytes} bytes of data; ${hxmc.rt.Interp.entriesGiven} entries for native callers (${hxmc.rt.Interp.entriesByPool()}); host table ${hxmc.macro.HostTable.count()} symbols, ${hxmc.macro.HostTable.bytes()} bytes, ${hxmc.macro.HostTable.lookups} lookups in ${Std.int(hxmc.macro.HostTable.lookupTime * 1e6)} us\n');
		}
		if (stats)
			for (k => v in phases)
				Sys.stderr().writeString('  ${k}: ${Std.int(v * 1000)} ms\n');
	}
}

// (interp.Tier) a step's functions compiled to native code: with the latest
// step of their generation, as compileLazy compiles them
@:access(hxmc.Driver)
private class MacroSite extends Tier.TierSite {
	final own:StepState;

	public function new(own) {
		super();
		this.own = own;
	}

	override function driver():Driver
		return own.lineage.latest.d;

	override function gen():hxmc.macro.Loader.Gen
		return own.lineage.latest.gen;

	override function enter()
		own.lineage.latest.enter();

	override function leave()
		own.lineage.latest.leave();

	// (the literals its own step's fingerprints named, in that step's Prep)
	override function literals(obj:Obj) {
		var st = own.lineage.latest;
		if (own != st)
			for (s in obj.symbols) {
				var lit = s.section == null && !s.abs && !st.d.prep.e.strByName.exists(s.name) ? own.d.prep.e.strByName.get(s.name) : null;
				if (lit != null) st.d.prep.addStr(lit, s.name);
			}
	}
}

// what a step's bundle compiles its functions with, kept for those compiled
// when first called (MirMacros.compileLazy, with the latest step of their
// generation: `lineage`): its driver (the program, its facts, which
// functions are interpreted), the inlining candidates and the thread-local
// variables of its time, the store, and what its generation's bundles share
// (Loader.gen, set as it loads)
@:access(hxmc.Driver)
private class StepState {
	public final d:Driver;
	public final abi:Abi;
	final opts:Options;
	public final cache:Null<BundleCache>;
	public var gen:Null<hxmc.macro.Loader.Gen> = null;
	public var lineage:Null<{latest:StepState}> = null;
	final emit:Target.Emitter;
	final ras:Regalloc.Scratch;
	final cands:Null<Map<FuncInfo, Bool>>;
	final refSlots:Null<Map<Int, haxe.ds.Vector<Bool>>>;
	final tls:Null<Map<String, Int>>;
	final nativeTls:String->Bool;
	// (the statics of the step running when a function is compiled later)
	var saved:Null<Array<Dynamic>> = null;

	public function new(d, abi, opts, cache) {
		this.d = d;
		this.abi = abi;
		this.opts = opts;
		this.cache = cache;
		emit = Target.emitter(abi, new Obj());
		ras = new Regalloc.Scratch(Target.selector(abi));
		cands = MirBuild.inlineCands;
		refSlots = Escape.refSlots;
		tls = InterpGen.emulatedTls;
		nativeTls = InterpGen.nativeTls;
	}

	public function enter() {
		saved = [MirBuild.inlineCands, Escape.refSlots, InterpGen.emulatedTls, InterpGen.nativeTls];
		MirBuild.inlineCands = cands;
		Escape.refSlots = refSlots;
		InterpGen.emulatedTls = tls;
		InterpGen.nativeTls = nativeTls;
	}

	public function leave() {
		if (saved == null) return;
		MirBuild.inlineCands = saved[0];
		Escape.refSlots = saved[1];
		InterpGen.emulatedTls = saved[2];
		InterpGen.nativeTls = saved[3];
		saved = null;
	}

	// f into obj: its object kept under key in the store, or compiled (and kept)
	public function compile(f:FuncInfo, sym:String, key:Null<String>, cold:Bool, obj:Obj) {
		if (key == null) {
			compileFunc(f, cold, obj);
			return;
		}
		// (an object per function, kept or compiled, appended in order: the bundle is the same)
		var fo = cache.get(key, sym, d.interp);
		if (fo == null) {
			fo = new Obj();
			var deps = InterpGen.deps = [];
			try
				compileFunc(f, cold, fo)
			catch (x:Dynamic) {
				InterpGen.deps = null;
				throw x;
			}
			InterpGen.deps = null;
			cache.put(key, sym, fo, deps);
		}
		obj.append(fo);
	}

	function compileFunc(f:FuncInfo, cold:Bool, into:Obj) {
		var opt = opts.opt;
		if (cold) opts.opt = false;
		try
			d.compileFunc(f, into, emit, ras)
		catch (x:Dynamic) {
			opts.opt = opt;
			throw x;
		}
		opts.opt = opt;
	}
}
