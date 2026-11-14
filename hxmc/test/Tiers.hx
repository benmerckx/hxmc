import Harness.*;
import sys.FileSystem;
import sys.io.File;

using StringTools;

// Tiered checks of hxmc (`node make.mjs quick|check`, which rebuild the tool
// first): one line per lane with its result and time, a summary at the end,
// exit 1 if any lane failed. Each tier runs quick's checks.
//   bin/hxmc/hxmc -cp hxmc/test -cp haxe/test -cp hxmc/src --run Tiers quick|check [--port] [case ...]
//   quick  the unit checks (Units), the x64 corpus (64 KB nursery), again
//          with RT_VERIFY=1 and -D hxmc.verify-tags (Corpus --verify-tags),
//          and the wasm corpus under node, again with a 64 KB nursery, an old
//          space of 1 MB at first, a budget of 64 MB (RT_MAX_MB) and
//          RT_VERIFY=1 (its major collections, compactions): after every edit
//   check  quick + linux-arm64 (qemu) and windows-x86_64 (wine), x64 with a
//          16 KB nursery, the wasm corpus with legacy exception handling
//          (-D hxmc.wasm-eh=legacy) under node, the corpus in the dynamic glibc
//          mode (-D hxmc.libc=glibc) for x64 and arm64 (qemu, with the cross C
//          library) and its executables checked with readelf (NativeCheck elf),
//          ThreadNatives x30 (16 KB, and with the adaptive nursery), the tool as
//          a module building three cases for x64, arm64 and wasm32-wasi
//          byte-identical to the native tool, the debugging information and
//          unwind tables (DebugCheck: gdb on the host, the tools elsewhere),
//          the native output (NativeCheck shared, jni, macho; uikit on a Mac
//          with Xcode); --port adds the native port's self-compile: before
//          commits (CI runs the rest: the nurseries, the port's
//          self-compiles, every target's cross-host, the fixpoint)
// Cases named restrict the corpus lanes to them; the port and
// ThreadNatives lanes ignore them. Lanes run one after another (they share the
// cases' output directories); the reference (bin/reference/haxe) is needed
// for the port lanes.
class Tiers {
	static var results:Array<{name:String, ok:Bool}> = [];
	static final SCRIPT = ["bin/hxmc/hxmc", "-cp", "hxmc/test", "-cp", "haxe/test", "-cp", "hxmc/src", "--run"];
	static final LEGACY = ["--wasm-eh", "legacy"];
	static final GLIBC = ["--libc", "glibc"];
	// (the tagged words of type parameters' values tested before every read as a reference)
	static final VERIFY_TAGS = ["--verify-tags"];

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

	// (kb 0: the adaptive nursery, RT_MINOR_KB unset; verify: RT_VERIFY=1)
	static function threads(n:Int, kb:Int, name = "ThreadNatives", verify = false) return () -> {
		exec(SCRIPT.concat(["Corpus", name]));
		var d = 'bin/hxmc-t/$name';
		var exp = File.getContent('hxmc/test/expected/$name.txt');
		var bad = 0;
		for (_ in 0...n) {
			var r = exec([FileSystem.fullPath(d + "/m")], {cwd: d, env: ["RT_MINOR_KB" => kb == 0 ? null : Std.string(kb), "RT_VERIFY" => verify ? "1" : null], timeout: 60});
			if (r.timedOut || 'exit ${r.code}\n' + r.out != exp) bad++;
		}
		{ok: bad == 0, detail: '${n - bad}/$n runs'};
	}

	static function portNative() {
		var r = exec(SCRIPT.concat(["Selfcheck", "--local", "--small"]), {merge: true});
		var lines = [for (l in r.out.split("\n")) if (l.startsWith("self-compile")) l];
		return {ok: r.code == 0, detail: lines.length > 0 ? lines[0] : lastLine(r.out)};
	}

	static function crosshost(args:Array<String>) return () -> {
		var r = exec(SCRIPT.concat(["Crosshost"]).concat(args), {merge: true});
		var bad = [for (l in r.out.split("\n")) if (l.contains(" FAIL ")) l.split(" ").filter(s -> s != "").slice(0, 2).join(" ")];
		{ok: r.code == 0, detail: lastLine(r.out) + (bad.length == 0 ? "" : "  " + bad.slice(0, 8).join(", "))};
	}

