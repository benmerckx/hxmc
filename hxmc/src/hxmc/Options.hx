package hxmc;

// What a run of the tool does (Main lists the defines and variables).
class Options {
	public var target = host();
	public var rtObj:Null<String> = null; // the runtime object (default: <target>/rt.o of Options.rtDir)
	public var stats = false;
	public var verbose = false;
	public var segAlign = 0; // -D hxmc.seg-align: the alignment of loadable segments (0: the target's)
	public var strip = true; // no symbol table unless -debug, -D hxmc.symbols or HXMC_SYMBOLS=1
	public var pic = false; // -D hxmc.pic: position-independent executable
	public var shared = false; // -D hxmc.shared: a shared library (Linux in the glibc mode; Android always)
	public var dllBase:Null<String> = null; // -D hxmc.dll-base=0x<hex>: a Windows DLL's preferred base
	public var output:Null<String> = null; // -D hxmc.output=<path>: the output, instead of --custom-target's (a build that names one output and writes another)
	// -D hxmc.exports=<name>[,<name>...]: what a shared library exports (Android: ANativeActivity_onCreate too)
	public var exports:Array<String> = [];
	// -D hxmc.ios-min-version=<major.minor>: the oldest iOS an iOS or Mac Catalyst output runs
	// on (LC_BUILD_VERSION's minimum, LinkMachO.minos; the packager writes
	// the same in the bundle's MinimumOSVersion), 15.0 and the floor; as
	// LinkMachO writes it
	public var iosMinos = LinkMachO.IOS_MIN;
	// a Mach-O output's code signature (CodeSign), for a packager that writes
	// the bundle around it: -D hxmc.codesign-id=<identifier>, -D
	// hxmc.codesign-info-plist=<file> (slot 1), -D
	// hxmc.codesign-resources=<file> (_CodeSignature/CodeResources, slot 3),
	// -D hxmc.codesign-entitlements=<file> (an XML plist, slot 5). Any of them:
	// ad hoc as `codesign -s -` signs (CodeSign.adhoc); none: linker-signed
	public var codesignId:Null<String> = null;
	public var codesignInfoPlist:Null<String> = null;
	public var codesignResources:Null<String> = null;
	public var codesignEntitlements:Null<String> = null;

	public function codesigned():Bool
		return codesignId != null || codesignInfoPlist != null || codesignResources != null || codesignEntitlements != null;
	public var opt = true; // MIR optimizations (HXMC_OPT=0: off)
	// the flags of FLAGS this build sets, +name=value each (Driver.toolKey)
	public var codeKey = "";
	// -D hxmc.loop-version=0: no loop versioning (LoopVersion); =why: why each loop is left alone
	public var loopVersion = true;
	public var loopVersionWhy = false;
	// -D hxmc.compact=0: @:hxmc.compact changes nothing, its reference fields 8 bytes (Main.compactRefs)
	public var compact = true;
	// (experimental) LLVM (docs/plans/llvm.md); flags (Options.flag: a define, else its variable):
	//   hxmc.llvm[=O1|O2|O3|Os]   the functions LlvmGen takes compiled by clang
	//   hxmc.llvm-rt              the runtime's modules too
	//   hxmc.llvm-cpu=<cpu>       clang's -mcpu (arm64) or -march (x86-64): apple-m3, x86-64-v3, native
	//   hxmc.llvm-whole           the whole program one LLVM module
	//   hxmc.llvm-consts          the program-wide numbers as constants
	//   hxmc.llvm-release         both (either compiles LLVM's code after the data, not cached)
	//   hxmc.llvm-tbaa=1|<list>   Mir's memory classes as alias information (LlvmGen.tbaaTag)
	//   hxmc.llvm-flags=<args>    more of clang's arguments, separated by spaces
	//   hxmc.llvm-clang=<path>    the clang (default: clang on the path)
	//   hxmc.llvm-pgo=gen         profile-guided optimization: an instrumented program (LLVM's
	//                             profile runtime linked; it writes default.profraw, or LLVM_PROFILE_FILE;
	//                             macOS, and Linux static with musl: hxmc.rt.Pgo writes it)
	//   hxmc.llvm-pgo=<file>      ... compiled with the profile (llvm-profdata merge -o <file> *.profraw)
	//   hxmc.llvm-inline          LLVM inlines in a program that reads its stacks too (they then lack
	//                             the frames of what it inlined; default: the frames the native code has)
	public var llvm:Null<String> = null;
	public var llvmRt = false;
	public var llvmCpu:Null<String> = null;
	public var llvmWhole = false;
	public var llvmConsts = false;
	public var llvmTbaa:Null<String> = null;
	public var llvmFlags:Null<String> = null;
	public var llvmClang = "clang";
	public var llvmPgo:Null<String> = null;
	public var llvmInline = false;

