import Harness.*;
import sys.FileSystem;
import sys.io.File;

using StringTools;

// hxmc's C declarations against the real headers (docs/interop.md,
// "Checking declarations against the headers"): each program below is
// lowered for each target with -D hxmc.header-check, which writes its
// declarations that name their headers as C++ assertions, and zig compiles
// them against that target's headers (zig's own C libraries: musl, the
// macOS SDK's, MinGW-w64's, wasi-libc). A declaration that disagrees fails
// the run; BadLayout must fail, with the messages its `// expect:` lines
// name. Without zig every check is skipped.
//   bin/hxmc/hxmc -cp hxmc/test -cp haxe/test --run HeaderCheck [target ...]
class HeaderCheck {
	static final OUT = "bin/hxmc-t/header";
	static final TARGETS = [
		"linux-x86_64" => "x86_64-linux-musl",
		"linux-arm64" => "aarch64-linux-musl",
		"macos-x86_64" => "x86_64-macos",
		"macos-arm64" => "aarch64-macos",
		"windows-x86_64" => "x86_64-windows-gnu",
		"windows-arm64" => "aarch64-windows-gnu",
		"wasm32-wasi" => "wasm32-wasi"
	];
	static final ORDER = ["linux-x86_64", "linux-arm64", "macos-x86_64", "macos-arm64", "windows-x86_64", "windows-arm64", "wasm32-wasi"];
	// a program, its class path, whether it is native only, POSIX only (the std's WASI imports name no header:
	// wasi-libc declares them as __wasi_*; on wasm32, CBindings' own)
	static final PROGRAMS = [
		{main: "HeaderStd", cp: "hxmc/test/header", native: true, posix: false},
		{main: "CBindings", cp: "hxmc/test/cases", native: false, posix: false},
		{main: "CBindingsCallbacks", cp: "hxmc/test/cases", native: true, posix: false},
		{main: "CBindingsFds", cp: "hxmc/test/cases", native: true, posix: true},
		{main: "CBindingsStrings", cp: "hxmc/test/cases", native: false, posix: false},
		{main: "CBindingsBuffer", cp: "hxmc/test/cases", native: false, posix: false},
		{main: "CBindingsOut", cp: "hxmc/test/cases", native: false, posix: false},
		{main: "CBindingsNull", cp: "hxmc/test/cases", native: false, posix: false},
		{main: "CBindingsArrays", cp: "hxmc/test/cases", native: false, posix: false}
	];

	public static function run(args:Array<String>):Int {
		var targets = args.length > 0 ? args : ORDER;
		var zig = Sys.getEnv("ZIG") ?? "zig";
		if (try exec([zig, "version"]).code != 0 catch (_:Dynamic) true) {
			Sys.println("header check: skipped (no zig)");
			return 0;
		}
		mkdirs(OUT);
		var failed = 0, ok = 0;
		for (t in targets) {
			var triple = TARGETS.get(t);
			if (triple == null) fail("header check: unknown target " + t);
			for (p in PROGRAMS) {
				if (p.native && t == "wasm32-wasi" || p.posix && !(t.startsWith("linux") || t.startsWith("macos"))) continue;
				var r = check(zig, p.main, p.cp, t, triple);
				if (r == null) ok++ else {
					failed++;
					Sys.println('${p.main} $t: $r');
				}
			}
			// (a declaration that disagrees: the check must fail, saying why)
			{
				var r = check(zig, "BadLayout", "hxmc/test/header", t, triple);
				var want = [for (l in File.getContent("hxmc/test/header/BadLayout.hx").split("\n")) if (l.startsWith("// expect: ")) l.substr(11)];
				var missing = r == null ? want : [for (w in want) if (r.indexOf(w) < 0) w];
				if (missing.length == 0) ok++ else {
					failed++;
					Sys.println('BadLayout $t: ' + (r == null ? "passed, but must fail" : "the failure lacks " + missing.join("; ") + "\n" + tail(r, 1500)));
				}
			}
		}
		Sys.println('header check: $ok/${ok + failed} ok');
		return failed > 0 ? 1 : 0;
	}

	// null: the declarations agree with the headers; else what failed
	static function check(zig:String, main:String, cp:String, target:String, triple:String):Null<String> {
		var cpp = '$OUT/$main-$target.cpp';
		var b = exec([
			"bin/hxmc/hxmc", '$OUT/$main-$target', "-cp", cp, "-cp", "bin/hxmc/std", "-main", main, "--custom-target", "hxmc", "-D", "disable-parallelism",
			"-D", "hxmc.target=" + target, "-D", "hxmc.lower-only", "-D", "hxmc.header-check=" + cpp
		]);
		if (b.code != 0) return "the build failed: " + tail(b.out + b.err, 1500);
		// (an object nobody reads: zig's -fsyntax-only fails to rename the output it does not write)
		var c = exec([zig, "c++", "-target", triple, "-std=c++17", "-nostdinc++", "-c", "-o", '$OUT/$main-$target.o',"-I", cp, "-I", "hxmc/test/cases", "-x", "c++", cpp]);
		return c.code == 0 ? null : c.out + c.err;
	}
}
