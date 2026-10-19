import Harness.*;
import sys.FileSystem;
import sys.io.File;

using StringTools;

// The hxmc test corpus (docs/testing.md): every program compiled by
// hxmc, run, and its output compared with its golden file.
//   bin/hxmc/hxmc -cp hxmc/test -cp haxe/test --run Corpus [-j N] [-v] [--target T] [--wasm-eh legacy] [--libc glibc] [--stage DIR] [--bless] [case ...]
// The cases are the programs of hxmc/test/cases (<Name>.hx with class <Name>)
// and the fuzzer programs frozen in hxmc/test/fuzz-1000.zip (extracted to
// bin/hxmc-fuzz, cases fuzz-<seed>). Each case's HXB archive is written once
// by the tool as the compiler (`-cp bin/hxmc/std --custom-target hxmc`;
// cached, rewritten when a source is newer); the tool compiles it and the
// output ("exit <code>" and stdout) must equal hxmc/test/expected/<case>.txt.
// The golden files are frozen: a new case gets one with --bless (written from
// hxmc's own output, to be checked by hand). A `// define: <name>[=<value>]`
// line of a case's source adds that -D to its build, a `// resource:
// <file>@<name>` line that resource (the file next to the source). --target cross-builds
// for another target (linux-arm64 runs under qemu-aarch64-static, windows-x86_64 under
// wine64, wasm32-wasi under node or, with HXMC_WASM_RUNNER=wasmtime,
// wasmtime; --wasm-eh legacy: built with -D hxmc.wasm-eh=legacy, run under
// node without exnref; --libc glibc: Linux, dynamically linked against the
// system's glibc, -D hxmc.libc=glibc, arm64 under qemu-aarch64-static -L
// /usr/aarch64-linux-gnu, the cross C library's root, or QEMU_LD_PREFIX;
// the cases that must be rejected are of the default mode); --stage only
// builds and copies each executable with
// its golden file to DIR/<case>/ (Check runs them on the target's machine).
class Corpus {
	static final OUT = "bin/hxmc-t";
	static final STD = "bin/hxmc/std";
	static final CASES = "hxmc/test/cases";
	static final REJECT = "hxmc/test/reject";
	static final EXPECTED = "hxmc/test/expected";
	static final FUZZ_ZIP = "hxmc/test/fuzz-1000.zip";
	static final FUZZ = "bin/hxmc-fuzz";
	// the cases a WebAssembly module cannot run
	static final WASM_EXCLUDED = ["ThreadNatives" => "no threads on wasm32-wasi", "ThreadLocal" => "no threads on wasm32-wasi", "NetNatives" => "no sockets on wasm32-wasi"];
	// the cases of the dynamic glibc mode only (shared libraries of the system)
	public static final GLIBC_ONLY = ["SharedLibs" => "shared libraries: the dynamic glibc mode only (--libc glibc)"];

	static var tool:String;
	static var target:Null<String>;
	static var stage:Null<String>;
	static var wasmEh:Null<String>; // --wasm-eh legacy: -D hxmc.wasm-eh=legacy
	static var libc:Null<String>; // --libc glibc: -D hxmc.libc=glibc
	static var bless = false;

	static function main() {
		var a = parseArgs(Sys.args(), ["-j", "--target", "--stage", "--wasm-eh", "--libc"]);
		tool = FileSystem.fullPath(Sys.getEnv("HXMC_TOOL") ?? "bin/hxmc/hxmc");
		target = a.get("--target");
		stage = a.get("--stage");
		wasmEh = a.get("--wasm-eh");
		libc = a.get("--libc");
		bless = a.has("--bless");
		var verbose = a.has("-v");
		if (!FileSystem.exists(STD + "/.stamp")) fail("Corpus: bin/hxmc/std is missing (make std)");
		var cases = caseList(a.rest);
		var t0 = now();
		var bad = 0, excluded = 0;
		parallel(cases, a.int("-j", cpus()), runCase, (c, r) -> {
			var good = r.status == "ok" || r.status == "blessed" || r.status == "excluded";
			Sys.println(pad(r.name, 24) + " " + pad(r.status, 12) + " " + (good || !verbose ? r.detail : ""));
			if (r.status == "excluded") excluded++ else if (r.status != "ok" && r.status != "blessed") {
				bad++;
				if (verbose) Sys.println("    " + r.detail.replace("\n", "\n    "));
			}
		});
		Sys.println('${cases.length - bad - excluded}/${cases.length - excluded} ok' + (excluded > 0 ? ' ($excluded excluded)' : '') + ', ${fixed(now() - t0)}s');
		Sys.exit(bad > 0 ? 1 : 0);
	}