	// the variable a flag falls back to: HXMC_LOOP_VERSION for hxmc.loop-version
	public static function flagVar(name:String):String
		return name.toUpperCase().split(".").join("_").split("-").join("_");

	// a flag: its define (-D turns the dashes into underscores), else its
	// variable (flagVar); null: neither, or empty. Without defines (read before
	// any build: the up-to-date check, the Mir interpreter's setup): the variable
	public static function flag(name:String, ?defines:core.Define.DefineContext):Null<String> {
		var u = name.split("-").join("_");
		var v = defines != null && core.Define.rawDefined(defines, u) ? core.Define.rawDefinedValue(defines, u) : Sys.getEnv(flagVar(name));
		return v == null || v == "" ? null : v;
	}

	// a switch flag: dflt when unset, else off for 0 and on for anything else
	public static function on(name:String, dflt:Bool, ?defines:core.Define.DefineContext):Bool {
		var v = flag(name, defines);
		return v == null ? dflt : v != "0";
	}

	// the flags that change the code (UpToDate: their variables are in the
	// key; Driver.toolKey: Options.codeKey). (hxmc.checked: the define only, the
	// std reads it too)
	public static final FLAGS = [
		"hxmc.loop-version", "hxmc.opt", "hxmc.frame-pointers", "hxmc.symbols", "hxmc.sroa", "hxmc.escape", "hxmc.escape-hash", "hxmc.escape-no",
		"hxmc.fold", "hxmc.frames-live", "hxmc.inline", "hxmc.devirt", "hxmc.dup-dispatch", "hxmc.dup-min", "hxmc.noshadow", "hxmc.framespill",
		"hxmc.trymem", "hxmc.licm", "hxmc.reach", "hxmc.falign", "hxmc.fshift", "hxmc.wasm-coalesce", "hxmc.interp-coalesce", "hxmc.wasm-stack-kb", "hxmc.nogc",
		"hxmc.checked", "hxmc.compact",
		// (experimental) the LLVM back end's (Options.llvm)
		"hxmc.llvm", "hxmc.llvm-rt", "hxmc.llvm-cpu", "hxmc.llvm-tbaa", "hxmc.llvm-whole", "hxmc.llvm-consts", "hxmc.llvm-release", "hxmc.llvm-flags", "hxmc.llvm-clang", "hxmc.llvm-pgo", "hxmc.llvm-inline"
	];
	// the switches of the passes, read again for each build (a server's too)
	// from its defines, before its typing (TargetFlags' hook): the passes
	// keep them in statics. (HXMC_MIR_TIER, HXMC_MIR_TIER_WINDOW,
	// HXMC_MIR_TYPE_RUNTIME, HXMC_MIR_LAZY_BODIES: the variable only, read
	// once, before any build)
	@:access(hxmc)
	public static function apply(d:core.Define.DefineContext) {
		Escape.on = on("hxmc.escape", true, d);
		var h = flag("hxmc.escape-hash", d);
		Escape.hashRange = h == null ? null : [for (x in h.split("-")) Std.parseInt(x)];
		Escape.no = flag("hxmc.escape-no", d) ?? "";
		Escape.log = on("hxmc.escape-log", false, d);
		Escape.dumpName = flag("hxmc.escape-dump", d);
		Fold.on = on("hxmc.fold", true, d);
		Fold.whyOn = on("hxmc.fold-why", false, d);
		Driver.sroa = on("hxmc.sroa", true, d);
		Driver.nogc = on("hxmc.nogc", false, d);
		Driver.wasmStackKb = flag("hxmc.wasm-stack-kb", d);
		Frames.live = on("hxmc.frames-live", true, d);
		Inline.configure(flag("hxmc.inline", d));
		Inline.devirtOn = on("hxmc.devirt", true, d);
		Lir.LFunc.dupDispatch = on("hxmc.dup-dispatch", true, d);
		Lir.LFunc.minTable = Std.parseInt(flag("hxmc.dup-min", d) ?? "64");
		MirBuild.noShadow = MemLower.noShadow = on("hxmc.noshadow", false, d);
		MirBuild.frameSpills = on("hxmc.framespill", true, d);
		MirBuild.tryMemAll = flag("hxmc.trymem", d) == "all";
		Opt.licmOn = on("hxmc.licm", true, d);
		hxmc.ir.Reach.on = on("hxmc.reach", true, d);
		hxmc.ir.Reach.whyName = flag("hxmc.reach-why", d);
		hxmc.x64.Emit.sizeStats = on("hxmc.size-stats", false, d);
		hxmc.x64.Emit.FALIGN = Std.parseInt(flag("hxmc.falign", d) ?? "16");
		hxmc.x64.Emit.FSHIFT = Std.parseInt(flag("hxmc.fshift", d) ?? "0");
		hxmc.wasm.WasmGen.coalesceOn = on("hxmc.wasm-coalesce", true, d);
		hxmc.interp.InterpGen.coalesce = on("hxmc.interp-coalesce", true, d);
		var pe = flag("hxmc.pe-diag", d);
		LinkPE.diags = pe == null ? null : pe.split(",");
		LinkPE.mapFile = flag("hxmc.map", d);
		hxmc.ir.Lower.surveyFile = flag("hxmc.survey", d);
		hxmc.ir.Lower.survey = hxmc.ir.Lower.surveyFile != null;
		ModuleCache.stats = on("hxmc.stats", false, d);
		#if (hxmc.target != "wasm32-wasi")
		var ms = on("hxmc.macro-stats", false, d);
		hxmc.interp.MirMacros.stats = hxmc.macro.HostTable.timed = ms;
		hxmc.interp.MirMacros.coldWords = Std.parseInt(flag("hxmc.mir-cold", d) ?? "") ?? hxmc.interp.MirMacros.COLD_WORDS;
		hxmc.interp.MirMacros.lazyOn = on("hxmc.mir-lazy", true, d);
		hxmc.interp.Tier.max = Std.parseInt(flag("hxmc.mir-tier-max", d) ?? "-1");
		hxmc.interp.Tier.stats = ms || on("hxmc.mir-tier-log", false, d);
		hxmc.macro.Loader.debug = on("hxmc.macro-debug", false, d);
		#end
	}

