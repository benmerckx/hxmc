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
	// -D hxmc.jit: a compiler that can load native macros (hxmc/src/hxmc/macro): spare
	// type and signature table entries, every runtime function kept, the
	// symbols written next to the executable (<out>.syms); Linux x86-64, static
	public var jit = false;

	public function new() {}

	// the default target: the one the tool runs on (WebAssembly, Eval: linux-x86_64)
	static function host():String {
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

	// the directory of the runtime objects (<dir><target>/rt.o; HXMC_RT_DIR,
	// else <tool dir>rt/)
	public static var rtDirOverride:Null<String> = null;

	public static function rtDir():String {
		if (rtDirOverride != null) return rtDirOverride;
		var env = Sys.getEnv("HXMC_RT_DIR");
		return env != null && env != "" ? haxe.io.Path.addTrailingSlash(env) : toolDir() + "rt/";
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
		if (o.wasmGc && o.target != "wasm32-wasi") throw "hxmc: -D hxmc.wasm-gc: -D hxmc.target=wasm32-wasi";
		var fp = def("hxmc.frame_pointers"), fpEnv = env("HXMC_FRAME_POINTERS");
		o.framePointers = fpEnv != null && fpEnv != "" ? fpEnv != "0" : def("hxmc.no_frame_pointers") != null ? false : fp == null || fp != "0";
		o.debugLines = def("debug") != null || def("hxmc.lines") != null;
		o.jit = def("hxmc.jit") != null;
		if (o.jit && (o.target != "linux-x86_64" || o.libc != null)) throw "hxmc: -D hxmc.jit: linux-x86_64 (static) only";
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
