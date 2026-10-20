import Harness.*;
import sys.FileSystem;
import sys.io.File;

using StringTools;

// Tiered checks of hxmc (`make quick|check|full`, which rebuild the tool
// first): one line per lane with its result and time, a summary at the end,
// exit 1 if any lane failed.
//   bin/hxmc/hxmc -cp hxmc/test -cp haxe/test --run Tiers quick|check|full [--port] [case ...]
//   quick  the x64 corpus (64 KB nursery), again with RT_VERIFY=1, and the wasm
//          corpus under node, the module cache's store (CacheCheck): after
//          every edit
//   check  quick + linux-arm64 (qemu) and windows-x86_64 (wine), x64 with a
//          16 KB nursery, the wasm corpus with legacy exception handling
//          (-D hxmc.wasm-eh=legacy) under node, the corpus in the dynamic glibc
//          mode (-D hxmc.libc=glibc) for x64 and arm64 (qemu, with the cross C
//          library) and its executables checked with readelf (ElfCheck),
//          ThreadNatives x30 (16 KB, and with the adaptive nursery), the tool as
//          a module building three cases for x64, arm64 and wasm32-wasi
//          byte-identical to the native tool, the debugging information and
//          unwind tables (DebugCheck: gdb on the host, the tools elsewhere),
//          shared libraries (SharedCheck), Android's APKs (ApkCheck) and iOS's
//          app bundles (IosCheck);
//          --port adds the native port's self-compile: before commits
//   full   x64, arm64 and wine at 64, 16 and 256 KB, each with RT_VERIFY=1 too;
//          x64 and arm64 in the glibc mode, also at 16 KB with RT_VERIFY=1;
//          wasm under node and wasmtime at 16, 64 and 256 KB, under node with
//          RT_VERIFY=1 at 64 and 256 KB and with legacy exception handling at
//          16 and 64 KB; ThreadNatives x300 (16 KB) and x100 (64 KB); the heap
//          census of a debug build; the
//          port's self-compile natively (64 KB, 256 KB, 256 KB with
//          RT_VERIFY=1, the adaptive nursery with RT_VERIFY=1) and as a
//          module (node, node with 256 KB, wasmtime, node with legacy
//          exception handling); the tool as a module building
//          every case for every target and itself; the fixpoint: before pushing
// Cases named restrict the corpus lanes to them; the port, ThreadNatives
// and fixpoint lanes ignore them. Lanes run one after another (they share the
// cases' output directories); the reference (bin/reference/haxe) is needed
// for the port lanes.
class Tiers {
	static var results:Array<{name:String, ok:Bool}> = [];
	static final SCRIPT = ["bin/hxmc/hxmc", "-cp", "hxmc/test", "-cp", "haxe/test", "--run"];
	static final LEGACY = ["--wasm-eh", "legacy"];
	static final GLIBC = ["--libc", "glibc"];

	static function lane(name:String, f:Void->{ok:Bool, detail:String}) {
		var t = now();
		var r = try f() catch (e:Dynamic) {ok: false, detail: Std.string(e)};
		results.push({name: name, ok: r.ok});
		Sys.println(pad(name, 28) + " " + (r.ok ? "ok  " : "FAIL") + " " + fixed(now() - t).lpad(" ", 6) + "s  " + r.detail);
	}

	static function lastLine(s:String):String {
		var lines = [for (l in s.trim().split("\n")) if (l.trim() != "") l];
		return lines.length == 0 ? "" : lines[lines.length - 1];
	}

	static function corpus(?target:String, ?env:Map<String, Null<String>>, cases:Array<String>, ?extra:Array<String>) return () -> {
		var cmd = SCRIPT.concat(["Corpus"]);
		if (extra != null) cmd = cmd.concat(extra);
		if (target != null) cmd = cmd.concat(["--target", target]);
		var r = exec(cmd.concat(cases), {env: env, merge: true});
		var bad = [];
		for (l in r.out.split("\n")) {
			var w = l.split(" ").filter(s -> s != "");
			if (w.length > 1 && !["ok", "excluded"].contains(w[1]) && !l.contains("/")) bad.push(w[0] + " " + w[1]);
		}
		{ok: r.code == 0, detail: lastLine(r.out) + (bad.length == 0 ? "" : "  " + bad.slice(0, 8).join(", "))};
	}