	public var jobs = 0; // parallel module compilations (HXMC_JOBS, -D hxmc.jobs; 0: the cores)
	public var dump:Null<String> = null; // function names whose machine code is printed (HXMC_DUMP)
	// -D hxmc.link=<path>[,<path>...]: objects and archives linked with the program (LinkInputs)
	public var links:Array<String> = [];
	// -D hxmc.wasm-eh=legacy: wasm32-wasi with the legacy exception-handling instructions
	// (try/catch_all/rethrow) for engines without exnref (default: exnref)
	public var wasmLegacyEh = false;
	// -D hxmc.wasm-memory-max=<MB>: wasm32-wasi, the module's memory at most
	// so large (its maximum: memory.grow fails past it, as a host that
	// refuses memory does; 0: no maximum, the default)
	public var wasmMemoryMaxMb = 0;
	// -D hxmc.native-array-outofbounds=throws|silent: NativeArray (Vector)
	// accesses out of bounds throw, or read the default and write nothing
	// (default: not tested; hxmc.ir.Lower.bounds)
	public var bounds = hxmc.ir.Lower.BOUNDS_UNCHECKED;
	// -D hxmc.null-checks=0|1: references tested against null before they
	// are dereferenced (hxmc.ir.Lower.nullChecks); default: on WebAssembly,
	// whose null accesses neither fault nor throw, off natively, where the
	// runtime's fault handler throws (hxmc.rt.Faults)
	public var nullChecks = false;
	// -D hxmc.span-checks=0|1: whether a span's element accesses are
	// range-checked (hxmc.ir.Lower.spanChecks; default 1, every build); ranges
	// (sub, blit, fill, the spans GC code lends) stay checked
	public var spanChecks = true;
	// -D hxmc.verify-tags: references tested not to be tagged words before they
	// are read as references (hxmc.ir.Lower.verifyTags)
	public var verifyTags = false;
	// -D hxmc.libc=glibc: Linux, a dynamically linked executable against the system's glibc (Abi.setLibc; default: musl, static)
	public var libc:Null<String> = null;
	// x86-64 functions keep a frame record (push rbp; mov rbp, rsp), so
	// profilers and debuggers walk the stack by frame pointer: the default;
	// -D hxmc.no-frame-pointers (or HXMC_FRAME_POINTERS=0) off (arm64 always
	// has them: Abi)
	public var framePointers = true;
	// -debug (or -D hxmc.lines alone): source lines (DWARF .debug_line and
	// .debug_info on ELF and Mach-O) from the typed AST's positions
	// (hxmc.ir.Ir.Stmt.SPos)
	public var debugLines = false;
	// stack traces (haxe.CallStack, exception stacks): the program's functions
	// and lines in a table when it can turn a stack into items (StackTable);
	// -D hxmc.no-stacks leaves them out (the stacks are empty then)
	public var stacks = true;
	// -D hxmc.stacks: the table, and the stacks recorded and reported (an
	// uncaught exception's), whether or not the program reads stacks
	public var stacksAlways = false;
	// a program that loads code for the Mir interpreter (Main: a compiler with
	// Mir macros and --run, Mem.mirHost): the pools and the host table its
	// code loaded crosses into native code through, spare type and signature
	// table entries, every function kept, the symbols written next to the
	// executable (<out>.syms)
	public var mirHost = false;
	// -D hxmc.interp[=<module prefixes>]: the program's functions run by the interpreter in the program (hxmc.interp.InterpGen, hxmc.rt.Interp); null: none
	public var interp:Null<String> = null;