	static function fuzzPrograms():Array<String> {
		var stamp = FUZZ + "/.stamp";
		if (!FileSystem.exists(stamp) || mtime(stamp) < mtime(FUZZ_ZIP)) {
			rmrf(FUZZ);
			mkdirs(FUZZ);
			var z = readZip(FUZZ_ZIP);
			for (n in z.names) {
				if (n.endsWith("/")) continue;
				var p = FUZZ + "/" + (n.startsWith("./") ? n.substr(2) : n);
				mkdirs(haxe.io.Path.directory(p));
				File.saveBytes(p, z.data[n]);
			}
			File.saveContent(stamp, "");
		}
		var r = [for (d in FileSystem.readDirectory(FUZZ)) if (FileSystem.exists(FUZZ + "/" + d + "/Main.hx")) d];
		r.sort(compare);
		return r;
	}

	static function caseList(names:Array<String>):Array<CorpusCase> {
		var cases:Array<CorpusCase> = [];
		var files = [for (f in FileSystem.readDirectory(CASES)) if (f.endsWith(".hx")) f.substr(0, f.length - 3)];
		files.sort(compare);
		for (f in files) cases.push({name: f, cps: [CASES], main: f});
		// programs the compiler must reject (@:hxmc.noGc, raw addresses, C types): reject-<Name>
		var rejects = [for (f in FileSystem.readDirectory(REJECT)) if (f.endsWith(".hx")) f.substr(0, f.length - 3)];
		rejects.sort(compare);
		for (f in rejects) cases.push({name: "reject-" + f, cps: [REJECT], main: f});
		for (d in fuzzPrograms()) cases.push({name: "fuzz-" + d, cps: [FUZZ + "/" + d], main: "Main"});
		if (names.length == 0) return cases;
		var known = [for (c in cases) c.name => c];
		var bad = [for (n in names) if (!known.exists(n)) n];
		if (bad.length > 0) fail("Corpus: unknown case(s): " + bad.join(", "));
		return [for (n in names) known[n]];
	}

