import Harness.*;
import sys.FileSystem;

using StringTools;

// Shared libraries written by hxmc (-D hxmc.shared, LinkDyn; Android's
// lib<name>.so is one):
//   bin/hxmc/hxmc -cp hxmc/test -cp haxe/test --run SharedCheck
// - in the dynamic glibc mode for x86-64 (and arm64 under qemu with the
//   cross C library, when there): hxmc/test/shared/Lib.hx as a library,
//   loaded by hxmc/test/shared/Host.hx (an executable of the same mode) with
//   dlopen, its export lib_run starting the runtime on a thread of its own
//   and returning what the program computed (thread-locals through TLSDESC,
//   RELATIVE relocations, imports through GOT slots, a thread, an exception);
// - readelf: a shared object at address 0, no interpreter or text
//   relocations, its SONAME, the exports defined and nothing else, the
//   generated main hidden;
// - the same library for android-arm64 and android-x86_64 (not run
//   here): 16 KB segments, Bionic's imports, the TLS models Bionic
//   implements for a dlopen'ed library;
// - hxmc/test/android/AndroidHello.hx as libmain.so for both, as a
//   packager builds the library its APK holds (docs/using.md, "Native output
//   for a packager"): the SONAME the output's file name, libmain.so, and
//   ANativeActivity_onCreate exported.
class SharedCheck {
	static final OUT = "bin/hxmc-shared";
	static var failures:Array<String> = [];

	static function check(what:String, ok:Bool, detail = "") {
		Sys.println(pad(what, 48) + " " + (ok ? "ok" : "FAIL") + (detail != "" ? "  " + detail : ""));
		if (!ok) failures.push(what);
	}

	static function has(tool:String):Bool
		return exec(["sh", "-c", "command -v " + tool]).code == 0;

	static function main() {
		var tool = FileSystem.fullPath(Sys.getEnv("HXMC_TOOL") ?? "bin/hxmc/hxmc");
		function build(out:String, main:String, args:Array<String>, cp = "hxmc/test/shared"):Bool {
			var r = exec([tool, out, "-cp", cp, "-cp", "bin/hxmc/std", "-main", main, "--custom-target", "hxmc", "-D", "disable-parallelism"].concat(args),
				{merge: true});
			if (r.code != 0) Sys.println(tail(r.out, 600));
			return r.code == 0;
		}
		var expected = "lib: p0,p1,p2,p3,p4 30 boom env=true thread=3889\nhost: lib_run returned 4919";
		var qemu = Sys.getEnv("QEMU_LD_PREFIX") ?? "/usr/aarch64-linux-gnu";
		for (t in ["linux-x86_64", "linux-arm64"]) {
			var dir = '$OUT/$t';
			mkdirs(dir);
			var lib = '$dir/libhxlib.so';
			var ok = build(lib, "Lib", ["-D", "hxmc.libc=glibc", "-D", "hxmc.shared", "-D", "hxmc.exports=lib_run,lib_result", "-D", 'hxmc.target=$t'])
				&& build('$dir/host', "Host", ["-D", "hxmc.libc=glibc", "-D", 'hxmc.target=$t']);
			check('$t glibc: the library and its host build', ok);
			if (!ok) continue;
			elf(lib, t, ["lib_run", "lib_result"]);
			var run = t == "linux-x86_64" ? [FileSystem.fullPath('$dir/host')] : has("qemu-aarch64-static") && FileSystem.exists(qemu) ? ["qemu-aarch64-static", "-L", qemu,
				FileSystem.fullPath('$dir/host')] : null;
			if (run == null) {
				Sys.println(pad('$t glibc: the host loads it', 48) + " skipped  no qemu-aarch64-static or " + qemu);
				continue;
			}
			var r = exec(run.concat([FileSystem.fullPath(lib)]), {env: ["HXMC_SHARED_CHECK" => "1"], merge: true});
			var out = [for (l in r.out.split("\n")) if (l.startsWith("lib:") || l.startsWith("host: lib_run returned")) l].join("\n");
			check('$t glibc: the host loads it, the runtime runs', r.code == 0 && out == expected, r.code == 0 ? out.split("\n").pop() : tail(r.out, 300));
		}
		for (t in ["android-arm64", "android-x86_64"]) {
			var dir = '$OUT/$t';
			mkdirs(dir);
			var lib = '$dir/libhxlib.so';
			var ok = build(lib, "Lib", ["-D", "hxmc.exports=lib_run,lib_result", "-D", 'hxmc.target=$t']);
			check('$t: the library builds', ok);
			if (ok) elf(lib, t, ["lib_run", "lib_result"]);
			var lib = '$dir/libmain.so';
			var ok = build(lib, "AndroidHello", ['-D', 'hxmc.target=$t'], "hxmc/test/android");
			check('$t: AndroidHello as libmain.so builds', ok);
			if (ok) elf(lib, t, ["ANativeActivity_onCreate"]);
		}
		if (failures.length > 0) {
			Sys.println("SharedCheck: " + failures.length + " failed");
			Sys.exit(1);
		}
		Sys.println("SharedCheck: all passed");
	}

	static function readelf(args:Array<String>, file:String):String
		return exec(["readelf", "-W"].concat(args).concat([file])).out;

	static function elf(lib:String, t:String, exports:Array<String>) {
		if (!has("readelf")) return;
		var h = readelf(["-h"], lib), l = readelf(["-l"], lib), d = readelf(["-d"], lib), syms = readelf(["--dyn-syms"], lib), r = readelf(["-r"], lib);
		check('$t: ET_DYN at address 0, no interpreter', h.contains("DYN (Shared object file)") && !l.contains("INTERP") && ~/LOAD\s+0x0+ 0x0+ /.match(l));
		check('$t: no text relocations, BIND_NOW', !d.contains("TEXTREL") && d.contains("BIND_NOW"));
		var soname = haxe.io.Path.withoutDirectory(lib);
		check('$t: SONAME $soname', d.contains('Library soname: [$soname]'));
		var defined = [for (line in syms.split("\n")) if (~/GLOBAL\s+DEFAULT\s+\d+\s+/.match(line)) line.trim().split(" ").pop()];
		defined.sort(compare);
		var want = exports.copy();
		want.sort(compare);
		check('$t: the exports defined, nothing else', defined.join(",") == want.join(","), defined.join(","));
		var android = t.startsWith("android");
		if (android) {
			var aligned = true;
			for (line in l.split("\n"))
				if (line.trim().startsWith("LOAD") && !line.trim().endsWith("0x4000")) aligned = false;
			check('$t: 16 KB segments', aligned);
			check('$t: libc.so with LIBC versions', d.contains("Shared library: [libc.so]") && syms.contains("@LIBC"));
		}
		var tls = t.endsWith("x86_64") && android ? r.contains("R_X86_64_DTPMOD64") && r.contains("__tls_get_addr") : r.contains("TLSDESC");
		check('$t: thread-locals ' + (t.endsWith("x86_64") && android ? "general dynamic" : "through TLSDESC"), tls);
		check('$t: RELATIVE relocations', r.contains("_RELATIVE"));
	}
}