	public function new() {}

	// the default target: the one the tool runs on (WebAssembly, Eval: linux-x86_64)
	public static function host():String {
		#if eval
		return "linux-x86_64";
		#else
		return switch Platform.target() {
			case 1 | 8: "linux-arm64";
			case 2: "macos-x86_64";
			case 3: "macos-arm64";
			case 4: "windows-x86_64";
			case 5: "windows-arm64";
			case _: "linux-x86_64";
		}
		#end
	}

	// the directory of the hxmc binary (with a trailing slash; absolute)
	public static function toolDir():String {
		var p = Sys.programPath();
		p = try sys.FileSystem.fullPath(p) catch (_:Dynamic) p;
		var d = haxe.io.Path.directory(p);
		return d == "" ? "./" : haxe.io.Path.addTrailingSlash(d);
	}

	// the directories searched for a target's runtime objects (rt.o, ssl.o,
	// uv.o: <dir><rtName>/, with a trailing slash), in this order:
	// - those of HXMC_RT_DIR (a list, by the host's path delimiter; the npm
	//   launcher passes the installed platform packages, after the user's),
	//   which add to the search;
	// - beside the binary, <tool dir><rtName>/: npm's platform package
	//   (@hxmc/<os>-<cpu>/haxe, its targets' <target>/rt.o);
	// - <tool dir>rt/<rtName>/: a checkout's bin/hxmc/rt (make rt), a release;
	// - the platform package of the target beside this one, of the same
	//   version: <tool dir>../<os>-<cpu>/<rtName>/ (a cross build's,
	//   npm i -D --force @hxmc/win32-x64)
	public static function rtSearch(rtName:String):Array<String> {
		var env = Sys.getEnv("HXMC_RT_DIR");
		var dirs = env == null || env == "" ? [] : [for (d in env.split(Sys.systemName() == "Windows" ? ";" : ":")) if (d != "") haxe.io.Path.addTrailingSlash(d)];
		var tool = toolDir();
		dirs.push(tool);
		dirs.push(tool + "rt/");
		var pkg = platformPackage(rtName);
		var toolPath = haxe.io.Path.removeTrailingSlashes(tool);
		if (pkg != null && haxe.io.Path.withoutDirectory(toolPath) != pkg) {
			var v = packageVersion(tool);
			var sib = haxe.io.Path.directory(toolPath) + "/" + pkg + "/";
			if (v != null && packageVersion(sib) == v) dirs.push(sib);
		}
		// (once each: the launcher's list names the package the binary is in)
		var r = [], seen = new Map<String, Bool>();
		for (d in dirs) {
			var key = haxe.io.Path.normalize(d + rtName);
			if (seen.exists(key)) continue;
			seen.set(key, true);
			r.push(d + rtName + "/");
		}
		return r;
	}

	// the directory of a target's runtime objects: the first of rtSearch that
	// has its rt.o, else the first
	public static function rtDir(rtName:String):String {
		var dirs = rtSearch(rtName);
		for (d in dirs)
			if (sys.FileSystem.exists(d + "rt.o")) return d;
		return dirs[0];
	}

	// the error for a target whose rt.o none of rtSearch's directories has
	public static function rtMissing(rtName:String):String {
		return "hxmc: no runtime object for " + rtName + " (" + rtHint(rtName) + "); searched: " + [for (d in rtSearch(rtName)) d + "rt.o"].join(", ");
	}

