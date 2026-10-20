package hxmc;

// The hxmc tool (docs/hxmc.md): runs the port's compiler pipeline on the
// program (from an HXB archive with --hxb-lib, or from source), lowers the
// filtered program to hxmc's IR (hxmc.ir.Lower) and compiles it to machine
// code:
//   hxmc <out> <haxe arguments...> -cp bin/hxmc/std --custom-target hxmc
// With a first argument that starts with `-` it is the compiler's command
// line (HaxeMain), e.g. for scripts: `hxmc -cp hxmc/src --run hxmc.MkStd`;
// `hxmc dev <arguments>` is the dev loop (docs/dev.md).
// Options (defines, or the environment for development):
//   -D hxmc.target=linux-x86_64     the target (Target.hx, Abi.hx: six of them)
//   -D hxmc.wasm-eh=legacy          wasm32-wasi: legacy exception handling (default: exnref)
//   -D hxmc.libc=glibc              Linux: dynamically linked against the system's glibc (default: musl, static)
//   -D hxmc.shared                  a shared library (Linux in the glibc mode; Android's is always one: an
//                                   output ending in .apk is an APK holding it, hxmc.android.Apk)
//   -D hxmc.exports=<names>         the names a shared library exports
//   -D hxmc.output=<path>           the output, instead of --custom-target's (hxmc dev: the iOS
//                                   simulator's builds as dylibs, where the build names its app)
//   -D hxmc.no-frame-pointers       x86-64: no frame record in functions (the default keeps one, for
//                                   perf -g and debuggers; HXMC_FRAME_POINTERS=0 off; arm64 always)
//   -debug                          source lines for debuggers (DWARF on ELF and Mach-O), symbols
//   -D hxmc.native-array-outofbounds=throws|silent
//                                   NativeArray/Vector accesses out of bounds throw, or read the
//                                   default and write nothing (default: not tested)
//   -D hxmc.null-checks=0|1         explicit tests of references against null before they are
//                                   dereferenced (default: on WebAssembly; natively a fault handler
//                                   throws instead, hxmc.rt.Faults)
//   -D hxmc.gc-prefault             Linux: the collector faults in the old space's pages on a helper
//                                   thread: less wall time for more CPU time (the compilers' builds)
//   HXMC_RT_OBJ                    the runtime object (default: <tool dir>/rt/<target>/rt.o)
//   HXMC_STATS=1                    print what the build did and how long it took
class Main {
	static var start = haxe.Timer.stamp();
	static var lowerCache = new LowerCache();

	static function main() {
		Defines.install();
		var args = Sys.args();
		if (args[0] == "--mkrt-macho") {
			args.shift();
			MkRt.macho(args);
			return;
		}
		if (args[0] == "--mkrt") {
			args.shift();
			MkRt.main(args);
			return;
		}
		// resident: the port's compilation server (`hxmc --server --wait <port>`;
		// builds come with `--connect <port>` and name their output with
		// -D hxmc.out=<path>)
		if (args[0] == "--server") {
			args.shift();
			if (Sys.getEnv("RT_OLD_MB") == null && Sys.getEnv("HXMC_GC_DEFAULTS") != "0" && Sys.systemName() != "Wasi") {
				Sys.putEnv("RT_OLD_MB", "4096");
				Sys.exit(Sys.command(Sys.programPath(), ["--server"].concat(args)));
			}
			Driver.resident = true;
			hxmc.ir.CInterop.install();
			compiler.Compiler.generateHook = function(com) {
				try {
					start = haxe.Timer.stamp();
					var o = core.Define.rawDefined(com.defines, "hxmc.out") ? core.Define.rawDefinedValue(com.defines, "hxmc.out") : null;
					if (o == null) throw "-D hxmc.out=<path> names the output of a server build";
					generate(com, o);
				} catch (e:Dynamic) {
					Sys.stderr().writeString("hxmc: " + Std.string(e) + "\n" + haxe.CallStack.toString(haxe.CallStack.exceptionStack()) + "\n");
				}
			}
			Sys.exit(haxe.Main.run(args));
		}
		if (args.length == 0 || StringTools.startsWith(args[0], "-"))
			Sys.exit(HaxeMain.run(args));
		// the dev loop: `hxmc dev [build.hxml | arguments]` (docs/dev.md)
		if (args[0] == "dev")
			Sys.exit(HaxeMain.dev(args.slice(1)));
		var out = args.shift();
		var failed = null;
		var key = UpToDate.key(args, out);
		if (UpToDate.check(key, out)) {
			if (Sys.getEnv("HXMC_STATS") == "1") Sys.println("hxmc: up to date (" + Std.int((haxe.Timer.stamp() - start) * 1000) + " ms)");
			Sys.exit(0);
		}
		if (key != null) UpToDate.forget(out);
		// a whole-program build keeps most of what it makes (the typed program,
		// then every module's code until the link): a large first old-space
		// limit spares it major collections (3 GB: the port's cold build with
		// the module cache's encoding promotes about 2 GB, just past 2 GB, which
		// cost a major collection of a second). The nursery is the runtime's
		// adaptive one: up to 16 MB for the front end, 16 MB per thread for the
		// parallel code generation (against a fixed 32 MB that 12 threads
		// shared: the cold self-build 11% faster with 21% less peak memory; a
		// fixed 256 MB would triple a small build's peak memory). The runtime
		// reads the limit at startup, so the tool runs itself again with it set
		// (not under WASI: no processes).
		if (Sys.getEnv("RT_OLD_MB") == null && Sys.getEnv("HXMC_GC_DEFAULTS") != "0" && Sys.systemName() != "Wasi") {
			Sys.putEnv("RT_OLD_MB", "3072");
			Sys.exit(Sys.command(Sys.programPath(), [out].concat(args)));
		}
		compiler.Compiler.generateHook = function(com) {
			try {
				generate(com, out);
			} catch (e:Dynamic) {
				failed = Std.string(e) + "\n" + haxe.CallStack.toString(haxe.CallStack.exceptionStack());
			}
		}
		ModuleCache.install();
		hxmc.ir.CInterop.install();
		var code = haxe.Main.run(args.concat(["--no-output"]));
		ModuleCache.finish(failed == null ? code : 1);
		if (failed != null) {
			Sys.stderr().writeString("hxmc: " + failed + "\n");
			Sys.exit(1);
		}
		if (code == 0) UpToDate.record(key, out);
		Sys.exit(code);
	}