	// a check script: ok when it exits 0
	static function script(args:Array<String>) return () -> {
		var r = exec(SCRIPT.concat(args), {merge: true});
		{ok: r.code == 0, detail: lastLine(r.out)};
	}

	// (kb 0: the adaptive nursery, RT_MINOR_KB unset)
	static function threads(n:Int, kb:Int) return () -> {
		exec(SCRIPT.concat(["Corpus", "ThreadNatives"]));
		var d = "bin/hxmc-t/ThreadNatives";
		var exp = File.getContent("hxmc/test/expected/ThreadNatives.txt");
		var bad = 0;
		for (_ in 0...n) {
			var r = exec([FileSystem.fullPath(d + "/m")], {cwd: d, env: ["RT_MINOR_KB" => kb == 0 ? null : Std.string(kb)], timeout: 60});
			if (r.timedOut || 'exit ${r.code}\n' + r.out != exp) bad++;
		}
		{ok: bad == 0, detail: '${n - bad}/$n runs'};
	}

	static function digest(path:String):String {
		var z = readZip(path);
		var names = z.names.copy();
		names.sort(compare);
		var ctx = new haxe.io.BytesBuffer();
		for (n in names) {
			ctx.addString(n);
			ctx.add(z.data[n]);
		}
		return haxe.crypto.Sha256.make(ctx.getBytes()).toHex();
	}

	static function portNative() {
		var r = exec(SCRIPT.concat(["Selfcheck", "--local", "--small"]), {merge: true});
		var lines = [for (l in r.out.split("\n")) if (l.startsWith("self-compile")) l];
		return {ok: r.code == 0, detail: lines.length > 0 ? lines[0] : lastLine(r.out)};
	}

	static function selfCompile(cmd:Array<String>, ?env:Map<String, Null<String>>) return () -> {
		var out = "bin/hxmc-t/self-tier.hxb";
		if (FileSystem.exists(out)) FileSystem.deleteFile(out);
		var r = exec(cmd.concat(["-cp", "haxe/src", "-main", "haxe.Main", "-D", "disable-parallelism", "--interp", "--no-output", "--hxb", out]), {env: env, merge: true});
		if (r.code != 0) return {ok: false, detail: tail(r.out, 300)};
		var same = digest(out) == digest("bin/hxmc-t/self-ref.hxb");
		{ok: same, detail: same ? "identical to the reference" : "DIFFERS from the reference"};
	}

	static function wasmPortBuild(legacy = false) return () -> {
		var out = legacy ? "bin/hxmc-t/wport/haxe-legacy.wasm" : "bin/hxmc-t/wport/haxe.wasm";
		var r = exec(["bin/hxmc/hxmc", out, "-cp", "haxe/src", "-main", "haxe.Main", "-D", "disable-parallelism", "-cp", "bin/hxmc/std",
			"--custom-target", "hxmc", "-D", "hxmc.target=wasm32-wasi"].concat(legacy ? ["-D", "hxmc.wasm-eh=legacy"] : []), {merge: true});
		{ok: r.code == 0, detail: r.code == 0 ? FileSystem.stat(out).size + " bytes" : tail(r.out, 300)};
	}

	static function crosshost(args:Array<String>) return () -> {
		var r = exec(SCRIPT.concat(["Crosshost"]).concat(args), {merge: true});
		var bad = [for (l in r.out.split("\n")) if (l.contains(" FAIL ")) l.split(" ").filter(s -> s != "").slice(0, 2).join(" ")];
		{ok: r.code == 0, detail: lastLine(r.out) + (bad.length == 0 ? "" : "  " + bad.slice(0, 8).join(", "))};
	}

