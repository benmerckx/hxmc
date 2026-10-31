import Harness.*;
import sys.FileSystem;
import sys.io.File;

using StringTools;

// Checks the executables of the dynamic glibc mode (-D hxmc.libc=glibc) with
// readelf: the program interpreter of their architecture, DT_NEEDED only of
// the libraries expected, every symbol version a glibc 2.17 has (the floor),
// BIND_NOW and no text relocations (DT_TEXTREL, or a relocation in a
// segment that is not writable).
//   <haxe> -cp hxmc/test -cp haxe/test --run ElfCheck <dir> [--summary <file>]
// <dir>: the corpus's outputs (bin/hxmc-t: <case>/m*-glibc) or a staged
// corpus (<case>/m), as Corpus --libc glibc writes them.
class ElfCheck {
	// the libraries an executable may need (libffidyn.so, libcvarsdyn.so: Ffi's and
	// CVars' own, next to them)
	static final NEEDED = ["libc.so.6", "libpthread.so.0", "libdl.so.2", "libm.so.6", "libffidyn.so", "libcvarsdyn.so"];
	static final INTERP = ["X86-64" => "/lib64/ld-linux-x86-64.so.2", "AArch64" => "/lib/ld-linux-aarch64.so.1"];

	static function readelf(args:Array<String>, file:String):String {
		var r = exec(["readelf", "-W"].concat(args).concat([file]));
		if (r.code != 0) throw 'readelf ${args.join(" ")} $file: ${r.err}';
		return r.out;
	}

	// a GLIBC_x.y[.z] version as a comparable number
	static function version(v:String):Int {
		var p = v.substr(6).split(".").map(Std.parseInt);
		return p[0] * 10000 + (p.length > 1 ? p[1] : 0) * 100 + (p.length > 2 ? p[2] : 0);
	}

	public static function check(file:String):Array<String> {
		var bad = [];
		var h = readelf(["-h"], file);
		var mre = ~/Machine:\s+(.*)/;
		var machine = mre.match(h) ? StringTools.trim(mre.matched(1)) : "";
		var arch = machine.indexOf("X86-64") >= 0 ? "X86-64" : machine.indexOf("AArch64") >= 0 ? "AArch64" : machine;
		var l = readelf(["-l"], file);
		var interp = ~/Requesting program interpreter: ([^\]]+)\]/;
		if (!interp.match(l)) bad.push("no program interpreter");
		else if (interp.matched(1) != INTERP[arch]) bad.push('interpreter ${interp.matched(1)}, not ${INTERP[arch]}');
		// relocations only in writable segments: the loadable segments' flags
		var segs = [];
		var load = ~/^\s*LOAD\s+0x([0-9a-f]+)\s+0x([0-9a-f]+)\s+0x([0-9a-f]+)\s+0x([0-9a-f]+)\s+0x([0-9a-f]+)\s+(.{3})/;
		for (line in l.split("\n"))
			if (load.match(line)) segs.push({at: Std.parseInt("0x" + load.matched(2)), size: Std.parseInt("0x" + load.matched(5)), w: load.matched(6).indexOf("W") >= 0});
		var d = readelf(["-d"], file);
		if (d.indexOf("TEXTREL") >= 0) bad.push("DT_TEXTREL");
		if (d.indexOf("BIND_NOW") < 0) bad.push("no BIND_NOW");
		var needed = ~/\(NEEDED\)\s+Shared library: \[([^\]]+)\]/;
		var s = d;
		var libs = [];
		while (needed.match(s)) {
			libs.push(needed.matched(1));
			s = needed.matchedRight();
		}
		if (libs.indexOf("libc.so.6") < 0) bad.push("no DT_NEEDED libc.so.6");
		for (x in libs)
			if (NEEDED.indexOf(x) < 0) bad.push("DT_NEEDED " + x);
		var r = readelf(["-r"], file);
		var rel = ~/^([0-9a-f]{12,16})\s+[0-9a-f]+\s+(R_\S+)/;
		var n = 0;
		for (line in r.split("\n"))
			if (rel.match(line)) {
				n++;
				var at = Std.parseInt("0x" + rel.matched(1));
				if (!Lambda.exists(segs, g -> g.w && at >= g.at && at < g.at + g.size)) bad.push('${rel.matched(2)} at 0x${rel.matched(1)}: not in a writable segment');
			}
		var v = readelf(["-V"], file);
		var name = ~/Name: (GLIBC_[0-9.]+)/;
		var vs = [];
		s = v;
		while (name.match(s)) {
			vs.push(name.matched(1));
			s = name.matchedRight();
		}
		if (vs.length == 0) bad.push("no symbol versions");
		for (x in vs)
			if (version(x) > version("GLIBC_2.17")) bad.push(x + " (above the 2.17 floor)");
		if (bad.length == 0) Sys.println(pad(file, 48) + " ok  " + arch + ", " + libs.join(" ") + ", " + n + " relocations, versions " + [for (k in [for (x in vs) x => true].keys()) k].join(" "));
		return bad;
	}

	static function main() {
		var a = parseArgs(Sys.args(), ["--summary"]);
		if (a.rest.length != 1) fail("usage: ElfCheck <dir> [--summary <file>]");
		var dir = a.rest[0];
		var files = [];
		var cases = FileSystem.readDirectory(dir);
		cases.sort(compare);
		for (c in cases) {
			var p = '$dir/$c';
			if (!FileSystem.isDirectory(p)) continue;
			for (f in FileSystem.readDirectory(p))
				if ((f == "m" && FileSystem.exists('$p/expected.txt')) || (f.startsWith("m") && f.endsWith("-glibc") && !FileSystem.isDirectory('$p/$f'))) files.push('$p/$f');
		}
		files.sort(compare);
		var failed = 0;
		for (f in files) {
			var bad = check(f);
			if (bad.length > 0) {
				failed++;
				Sys.println(pad(f, 48) + " FAIL " + bad.slice(0, 6).join("; "));
			}
		}
		Sys.println('${files.length - failed}/${files.length} executables ok');
		summary(a.get("--summary"), '### readelf, the glibc mode: ${files.length - failed}/${files.length} executables ok\n');
		Sys.exit(failed > 0 || files.length == 0 ? 1 : 0);
	}
}