	// the version of the npm package in dir (its package.json's), or null
	static function packageVersion(dir:String):Null<String> {
		var p = dir + "package.json";
		if (!sys.FileSystem.exists(p)) return null;
		var json:Dynamic = try haxe.Json.parse(sys.io.File.getContent(p)) catch (_:Dynamic) null;
		var v:Dynamic = json == null ? null : json.version;
		return Std.isOfType(v, String) ? v : null;
	}

	// npm's platform package with a target's runtime objects (its name in
	// @hxmc/), or null
	static function platformPackage(rtName:String):Null<String> {
		return switch rtName {
			case "linux-x86_64" | "linux-x86_64-glibc": "linux-x64";
			case "linux-arm64" | "linux-arm64-glibc": "linux-arm64";
			case "macos-x86_64": "darwin-x64";
			case "macos-arm64": "darwin-arm64";
			case "windows-x86_64": "win32-x64";
			case "windows-arm64": "win32-arm64";
			case _: null;
		}
	}

	// where the runtime objects of a target come from, for the error that
	// says they are missing: npm's platform package that has them (another
	// machine's installs with --force), else a release archive or a build
	// from source (make rt)
	public static function rtHint(rtName:String):String {
		var pkg = platformPackage(rtName);
		if (pkg != null) return 'npm: install @hxmc/$pkg (npm i -D --force @hxmc/$pkg on another machine); a checkout: make rt';
		return StringTools.startsWith(rtName, "android-")
			? "Android builds need the runtime objects of the GitHub release rt-<hash> (npm: the one @hxmc/cli's package.json names, hxmc.rt) or a build from source (make rt): HXMC_RT_DIR names their directory"
			: "make rt";
	}