	// the heap census of a debug build (-D hxmc.census, RT_CENSUS=2: at every
	// major collection and at exit) on a case that collects
	static function census() {
		var out = "bin/hxmc-t/census/m";
		mkdirs("bin/hxmc-t/census");
		var b = exec(["bin/hxmc/hxmc", out, "-cp", "hxmc/test/cases", "-main", "Bench", "-D", "hxmc.census", "-D", "disable-parallelism", "-cp", "bin/hxmc/std",
			"--custom-target", "hxmc"], {merge: true});
		if (b.code != 0) return {ok: false, detail: tail(b.out, 300)};
		var r = exec([FileSystem.fullPath(out)], {cwd: "hxmc/test/cases", env: ["RT_CENSUS" => "2", "RT_MINOR_KB" => "256"]});
		var n = [for (l in r.err.split("\n")) if (l.startsWith("census (")) l].length;
		return {ok: r.code == 0 && n > 0, detail: r.code == 0 ? n + " censuses" : tail(r.err, 300)};
	}

	// the debugging information and unwind tables (DebugCheck): a debugger on
	// the host's -debug build, the tools' checks of the other targets'
	static function debugLanes() {
		lane("debug info (gdb)", script(["DebugCheck"]));
		for (t in ["linux-arm64", "windows-x86_64", "windows-arm64", "macos-arm64"])
			lane('debug info $t', script(["DebugCheck", "--target", t]));
	}

	static function make(args:Array<String>) return () -> {
		var r = exec(["make", "--no-print-directory"].concat(args), {merge: true});
		{ok: r.code == 0, detail: lastLine(r.out)};
	}

	static function fixpoint() {
		var r = exec(["make", "--no-print-directory", "fixpoint"], {merge: true});
		var said = [for (l in r.out.split("\n")) if (l.startsWith("fixpoint:")) l];
		return {ok: r.code == 0, detail: said.length > 0 ? said[0] : tail(r.out, 300)};
	}

