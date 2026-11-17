import Harness.*;
import haxe.io.Bytes;
import sys.FileSystem;
import sys.io.File;

using StringTools;

// What debuggers and unwinders get from hxmc (docs/hxmc.md, "Debugging"),
// checked with the system's tools on hxmc/test/debug/Lines.hx:
//   bin/hxmc/hxmc -cp hxmc/test -cp haxe/test --run DebugCheck [--target T] [--stage DIR]
//   <haxe> -cp hxmc/test -cp haxe/test --run DebugCheck --run DIR
// - built with -debug for the host (Linux): gdb in batch mode (lldb where
//   there is no gdb) stops at the line marked `break here`, and its
//   backtrace names the Haxe functions (pack.Class.field) with the lines of
//   the calls marked `frame:`, in order;
// - built with -D hxmc.lines (the lines alone) and without: the same code
//   (a debug build's code is the release build's);
// - the unwind tables: readelf --debug-dump=frames (ELF: an FDE per
//   function, nothing it warns about), llvm-readobj --unwind (Windows: a
//   function entry per function with a frame); llvm-dwarfdump --verify (the
//   DWARF of ELF, Mach-O and PE) and a line table row at the breakpoint;
// - the sizes of the unwind tables and of the line information.
// --target cross-builds (no debugger: the tools' checks only); --stage
// writes the -debug build and its source to DIR, for --run on the target's
// machine (CI's test jobs: gdb on Linux, lldb on macOS). Exits non-zero on
// a failure; a missing tool is reported and skipped.
class DebugCheck {
	static final OUT = "bin/hxmc-debug";
	static final SRC = "hxmc/test/debug";
	static final STD = "bin/hxmc/std";

	static var failures:Array<String> = [];

	static function check(what:String, ok:Bool, detail = "") {
		Sys.println(pad(what, 44) + " " + (ok ? "ok" : "FAIL") + (detail != "" ? "  " + detail : ""));
		if (!ok) failures.push(what);
	}

	static function skip(what:String, why:String)
		Sys.println(pad(what, 44) + " skipped  " + why);

	static function has(tool:String):Bool
		return !windows && exec(["sh", "-c", "command -v " + tool]).code == 0;

