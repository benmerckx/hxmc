import Harness.*;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using StringTools;

// The build: every target the repository has, on Linux, macOS and Windows
// alike, with node and git alone (README.md, docs/development.md). Run from
// the repository root through make.mjs, which builds the first tool from the
// committed stage0 when there is none:
//   node make.mjs <target>... [NAME=value]... [-o <file>]...
// or on a tool's Eval: bin/hxmc/hxmc -cp tools/make -cp haxe/test --run Make ...
// `node make.mjs help` lists the targets and variables (HELP below). A
// variable comes from its NAME=value argument, else the environment, else
// its default (Make.vars). -o <file>: the file is up to date whatever its
// prerequisites (a release binary a CI job downloaded). Targets build in
// order, each output only when a prerequisite is newer, as make does; the
// tool's module cache makes the builds themselves incremental. Commands run
// without a shell (Harness.spawn: libuv).
class Make {
	static final HELP = "
node make.mjs <target>... [NAME=value]...

Build
  hxmc        bin/hxmc/hxmc: the tool, built by the previous tool from source (the first one by
              bin/hxmc/boot/hxmc1, which the stage0 module builds under node)
  bootstrap   the stage-1 compiler from the stage0 again, the tool by it, then the fixpoint
  port        PORT_BIN (bin/port/haxe): the port for the host, built by hxmc (seconds after an edit)
  lix         bin/lix/lix (+ haxe, haxelib, neko): lix (tools/lix) for the host
  reference   REFERENCE (bin/reference/haxe): the nightly of the pinned upstream commit, by lix
  stage0      hxmc/bootstrap/stage0.wasm.br: the tool as a wasm32-wasi module, brotli (commit it
              when the sources need a newer one)
  rt          the runtime objects (bin/hxmc/rt/<target>/{rt,ssl,uv}.o): the release rt-<hash of
              hxmc/deps> (hxmc/bootstrap/rt.mjs), else rt-build: zig, mbedtls and libuv (hxmc/deps;
              zig and a POSIX shell); rt-target: RT_TARGET's alone, rt-layouts: the committed
              layouts checked (CI's rt jobs)
  std         bin/hxmc/std: hxmc's std merged with upstream's (hxmc.MkStd)

Test (docs/testing.md; the tiers: hxmc/test/Tiers.hx)
  quick       after every edit of hxmc: the tool, the x64 corpus, again with RT_VERIFY=1 and
              -D hxmc.verify-tags, the wasm corpus under node, the unit checks (CASES restricts
              the corpus)
  check       before a commit: quick + arm64 (qemu), wine, a 16 KB nursery, legacy exception handling,
              the glibc mode, ThreadNatives x30, crosshost on three cases, debug info, the native
              output; PORT=1 adds the native port's self-compile
  test        the port against the reference, the lanes of LANES (default hxb; CI's conformance jobs):
              hxb, macro, hxblib (HXB of the three case lists, Conformance; CASES_FILE for hxb),
              display, server, jsonrpc, interp (--interp runs), haxelib (-L, batch and server),
              libs (hxmc's -lib resolution against haxelib and lix's haxe shim),
              debugger (the Eval debugger; SHARD=i/n), targets (upstream's unit suite compiled for
              each target by both, compared), unit (unit tests of port modules, in-process)
  test-fuzz   the fuzzer on PORT_BIN: LANE (default diff:hxb), the kept programs, then N programs
  fixpoint    the tool rebuilds itself byte-identical (the module cache cold, warm and off)
  crosshost   the tool as a WebAssembly module builds the corpus and itself byte-identical to the
              native tool (hxmc/test/Crosshost.hx; CROSSHOST_ARGS)
  units       root facts, the module cache's store, the runtime objects' search, the frontends'
              seam (hxmc/test/Units.hx)
  native-check  the native output a packager builds on (hxmc/test/NativeCheck.hx): shared
              libraries and Android's .so, Java through JNI, iOS's Mach-O, a UIKit app (a Mac
              with Xcode), the C declarations against each target's headers (zig); NATIVE: one part
  mir-check   the Mir lane (hxmc/test/MirCheck.hx): bin/npm/native/HOST/haxe running the corpus
              in itself, the macro cases with Mir macros against the reference, its compiled
              functions kept across builds, its statics in the compilation server
  portable-check  hxmc's spans on Eval and JavaScript, built by the reference (reference),
              print what hxmc's builds print (hxmc/test/PortableCheck.hx)
  upstream-suites  upstream's runtime suites (tests/unit, sys, threads) built by hxmc and run
              (hxmc/test/UpstreamSuites.hx; SUITES: a subset, SUITES_TARGET=native|wasm32-wasi)
  test-module-cache  the module cache's gate: the same outputs with and without it, for hxmc and
              JS (hxmc/test/ModuleCacheCheck.hx; PORT=1 adds the port itself)
  dev-check   the dev loop: `hxmc dev` through edits and a compile error, the compilation server's
              builds against fresh ones (hxmc/test/dev)
  corpus-stage, test-libraries  CI's: the corpus cross-built for CORPUS_TARGETS (bin/corpus),
              -lib (lix's scopes, node_modules, haxelib) with the npm package's compiler
  corpus-verify  the corpus with -D hxmc.verify-tags and RT_VERIFY=1 for VERIFY_TARGET (the host's,
              or wasm32-wasi): a type parameter's tagged word read as a reference fails it
  smoke       the release binary BIN (default RELEASE_BIN) on this machine: TLS, libuv, --interp,
              a native build (hxmc/test/Smoke.hx)

Bench (docs/testing.md, \"Benchmarks\")
  bench       the HaxeBenchmarks cases on hxmc, C++, JVM, JS, HL/C and HL (hxmc/test/Bench.hx; BENCH_ARGS)
  bench-compile  the port against the reference compiling hello, stdlib and itself to HXB
              (hxmc/test/CompileBench.hx; COMPILE_BENCH_ARGS)
  bench-micro WHICH=arrays|maps (default both): Array vs NativeArray vs Vector (ARRAY_BENCH_ARGS),
              ObjectMap and StringMap (MAP_BENCH_ARGS)
  bench-simd  image kernels, scalar and with hxmc.simd, natively, as wasm and in C (CC; SIMD_BENCH_ARGS)
  measure     peak memory and time of the self-compile (ours, the reference) and of the tool's
              builds (haxe/test/Measure.hx)

Site & release
  site        bin/site: the website (site/; LIX_DIR's lix binaries, BENCH_DATA's benchmark history)
  site-check  bin/site in headless browsers (site/tools/browser-test.mjs; Playwright; BROWSERS)
  release     bin/release/TARGET/haxe[.exe]: the port cross-built by hxmc, with mbedtls and libuv
  lix-dist    bin/lix-dist/lix-<target>[.exe]: lix for the six targets (the release, the site's tools/)
  npm         bin/npm/*.tgz: the npm packages of packages/ (packages/pack.mjs; NPM_VERSION)
  wasm, fuzz  bin/wasm/hih[-legacy].wasm (the playground's compiler), bin/fuzz/fuzz (the fuzzer)
  <file>      one output: bin/npm/native/<target>/haxe[.exe], bin/release/<target>/haxe[.exe] or
              lix[.exe], bin/port/haxe, ...

Dev
  clean       remove the build outputs (keeps the tool, the runtime objects and the reference)
  distclean   also remove bin/ entirely

Variables (NAME=value, else the environment, else the default):
  JOBS (the CPUs), NODE (node), ZIG (zig), HOST (this machine), TARGET (HOST), RT_TARGET (HOST),
  CORPUS_TARGETS (the six, wasm32-wasi, wasm32-wasi-legacy, both glibc ones), HXFLAGS (the port's
  build), PORT_BIN, REFERENCE, LANES (hxb), SHARD, LANE (diff:hxb), N (200), EVAL (the tool),
  FUZZ (bin/fuzz/fuzz), SUMMARY (a Markdown file the harnesses append to), CASES, CASES_FILE, PORT,
  LIX_DIR, BENCH_DATA, BENCH_ARGS, COMPILE_BENCH_ARGS, WHICH, ARRAY_BENCH_ARGS, MAP_BENCH_ARGS,
  SIMD_BENCH_ARGS, CC, CROSSHOST_ARGS (--tool), SUITES, SUITES_TARGET, VERIFY_TARGET (HOST), NATIVE,
  NPM_VERSION (packages/cli/package.json's), SITE_VERSION (the commit), BROWSERS, BIN
";

	// the targets of the tool and of the release binaries
	static final TARGETS = ["linux-x86_64", "linux-arm64", "windows-x86_64", "windows-arm64", "macos-x86_64", "macos-arm64"];
	// the runtime objects: the six targets, Linux in the dynamic glibc mode (-D hxmc.libc=glibc), Android
	static final RT_TARGETS = TARGETS.concat(["linux-x86_64-glibc", "linux-arm64-glibc", "android-arm64", "android-x86_64"]);
	static final STAGE0 = "hxmc/bootstrap/stage0.wasm.br";
	static final STD = "bin/hxmc/std/.stamp";
	// hxmc's std merged with the Eval originals for macros, given last
	static final HXMC_ARGS = ["-cp", "bin/hxmc/std", "--custom-target", "hxmc"];
	// the compilers' runtime: the collector's helper thread that faults in the
	// old space's pages ahead of the minor collections
	static final COMPILER_ARGS = ["-D", "hxmc.gc-prefault"];
	// the tool: the port (haxe/src) with hxmc (hxmc/src) as its generate hook,
	// typed against hxmc's std, without the port's other target generators
	// (as make.mjs's TOOL_ARGS, which builds the stage-1 compiler)
	static final TOOL_ARGS = ["-cp", "haxe/src", "-cp", "hxmc/src", "-main", "hxmc.Main", "-D", "disable-parallelism", "-D", "hih_no_generators", "-cp",
		"bin/hxmc/std"].concat(COMPILER_ARGS).concat(["--custom-target", "hxmc"]);
	// `haxe` with hxmc built in (the npm package's compiler: every generator)
	static final PKG_ARGS = ["-cp", "haxe/src", "-cp", "hxmc/src", "-main", "hxmc.HaxeMain", "-D", "disable-parallelism"].concat(COMPILER_ARGS)
		.concat(HXMC_ARGS);
	// what @hxmc/cli ships besides its sources (packages/cli): hxmc's merged std
	static final CLI_BOOT = "packages/cli/hxmc/bootstrap";
	static final HXCORO = "bin/hxcoro";
	static final HXCORO_REV = "e8e26f8d374919d508d777f73b2fe51daa347184";
	// Mozilla's CA certificates (curl's extract), trusted besides the system's
	// (Windows' preinstalled roots lack common ones), as a generated module
	static final CACERT = "cacert-2026-09-25.pem";
	static final CACERT_SHA256 = "a41b5d356aea97a529fe27e0f7316d2f9d946d75927476cf9cf1b90637d00505";
	// the lanes of `test` (LANES): each one's harness and arguments (haxe/test/*.hx)
	static final TEST_LANES = ["hxb", "macro", "hxblib", "display", "server", "jsonrpc", "interp", "haxelib", "libs", "debugger", "targets", "unit"];

	static var vars = new Map<String, String>();
	static var old = new Map<String, Bool>();
	static var done = new Map<String, Bool>();
	// make.mjs just built the stage-1 compiler (bootstrap needs no other)
	static var freshStage1 = false;
	// make.mjs just built linux-x86_64's runtime objects with zig (rt-build's first step)
	static var freshRt = false;

	static var HOST:String;
	static var TOOL:String;
	static var BOOT:String;
	static var HOST_RT:String;
	static var JOBS:String;

	static function main() {
		var targets = [];
		var args = Sys.args();
		var i = 0;
		while (i < args.length) {
			var a = args[i++];
			if (a == "-o" && i < args.length) old[norm(args[i++])] = true;
			else if (a == "--fresh-stage1") freshStage1 = true;
			else if (a == "--fresh-rt") freshRt = true;
			else if (~/^[A-Z][A-Z0-9_]*=/.match(a)) vars[a.substr(0, a.indexOf("="))] = a.substr(a.indexOf("=") + 1);
			else targets.push(a);
		}
		HOST = v("HOST", host);
		TOOL = "bin/hxmc/hxmc" + exe(HOST);
		BOOT = "bin/hxmc/boot/hxmc1" + exe(HOST);
		HOST_RT = 'bin/hxmc/rt/$HOST/rt.o';
		JOBS = v("JOBS", () -> "" + cpus());
		// the upstream std, for every compiler run below; the runtime objects for
		// every build by the tool (also as a WebAssembly module)
		Sys.putEnv("HAXE_STD_PATH", abs("haxe/upstream/std"));
		Sys.putEnv("HXMC_RT_DIR", abs("bin/hxmc/rt"));
		Sys.putEnv("ZIG", v("ZIG", () -> "zig"));
		if (targets.length == 0) targets = ["help"];
		try {
			for (t in targets) make(t);
		} catch (e:Failure) {
			Sys.println("make: " + e.message);
			Sys.exit(1);
		}
	}

	// --- Variables ---

	static function v(name:String, dflt:Void->String):String {
		if (vars.exists(name)) return vars[name];
		var e = Sys.getEnv(name);
		var r = e != null ? e : dflt();
		vars[name] = r;
		return r;
	}

	static function words(name:String, dflt:String):Array<String>
		return [for (w in ~/\s+/g.split(v(name, () -> dflt).trim())) if (w != "") w];

	static function exe(target:String):String
		return target.startsWith("windows") ? ".exe" : "";

	// the machine the tool runs on (its own runtime object)
	static function host():String {
		var os = switch Sys.systemName() {
			case "Windows": "windows";
			case "Mac": "macos";
			case _: "linux";
		}
		var m = if (windows) {
			(Sys.getEnv("PROCESSOR_ARCHITEW6432") ?? Sys.getEnv("PROCESSOR_ARCHITECTURE") ?? "").toLowerCase();
		} else {
			var r = spawn(["uname", "-m"]);
			r.out.trim();
		}
		return os + "-" + (m == "aarch64" || m == "arm64" ? "arm64" : "x86_64");
	}

	static function portBin() return v("PORT_BIN", () -> "bin/port/haxe" + exe(HOST));

	// (Windows: the nightly where lix put it, beside its DLLs and std; elsewhere a link to it)
	static function reference()
		return v("REFERENCE", () -> windows ? 'bin/reference/lix/versions/${upstreamRev()}/haxe.exe' : "bin/reference/haxe");

	static function upstreamRev():String
		return output(["git", "rev-parse", "--short=7", "HEAD:haxe/upstream"]).trim();

	static function hostHaxe() return 'bin/npm/native/$HOST/haxe' + exe(HOST);

	static function releaseBin() {
		var t = v("TARGET", () -> HOST);
		return 'bin/release/$t/haxe' + exe(t);
	}

	// --- Running ---

	static function norm(p:String):String
		return p.replace("\\", "/");

	static function abs(p:String):String
		return Path.isAbsolute(p) ? norm(p) : norm(root) + "/" + norm(p);

	static function show(cmd:Array<String>)
		Sys.println([for (a in cmd) a == "" || ~/[\s"'$]/.match(a) ? '"' + a.replace('"', '\\"') + '"' : a].join(" "));

	// cmd with this process's streams; false when it failed
	static function sh(cmd:Array<String>, ?env:Map<String, Null<String>>, ?cwd:String):Bool {
		show(cmd);
		var r = spawn(cmd, {inherit: true, env: env, cwd: cwd});
		if (r.code == 127 && r.err != "") Sys.println(r.err);
		return r.code == 0;
	}

	static function run(cmd:Array<String>, ?env:Map<String, Null<String>>, ?cwd:String)
		if (!sh(cmd, env, cwd)) throw new Failure(cmd[0] + " failed");

	// cmd with its output to a log, shown when it fails
	static function logged(cmd:Array<String>, log:String, ?env:Map<String, Null<String>>) {
		show(cmd);
		mkdirs(Path.directory(log));
		var r = spawn(cmd, {log: log, env: env});
		if (r.code != 0) {
			Sys.println(readText(log));
			throw new Failure(cmd[0] + " failed (" + log + ")");
		}
	}

	static function output(cmd:Array<String>):String {
		var r = spawn(cmd);
		if (r.code != 0) throw new Failure(cmd.join(" ") + ": " + r.err);
		return r.out;
	}

	// a Haxe script on Eval: the tool, else the stage-1 compiler
	static function evalTool():String
		return FileSystem.exists(TOOL) ? TOOL : BOOT;

	// the test scripts (haxe/test, hxmc/test) on the tool's Eval
	static function script(name:String, args:Array<String>, ?env:Map<String, Null<String>>)
		run([TOOL, "-cp", "hxmc/test", "-cp", "haxe/test", "-cp", "hxmc/src", "--run", name].concat(args), env);

	// a build by the tool, its log next to the output
	static function hxmc(out:String, args:Array<String>) {
		logged([TOOL, out].concat(args), out + ".log");
		size(out);
	}

	static function size(f:String)
		Sys.println(f + ": " + FileSystem.stat(f).size + " bytes");

	// --- Up to date ---

	static var trees = new Map<String, Array<String>>();

	// the files (and directories: a file deleted changes only its directory's
	// time) under dir, ext only when given
	static function tree(dir:String, ?ext:String):Array<String> {
		var key = dir + ":" + ext;
		if (trees.exists(key)) return trees[key];
		var out = [];
		function go(d:String) {
			if (!FileSystem.exists(d)) return;
			if (ext == null) out.push(d);
			for (n in FileSystem.readDirectory(d)) {
				var p = d + "/" + n;
				if (FileSystem.isDirectory(p)) go(p) else if (ext == null || n.endsWith(ext)) out.push(p);
			}
		}
		go(dir);
		trees[key] = out;
		return out;
	}

	static function portSrc() return tree("haxe/src", ".hx");

	static function hxmcSrc() return tree("hxmc/src", ".hx");

	// out is older than one of deps, or missing (-o: never, and never newer)
	static function stale(out:String, deps:Array<String>):Bool {
		if (old.exists(norm(out))) return false;
		if (!FileSystem.exists(out)) return true;
		var t = mtime(out);
		for (d in deps)
			if (!old.exists(norm(d)) && FileSystem.exists(d) && mtime(d) > t) return true;
		return false;
	}

	// a file's modification time now (FileSystem has no utime: written again)
	static function touch(f:String)
		File.saveBytes(f, FileSystem.exists(f) ? File.getBytes(f) : haxe.io.Bytes.alloc(0));

	// a new build of a program over the old one, which may be running (Windows
	// renames a running executable but neither deletes nor replaces it)
	static function replace(next:String, to:String) {
		if (FileSystem.exists(to)) {
			var gone = to + ".old";
			try FileSystem.deleteFile(gone) catch (_:Dynamic) {}
			if (FileSystem.exists(gone)) gone = to + ".old." + Std.random(1000000);
			FileSystem.rename(to, gone);
			try FileSystem.deleteFile(gone) catch (_:Dynamic) {}
		}
		FileSystem.rename(next, to);
	}

	// --- Targets ---

	static function make(t:String) {
		if (done.exists(t)) return;
		done[t] = true;
		switch t {
			case "help": Sys.print(HELP);
			case "std": std();
			case "rt": rt();
			case "rt-build": rtBuild();
			case "rt-target": rtTarget();
			case "rt-layouts": rtLayouts();
			case "hxmc": tool();
			case "bootstrap": bootstrap();
			case "fixpoint": fixpoint();
			case "stage0": stage0();
			case "crosshost":
				deps();
				script("Crosshost", words("CROSSHOST_ARGS", "--tool").concat(words("CASES", "")));
			case "portable-check":
				tool();
				std();
				script("PortableCheck", [], ["HAXE_REFERENCE" => abs(reference())]);
			case "port": file(portBin());
			case "release": file(releaseBin());
			case "wasm":
				file("bin/wasm/hih.wasm");
				file("bin/wasm/hih-legacy.wasm");
			case "fuzz": file("bin/fuzz/fuzz" + exe(HOST));
			case "npm": npm();
			case "site": site();
			case "site-check": run([node(), "site/tools/browser-test.mjs", "bin/site"].concat(words("BROWSERS", "chromium firefox webkit")));
			case "lix": file("bin/lix/lix" + exe(HOST));
			case "lix-dist": lixDist();
			case "reference": file(reference());
			case "test": test();
			case "test-fuzz": testFuzz();
			case "test-libraries":
				deps();
				file(hostHaxe());
				script("Libraries", []);
			case "test-module-cache":
				deps();
				file(hostHaxe());
				script("ModuleCacheCheck", ["--haxe", hostHaxe()].concat(v("PORT", () -> "") != "" ? ["--port"] : []));
			case "upstream-suites": upstreamSuites();
			case "corpus-stage": corpusStage();
			case "corpus-verify":
				deps();
				script("Corpus", ["-v", "--target", v("VERIFY_TARGET", () -> HOST), "--verify-tags"].concat(words("CASES", "")), ["RT_VERIFY" => "1"]);
			case "native-check":
				deps();
				script("NativeCheck", words("NATIVE", ""));
			case "units":
				deps();
				script("Units", []);
			case "dev-check": devCheck();
			case "mir-check":
				deps();
				file(reference());
				file(hostHaxe());
				script("MirCheck", ["--eval", TOOL, "--haxe", hostHaxe(), "--reference", reference(), "-j", JOBS].concat(words("CASES", "")),
					["HXMC_STD" => abs("bin/hxmc/std")]);
			case "smoke": smoke();
			case "bench":
				deps();
				file(portBin());
				file("bin/lix/lix" + exe(HOST));
				script("Bench", words("BENCH_ARGS", ""));
			case "bench-compile":
				deps();
				file(portBin());
				file(reference());
				script("CompileBench", words("COMPILE_BENCH_ARGS", ""));
			case "bench-micro": benchMicro();
			case "bench-simd": benchSimd();
			case "measure":
				deps();
				file(reference());
				file(portBin());
				file("bin/npm/native/wasm32-wasi/haxe.wasm");
				script("Measure", ["--port", portBin()]);
			case "quick":
				deps();
				script("Tiers", ["quick"].concat(words("CASES", "")));
			case "check":
				deps();
				script("Tiers", ["check"].concat(v("PORT", () -> "") != "" ? ["--port"] : []).concat(words("CASES", "")));
			case "clean":
				for (d in [
					"bin/port", "bin/release", "bin/lix-dist", "bin/site", "bin/wasm", "bin/fuzz", "bin/lix", "bin/npm", "bin/stage0", "bin/test", "bin/dev",
					"bin/corpus", "bin/hxmc/boot", "bin/hxmc/fix", "bin/hxmc-t", "bin/hxmc-fuzz", CLI_BOOT + "/hxmc-std"
				])
					rmrf(d);
			case "distclean":
				make("clean");
				// (the running tool stays on Windows)
				try rmrf("bin") catch (_:Dynamic) {}
			case _ if (t.indexOf("/") >= 0):
				file(t);
			case _:
				throw new Failure('no target $t (node make.mjs help)');
		}
	}

	// what most targets need: the tool, the std, the host's runtime objects
	static function deps() {
		tool();
		std();
		rt();
	}

	static function node():String
		return v("NODE", () -> "node");

	// the stage0 module under node (a large stack for the compiler's recursion:
	// wasi.mjs runs it on a thread of that stack)
	static function wasi(module:String):Array<String>
		return [node(), "--stack-size=65500", "hxmc/bootstrap/wasi.mjs", module];

	static function std() {
		if (done.exists(":std")) return;
		done[":std"] = true;
		if (!stale(STD, ["hxmc/src/hxmc/MkStd.hx"].concat(tree("hxmc/std")).concat(tree("hxmc/portable")))) return;
		var eval = FileSystem.exists(TOOL) || FileSystem.exists(BOOT) ? [evalTool()] : wasi(STAGE0);
		run(eval.concat(["-cp", "hxmc/src", "--run", "hxmc.MkStd"]));
	}

	// the published objects of this hxmc/deps, else built here
	static function rt() {
		if (done.exists(":rt")) return;
		done[":rt"] = true;
		if (!stale(HOST_RT, tree("hxmc/deps"))) return;
		show([node(), "hxmc/bootstrap/rt.mjs", "fetch", "bin/hxmc/rt"]);
		var r = spawn([node(), "hxmc/bootstrap/rt.mjs", "fetch", "bin/hxmc/rt"], {inherit: true});
		if (r.code == 2) rtBuild() else if (r.code != 0) throw new Failure("rt.mjs fetch failed");
		for (t in FileSystem.readDirectory("bin/hxmc/rt"))
			if (FileSystem.isDirectory("bin/hxmc/rt/" + t))
				for (o in FileSystem.readDirectory("bin/hxmc/rt/" + t))
					if (o.endsWith(".o")) touch('bin/hxmc/rt/$t/$o');
	}

	// mbedtls and libuv per target (rebuilt only when their versions or flags change)
	static function depsOf(t:String) {
		var stamp = 'bin/hxmc/deps/$t/VERSIONS';
		if (!stale(stamp, ["hxmc/deps/deps.sh"])) return;
		run(["sh", "hxmc/deps/deps.sh", t, 'bin/hxmc/deps/$t']);
		touch(stamp);
	}

	// the host's object needs no tool (Linux: zig cc and ld.lld); the Windows
	// and macOS ones are assembled by the tool (hxmc --mkrt)
	static function rtBuild() {
		for (t in RT_TARGETS)
			depsOf(t);
		if (!freshRt) run(["sh", "hxmc/deps/mkrt.sh", "linux-x86_64"]);
		tool();
		for (t in RT_TARGETS)
			if (t != "linux-x86_64") run(["sh", "hxmc/deps/mkrt.sh", t], ["HXMC" => abs(TOOL)]);
		rtLayouts();
	}

	// one target's objects (with linux-x86_64's, which the tool that assembles
	// the others links)
	static function rtTarget() {
		var t = v("RT_TARGET", () -> HOST);
		depsOf("linux-x86_64");
		depsOf(t);
		if (!freshRt) run(["sh", "hxmc/deps/mkrt.sh", "linux-x86_64"]);
		if (t != "linux-x86_64") {
			tool();
			run(["sh", "hxmc/deps/mkrt.sh", t], ["HXMC" => abs(TOOL)]);
		}
	}

	// the committed layouts are what every target's headers give (bin/hxmc/deps/<target>/include)
	static function rtLayouts() {
		tool();
		run([TOOL, "-cp", "hxmc/deps", "--run", "Layouts", "--check"]);
		File.saveContent("bin/hxmc/rt/HASH", output([node(), "hxmc/bootstrap/rt.mjs", "hash"]));
	}

	// The tool compiles its own source with the previous tool (written next
	// to it, then moved: the running binary is replaced); the first one comes
	// from the stage-1 compiler. A change to code generation reaches the
	// tool's own code on the next rebuild (fixpoint checks that a rebuild
	// changes nothing).
	static function tool(force = false) {
		if (done.exists(":tool") && !force) return;
		done[":tool"] = true;
		std();
		rt();
		if (!force && !stale(TOOL, portSrc().concat(hxmcSrc()).concat([STD, HOST_RT]))) return;
		if (force || !FileSystem.exists(TOOL)) stage1(false);
		var by = force || !FileSystem.exists(TOOL) ? BOOT : TOOL;
		var next = "bin/hxmc/hxmc.new" + exe(HOST);
		logged([by, next].concat(TOOL_ARGS), "bin/hxmc/tool.log");
		replace(next, TOOL);
		for (d in ["bin/hxmc/hxmc.new.hxmc", next + ".hxmc"])
			rmrf(d);
		size(TOOL);
	}

	// the stage0 module builds the first native tool (one thread, about half a
	// minute; make.mjs --stage1)
	static function stage1(force:Bool) {
		if (freshStage1) return;
		if (!force && !stale(BOOT, [STAGE0, STD, HOST_RT])) return;
		run([node(), "make.mjs", "--stage1"]);
		freshStage1 = true;
	}

	static function bootstrap() {
		std();
		rt();
		stage1(true);
		tool(true);
		fixpoint();
	}

	// (the tool rebuilt by itself three times, the same executable each time:
	// with the module cache cold, warm, and off, hxmc/src/hxmc/ModuleCache.hx;
	// the cache in bin/hxmc/fix/cache)
	static function fixpoint() {
		tool();
		var dir = "bin/hxmc/fix", e = exe(HOST);
		rmrf(dir);
		mkdirs(dir);
		logged([TOOL, '$dir/a$e'].concat(TOOL_ARGS), '$dir/a.log');
		for (b in ["cold", "warm"]) {
			logged(['$dir/a$e', '$dir/$b$e'].concat(TOOL_ARGS), '$dir/$b.log', ["HXMC_CACHE" => '$dir/cache', "HXMC_STATS" => "1"]);
			for (l in readText('$dir/$b.log').split("\n"))
				if (l.indexOf("module cache:") >= 0) Sys.println(l.trim());
		}
		logged(['$dir/a$e', '$dir/off$e'].concat(TOOL_ARGS), '$dir/off.log', ["HXMC_MODULE_CACHE" => "0"]);
		var a = File.getBytes('$dir/a$e');
		for (f in ['$dir/cold$e', '$dir/warm$e', '$dir/off$e', TOOL])
			if (File.getBytes(f).compare(a) != 0) throw new Failure('fixpoint: $f differs from $dir/a$e');
		Sys.println("fixpoint: the tool rebuilt by itself is byte-identical (the module cache cold, warm and off)");
		rmrf(dir);
	}

	// a new stage0 (deliberate: commit it when the sources need it)
	static function stage0() {
		tool();
		hxmc("bin/stage0/hxmc.wasm", TOOL_ARGS.concat(["-D", "hxmc.target=wasm32-wasi"]));
		run([
			node(),
			"-e",
			"const z=require('zlib'),fs=require('fs'),[i,o]=process.argv.slice(1),b=fs.readFileSync(i);fs.writeFileSync(o,z.brotliCompressSync(b,{params:{[z.constants.BROTLI_PARAM_QUALITY]:11,[z.constants.BROTLI_PARAM_LGWIN]:24,[z.constants.BROTLI_PARAM_SIZE_HINT]:b.length}}))",
			"bin/stage0/hxmc.wasm",
			STAGE0
		]);
		size(STAGE0);
	}

	// --- Files ---

	// the port (typed with -D disable-parallelism; the binary runs its
	// parallel passes unless its own invocation passes that define)
	static function portArgs():Array<String>
		return ["-cp", "haxe/src", "-main", "haxe.Main", "-D", "disable-parallelism"].concat(COMPILER_ARGS)
			.concat(words("HXFLAGS", ""))
			.concat(HXMC_ARGS);

	static function lixArgs():Array<String>
		return ["-cp", "tools/lix/src", "-cp", "bin/lix/gen", "-cp", HXCORO + "/src", "-main", "lix.cli.Main", "-D", "no-deprecation-warnings"].concat(HXMC_ARGS);

	// one output by its path
	static function file(path:String) {
		path = norm(path);
		if (done.exists("file:" + path) || old.exists(path)) return;
		done["file:" + path] = true;
		var re = ~/^bin\/(release|npm\/native)\/([a-z0-9_-]+)\/(haxe|lix)(\.exe|\.wasm)?$/;
		if (path == norm(portBin())) {
			deps();
			if (stale(path, portSrc().concat([TOOL, STD, HOST_RT]))) hxmc(path, portArgs());
		} else if (path == norm(reference())) {
			referenceBin(path);
		} else if (path == "bin/lix/lix" + exe(HOST)) {
			lixDeps();
			if (stale(path, lixSrc())) {
				hxmc(path, lixArgs());
				for (cmd in ["haxe", "haxelib", "neko"])
					link("lix" + exe(HOST), 'bin/lix/$cmd' + exe(HOST));
			}
		} else if (path == "bin/wasm/hih.wasm" || path == "bin/wasm/hih-legacy.wasm") {
			tool();
			std();
			// the playground's compiler: a wasm32-wasi module (its runtime is
			// Haxe, no runtime object), without the target generators; with
			// exnref, and with the legacy exception-handling instructions for
			// browsers without exnref (the playground fetches one of the two)
			if (stale(path, portSrc().concat([TOOL, STD])))
				hxmc(path, portArgs().concat(["-D", "hih_no_generators", "-D", "hxmc.target=wasm32-wasi"])
					.concat(path.endsWith("legacy.wasm") ? ["-D", "hxmc.wasm-eh=legacy"] : []));
		} else if (path == "bin/fuzz/fuzz" + exe(HOST)) {
			deps();
			var src = tree("haxe/test/fuzz", ".hx").concat(["haxe/test/HlcNames.hx"]);
			if (stale(path, src.concat([TOOL, STD, HOST_RT]))) hxmc(path, ["-cp", "haxe/test/fuzz", "-cp", "haxe/test", "-main", "Fuzz"].concat(HXMC_ARGS));
		} else if (re.match(path)) {
			var kind = re.matched(1), t = re.matched(2), what = re.matched(3);
			var wasm = re.matched(4) == ".wasm";
			if ((t == "wasm32-wasi") != wasm || (re.matched(4) == ".exe") != (exe(t) == ".exe") || (what == "lix" && kind != "release"))
				throw new Failure('no rule for $path');
			if (what == "lix") {
				lixDeps();
				if (stale(path, lixSrc())) hxmc(path, lixArgs().concat(["-D", 'hxmc.target=$t']));
			} else {
				tool();
				std();
				if (!wasm) rt();
				var src = portSrc().concat([TOOL, STD]).concat(wasm ? [] : [HOST_RT]);
				if (kind == "npm/native") src = src.concat(hxmcSrc());
				if (stale(path, src)) hxmc(path, (kind == "release" ? portArgs() : PKG_ARGS).concat(["-D", 'hxmc.target=$t']));
			}
		} else if (path == TOOL) {
			tool();
		} else if (path == STD) {
			std();
		} else
			throw new Failure('no rule for $path');
	}

	// a link to a program (Windows: a copy, links need a privilege there)
	static function link(target:String, at:String) {
		if (windows) File.copy(Path.directory(at) + "/" + target, at) else run(["ln", "-sf", target, at]);
	}

	static function lixSrc():Array<String>
		return tree("tools/lix/src", ".hx").concat([TOOL, STD, HXCORO + "/.rev", "bin/lix/gen/shim/CaBundle.hx", HOST_RT]);

	static function lixDeps() {
		if (done.exists(":lix")) return;
		done[":lix"] = true;
		deps();
		if (!FileSystem.exists(HXCORO + "/.rev")) {
			rmrf(HXCORO);
			run(["git", "init", "-q", HXCORO]);
			run(["git", "-C", HXCORO, "fetch", "-q", "--depth", "1", "https://github.com/HaxeFoundation/hxcoro.git", HXCORO_REV]);
			run(["git", "-C", HXCORO, "checkout", "-q", "FETCH_HEAD"]);
			File.saveContent(HXCORO + "/.rev", HXCORO_REV + "\n");
		}
		var gen = "bin/lix/gen/shim/CaBundle.hx";
		if (stale(gen, ["tools/lix/CaBundle.hx"])) {
			mkdirs("bin/lix");
			download("https://curl.se/ca/" + CACERT, "bin/lix/" + CACERT);
			run([evalTool(), "-cp", "tools/lix", "--run", "CaBundle", "bin/lix/" + CACERT, CACERT_SHA256, "bin/lix/gen"]);
		}
	}

	// a download by node (three tries)
	static function download(url:String, to:String)
		run([
			node(),
			"-e",
			"const [u,o]=process.argv.slice(1);(async()=>{for(let i=1;;i++){try{const r=await fetch(u);if(!r.ok)throw new Error(r.status+' '+u);require('fs').writeFileSync(o,Buffer.from(await r.arrayBuffer()));return}catch(e){if(i>=3){console.error(String(e));process.exit(1)}await new Promise(f=>setTimeout(f,2000*i))}}})()",
			url,
			to
		]);

	static function lixDist() {
		for (t in TARGETS)
			file('bin/release/$t/lix' + exe(t));
		mkdirs("bin/lix-dist");
		for (t in TARGETS)
			File.copy('bin/release/$t/lix' + exe(t), 'bin/lix-dist/lix-$t' + exe(t));
		for (n in FileSystem.readDirectory("bin/lix-dist"))
			size("bin/lix-dist/" + n);
	}

	// the official nightly (build.haxe.org) of the pinned upstream commit,
	// downloaded by lix into bin/reference/lix (HAXESHIM_ROOT); the pin must be
	// a commit with a nightly
	static function referenceBin(path:String) {
		var lix = "bin/lix/lix" + exe(HOST);
		file(lix);
		if (!stale(path, [lix])) return;
		var rev = upstreamRev();
		mkdirs("bin/reference");
		run([abs(lix), "download", "haxe", rev], ["HAXESHIM_ROOT" => abs("bin/reference/lix")], "bin/reference");
		var bin = 'bin/reference/lix/versions/$rev/haxe' + exe(HOST);
		if (norm(path) != bin) link('lix/versions/$rev/haxe' + exe(HOST), path);
		run([path, "-version"]);
	}

	// --- The npm packages (packages/, packed by packages/pack.mjs) ---

	static function npm() {
		// (the platform packages take the runtime objects from bin/hxmc/rt)
		var stamp = CLI_BOOT + "/hxmc-std/.stamp";
		rt();
		if (stale(stamp, ["hxmc/src/hxmc/MkStd.hx"].concat(tree("hxmc/std")).concat(tree("hxmc/portable"))))
			run([evalTool(), "-cp", "hxmc/src", "--run", "hxmc.MkStd", "hxmc/std", "haxe/upstream/std", CLI_BOOT + "/hxmc-std"]);
		for (t in TARGETS)
			file('bin/npm/native/$t/haxe' + exe(t));
		var version = v("NPM_VERSION", () -> haxe.Json.parse(File.getContent("packages/cli/package.json")).version);
		if (FileSystem.exists("bin/npm"))
			for (n in FileSystem.readDirectory("bin/npm"))
				if (n.endsWith(".tgz")) FileSystem.deleteFile("bin/npm/" + n);
		run([node(), "packages/pack.mjs", version, "bin/npm/native", "bin/npm"]);
		for (n in FileSystem.readDirectory("bin/npm"))
			if (n.endsWith(".tgz")) size("bin/npm/" + n);
	}

	// --- The website (site/) ---

	// Plain pages (site/*.html: About, Benchmarks, Playground) with the
	// stylesheet, their scripts (site/client, compiled by the port:
	// site/build.hxml), the playground's compiler (bin/wasm) and examples, the
	// std subset its compiler reads (site/tools/MkBundle.hx), the measured
	// results (site/data), lix under tools/ (LIX_DIR), the benchmark histories
	// (BENCH_DATA: the programs', the compiler's, the target generators') and
	// the build facts (build-info.json). The site's build in the addresses of
	// the files its pages fetch (Version.hx, and the pages' scripts and
	// stylesheet): a deploy reaches browsers at once.
	static function site() {
		make("wasm");
		deps();
		file(portBin());
		var version = v("SITE_VERSION", () -> try output(["git", "rev-parse", "--short", "HEAD"]).trim() catch (_:Failure) "dev");
		rmrf("bin/site");
		mkdirs("bin/site");
		for (n in FileSystem.readDirectory("site"))
			if (n.endsWith(".html"))
				File.saveContent("bin/site/" + n, ~/(src|href)="([a-z]*\.(js|css))"/g.replace(File.getContent("site/" + n), '$1="$2?v=$version"'));
		for (f in ["site/style.css", "site/favicon.svg", "bin/wasm/hih.wasm", "bin/wasm/hih-legacy.wasm"])
			File.copy(f, "bin/site/" + Path.withoutDirectory(f));
		run([portBin(), "-D", 'site_version=$version', "site/build.hxml"]);
		run([evalTool(), "-cp", "site/tools", "--run", "MkBundle", Sys.getEnv("HAXE_STD_PATH"), "bin/site/std.bundle"]);
		for (n in FileSystem.readDirectory("site/data"))
			if (n.endsWith(".json")) File.copy("site/data/" + n, "bin/site/" + n);
		copyTree("site/playground", "bin/site/playground");
		var lixDir = v("LIX_DIR", () -> "");
		if (lixDir != "") {
			mkdirs("bin/site/tools");
			for (n in FileSystem.readDirectory(lixDir))
				if (n.startsWith("lix-")) File.copy(lixDir + "/" + n, "bin/site/tools/" + n);
		}
		var bench = v("BENCH_DATA", () -> "");
		if (bench != "") {
			if (FileSystem.exists(bench + "/history.json")) {
				mkdirs("bin/site/bench");
				File.copy(bench + "/history.json", "bin/site/bench/history.json");
				if (FileSystem.exists(bench + "/latest.json")) File.copy(bench + "/latest.json", "bin/site/bench/latest.json");
			}
			if (FileSystem.exists(bench + "/targets.json")) File.copy(bench + "/targets.json", "bin/site/targets.json");
			if (FileSystem.exists(bench + "/compile-history.json")) {
				mkdirs("bin/site/bench");
				for (n in ["compile-history.json", "compile-latest.json"])
					File.copy(bench + "/" + n, "bin/site/bench/" + n);
			}
		}
		// (sizes in MB, gzipped at level 9 as gzip -9 does)
		var sizes = output([
			node(),
			"-e",
			"const z=require('zlib'),fs=require('fs'),mb=n=>(n/1048576).toFixed(1)+' MB',gz=f=>mb(z.gzipSync(fs.readFileSync(f),{level:9}).length);"
			+ "const l='bin/site/tools/lix-linux-x86_64';console.log(JSON.stringify([mb(fs.statSync('bin/site/hih.wasm').size),gz('bin/site/hih.wasm'),gz('bin/site/hih-legacy.wasm'),gz('bin/site/std.bundle'),fs.existsSync(l)?mb(fs.statSync(l).size):'-']))"
		]);
		var s:Array<String> = haxe.Json.parse(sizes);
		var now = Date.now();
		var utc = DateTools.delta(now, now.getTimezoneOffset() * 60000.0);
		var info = '{\n\t"date": "${DateTools.format(utc, "%Y-%m-%d")}",\n\t"commit": "${output(["git", "rev-parse", "--short", "HEAD"]).trim()}",\n'
			+ '\t"wasmSize": "${s[0]}",\n\t"wasmGz": "${s[1]}",\n\t"wasmLegacyGz": "${s[2]}",\n\t"dataGz": "${s[3]}",\n\t"lixSize": "${s[4]}"\n}\n';
		File.saveContent("bin/site/build-info.json", info);
		Sys.print(info);
	}

	// --- Tests (docs/testing.md) ---

	static function laneCmd(lane:String, eval:Array<String>):Array<String> {
		var j = ["-j", JOBS];
		var h:Array<String> = switch lane {
			case "hxb": ["Conformance"].concat(j).concat(["--cases", v("CASES_FILE", () -> "haxe/test/conformance-cases.txt")]);
			case "macro": ["Conformance"].concat(j).concat(["--cases", "haxe/test/conformance-macro-cases.txt"]);
			case "hxblib": ["Conformance"].concat(j).concat(["--cases", "haxe/test/conformance-hxblib-cases.txt", "--hxb-lib"]);
			case "display": ["Display"].concat(j);
			case "server": ["Server"].concat(j);
			case "jsonrpc": ["ServerJsonRpc"];
			case "interp": ["Interp"].concat(j);
			case "haxelib": ["Haxelib", "--server"];
			// (hxmc/test/LibResolution.hx: hxmc/src/hxmc/libs against haxelib, the reference's, and lix's haxe shim)
			case "libs":
				["LibResolution", "--haxelib", Path.directory(FileSystem.fullPath(reference())) + "/haxelib" + exe(HOST), "--lix", "bin/lix/haxe" + exe(HOST)];
			case "debugger": ["EvalDebugger"].concat(v("SHARD", () -> "") != "" ? ["--shard", v("SHARD", () -> "")] : []);
			case "targets": ["UpstreamTargets"].concat(j);
			case _: throw new Failure('test: no lane $lane (LANES: ${TEST_LANES.join(" ")})');
		}
		var summary = v("SUMMARY", () -> "");
		return eval.concat(["-cp", "hxmc/test", "-cp", "haxe/test"]).concat(lane == "libs" ? ["-cp", "hxmc/src"] : []).concat(["--run"]).concat(h)
			.concat(summary != "" ? ["--summary", summary] : []);
	}

	// every lane runs, the failed ones named at the end (lix: -L's shim, the
	// targets' libraries)
	static function test() {
		var lanes = words("LANES", "hxb");
		for (l in lanes)
			if (!TEST_LANES.contains(l)) throw new Failure('test: no lane $l (LANES: ${TEST_LANES.join(" ")})');
		file(portBin());
		file(reference());
		if (lanes.contains("haxelib") || lanes.contains("libs") || lanes.contains("targets")) file("bin/lix/lix" + exe(HOST));
		var evalWords = words("EVAL", "");
		if (evalWords.length == 0) {
			tool();
			evalWords = [TOOL];
		}
		var env:Map<String, Null<String>> = ["HAXE_REFERENCE" => abs(reference()), "HAXE_IN_HAXE_PORT" => abs(portBin())];
		var failed = [];
		for (l in lanes) {
			// (unit: haxe/test/unit.hxml, the port's modules typed and run
			// in-process: no harness, no reference, no summary)
			var cmd = l == "unit" ? evalWords.concat(["--cwd", ".", "haxe/test/unit.hxml"]) : laneCmd(l, evalWords);
			if (!sh(cmd, env)) failed.push(l);
		}
		if (failed.length > 0) throw new Failure("test: failed: " + failed.join(" "));
	}

	// (the kept programs, then N random ones; both run, either failing fails)
	static function testFuzz() {
		var fuzz = words("FUZZ", "bin/fuzz/fuzz" + exe(HOST));
		if (fuzz[0] == "bin/fuzz/fuzz" + exe(HOST) || fuzz[0] == norm(portBin())) file(fuzz[0]);
		file(portBin());
		file(reference());
		var env:Map<String, Null<String>> = ["HAXE_REFERENCE" => abs(reference())];
		var lane = v("LANE", () -> "diff:hxb"), port = abs(portBin());
		var failed = [];
		if (!sh(fuzz.concat(["-j", JOBS, "--cases", "haxe/test/fuzz/cases", "--port", port, "--lane", lane]), env)) failed.push("cases");
		if (!sh(fuzz.concat(["-j", JOBS, "-n", v("N", () -> "200"), "--port", port, "--lane", lane]), env)) failed.push("random");
		if (failed.length > 0) throw new Failure('test-fuzz $lane: failed: ' + failed.join(" "));
	}

	// upstream's runtime suites on hxmc (docs/testing.md): unit, sys and threads
	// natively, unit on wasm32-wasi; SUITES and SUITES_TARGET narrow it
	static function upstreamSuites() {
		deps();
		file("bin/lix/lix" + exe(HOST));
		var suites = words("SUITES", ""), only = v("SUITES_TARGET", () -> "");
		var failed = [];
		var base = [TOOL, "-cp", "hxmc/test", "-cp", "haxe/test", "-cp", "hxmc/src", "--run", "UpstreamSuites"];
		if (only != "wasm32-wasi" && !sh(base.concat(suites))) failed.push("native");
		if (only != "native" && !sh(base.concat(["--target", "wasm32-wasi"]).concat(suites.length > 0 ? suites : ["unit"]))) failed.push("wasm32-wasi");
		if (failed.length > 0) throw new Failure("upstream-suites: failed: " + failed.join(" "));
	}

	static function corpusStage() {
		deps();
		for (t in words("CORPUS_TARGETS", TARGETS.concat(["wasm32-wasi", "wasm32-wasi-legacy", "linux-x86_64-glibc", "linux-arm64-glibc"]).join(" "))) {
			var a = if (t == "wasm32-wasi-legacy") ["--target", "wasm32-wasi", "--wasm-eh", "legacy"] else if (t.endsWith("-glibc"))
				["--target", t.substr(0, t.length - 6), "--libc", "glibc"] else ["--target", t];
			rmrf('bin/corpus/$t');
			script("Corpus", ["-v"].concat(a).concat(["--stage", 'bin/corpus/$t']));
			if (t.endsWith("-glibc")) script("NativeCheck", ["elf", 'bin/corpus/$t']);
			else if (!t.startsWith("wasm")) script("DebugCheck", ["--target", t, "--stage", 'bin/corpus/$t/_debug']);
		}
	}

	// the dev loop (docs/dev.md): `hxmc dev` on a console program through edits
	// and a compile error (dev-console.mjs), then the compilation server's
	// builds through edits against fresh ones (server-verify.mjs), the tool's
	// and a frontend's whose hook rewrites bodies (hxmc/test/frontend/Hook.hx)
	static function devCheck() {
		deps();
		run([node(), "hxmc/test/dev/dev-console.mjs", TOOL, "bin/dev/console"]);
		run([node(), "hxmc/test/dev/server-verify.mjs", TOOL]);
		mkdirs("bin/dev");
		var hook = "bin/dev/hook" + exe(HOST);
		run([
			TOOL, hook, "-cp", "haxe/src", "-cp", "hxmc/src", "-cp", "hxmc/test/frontend", "-main", "Hook", "-D", "disable-parallelism", "-D",
			"hih_no_generators", "-cp", "bin/hxmc/std", "--custom-target", "hxmc"
		], ["HXMC_STD" => abs("bin/hxmc/std")]);
		run([node(), "hxmc/test/dev/server-verify.mjs", hook, "frontend"], ["HXMC_STD" => abs("bin/hxmc/std")]);
	}

	// the release binary on this machine (CI's test jobs: the binary they
	// downloaded, BIN)
	static function smoke() {
		var bin = v("BIN", () -> "");
		if (bin == "") {
			file(releaseBin());
			bin = releaseBin();
		}
		run([bin, "-cp", "hxmc/test", "-cp", "haxe/test", "--run", "Smoke", abs(bin)]);
	}

	// --- Benchmarks ---

	// the microbenchmarks of WHICH: arrays (hxmc/test/bench/VectorBench.hx,
	// hxmc/test/bench/README.md), maps (hxmc/test/bench/MapBench.hx)
	static function benchMicro() {
		var which = words("WHICH", "arrays maps");
		for (w in which)
			if (w != "arrays" && w != "maps") throw new Failure('bench-micro: no microbenchmark $w (WHICH: arrays maps)');
		deps();
		var e = exe(HOST);
		for (w in which) {
			var out = w == "arrays" ? 'bin/vector-bench/m$e' : 'bin/map-bench/m$e';
			var src = w == "arrays" ? ["hxmc/test/bench/VectorBench.hx", "hxmc/test/bench/VectorBenchMacro.hx"] : ["hxmc/test/bench/MapBench.hx"];
			if (stale(out, src.concat([TOOL, STD, HOST_RT])))
				hxmc(out, ["-cp", "hxmc/test/bench", "-main", w == "arrays" ? "VectorBench" : "MapBench"].concat(HXMC_ARGS));
		}
		for (w in which)
			run([w == "arrays" ? 'bin/vector-bench/m$e' : 'bin/map-bench/m$e'].concat(words(w == "arrays" ? "ARRAY_BENCH_ARGS" : "MAP_BENCH_ARGS", "")));
	}

	// the image kernels, scalar and with hxmc.simd (hxmc/test/bench/simd,
	// docs/plans/simd.md, "Benchmarks"): hxmc natively and as a wasm32-wasi
	// module under node, then the C version at -O2, at -O3 without the
	// vectorizers and at -O3, and with SSE4.1 intrinsics at -O2 (CC;
	// SIMD_BENCH_ARGS: the scale)
	static function benchSimd() {
		deps();
		var dir = "hxmc/test/bench/simd", e = exe(HOST), args = words("SIMD_BENCH_ARGS", ""), cc = words("CC", "cc");
		var hx = [TOOL, STD, HOST_RT, '$dir/SimdBench.hx'];
		if (stale('bin/simd-bench/m$e', hx)) hxmc('bin/simd-bench/m$e', ["-cp", dir, "-main", "SimdBench"].concat(HXMC_ARGS));
		if (stale("bin/simd-bench/m.wasm", hx))
			hxmc("bin/simd-bench/m.wasm", ["-cp", dir, "-main", "SimdBench"].concat(HXMC_ARGS).concat(["-D", "hxmc.target=wasm32-wasi"]));
		var c = [
			"c-O2" => ["-O2"],
			"c-O3-novec" => ["-O3", "-fno-tree-vectorize", "-fno-tree-slp-vectorize"],
			"c-O3" => ["-O3"],
			"c-sse41" => ["-O2", "-msse4.1", "-DSSE41"]
		];
		for (n => flags in c)
			if (stale('bin/simd-bench/$n$e', ['$dir/simd_bench.c'])) run(cc.concat(flags).concat(["-o", 'bin/simd-bench/$n$e', '$dir/simd_bench.c']));
		Sys.println("== hxmc");
		run(['bin/simd-bench/m$e'].concat(args));
		Sys.println("== hxmc, wasm32-wasi under node");
		run(wasi("bin/simd-bench/m.wasm").concat(args));
		for (n in ["O2", "O3-novec", "O3"]) {
			Sys.println('== C -$n');
			run(['bin/simd-bench/c-$n$e'].concat(args));
		}
		Sys.println("== C, SSE4.1 intrinsics, -O2");
		run(['bin/simd-bench/c-sse41$e'].concat(args));
	}
}

class Failure {
	public var message:String;

	public function new(m:String)
		message = m;
}
