package hxmc;

// What a run of the tool does (Main lists the defines and variables).
class Options {
	public var target = host();
	public var rtObj:Null<String> = null; // the runtime object (default: <tool dir>/rt/<target>/rt.o)
	public var stats = false;
	public var verbose = false;
	public var segAlign = 0; // -D hxmc.seg-align: the alignment of loadable segments (0: the target's)
	public var strip = true; // no symbol table unless -debug, -D hxmc.symbols or HXMC_SYMBOLS=1
	public var pic = false; // -D hxmc.pic: position-independent executable
	public var shared = false; // -D hxmc.shared: a shared library (Linux in the glibc mode; Android always)
	public var dllBase:Null<String> = null; // -D hxmc.dll-base=0x<hex>: a Windows DLL's preferred base
	public var output:Null<String> = null; // -D hxmc.output=<path>: the output, instead of --custom-target's (hxmc dev: the iOS simulator's dylibs, where the build names an app)
	// -D hxmc.exports=<name>[,<name>...]: what a shared library exports (Android: ANativeActivity_onCreate too)
	public var exports:Array<String> = [];
	// Android's APK (hxmc.android.Apk): -D hxmc.android-package=<id>, -D
	// hxmc.android-label=<text>, -D hxmc.android-min-sdk=<n>, -D
	// hxmc.android-target-sdk=<n>, -D hxmc.android-version=<code>
	public var android = new Map<String, String>();
	// iOS's app bundle (hxmc.ios.Bundle): -D hxmc.ios-bundle-id=<id>, -D
	// hxmc.ios-name=<text>, -D hxmc.ios-version=<n>, -D
	// hxmc.ios-version-name=<text>, -D hxmc.ios-min-version=<major.minor>, -D
	// hxmc.ios-entitlements=<file>
	public var ios = new Map<String, String>();
	public var opt = true; // MIR optimizations (HXMC_OPT=0: off)
	public var jobs = 0; // parallel module compilations (HXMC_JOBS, -D hxmc.jobs; 0: the cores)
	public var dump:Null<String> = null; // function names whose machine code is printed (HXMC_DUMP)
	// -D hxmc.link=<path>[,<path>...]: objects and archives linked with the program (LinkInputs)
	public var links:Array<String> = [];
	// -D hxmc.wasm-eh=legacy: wasm32-wasi with the legacy exception-handling instructions
	// (try/catch_all/rethrow) for engines without exnref (default: exnref)
	public var wasmLegacyEh = false;
	// -D hxmc.wasm-gc: wasm32-wasi as a WasmGC module (objects in the engine's
	// collector: hxmc.wasmgc), an experiment to compare with linear memory
	public var wasmGc = false;
	// -D hxmc.native-array-outofbounds=throws|silent: NativeArray (Vector)
	// accesses out of bounds throw, or read the default and write nothing
	// (default: not tested; hxmc.ir.Lower.bounds)
	public var bounds = hxmc.ir.Lower.BOUNDS_UNCHECKED;
	// -D hxmc.null-checks=0|1: references tested against null before they
	// are dereferenced (hxmc.ir.Lower.nullChecks); default: on WebAssembly,
	// whose null accesses neither fault nor throw, off natively, where the
	// runtime's fault handler throws (hxmc.rt.Faults)
	public var nullChecks = false;
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
		return switch hxmc.unsafe.Mem.target() {
			case 1 | 8: "linux-arm64";
			case 2: "macos-x86_64";
			case 3: "macos-arm64";
			case 4: "windows-x86_64";
			case 5: "windows-arm64";
			case _: "linux-x86_64";
		}
		#end
	}

	// the directory of the hxmc binary (with a trailing slash)
	public static function toolDir():String {
		var p = Sys.programPath();
		var d = haxe.io.Path.directory(p);
		return d == "" ? "./" : haxe.io.Path.addTrailingSlash(d);
	}

	// the directory of a target's runtime objects (rt.o, ssl.o, uv.o; with a
	// trailing slash): <dir><rtName>/ of the first directory of HXMC_RT_DIR
	// (a list, by the host's path delimiter: the npm launcher passes the
	// installed platform packages and the user's HXMC_RT_DIR) that has its rt.o,
	// else of the first one; HXMC_RT_DIR unset: <tool dir>rt/
	public static function rtDir(rtName:String):String {
		var env = Sys.getEnv("HXMC_RT_DIR");
		var dirs = env == null || env == "" ? [] : [for (d in env.split(Sys.systemName() == "Windows" ? ";" : ":")) if (d != "") haxe.io.Path.addTrailingSlash(d)];
		if (dirs.length == 0) dirs.push(toolDir() + "rt/");
		for (d in dirs)
			if (sys.FileSystem.exists(d + rtName + "/rt.o")) return d + rtName + "/";
		return dirs[0] + rtName + "/";
	}

	// where the runtime objects of a target come from, for the error that
	// says they are missing: npm's platform package that has them (another
	// machine's installs with --force), else a release archive or a build
	// from source (make rt)
	public static function rtHint(rtName:String):String {
		var pkg = switch rtName {
			case "linux-x86_64" | "linux-x86_64-glibc": "linux-x64";
			case "linux-arm64" | "linux-arm64-glibc": "linux-arm64";
			case "macos-x86_64": "darwin-x64";
			case "macos-arm64": "darwin-arm64";
			case "windows-x86_64": "win32-x64";
			case "windows-arm64": "win32-arm64";
			case _: null;
		}
		if (pkg != null) return 'npm: install @hxmc/$pkg (npm i -D --force @hxmc/$pkg on another machine); a checkout: make rt';
		return StringTools.startsWith(rtName, "android-")
			? "Android builds need the runtime objects of a release archive or a build from source (make rt): HXMC_RT_DIR names their directory"
			: "make rt";
	}

	public static function read(com:context.Common.CommonContext):Options {
		var o = new Options();
		inline function def(k:String):Null<String>
			return core.Define.rawDefined(com.defines, k) ? core.Define.rawDefinedValue(com.defines, k) : null;
		var env = Sys.getEnv;
		var t = def("hxmc.target");
		if (t != null && t != "1") o.target = t;
		o.rtObj = env("HXMC_RT_OBJ");
		o.stats = env("HXMC_STATS") == "1";
		o.verbose = def("hxmc.verbose") != null || env("HXMC_VERBOSE") == "1";
		o.dump = env("HXMC_DUMP");
		var sa = def("hxmc.seg_align"); // (-D turns the dash into an underscore)
		if (sa != null) o.segAlign = Std.parseInt(sa);
		o.pic = def("hxmc.pic") != null;
		o.strip = !(def("debug") != null || def("hxmc.symbols") != null || env("HXMC_SYMBOLS") == "1");
		o.shared = def("hxmc.shared") != null;
		o.output = def("hxmc.output");
		o.dllBase = def("hxmc.dll_base"); // (-D turns the dash into an underscore)
		var ex = def("hxmc.exports");
		if (ex != null)
			for (n in ex.split(","))
				if (StringTools.trim(n) != "") o.exports.push(StringTools.trim(n));
		for (k in ["package", "label", "min_sdk", "target_sdk", "version", "version_name", "key", "permissions"]) {
			var v = def("hxmc.android_" + k); // (-D turns the dashes into underscores)
			if (v != null) o.android.set(k, v);
		}
		for (k in ["bundle_id", "name", "version", "version_name", "min_version", "entitlements"]) {
			var v = def("hxmc.ios_" + k);
			if (v != null) o.ios.set(k, v);
		}
		o.opt = env("HXMC_OPT") != "0";
		var eh = def("hxmc.wasm_eh"); // (-D turns the dash into an underscore)
		if (eh != null) switch eh {
			case "legacy": o.wasmLegacyEh = true;
			case "exnref":
			case _: throw "hxmc: -D hxmc.wasm-eh=" + eh + ": exnref or legacy";
		}
		o.libc = def("hxmc.libc");
		o.wasmGc = def("hxmc.wasm_gc") != null;
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
		if (o.wasmGc && o.target != "wasm32-wasi") throw "hxmc: -D hxmc.wasm-gc: -D hxmc.target=wasm32-wasi";
		var fp = def("hxmc.frame_pointers"), fpEnv = env("HXMC_FRAME_POINTERS");
		o.framePointers = fpEnv != null && fpEnv != "" ? fpEnv != "0" : def("hxmc.no_frame_pointers") != null ? false : fp == null || fp != "0";
		o.debugLines = def("debug") != null || def("hxmc.lines") != null;
		o.stacks = def("hxmc.no_stacks") == null;
		o.stacksAlways = o.stacks && def("hxmc.stacks") != null;
		o.interp = def("hxmc.interp");
		var j = def("hxmc.jobs");
		if (j == null) j = env("HXMC_JOBS");
		if (j != null) o.jobs = Std.parseInt(j);
		var ls = def("hxmc.link");
		if (ls != null)
			for (p in ls.split(","))
				if (StringTools.trim(p) != "") o.links.push(sys.FileSystem.absolutePath(StringTools.trim(p)));
		return o;
	}
}