	// the debugging information and unwind tables (DebugCheck): a debugger on
	// the host's -debug build, the tools' checks of the other targets'
	static function debugLanes() {
		lane("debug info (gdb)", script(["DebugCheck"]));
		for (t in ["linux-arm64", "windows-x86_64", "windows-arm64", "macos-arm64"])
			lane('debug info $t', script(["DebugCheck", "--target", t]));
	}

	static function main() {
		var args = Sys.args();
		if (args.length == 0 || !["quick", "check"].contains(args[0])) fail("usage: Tiers quick|check [--port] [case ...]");
		var tier = args[0], port = args.contains("--port");
		var cases = [for (a in args.slice(1)) if (a != "--port") a];
		var t0 = now();
		lane("units", script(["Units"]));
		lane("x64", corpus(cases));
		lane("x64 RT_VERIFY verify-tags", corpus(null, ["RT_VERIFY" => "1"], cases, VERIFY_TAGS));
		lane("wasm node", corpus("wasm32-wasi", null, cases));
		// (the old space's major collections at every 16 MB promoted, all
		// compactions (RT_COMPACT=2: a small program would grow memory and
		// copy, RT_GROW_MB), and under a budget of linear memory, checked)
		lane("wasm node compacting RT_VERIFY", corpus("wasm32-wasi", ["RT_MINOR_KB" => "64", "RT_OLD_MB" => "1", "RT_MAX_MB" => "64", "RT_COMPACT" => "2", "RT_VERIFY" => "1"], cases));
		if (tier == "check") {
			lane("x64 16K", corpus(null, ["RT_MINOR_KB" => "16"], cases));
			lane("arm64 (qemu)", corpus("linux-arm64", null, cases));
			lane("windows (wine)", corpus("windows-x86_64", null, cases));
			lane("x64 glibc", corpus(null, null, cases, GLIBC));
			// (arm64: the cross C library's root for qemu, libc6-arm64-cross)
			if (FileSystem.exists(Sys.getEnv("QEMU_LD_PREFIX") ?? "/usr/aarch64-linux-gnu")) lane("arm64 glibc (qemu)", corpus("linux-arm64", null, cases, GLIBC));
			lane("glibc readelf", script(["NativeCheck", "elf", "bin/hxmc-t"]));
			for (p in ["shared", "jni", "macho"])
				lane('native $p', script(["NativeCheck", p]));
			// (macOS with Xcode's iOS simulator: the corpus run in an iPhone simulator)
			if (Corpus.iosDevice() != null) lane("iOS simulator", corpus("ios-sim-arm64", null, cases));
			// (an arm64 Mac: the corpus as Mac Catalyst processes, UIKit's views among them)
			if (Corpus.hostTarget() == "macos-arm64") lane("Mac Catalyst", corpus("macos-catalyst-arm64", null, cases));
			// (a Mac with Xcode: a UIKit app in its bundle, Catalyst and the simulator's iPhone and iPad)
			if (Corpus.iosDevice() != null) lane("native uikit", script(["NativeCheck", "uikit"]));
			lane("wasm node legacy EH", corpus("wasm32-wasi", null, cases, LEGACY));
			lane("ThreadNatives x30", threads(30, 16));
			lane("ThreadNatives x30 adaptive", threads(30, 0));
			// (a nursery of a megabyte or more: parallel minor collections of @:hxmc.compact objects)
			lane("CompactParGc x10 adaptive RT_VERIFY", threads(10, 0, "CompactParGc", true));
			lane("CompactEnums x10 adaptive RT_VERIFY", threads(10, 0, "CompactEnums", true));
			lane("HeaderEnums x10 adaptive RT_VERIFY", threads(10, 0, "HeaderEnums", true));
			lane("cross-host", crosshost(["--targets", "linux-x86_64,linux-arm64,wasm32-wasi,linux-x86_64-glibc"].concat(cases.length > 0 ? cases : ["Unsafe", "SwitchIndex", "Regress"])));
			debugLanes();
			if (port) lane("port self-compile", portNative);
		}
		var bad = [for (r in results) if (!r.ok) r.name];
		Sys.println('$tier: ${results.length - bad.length}/${results.length} lanes ok, ${Math.round(now() - t0)}s' + (bad.length == 0 ? "" : "; FAILED: " + bad.join(", ")));
		Sys.exit(bad.length > 0 ? 1 : 0);
	}
}