	static function generate(com:context.Common.CommonContext, out:String) {
		// the class whose static main the program runs, as the other targets
		// find it (Common.getEntryPoint): the -main module's statics when they
		// hold main (a module-level `function main()`), else its class of that name
		if (com.main.mainPath == null) throw "a program needs an entry point: -main <module>";
		var mainClass = context.Common.getEntryPoint(com).cls;
		var opts = Options.read(com);
		var abi = Abi.get(opts.target);
		abi.setLibc(opts.libc);
		hxmc.ir.Lower.targetOs = abi.osCode();
		hxmc.ir.Lower.wasmGc = opts.wasmGc;
		// (genjs's order: `Hashtbl.fold (fun name data acc -> (name,data) :: acc) com.resources []`)
		hxmc.ir.Lower.resources = com.resources.fold((name, data, acc:Array<{name:String, data:String}>) -> [{name: name, data: codegen.Codegen.bytesSerialize(data)}].concat(acc), []);
		hxmc.ir.Lower.bounds = opts.bounds;
		hxmc.ir.Lower.nullChecks = opts.nullChecks;
		// WebAssembly's runtime is typed with the program only for that target
		if (abi.wasm && !Lambda.exists(com.types, t -> switch t {
			case TClassDecl(c): c.clPath.pack.join(".") == "hxmc.rt.wasm" && c.clPath.name == "Gc";
			case _: false;
		}))
			throw "hxmc: a program for " + abi.name + " must be typed for it: -D hxmc.target=" + abi.name + " (also when writing its HXB)";
		hxmc.ir.Lower.targetArm = abi.arm ? 1 : 0;
		hxmc.ir.Lower.targetCode = MirBuild.targetCode(abi);
		hxmc.ir.Lower.targetPlatform = abi.platformCode();
		hxmc.ir.Lower.lines = opts.debugLines && !abi.wasm;
		var t0 = haxe.Timer.stamp();
		// resident: bodies of the fields the server kept are reused (LowerCache)
		var useCache = Driver.resident && Sys.getEnv("HXMC_LOWER_CACHE") != "0";
		var prog = useCache ? lowerCache.lower(mainClass, com.types, com.basic) : hxmc.ir.Lower.program(mainClass, com.types, com.basic);
		if (opts.stats) {
			Sys.println('hxmc: lowering ${Std.int((haxe.Timer.stamp() - t0) * 1000)} ms (since start ${Std.int((t0 - start) * 1000)} ms)');
			if (useCache)
				Sys.println('hxmc: bodies ${lowerCache.hits} reused (${lowerCache.keyed} by key), ${lowerCache.misses} lowered' + (lowerCache.why != null ? ' (lowered again: ${lowerCache.why})' : ''));
		}
		if (Sys.getEnv("HXMC_LOWER_ONLY") == "1") return; // (profiling the lowering)
		if (opts.wasmGc) {
			hxmc.wasmgc.GcGen.run(prog, out, opts);
			return;
		}
		Driver.run(prog, out, opts);
		// HXMC_LOWER_CHECK=1: the same program lowered from scratch must give the same executable
		if (useCache && Sys.getEnv("HXMC_LOWER_CHECK") == "1") {
			var fresh = hxmc.ir.Lower.program(mainClass, com.types, com.basic);
			Driver.run(fresh, out + ".check", opts);
			var same = sys.io.File.getBytes(out).compare(sys.io.File.getBytes(out + ".check")) == 0;
			Sys.println("hxmc: lowering check: " + (same ? "same executable" : "DIFFERENT executable"));
		}
	}
}