	public static function read(com:context.Common.CommonContext):Options {
		var o = new Options();
		inline function def(k:String):Null<String>
			return core.Define.rawDefined(com.defines, k) ? core.Define.rawDefinedValue(com.defines, k) : null;
		var t = def("hxmc.target");
		if (t != null && t != "1") o.target = t;
		o.rtObj = Sys.getEnv("HXMC_RT_OBJ");
		o.stats = on("hxmc.stats", false, com.defines);
		o.verbose = on("hxmc.verbose", false, com.defines);
		o.dump = flag("hxmc.dump", com.defines);
		var sa = def("hxmc.seg_align"); // (-D turns the dash into an underscore)
		if (sa != null) o.segAlign = Std.parseInt(sa);
		o.pic = def("hxmc.pic") != null;
		o.strip = !(def("debug") != null || on("hxmc.symbols", false, com.defines));
		o.shared = def("hxmc.shared") != null;
		o.output = def("hxmc.output");
		o.dllBase = def("hxmc.dll_base"); // (-D turns the dash into an underscore)
		var ex = def("hxmc.exports");
		if (ex != null)
			for (n in ex.split(","))
				if (StringTools.trim(n) != "") o.exports.push(StringTools.trim(n));
		var min = def("hxmc.ios_min_version");
		if (min != null) {
			var v = ~/^([0-9]+)\.([0-9]+)$/;
			if (!v.match(min) || Std.parseInt(v.matched(1)) < 15 || Std.parseInt(v.matched(2)) > 255)
				throw "hxmc: iOS: -D hxmc.ios-min-version=" + min + ": major.minor, 15.0 or later";
			o.iosMinos = (Std.parseInt(v.matched(1)) << 16) | (Std.parseInt(v.matched(2)) << 8);
		}
		o.codesignId = def("hxmc.codesign_id");
		o.codesignInfoPlist = def("hxmc.codesign_info_plist");
		o.codesignResources = def("hxmc.codesign_resources");
		o.codesignEntitlements = def("hxmc.codesign_entitlements");
		o.opt = on("hxmc.opt", true, com.defines);
		var eh = def("hxmc.wasm_eh"); // (-D turns the dash into an underscore)
		if (eh != null) switch eh {
			case "legacy": o.wasmLegacyEh = true;
			case "exnref":
			case _: throw "hxmc: -D hxmc.wasm-eh=" + eh + ": exnref or legacy";
		}
		var mm = def("hxmc.wasm_memory_max"); // (-D turns the dashes into underscores)
		if (mm != null) {
			var v = Std.parseInt(mm);
			if (v == null || v < 1 || v > 4096 || Std.string(v) != StringTools.trim(mm)) throw "hxmc: -D hxmc.wasm-memory-max=" + mm + ": megabytes, 1 to 4096";
			o.wasmMemoryMaxMb = v;
		}
		o.libc = def("hxmc.libc");
		// (the WasmGC back end is gone, issue #80: an error rather than a linear-memory module)
		if (def("hxmc.wasm_gc") != null) throw "hxmc: -D hxmc.wasm-gc was removed (wasm32-wasi modules use linear memory and hxmc's collector)";
		var oob = def("hxmc.native_array_outofbounds"); // (-D turns the dashes into underscores)
		if (oob != null) o.bounds = switch oob {
			case "throws": hxmc.ir.Lower.BOUNDS_THROWS;
			case "silent": hxmc.ir.Lower.BOUNDS_SILENT;
			case _: throw "hxmc: -D hxmc.native-array-outofbounds=" + oob + ": throws or silent (not defined: unchecked)";
		}
		var nc = def("hxmc.null_checks"); // (-D turns the dash into an underscore)
		o.nullChecks = switch nc {
			case null: o.target == "wasm32-wasi";
			case "0": false;
			case "1": true;
			case _: throw "hxmc: -D hxmc.null-checks=" + nc + ": 0 or 1";
		}
		var lv = flag("hxmc.loop-version", com.defines);
		o.loopVersion = lv != "0";
		o.loopVersionWhy = lv == "why";
		o.compact = on("hxmc.compact", true, com.defines);
		var llv = flag("hxmc.llvm", com.defines);
		if (llv != null && llv != "0") o.llvm = llv == "1" ? "O2" : llv;
		o.llvmRt = on("hxmc.llvm-rt", false, com.defines);
		o.llvmCpu = flag("hxmc.llvm-cpu", com.defines);
		var rel = on("hxmc.llvm-release", false, com.defines);
		o.llvmWhole = rel || on("hxmc.llvm-whole", false, com.defines);
		o.llvmConsts = rel || on("hxmc.llvm-consts", false, com.defines);
		o.llvmTbaa = flag("hxmc.llvm-tbaa", com.defines);
		o.llvmFlags = flag("hxmc.llvm-flags", com.defines);
		var cl = flag("hxmc.llvm-clang", com.defines);
		if (cl != null) o.llvmClang = cl;
		o.llvmPgo = flag("hxmc.llvm-pgo", com.defines);
		o.llvmInline = on("hxmc.llvm-inline", false, com.defines);
		if (o.llvmPgo != null && o.llvmPgo != "gen") {
			if (!sys.FileSystem.exists(o.llvmPgo)) throw "hxmc: -D hxmc.llvm-pgo=" + o.llvmPgo + ": no such profile (gen, or a file of llvm-profdata merge)";
			o.llvmPgo = sys.FileSystem.fullPath(o.llvmPgo);
		}
		// (LLVM drops a load whose value is not used, the fault of a null access with it: explicit tests, as on WebAssembly)
		if (o.llvm != null && nc == null) o.nullChecks = true;
		o.verifyTags = def("hxmc.verify_tags") != null;
		var sc = def("hxmc.span_checks");
		o.spanChecks = switch sc {
			case null | "1": true;
			case "0": false;
			case _: throw "hxmc: -D hxmc.span-checks=" + sc + ": 0 or 1";
		}
		var fp = flag("hxmc.frame-pointers", com.defines); // (else the old -D hxmc.no-frame-pointers)
		o.framePointers = fp != null ? fp != "0" : def("hxmc.no_frame_pointers") == null;
		o.debugLines = def("debug") != null || def("hxmc.lines") != null;
		o.stacks = def("hxmc.no_stacks") == null;
		o.stacksAlways = o.stacks && def("hxmc.stacks") != null;
		o.interp = def("hxmc.interp");
		for (n in FLAGS) {
			var v = flag(n, com.defines);
			if (v != null) o.codeKey += "+" + n.substr(5) + "=" + v;
		}
		var j = flag("hxmc.jobs", com.defines);
		if (j != null) o.jobs = Std.parseInt(j);
		var ls = def("hxmc.link");
		if (ls != null)
			for (p in ls.split(","))
				if (StringTools.trim(p) != "") o.links.push(sys.FileSystem.absolutePath(StringTools.trim(p)));
		// A diagnostic reference for optimized code: keep the generated
		// checks by disabling Mir optimization, including check elimination.
		// Apply last so narrower switches cannot weaken the checked build.
		if (def("hxmc.checked") != null) {
			o.opt = false;
			o.bounds = hxmc.ir.Lower.BOUNDS_THROWS;
			o.nullChecks = true;
			o.spanChecks = true;
			o.verifyTags = true;
		}
		return o;
	}
}