	static function runCase(c:CorpusCase):CorpusResult {
		var d = OUT + "/" + c.name;
		mkdirs(d);
		var wasm = target != null && target.startsWith("wasm");
		if (c.name.startsWith("reject-")) return stage != null || libc != null ? {name: c.name, status: "excluded", detail: "a compile error"} : rejectCase(c);
		var t = target != null ? target : hostTarget();
		var native = nativeInputs(c, t, d);
		if (native.skip != null) return {name: c.name, status: "excluded", detail: native.skip};
		if (wasm && WASM_EXCLUDED.exists(c.name)) return {name: c.name, status: "excluded", detail: WASM_EXCLUDED[c.name]};
		if (libc != "glibc" && GLIBC_ONLY.exists(c.name)) return {name: c.name, status: "excluded", detail: GLIBC_ONLY[c.name]};
		var hxb = d + "/" + (wasm ? 'prog-$target.hxb.zip' : "prog.hxb.zip");
		var defines = caseDefines(c.cps[0] + "/" + c.main + ".hx");
		var t0 = now();
		// (WebAssembly: the program is typed for it, with its runtime)
		if (!FileSystem.exists(hxb) || mtime(hxb) < Math.max(newest(c.cps), mtime(STD + "/.stamp"))) {
			var cmd = [tool];
			// (absolute class paths: positions name the files relative to them)
			for (cp in c.cps) cmd = cmd.concat(["-cp", FileSystem.fullPath(cp)]);
			cmd = cmd.concat(["-cp", FileSystem.fullPath(STD), "-main", c.main, "--custom-target", 'hxmc=$d/x', "--hxb", hxb, "-D", "disable-parallelism", "--no-output"]);
			if (wasm) cmd = cmd.concat(["-D", "hxmc.target=" + target]);
			var r = exec(cmd.concat(defines));
			if (r.code != 0) return {name: c.name, status: "hxb-fail", detail: tail(r.out + r.err, 1500)};
		}
		var expected = EXPECTED + "/" + c.name + ".txt";
		if (!FileSystem.exists(expected) && !bless)
			return {name: c.name, status: "no-golden", detail: '$expected is missing (--bless writes it from hxmc\'s output)'};
		var exe = d + "/" + (target != null ? "m-" + target : "m");
		if (libc != null) exe += "-" + libc;
		if (target != null && target.startsWith("windows")) exe += ".exe";
		if (wasm) exe += (wasmEh != null ? "-" + wasmEh : "") + ".wasm";
		var cmd = [tool, exe, "--hxb-lib", hxb, "-main", c.main, "--custom-target", "hxmc", "-D", "disable-parallelism"];
		if (target != null) cmd = cmd.concat(["-D", "hxmc.target=" + target]);
		if (libc != null) cmd = cmd.concat(["-D", "hxmc.libc=" + libc]);
		if (native.links.length > 0) cmd = cmd.concat(["-D", "hxmc.link=" + native.links.join(",")]);
		if (wasm && wasmEh != null) cmd = cmd.concat(["-D", "hxmc.wasm-eh=" + wasmEh]);
		// (the defines: caseDefines, as when typing)
		var src = c.cps[0] + "/" + c.main + ".hx";
		if (FileSystem.exists(src))
			for (l in File.getContent(src).split("\n"))
				if (l.trim().startsWith("// resource: ")) {
					var r = l.trim().substr(13).split("@");
					cmd = cmd.concat(["--resource", FileSystem.fullPath(c.cps[0] + "/" + r[0]) + (r.length > 1 ? "@" + r[1] : "")]);
				}
		var r = exec(cmd.concat(defines), {env: ["HXMC_STATS" => "1"]});
		File.saveContent(d + "/hxmc.log", r.out + r.err);
		if (r.code != 0) return {name: c.name, status: "hxmc-fail", detail: tail(r.out + r.err, 2000)};
		var re = ~/hxmc: ([0-9]+) functions/;
		var nf = re.match(r.out) ? re.matched(1) + " functions" : "";
		if (stage != null) {
			// cross builds: the executable and the expected output, run elsewhere (Check)
			var sd = stage + "/" + c.name;
			mkdirs(sd);
			File.copy(exe, sd + "/m" + (exe.endsWith(".exe") ? ".exe" : exe.endsWith(".wasm") ? ".wasm" : ""));
			File.copy(expected, sd + "/expected.txt");
			for (f in native.copy)
				File.copy(f, sd + "/" + haxe.io.Path.withoutDirectory(f));
			return {name: c.name, status: "ok", detail: "staged " + nf};
		}
		var runner = switch target {
			case "linux-arm64" if (libc == "glibc"): ["qemu-aarch64-static", "-L", Sys.getEnv("QEMU_LD_PREFIX") ?? "/usr/aarch64-linux-gnu"];
			case "linux-arm64": ["qemu-aarch64-static"];
			case "windows-x86_64": ["/usr/lib/wine/wine64"];
			case _ if (wasm): wasmRunner();
			case _: [];
		}
		// a small nursery: frequent collections, so a missing or stale root shows
		var r = exec(runner.concat([FileSystem.fullPath(exe)]), {cwd: d, timeout: 120, env: ["RT_MINOR_KB" => Sys.getEnv("RT_MINOR_KB") ?? "64", "WINEDEBUG" => "-all", "HXMC_WASM_IMPORTS" => native.host,
			// (legacy exception handling: node without exnref, hxmc/bootstrap/wasi.mjs)
			"HXMC_WASM_EXNREF" => wasmEh == "legacy" ? "0" : Sys.getEnv("HXMC_WASM_EXNREF")]});
		if (r.timedOut) return {name: c.name, status: "timeout", detail: ""};
		var got = 'exit ${r.code}\n' + r.out;
		if (bless && !FileSystem.exists(expected)) {
			File.saveContent(expected, got);
			return {name: c.name, status: "blessed", detail: 'wrote $expected (check it)'};
		}
		if (got != File.getContent(expected)) {
			File.saveContent(d + "/got.txt", got + r.err);
			return {name: c.name, status: "differs", detail: 'diff $expected $d/got.txt\n' + tail(r.err, 800)};
		}
		return {name: c.name, status: "ok", detail: '${fixed(now() - t0)}s $nf'};
	}

