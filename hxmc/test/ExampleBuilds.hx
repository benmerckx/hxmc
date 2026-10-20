import Harness.*;
import sys.FileSystem;

using StringTools;

// The packages' examples built, not run: `make check`'s examples lane
// (docs/testing.md), what CI's site and gfx jobs build, without a browser,
// GPU or display. The examples are the site's gallery's (site/src/Examples.hx:
// every packages/<pkg>/examples file with a header), of every package with
// examples (also theme's, which the gallery leaves out); each is built as the
// site builds it, for wasm32-wasi (Examples.wasm, Examples.wasmArgs: the
// package's class paths, legacy exception handling), and each program on a
// canvas or playing a sound, a program on @hxmc/os's window and audio, also
// for this machine (Examples.buildArgs: as make gfx-programs, 3d-check,
// audio-programs and the site's measurements build them; Linux in the glibc
// mode). The builds run in parallel, with the module cache, into
// bin/hxmc-t/examples (each one's log beside it); a build that fails prints
// its log's end.
//   bin/hxmc/hxmc -cp hxmc/test -cp haxe/test <the site's class paths> --run ExampleBuilds [-j n] [id ...]
// (the site's class paths, which Examples needs: the Makefile's SITE_CP;
// ids restrict it to those examples)
class ExampleBuilds {
	static final OUT = "bin/hxmc-t/examples";
	static final TOOL = "bin/hxmc/hxmc";

	static function hostTarget():String {
		var m = exec(["uname", "-m"]).out.trim();
		var os = Sys.systemName() == "Mac" ? "macos" : Sys.systemName() == "Windows" ? "windows" : "linux";
		return os + "-" + (m == "aarch64" || m == "arm64" || m == "ARM64" ? "arm64" : "x86_64");
	}

	static function main() {
		var args = Sys.args();
		// (each build is parallel itself: half the cores' worth of builds at once)
		var jobs = Std.int(Math.max(1, cpus() / 2));
		var ids = [];
		var i = 0;
		while (i < args.length) {
			var a = args[i++];
			if (a == "-j") jobs = Std.parseInt(args[i++]) else ids.push(a);
		}
		// (the gallery's packages, then any other with examples: theme's)
		var others = [for (p in FileSystem.readDirectory("packages")) if (!Examples.PACKAGES.contains(p) && FileSystem.exists('packages/$p/examples')) p];
		others.sort(compare);
		var examples = Examples.collect(Examples.PACKAGES.concat(others));
		var known = [for (e in examples) e.id];
		var bad = [for (id in ids) if (!known.contains(id)) id];
		if (bad.length > 0) fail('ExampleBuilds: unknown example(s): ${bad.join(", ")} (known: ${known.join(", ")})');
		if (ids.length > 0) examples = [for (e in examples) if (ids.contains(e.id)) e];
		var host = hostTarget();
		var builds:Array<{id:String, target:String, args:Array<String>}> = [];
		for (e in examples)
			if (Examples.wasm(e)) builds.push({id: e.id, target: "wasm32-wasi", args: Examples.wasmArgs(e, '$OUT/wasm32-wasi/${e.id}.wasm')});
		for (e in examples)
			if (e.demo.match(Canvas(_, _) | Sound))
				builds.push({id: e.id, target: host, args: Examples.buildArgs(e.pkg, e.main, host, '$OUT/$host/${e.id}' + (host.startsWith("windows") ? ".exe" : ""))});
		mkdirs(OUT + "/wasm32-wasi");
		mkdirs(OUT + "/" + host);
		var t0 = now();
		var failed = [];
		parallel(builds, jobs, b -> exec([TOOL].concat(b.args), {log: b.args[0] + ".log"}), (b, r) -> {
			var ok = r != null && r.code == 0 && FileSystem.exists(b.args[0]);
			Sys.println(pad(b.id, 18) + " " + pad(b.target, 13) + " " + (ok ? "ok  " : "FAIL") + " " + fixed(r == null ? 0 : r.seconds).lpad(" ", 6) + "s");
			if (!ok) {
				failed.push(b.id + " (" + b.target + ")");
				Sys.println(tail(readText(b.args[0] + ".log"), 1500));
			}
		});
		var targets = [for (t in ["wasm32-wasi", host]) '${builds.filter(b -> b.target == t).length} $t'].join(", ");
		Sys.println('examples: ${builds.length - failed.length}/${builds.length} built ($targets), ${Math.round(now() - t0)}s'
			+ (failed.length == 0 ? "" : "; FAILED: " + failed.join(", ")));
		Sys.exit(failed.length == 0 ? 0 : 1);
	}
}