	static function main() {
		var args = Sys.args();
		if (args.length == 0 || !["quick", "check", "full"].contains(args[0])) fail("usage: Tiers quick|check|full [--port] [case ...]");
		var tier = args[0], port = args.contains("--port");
		var cases = [for (a in args.slice(1)) if (a != "--port") a];
		var t0 = now();
		if (tier != "full") {
			lane("x64", corpus(cases));
			lane("x64 RT_VERIFY", corpus(null, ["RT_VERIFY" => "1"], cases));
			lane("wasm node", corpus("wasm32-wasi", null, cases));
			lane("module cache store", script(["CacheCheck"]));
		}
		if (tier == "check") {
			lane("x64 16K", corpus(null, ["RT_MINOR_KB" => "16"], cases));
			lane("arm64 (qemu)", corpus("linux-arm64", null, cases));
			lane("windows (wine)", corpus("windows-x86_64", null, cases));
			lane("x64 glibc", corpus(null, null, cases, GLIBC));
			// (arm64: the cross C library's root for qemu, libc6-arm64-cross)
			if (FileSystem.exists(Sys.getEnv("QEMU_LD_PREFIX") ?? "/usr/aarch64-linux-gnu")) lane("arm64 glibc (qemu)", corpus("linux-arm64", null, cases, GLIBC));
			lane("glibc readelf", script(["ElfCheck", "bin/hxmc-t"]));
			lane("shared libraries", script(["SharedCheck"]));
			for (t in ["android-arm64", "android-x86_64"])
				lane('APKs $t', make(["android-check", "ANDROID_TARGET=" + t]));
			for (t in ["ios-arm64", "ios-sim-arm64"])
				lane('iOS apps $t', make(["ios-check", "IOS_TARGET=" + t]));
			lane("wasm node legacy EH", corpus("wasm32-wasi", null, cases, LEGACY));
			lane("ThreadNatives x30", threads(30, 16));
			lane("ThreadNatives x30 adaptive", threads(30, 0));
			lane("cross-host", crosshost(["--targets", "linux-x86_64,linux-arm64,wasm32-wasi,linux-x86_64-glibc"].concat(cases.length > 0 ? cases : ["Unsafe", "SwitchIndex", "Regress"])));
			debugLanes();
			if (port) lane("port self-compile", portNative);
		}
		if (tier == "full") {
			for (t in ["linux-x86_64", "linux-arm64", "windows-x86_64"])
				for (kb in ["64", "16", "256"]) {
					lane('$t ${kb}K', corpus(t, ["RT_MINOR_KB" => kb], cases));
					lane('$t ${kb}K RT_VERIFY', corpus(t, ["RT_MINOR_KB" => kb, "RT_VERIFY" => "1"], cases));
				}
			for (t in ["linux-x86_64", "linux-arm64"]) {
				lane('$t glibc', corpus(t, null, cases, GLIBC));
				lane('$t glibc 16K RT_VERIFY', corpus(t, ["RT_MINOR_KB" => "16", "RT_VERIFY" => "1"], cases, GLIBC));
			}
			lane("glibc readelf", script(["ElfCheck", "bin/hxmc-t"]));
			debugLanes();
			for (kb in ["16", "64", "256"]) {
				lane('wasm node ${kb}K', corpus("wasm32-wasi", ["RT_MINOR_KB" => kb], cases));
				lane('wasm wasmtime ${kb}K', corpus("wasm32-wasi", ["RT_MINOR_KB" => kb, "HXMC_WASM_RUNNER" => "wasmtime"], cases));
			}
			for (kb in ["64", "256"]) lane('wasm node ${kb}K RT_VERIFY', corpus("wasm32-wasi", ["RT_MINOR_KB" => kb, "RT_VERIFY" => "1"], cases));
			for (kb in ["16", "64"]) lane('wasm node legacy EH ${kb}K', corpus("wasm32-wasi", ["RT_MINOR_KB" => kb], cases, LEGACY));
			lane("ThreadNatives x300 16K", threads(300, 16));
			lane("ThreadNatives x100 64K", threads(100, 64));
			lane("census", census);
			lane("port self-compile", portNative);
			lane("port 256K RT_VERIFY", selfCompile(["bin/hxmc-t/port/s"], ["RT_MINOR_KB" => "256", "RT_VERIFY" => "1"]));
			lane("port adaptive RT_VERIFY", selfCompile(["bin/hxmc-t/port/s"], ["RT_MINOR_KB" => null, "RT_VERIFY" => "1"]));
			lane("wasm port build", wasmPortBuild());
			var wp = FileSystem.fullPath("bin/hxmc-t/wport") + "/haxe.wasm";
			var node = ["node", "--no-warnings", "--stack-size=8000", FileSystem.fullPath("hxmc/bootstrap/wasi.mjs"), wp];
			lane("wasm port node", selfCompile(node));
			lane("wasm port node 256K", selfCompile(node, ["RT_MINOR_KB" => "256"]));
			lane("wasm port wasmtime", selfCompile(["wasmtime", "run", "-W", "exceptions=y", "-W", "max-wasm-stack=67108864", "--dir", "/", "--env", "HAXE_STD_PATH",
				"--env", "PWD=" + root, wp]));
			lane("wasm port build legacy EH", wasmPortBuild(true));
			lane("wasm port node legacy EH", selfCompile(["node", "--no-warnings", "--stack-size=8000", FileSystem.fullPath("hxmc/bootstrap/wasi.mjs"), FileSystem.fullPath("bin/hxmc-t/wport") + "/haxe-legacy.wasm"], ["HXMC_WASM_EXNREF" => "0"]));
			lane("cross-host", crosshost(["--tool"].concat(cases)));
			lane("fixpoint", fixpoint);
		}
		var bad = [for (r in results) if (!r.ok) r.name];
		Sys.println('$tier: ${results.length - bad.length}/${results.length} lanes ok, ${Math.round(now() - t0)}s' + (bad.length == 0 ? "" : "; FAILED: " + bad.join(", ")));
		Sys.exit(bad.length > 0 ? 1 : 0);
	}
}