	// Per-case defines must apply to typing as well as code generation.
	public static function caseDefines(src:String):Array<String> {
		var result = [];
		if (FileSystem.exists(src))
			for (l in File.getContent(src).split("\n"))
				if (l.trim().startsWith("// define: ")) result = result.concat(["-D", l.trim().substr(11)]);
		return result;
	}

	// A case the compiler must reject: every `// expect: <text>` line of its
	// source names a part of the error.
	static function rejectCase(c:CorpusCase):CorpusResult {
		var src = File.getContent(c.cps[0] + "/" + c.main + ".hx");
		var want = [for (l in src.split("\n")) if (l.trim().startsWith("// expect: ")) l.trim().substr(11)];
		if (want.length == 0) return {name: c.name, status: "no-golden", detail: "no `// expect: ` line"};
		var d = OUT + "/" + c.name;
		mkdirs(d);
		var cmd = [tool, d + "/m", "-cp", FileSystem.fullPath(c.cps[0]), "-cp", FileSystem.fullPath(STD), "-main", c.main, "--custom-target", "hxmc", "-D", "disable-parallelism"];
		// (`// target: <target>`: the target the case is about, whatever the host)
		var own = [for (l in src.split("\n")) if (l.trim().startsWith("// target: ")) l.trim().substr(11)];
		if (own.length > 0) cmd = cmd.concat(["-D", "hxmc.target=" + own[0]]) else if (target != null) cmd = cmd.concat(["-D", "hxmc.target=" + target]);
		var r = exec(cmd.concat(caseDefines(c.cps[0] + "/" + c.main + ".hx")));
		var out = r.out + r.err;
		if (r.code == 0) return {name: c.name, status: "differs", detail: "compiled, but must be rejected"};
		for (w in want)
			if (out.indexOf(w) < 0) return {name: c.name, status: "differs", detail: 'the error lacks "$w":\n' + tail(out, 1500)};
		return {name: c.name, status: "ok", detail: "rejected"};
	}

	public static function hostTarget():String {
		var m = exec(["uname", "-m"]).out.trim();
		var os = Sys.systemName() == "Mac" ? "macos" : Sys.systemName() == "Windows" ? "windows" : "linux";
		return os + "-" + (m == "aarch64" || m == "arm64" || m == "ARM64" ? "arm64" : "x86_64");
	}

	static var zigOk:Null<Bool>;

	static function zig():Null<String> {
		var z = Sys.getEnv("ZIG") ?? "zig";
		if (zigOk == null) zigOk = try exec([z, "version"]).code == 0 catch (_:Dynamic) false;
		return zigOk ? z : null;
	}