	static function main() {
		var a = parseArgs(Sys.args(), ["--target", "--stage", "--run"]);
		if (a.has("--run")) {
			if (!windows) exec(["chmod", "+x", a.get("--run") + "/lines"]);
			debugger(a.get("--run") + "/lines", a.get("--run") + "/Lines.hx");
			finish();
		}
		var target = a.get("--target");
		var tool = FileSystem.fullPath(Sys.getEnv("HXMC_TOOL") ?? "bin/hxmc/hxmc");
		var dir = OUT + "/" + (target ?? "host");
		mkdirs(dir);
		var exe = target != null && target.startsWith("windows") ? ".exe" : "";
		function build(name:String, args:Array<String>):String {
			var cmd = [tool, '$dir/$name', "-cp", SRC, "-cp", STD, "-main", "Lines", "--custom-target", "hxmc", "-D", "disable-parallelism"].concat(args);
			if (target != null) cmd = cmd.concat(["-D", "hxmc.target=" + target]);
			var r = exec(cmd, {merge: true});
			if (r.code != 0) fail('DebugCheck: building $name failed:\n' + tail(r.out, 3000));
			return '$dir/$name$exe';
		}
		var debug = build("lines", ["-debug"]);
		var plain = build("plain", []);
		var lines = build("plain-lines", ["-D", "hxmc.lines"]);
		var fmt = format(debug);
		// the code does not depend on the line information
		var t1 = section(plain, fmt.text), t2 = section(lines, fmt.text);
		check("the same code with and without lines", t1 != null && t2 != null && t1.compare(t2) == 0, t1 == null ? "no " + fmt.text : "");
		switch fmt.kind {
			case "elf":
				if (has("readelf")) {
					var r = exec(["readelf", "-W", "--debug-dump=frames", debug], {merge: true});
					var fde = ~/ FDE cie=[0-9a-f]+ pc=0*([0-9a-f]+)\.\./;
					var starts = new Map<String, Bool>();
					for (l in r.out.split("\n"))
						if (fde.match(l)) starts.set(fde.matched(1), true);
					var bad = r.code != 0 || ~/readelf: (warning|error)/i.match(r.out);
					// every function of the symbol table with a size (the C
					// library's assembly has none, and no CFI) but the signal
					// return trampoline, which debuggers recognize
					var syms = exec(["readelf", "-W", "-s", debug], {merge: true});
					var funcs = 0, missing = [];
					for (l in syms.out.split("\n")) {
						var w = l.split(" ").filter(x -> x != "");
						if (w.length < 8 || w[3] != "FUNC" || w[2] == "0") continue;
						funcs++;
						var at = ~/^0+/.replace(w[1], "");
						if (!starts.exists(at) && w[7] != "__restore_rt") missing.push(w[7]);
					}
					check("readelf: an FDE per function", !bad && missing.length == 0 && funcs > 100, '${Lambda.count(starts)} FDEs, $funcs functions' + (missing.length > 0 ? ", none for " + missing.slice(0, 10).join(" ") : ""));
				} else skip("readelf: an FDE per function", "(no readelf)");
			case "pe":
				if (has("llvm-readobj")) {
					var r = exec(["llvm-readobj", "--unwind", plain], {merge: true});
					var n = r.out.split("RuntimeFunction {").length - 1;
					check("llvm-readobj: the functions' unwind entries", r.code == 0 && n > 100 && !~/warning|error|invalid/i.match(r.out), '$n entries');
				} else skip("llvm-readobj: the functions' unwind entries", "(no llvm-readobj)");
			case _:
		}
		{
			if (has("llvm-dwarfdump")) {
				var r = exec(["llvm-dwarfdump", "--verify", debug], {merge: true});
				check("llvm-dwarfdump --verify", r.code == 0 && r.out.indexOf("No errors.") >= 0, r.code == 0 ? "" : tail(r.out, 400));
				var l = exec(["llvm-dwarfdump", "--debug-line", debug], {merge: true});
				var src = File.getContent('$SRC/Lines.hx').split("\n");
				var breakLine = 1 + Lambda.findIndex(src, s -> s.indexOf("// break here") >= 0);
				check("a line table row at the breakpoint's line", l.out.indexOf("Lines.hx") >= 0 && new EReg("\\s" + breakLine + "\\s+\\d+\\s+\\d+\\s", "").match(l.out));
			} else skip("llvm-dwarfdump --verify", "(no llvm-dwarfdump)");
		}
		// the sizes
		function isUnwind(k:String)
			return k.indexOf("eh_frame") >= 0 || k.indexOf("unwind_info") >= 0 || k == ".pdata" || k == ".xdata";
		var sp = sizes(plain), sd = sizes(debug);
		var total = FileSystem.stat(plain).size;
		var unwind = 0;
		for (k => v in sp)
			if (isUnwind(k)) unwind += v;
		var dw = 0;
		for (k => v in sd)
			if (k.indexOf("debug_") >= 0) dw += v;
		Sys.println('sizes: ${total} bytes; unwind tables ${unwind} (${pct(unwind, total)}: ${[for (k => v in sp) if (isUnwind(k)) '$k $v'].join(", ")}); -debug: DWARF ${dw} (${pct(dw, total)})');
		if (a.has("--stage")) {
			var d = a.get("--stage");
			mkdirs(d);
			File.copy(debug, d + "/lines" + exe);
			File.copy('$SRC/Lines.hx', d + "/Lines.hx");
			Sys.println('staged in $d');
		} else if (target == null) debugger(debug, '$SRC/Lines.hx');
		finish();
	}

	static function finish() {
		Sys.println(failures.length == 0 ? "DebugCheck: all checks passed" : "DebugCheck: failed: " + failures.join(", "));
		Sys.exit(failures.length == 0 ? 0 : 1);
	}

	static function pct(n:Int, of:Int):String
		return fixed(100 * n / of, 2) + "%";

