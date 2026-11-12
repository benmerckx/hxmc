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
//   -D hxmc.wasm-memory-max=<MB>    wasm32-wasi: the memory's maximum (memory.grow fails past it)
//   -D hxmc.libc=glibc              Linux: dynamically linked against the system's glibc (default: musl, static)
//   -D hxmc.shared                  a shared library (Linux in the glibc mode; Android's is always one,
//                                   which a packager puts in an APK)
//   -D hxmc.exports=<names>         the names a shared library exports (its soname: the output's file name)
//   -D hxmc.ios-min-version=<x.y>   iOS, Mac Catalyst: the oldest iOS version an output runs on (15.0, the floor)
//   -D hxmc.codesign-id=<id>, -D hxmc.codesign-info-plist=<file>, -D hxmc.codesign-resources=<file>,
//   -D hxmc.codesign-entitlements=<file>
//                                   a Mach-O output signed ad hoc as `codesign -s -` signs, binding a
//                                   bundle's files a packager wrote (default: linker-signed; CodeSign)
//   -D hxmc.output=<path>           the output, instead of --custom-target's
//   -D hxmc.frame-pointers=0        x86-64: no frame record in functions (the default keeps one, for
//                                   perf -g and debuggers; arm64 always)
//   -debug                          source lines for debuggers (DWARF on ELF and Mach-O), symbols
//   -D hxmc.no-stacks               no call stacks (haxe.CallStack, exception stacks: empty); by
//                                   default a program that reads them gets its table of functions and
//                                   lines (StackTable)
//   -D hxmc.stacks                  the table and stacks in every program: an uncaught exception's
//                                   report names the frames of its throw
//   -D hxmc.native-array-outofbounds=throws|silent
//                                   NativeArray/Vector accesses out of bounds throw, or read the
//                                   default and write nothing (default: not tested)
//   -D hxmc.null-checks=0|1         explicit tests of references against null before they are
//                                   dereferenced (default: on WebAssembly; natively a fault handler
//                                   throws instead, hxmc.rt.Faults)
//   -D hxmc.gc-prefault             Linux: the collector faults in the old space's pages on a helper
//                                   thread: less wall time for more CPU time (the compilers' builds)
//   -D hxmc.compact=0               @:hxmc.compact changes nothing: reference fields 8 bytes everywhere
//                                   (docs/hxmc.md, "Compressed references")
//   HXMC_RT_OBJ                     the runtime object (default: <target>/rt.o where Options.rtSearch finds it)
//   HXMC_RT_DIR                     directories of runtime objects, searched first (added to the search)
//   HXMC_STATS=1                    print what the build did and how long it took
class Main {
	static var start = haxe.Timer.stamp();
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
			// (its old space's first limit 2 GB; after each major collection
			// 150% of what is live, not 300%: the server keeps about 1.4 GB live
			// and each warm self-build promotes about 600 MB. Twelve self-builds,
			// a module edited before each: with 4 GB and 300% a major collection
			// every six builds, peak 6.7 GB; 4 GB and 150%, three, peak 5.8 GB
			// (the first major collection's, at the first limit); 2 GB and 150%,
			// five, peak 4.8 GB)
			if ((Sys.getEnv("RT_OLD_MB") == null || Sys.getEnv("RT_OLD_GROWTH") == null) && Sys.systemName() != "Wasi") {
				if (Sys.getEnv("RT_OLD_MB") == null) Sys.putEnv("RT_OLD_MB", "2048");
				if (Sys.getEnv("RT_OLD_GROWTH") == null) Sys.putEnv("RT_OLD_GROWTH", "150");
				Sys.exit(Sys.command(Sys.programPath(), ["--server"].concat(args)));
			}
			Driver.resident = true;
			hxmc.ir.CInterop.install();
			hxmc.TargetFlags.install();
			hxmc.StdDce.install();
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
			// (the variable: no defines read yet)
			if (Options.on("hxmc.stats", false)) Sys.println("hxmc: up to date (" + Std.int((haxe.Timer.stamp() - start) * 1000) + " ms)");
			Sys.exit(0);
		}
		if (key != null) UpToDate.forget(out);
		// a whole-program build keeps much of what it makes (the typed program,
		// then every module's code until the link) and promotes as much
		// garbage: its first old-space limit is 768 MB. A copying major
		// collection peaks at what the old space holds plus what is live: at
		// 768 MB the self-build has one (0.7-1.3 s, 0.35 GB live) and peaks at
		// 1.18 GB, against 1.45-1.50 GB under a 3 GB limit (no major collection,
		// the garbage kept), in as much wall time; at 512 MB it has two and peaks
		// at 1.9 GB, at 1024 MB one at 1.6-1.7 GB. The nursery is the runtime's
		// adaptive one: up to 16 MB for the front end, 16 MB per thread for the
		// parallel code generation (against a fixed 32 MB that 12 threads
		// shared: the cold self-build 11% faster with 21% less peak memory; a
		// fixed 256 MB would triple a small build's peak memory). The runtime
		// reads the limit at startup, so the tool runs itself again with it set
		// (not under WASI: no processes).
		if (Sys.getEnv("RT_OLD_MB") == null && Sys.systemName() != "Wasi") {
			Sys.putEnv("RT_OLD_MB", "768");
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
		hxmc.TargetFlags.install();
		hxmc.StdDce.install();
		var code = haxe.Main.run(args.concat(["--no-output"]));
		ModuleCache.finish(failed == null ? code : 1);
		if (failed != null) {
			Sys.stderr().writeString("hxmc: " + failed + "\n");
			Sys.exit(1);
		}
		if (code == 0) UpToDate.record(key, out);
		Sys.exit(code);
	}

	// A frontend's seam (docs/hxmc.md, "Frontends"): a compiler built from
	// hxmc's sources with its own main sets it (then runs HaxeMain.run, or its
	// own generate hook calling generate); generate calls it with the lowered
	// program before Driver.run, to add functions to it
	public static var beforeCodegen:Null<(com:context.Common.CommonContext, prog:hxmc.ir.Ir.Program) -> Void> = null;

	// whether @:hxmc.compact fields are 4 bytes (docs/hxmc.md, "Compressed
	// references"): an executable whose image is below 32 GB (Link, LinkDyn's
	// glibc mode and LinkPE's x86-64: at 0x400000; a macOS executable, slid,
	// at 4 GB and a little), whose heap hxmc.rt.Gc.init reserves below 32 GB
	// too (macOS: in the image's __HXHEAP segment, LinkMachO.heapWindow), so
	// that an address shifted right by 3 fits 32 bits with no base. Not a
	// shared library (loaded anywhere: Android's, -D hxmc.shared), iOS and
	// Mac Catalyst, Windows on arm64 (relocatable), nor WebAssembly
	// (references are 4 bytes there): there the fields stay 8 bytes, as
	// everywhere with -D hxmc.compact=0. A Mir host (opts.mirHost) has them
	// as any executable; the code it loads takes its decision
	// (macro.Loader.compactHost: MirMacros, MirRun), as -D hxmc.interp's
	// interpreted functions take their program's
	public static function compactRefs(abi:Abi, opts:Options):Bool
		return opts.compact && !abi.wasm && !abi.android && !opts.shared && abi.output != Abi.OutputKind.SharedLibrary
			&& (abi.os == "linux" || abi.os == "windows" && !abi.arm || abi.os == "macos" && !abi.uikit());

	// the program typed (com) to machine code at out: lowered (hxmc.ir.Lower),
	// given to beforeCodegen (this argument, else Main.beforeCodegen), compiled
	public static function generate(com:context.Common.CommonContext, out:String, ?beforeCodegen:(com:context.Common.CommonContext, prog:hxmc.ir.Ir.Program) -> Void) {
		if (beforeCodegen == null) beforeCodegen = Main.beforeCodegen;
		// the class whose static main the program runs, as the other targets
		// find it (Common.getEntryPoint): the -main module's statics when they
		// hold main (a module-level `function main()`), else its class of that name
		if (com.main.mainPath == null) throw "a program needs an entry point: -main <module>";
		var mainClass = context.Common.getEntryPoint(com).cls;
		var opts = Options.read(com);
		var abi = Abi.get(opts.target);
		abi.setLibc(opts.libc);
		hxmc.ir.Lower.targetOs = abi.osCode();
		// (genjs's order: `Hashtbl.fold (fun name data acc -> (name,data) :: acc) com.resources []`)
		hxmc.ir.Lower.resources = com.resources.fold((name, data, acc:Array<{name:String, data:haxe.io.Bytes}>) -> [{name: name, data: data}].concat(acc), []);
		hxmc.ir.Lower.bounds = opts.bounds;
		hxmc.ir.Lower.nullChecks = opts.nullChecks;
		hxmc.ir.Lower.spanChecks = opts.spanChecks;
		hxmc.ir.Lower.verifyTags = opts.verifyTags;
		hxmc.ir.Lower.interp = opts.interp != null;
		hxmc.ir.Lower.simdScalar = opts.interp != null;
		// WebAssembly's runtime is typed with the program only for that target
		if (abi.wasm && !Lambda.exists(com.types, t -> switch t {
			case TClassDecl(c): c.clPath.pack.join(".") == "hxmc.rt.wasm" && c.clPath.name == "Gc";
			case _: false;
		}))
			throw "hxmc: a program for " + abi.name + " must be typed for it: -D hxmc.target=" + abi.name + " (also when writing its HXB)";
		hxmc.ir.Lower.targetArm = abi.arm ? 1 : 0;
		hxmc.ir.Lower.targetCode = MirBuild.targetCode(abi);
		hxmc.ir.Lower.targetPlatform = abi.platformCode();
		// (a compiler with Mir macros and --run, for a native target: Mem.mirHost)
		hxmc.ir.Lower.mirHost = !abi.wasm && Lambda.exists(com.types, t -> switch t {
			case TClassDecl(c): c.clPath.pack.join(".") == "hxmc.interp" && c.clPath.name == "MirMacros";
			case _: false;
		}) ? 1 : 0;
		opts.mirHost = hxmc.ir.Lower.mirHost == 1;
		hxmc.ir.Lower.compact = compactRefs(abi, opts);
		// (Mem.compact: a class of the program asks for compressed references; one
		// Lower never reaches keeps the runtime's tests, which then find none)
		hxmc.ir.Lower.compactTypes = hxmc.ir.Lower.compact && Lambda.exists(com.types, t -> switch t {
			case TClassDecl(c): hxmc.ir.Lower.hasMeta(":hxmc.compact", c.clMeta);
			case TEnumDecl(e): hxmc.ir.Lower.hasMeta(":hxmc.compact", e.eMeta);
			case _: false;
		}) ? 1 : 0;
		// (the positions of every statement, natively: a program that reads
		// stacks gets the table of its functions and lines, which Reach finds
		// out after the lowering, StackTable; -debug writes DWARF lines from
		// them; they change no code)
		hxmc.ir.Lower.lines = (opts.debugLines || opts.stacks) && !abi.wasm;
		hxmc.ir.Reach.stacksAlways = opts.stacksAlways;
		// the runtime's symbols generated code may call by name, defined by the
		// modules hxmc.rt.Runtime imports for the target, whatever this program calls
		hxmc.ir.RuntimeSymbols.check(com, abi.wasm ? hxmc.ir.RuntimeSymbols.WASM32 : hxmc.ir.RuntimeSymbols.NATIVE, abi.name);
		// -D hxmc.header-check=<file>: the declarations checked against C's headers (HeaderCheck)
		var headerCheck = Options.flag("hxmc.header-check", com.defines);
		hxmc.ir.HeaderCheck.start(headerCheck);
		var t0 = haxe.Timer.stamp();
		hxmc.ir.KernelCheck.seconds = 0;
		var prog = hxmc.ir.Lower.program(mainClass, com.types, com.basic);
		if (opts.stats) {
			Sys.println('hxmc: lowering ${Std.int((haxe.Timer.stamp() - t0) * 1000)} ms (since start ${Std.int((t0 - start) * 1000)} ms)');
			Sys.println('hxmc: raw memory check ${Std.int(hxmc.ir.RawCheck.seconds * 1000)} ms, kernel check ${Std.int(hxmc.ir.KernelCheck.seconds * 1000)} ms');
		}
		if (headerCheck != null) hxmc.ir.HeaderCheck.write(headerCheck, abi.name);
		if (Options.on("hxmc.lower-only", false, com.defines)) return; // (profiling the lowering)
		if (beforeCodegen != null) beforeCodegen(com, prog);
		// (a Mir host: the std's types)
		Driver.hostIdents = opts.mirHost ? hxmc.macro.HostTable.idents(com) : null;
		Driver.run(prog, out, opts);
	}
}