	// The C companions of a case, built for the target with zig (skipped
	// cleanly without zig): <Name>.c, an object linked statically;
	// <Name>_dyn.c, the dynamic library <name>dyn (a DLL next to the
	// executable on Windows, a dylib on macOS, a shared object next to it in
	// the dynamic glibc mode; an object linked statically on Linux otherwise,
	// whose executables are static). WebAssembly modules have no
	// C objects: their C functions are imports.
	public static function nativeInputs(c:CorpusCase, target:String, d:String, ?libcMode:String):{links:Array<String>, copy:Array<String>, skip:Null<String>, host:Null<String>} {
		var r = {links: [], copy: [], skip: null, host: null};
		var src = c.cps[0] + "/" + c.main + ".c";
		var dyn = c.cps[0] + "/" + c.main + "_dyn.c";
		// <Name>.cjs: the host of a WebAssembly program's imports (node only:
		// HXMC_WASM_IMPORTS, hxmc/bootstrap/wasi.mjs), copied as host.cjs
		var cjs = c.cps[0] + "/" + c.main + ".cjs";
		if (FileSystem.exists(cjs)) {
			if (!target.startsWith("wasm")) r.skip = "WebAssembly only (imports from a host)";
			else if (stage == null && Sys.getEnv("HXMC_WASM_RUNNER") == "wasmtime") r.skip = "needs node (the host is JavaScript)";
			else {
				File.copy(cjs, d + "/host.cjs");
				r.host = FileSystem.fullPath(d + "/host.cjs");
				r.copy.push(d + "/host.cjs");
			}
			return r;
		}
		if (!FileSystem.exists(src) && !FileSystem.exists(dyn)) return r;
		if (target.startsWith("wasm")) {
			r.skip = "C objects: none in a WebAssembly module (C functions are imports there)";
			return r;
		}
		var z = zig();
		if (z == null) {
			r.skip = "needs zig to build " + src;
			return r;
		}
		var glibc = (libcMode ?? libc) == "glibc" && target.startsWith("linux");
		var triple = switch target {
			case "linux-x86_64" if (glibc): "x86_64-linux-gnu.2.17";
			case "linux-arm64" if (glibc): "aarch64-linux-gnu.2.17";
			case "linux-x86_64": "x86_64-linux-musl";
			case "linux-arm64": "aarch64-linux-musl";
			case "windows-x86_64": "x86_64-windows-gnu";
			case "windows-arm64": "aarch64-windows-gnu";
			case "macos-x86_64": "x86_64-macos";
			case _: "aarch64-macos";
		}
		var flags = ["-O2", "-g0", "-fno-stack-protector"].concat(glibc ? ["-fPIE"] : target.startsWith("linux") ? ["-fno-pic", "-fno-pie"] : []);
		function build(file:String, out:String, extra:Array<String>):Bool {
			if (FileSystem.exists(out) && mtime(out) >= mtime(file)) return true;
			var b = exec([z, "cc", "-target", triple].concat([for (f in flags) if (f != "-fPIE" || extra.indexOf("-shared") < 0) f]).concat(extra).concat([file, "-o", out]));
			if (b.code != 0) {
				r.skip = "zig cc failed: " + tail(b.out + b.err, 400);
				return false;
			}
			return true;
		}
		if (FileSystem.exists(src)) {
			var o = FileSystem.fullPath(d) + '/${c.main}-$target' + (glibc ? "-glibc" : "") + ".o";
			if (!build(src, o, ["-c"])) return r;
			r.links.push(o);
		}
		if (FileSystem.exists(dyn)) {
			var lib = c.main.toLowerCase() + "dyn";
			if (target.startsWith("linux") && !glibc) {
				var o = FileSystem.fullPath(d) + '/${c.main}_dyn-$target.o';
				if (!build(dyn, o, ["-c"])) return r;
				r.links.push(o);
			} else {
				// (one directory per target: the library keeps its file name)
				var ld = d + "/" + target + (glibc ? "-glibc" : "");
				mkdirs(ld);
				var f = target.startsWith("windows") ? '$ld/$lib.dll' : glibc ? '$ld/lib$lib.so' : '$ld/lib$lib.dylib';
				var extra = target.startsWith("windows") || glibc ? ["-shared"] : ["-shared", "-Wl,-install_name,@rpath/lib" + lib + ".dylib"];
				if (glibc) extra.push("-fPIC");
				if (!build(dyn, f, extra)) return r;
				// next to the executable
				File.copy(f, d + "/" + haxe.io.Path.withoutDirectory(f));
				r.copy.push(f);
			}
		}
		return r;
	}

	// wasm32-wasi: node (hxmc/bootstrap/wasi.mjs) or, with HXMC_WASM_RUNNER=wasmtime, wasmtime
	public static function wasmRunner():Array<String> {
		if (Sys.getEnv("HXMC_WASM_RUNNER") == "wasmtime") return ["wasmtime", "run", "-W", "exceptions=y", "--dir", ".", "--dir", "/", "--env", "RT_MINOR_KB"];
		return ["node", "--no-warnings", FileSystem.fullPath("hxmc/bootstrap/wasi.mjs")];
	}

}

typedef CorpusCase = {name:String, cps:Array<String>, main:String}
typedef CorpusResult = {name:String, status:String, detail:String}