	// the debugger session: a breakpoint at `break here`, the backtrace
	static function debugger(exe:String, source:String) {
		var src = File.getContent(source).split("\n");
		var breakLine = 0;
		var frames:Array<{func:String, line:Int}> = [];
		for (i in 0...src.length) {
			if (src[i].indexOf("// break here") >= 0) breakLine = i + 1;
			var m = src[i].indexOf("// frame: ");
			if (m >= 0) frames.push({func: src[i].substr(m + 10).trim(), line: i + 1});
		}
		// the frames from the innermost: the breakpoint's, then inner's own
		// recursive calls (twice), outer's, main's
		var inner = frames[0], outer = frames[1], mainF = frames[2];
		var expect = [{func: inner.func, line: breakLine}, inner, inner, outer, mainF];
		exe = FileSystem.fullPath(exe);
		var r:Harness.ExecResult;
		var which:String;
		if (has("gdb")) {
			which = "gdb";
			r = exec(["gdb", "-batch", "-nx", "-ex", "break Lines.hx:" + breakLine, "-ex", "run", "-ex", "bt", "-ex", "kill", exe], {merge: true, timeout: 120});
		} else if (has("lldb")) {
			which = "lldb";
			r = exec(["lldb", "-b", "-o", "breakpoint set --file Lines.hx --line " + breakLine, "-o", "run", "-o", "bt", "-o", "kill", exe], {merge: true, timeout: 120});
		} else {
			skip("a debugger's breakpoint and backtrace", "(no gdb or lldb)");
			return;
		}
		// frames: gdb `#1  0x... in Lines.inner () at /.../Lines.hx:9`, lldb
		// `frame #1: 0x... lines`Lines.inner at Lines.hx:9`
		var got:Array<{func:String, line:Int}> = [];
		var re = ~/(?:in |#\d+\s+|`)([\w.$]+)(?: \([^)]*\))? at \S*?Lines\.hx:(\d+)/;
		for (l in r.out.split("\n"))
			if ((l.indexOf("#") >= 0 || l.indexOf("frame") >= 0) && re.match(l)) got.push({func: re.matched(1), line: Std.parseInt(re.matched(2))});
		// (the backtrace: from a frame of the breakpoint followed by the others;
		// lldb also shows the stop's frame before it)
		var at = -1;
		for (k in 0...got.length) {
			var all = true;
			for (j in 0...expect.length)
				if (k + j >= got.length || got[k + j].func != expect[j].func || got[k + j].line != expect[j].line) all = false;
			if (all) {
				at = k;
				break;
			}
		}
		// (a debugger the system does not let start a process: reported, not a failure)
		if (at < 0 && ~/attach failed|not allowed|Operation not permitted|ptrace: /i.match(r.out)) {
			skip(which + ": the breakpoint and the backtrace", "(the system refused: " + tail(r.out, 300).replace("\n", " ") + ")");
			return;
		}
		var ok = at >= 0;
		check(which + ": the breakpoint and the backtrace", ok, ok ? [for (f in expect) f.func + ":" + f.line].join(" < ") : "\n" + r.out);
		if (ok) Sys.println("    " + [for (l in r.out.split("\n")) if (l.startsWith("#") || l.indexOf("frame #") >= 0 || l.startsWith("Breakpoint")) l].join("\n    "));
	}

	// ---- the executable's sections (ELF, PE, Mach-O)

	static function format(path:String):{kind:String, text:String} {
		var b = File.getBytes(path);
		if (b.getInt32(0) == 0x464c457f) return {kind: "elf", text: ".text"};
		if (b.get(0) == 0x4d && b.get(1) == 0x5a) return {kind: "pe", text: ".text"};
		return {kind: "macho", text: "__text"};
	}

	// name -> (file offset, size)
	static function sectionTable(path:String):Map<String, {off:Int, size:Int}> {
		var b = File.getBytes(path);
		var m = new Map();
		function cstr(at:Int, max:Int):String {
			var e = at;
			while (e < at + max && b.get(e) != 0)
				e++;
			return b.getString(at, e - at);
		}
		if (b.getInt32(0) == 0x464c457f) {
			var shoff = b.getInt32(40), n = b.getUInt16(60), str = b.getUInt16(62);
			var strOff = b.getInt32(shoff + 64 * str + 24);
			for (i in 0...n) {
				var h = shoff + 64 * i;
				m.set(cstr(strOff + b.getInt32(h), 64), {off: b.getInt32(h + 24), size: b.getInt32(h + 32)});
			}
		} else if (b.get(0) == 0x4d && b.get(1) == 0x5a) {
			var pe = b.getInt32(0x3c);
			var n = b.getUInt16(pe + 6), opt = b.getUInt16(pe + 20);
			// (long names: /<offset> in the string table after the COFF symbols)
			var strtab = b.getInt32(pe + 12) + 18 * b.getInt32(pe + 16);
			var at = pe + 24 + opt;
			for (i in 0...n) {
				var h = at + 40 * i;
				var name = cstr(h, 8);
				if (name.startsWith("/")) name = cstr(strtab + Std.parseInt(name.substr(1)), 256);
				m.set(name, {off: b.getInt32(h + 20), size: b.getInt32(h + 8)});
			}
		} else {
			var n = b.getInt32(16);
			var at = 32;
			for (_ in 0...n) {
				var cmd = b.getInt32(at), size = b.getInt32(at + 4);
				if (cmd == 0x19)
					for (k in 0...b.getInt32(at + 64)) {
						var s = at + 72 + 80 * k;
						m.set(cstr(s, 16), {off: b.getInt32(s + 48), size: b.getInt32(s + 40)});
					}
				at += size;
			}
		}
		return m;
	}

	static function section(path:String, name:String):Null<Bytes> {
		var s = sectionTable(path).get(name);
		return s == null ? null : File.getBytes(path).sub(s.off, s.size);
	}

	static function sizes(path:String):Map<String, Int>
		return [for (k => v in sectionTable(path)) k => v.size];

}
