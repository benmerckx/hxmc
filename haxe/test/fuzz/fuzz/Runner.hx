package fuzz;

import haxe.io.Bytes;
import sys.FileSystem;
import sys.io.File;

/** How to compile to and run one target. `{out}` stands for the side's output directory. **/
typedef TargetSpec = {
	name:String,
	args:Array<String>,
	/** `none`, `file:<path>`, `dir:<path>`, `zip:<path>` (all members) or `hxb:<path>` (the `.hxb` members) **/
	output:String,
	/** Shell command running the compiled program, or null. For `none` outputs the compiler log is the run output. **/
	run:Null<String>,
	/** Replaces the compiler of the side running this target (e.g. the hxmc tool). **/
	?compiler:String,
}

/** A compiler invocation: one side of a lane. **/
typedef Side = {
	label:String,
	compiler:String,
	target:TargetSpec,
}

/**
	A comparison. `diff` lanes compile the same target with the reference and
	the port and require identical diagnostics, outputs and (with `run`) run
	output; `exec` lanes compare only what two (possibly different) targets
	print when the program runs.
**/
typedef Lane = {
	name:String,
	a:Side,
	b:Side,
	exec:Bool,
	run:Bool,
}

typedef Verdict = {
	/** `ok`, `invalid` (side A rejected the program) or a failure kind **/
	kind:String,
	detail:String,
}

typedef SideResult = {
	code:Int,
	log:String,
	runCode:Int,
	runLog:String,
	dir:String,
}

class Runner {
	public static var compileTimeout = 120;
	public static var runTimeout = 30;
	public static var root:String;
	public static var common:Array<String> = [];

	/** Exit codes of `timeout` and of a shell that could not find the command. **/
	static inline var TIMEOUT = 124;

	public static function targets(ref:String):Map<String, TargetSpec> {
		var m = new Map<String, TargetSpec>();
		function add(t:TargetSpec)
			m.set(t.name, t);
		add({
			name: "hxb",
			args: ["--interp", "--no-output", "--hxb", "{out}/out.hxb"],
			output: "hxb:out.hxb",
			run: null
		});
		add({
			name: "interp",
			args: ["--interp"],
			output: "none",
			run: null
		});
		add({
			name: "js",
			args: ["--js", "{out}/main.js"],
			output: "file:main.js",
			run: "node {out}/main.js"
		});
		add({
			name: "lua",
			args: ["--lua", "{out}/main.lua"],
			output: "file:main.lua",
			run: "lua {out}/main.lua"
		});
		add({
			name: "python",
			args: ["--python", "{out}/main.py"],
			output: "file:main.py",
			run: "python3 {out}/main.py"
		});
		add({
			name: "neko",
			args: ["--neko", "{out}/main.n"],
			output: "file:main.n",
			run: "neko {out}/main.n"
		});
		add({
			name: "hl",
			args: ["--hl", "{out}/main.hl"],
			output: "file:main.hl",
			run: "hl {out}/main.hl"
		});
		add({
			name: "hlc",
			args: ["--hl", "{out}/hlc/main.c", "-D", "no-compilation"],
			output: "dir:hlc",
			run: null
		});
		add({
			name: "php",
			args: ["--php", "{out}/php"],
			output: "dir:php",
			run: "php {out}/php/index.php"
		});
		add({
			name: "cpp",
			args: ["--cpp", "{out}/cpp", "-D", "no-compilation"],
			output: "dir:cpp",
			run: null
		});
		add({
			name: "jvm",
			args: ["--jvm", "{out}/main.jar"],
			output: "zip:main.jar",
			run: "java -jar {out}/main.jar"
		});
		add({
			name: "swf",
			args: ["--swf", "{out}/main.swf"],
			output: "file:main.swf",
			run: null
		});
		// the program compiled to a native executable for the host by the hxmc tool
		// (bin/hxmc/hxmc, with the target's std bin/hxmc/std: `make hxmc std`)
		// (run with a 64 KB nursery, as hxmc's corpus: frequent collections, so
		// a missing or stale root shows)
		add({
			name: "hxmc",
			args: ["-cp", root + "/bin/hxmc/std", "--custom-target", "hxmc"],
			output: "none",
			run: "env RT_MINOR_KB=64 {out}/prog",
			compiler: root + "/bin/hxmc/hxmc {out}/prog"
		});
		// Checks retained and no Mir optimizations: a differential safety lane.
		add({
			name: "hxmc-checked",
			args: ["-cp", root + "/bin/hxmc/std", "--custom-target", "hxmc", "-D", "hxmc.checked"],
			output: "none",
			run: "env RT_MINOR_KB=64 RT_VERIFY=1 {out}/prog",
			compiler: root + "/bin/hxmc/hxmc {out}/prog"
		});
		// the same as a wasm32-wasi module, run by node (hxmc/bootstrap/wasi.mjs)
		add({
			name: "hxmc-wasm",
			args: ["-cp", root + "/bin/hxmc/std", "--custom-target", "hxmc", "-D", "hxmc.target=wasm32-wasi"],
			output: "none",
			run: "env RT_MINOR_KB=64 node --no-warnings " + root + "/hxmc/bootstrap/wasi.mjs {out}/prog.wasm",
			compiler: root + "/bin/hxmc/hxmc {out}/prog.wasm"
		});
		return m;
	}

	static function shellQuote(s:String):String {
		if (s.length > 0 && ~/^[A-Za-z0-9_\/.,:=+@%{}-]+$/.match(s))
			return s;
		return "'" + s.split("'").join("'\\''") + "'";
	}

	static function sh(cmd:String):Int
		return Sys.command("sh", ["-c", cmd]);

	static function readText(path:String):String {
		try {
			return File.getContent(path);
		} catch (_:Dynamic) {
			return "";
		}
	}

	static function readCode(path:String):Int {
		var s = StringTools.trim(readText(path));
		var i = Std.parseInt(s);
		return i == null ? -1 : i;
	}

	public static function rmrf(path:String) {
		if (!FileSystem.exists(path))
			return;
		if (FileSystem.isDirectory(path)) {
			for (f in FileSystem.readDirectory(path))
				rmrf(path + "/" + f);
			FileSystem.deleteDirectory(path);
		} else
			FileSystem.deleteFile(path);
	}

	public static function writeProgram(files:Array<{path:String, text:String}>, dir:String) {
		rmrf(dir);
		for (f in files) {
			var p = dir + "/" + f.path;
			var slash = p.lastIndexOf("/");
			FileSystem.createDirectory(p.substr(0, slash));
			File.saveContent(p, f.text);
		}
	}

	/** The compile command of a side, run from `<work>/<label>` with the sources in `<work>/src`. **/
	public static function commandLine(side:Side, out:String):String {
		var compiler = side.target.compiler != null ? side.target.compiler : side.compiler;
		var args = ["-cp", "../src", "-main", "Main"].concat(common).concat(side.target.args);
		return StringTools.replace(compiler, "{out}", out) + " " + [for (a in args) shellQuote(StringTools.replace(a, "{out}", out))].join(" ");
	}

	public static function runSide(side:Side, work:String, run:Bool):SideResult {
		var dir = work + "/" + side.label;
		rmrf(dir);
		// both sides compile in <work>/cwd (then renamed to <work>/<label>): output that
		// embeds the working directory (gencpp's __files__.cpp, source maps of the null
		// position, fdb paths) is then the same for both
		var cwd = work + "/cwd";
		rmrf(cwd);
		FileSystem.createDirectory(cwd + "/out");
		// as haxe/test/Conformance.hx: both compilers use the checkout's std
		var std = shellQuote(root + "/haxe/upstream/std");
		var env = "HAXE_STD_PATH=" + std + " HAXE_IN_HAXE_STD_PATH=" + std + " ";
		var cmd = "cd " + shellQuote(cwd) + " && " + env + "timeout " + compileTimeout + " " + commandLine(side, "out")
			+ " > compile.log 2>&1 < /dev/null; echo $? > compile.code";
		sh(cmd);
		FileSystem.rename(cwd, dir);
		var code = readCode(dir + "/compile.code");
		var res:SideResult = {
			code: code,
			log: normalize(readText(dir + "/compile.log"), work),
			runCode: 0,
			runLog: "",
			dir: dir
		};
		if (code == 0 && run && side.target.run != null) {
			var rc = "cd " + shellQuote(dir) + " && timeout " + runTimeout + " " + StringTools.replace(side.target.run, "{out}", "out")
				+ " > run.log 2>&1 < /dev/null; echo $? > run.code";
			sh(rc);
			res.runCode = readCode(dir + "/run.code");
			res.runLog = normalize(readText(dir + "/run.log"), work);
		}
		return res;
	}

	static function normalize(s:String, work:String):String {
		s = StringTools.replace(s, work, "<work>");
		return StringTools.replace(s, root, "<root>");
	}

	/**
		Logs of a "Compiler failure" without the backtrace, which only the
		OCaml reference prints; null when the log reports no compiler failure.
	**/
	static function failure(log:String):Null<String> {
		if (log.indexOf("Compiler failure") < 0)
			return null;
		return [for (l in log.split("\n")) if (!~/^\s*\|\s*(File "|Called from |Raised |Re-raised |$)/.match(l)) l].join("\n");
	}

	/** The first backtrace line of a reference compiler failure. **/
	static function failureSite(log:String):String {
		for (l in log.split("\n"))
			if (~/^\s*\|\s*(File "|Raised )/.match(l))
				return StringTools.trim(l.substr(l.indexOf("|") + 1));
		return firstLine(log);
	}

	static function crashed(code:Int):Bool
		return code == TIMEOUT || code >= 125 || code < 0;

	/** Runs one lane on the program written to `<work>/src`. **/
	public static function check(lane:Lane, work:String):Verdict {
		var a = runSide(lane.a, work, lane.run || lane.exec);
		var b = runSide(lane.b, work, lane.run || lane.exec);
		if (lane.exec)
			return compareExec(lane, a, b);
		if (crashed(a.code))
			return {kind: "invalid", detail: "reference exit " + a.code + ": " + firstLine(a.log)};
		if (crashed(b.code))
			return {kind: b.code == TIMEOUT ? "port-timeout" : "port-crash", detail: "exit " + b.code + ": " + lastLines(b.log)};
		if (a.code != 0 && b.code == 0)
			return {kind: "port-accepts", detail: "reference: " + firstLine(a.log)};
		if (a.code == 0 && b.code != 0)
			return {kind: "port-rejects", detail: firstLine(b.log)};
		if (a.code != 0) {
			var fa = failure(a.log), fb = failure(b.log);
			if (fa != null && fb != null && fa == fb)
				return {kind: "reference-failure", detail: failureSite(a.log)};
			if (a.log != b.log)
				return {kind: "diagnostics-differ", detail: firstDiff(a.log, b.log)};
			return {kind: "invalid", detail: firstLine(a.log)};
		}
		if (!sameOutput(a.log, b.log))
			return {kind: lane.a.target.output == "none" ? "output-differs" : "log-differs", detail: firstDiff(a.log, b.log)};
		var d = compareOutputs(lane.a.target.output, a.dir + "/out", b.dir + "/out");
		if (d != null)
			return {kind: "output-differs", detail: d};
		if (lane.run && lane.a.target.run != null) {
			if (a.runCode != b.runCode)
				return {kind: "run-differs", detail: "exit " + a.runCode + " vs " + b.runCode};
			if (!sameOutput(a.runLog, b.runLog))
				return {kind: "run-differs", detail: firstDiff(a.runLog, b.runLog)};
		}
		return {kind: "ok", detail: ""};
	}

	static function programOutput(side:Side, r:SideResult):String {
		var s = side.target.run == null ? r.log : r.runLog;
		// drop compiler warnings printed before the program starts
		var i = s.indexOf("start\n");
		return i < 0 ? s : s.substr(i);
	}

	static function compareExec(lane:Lane, a:SideResult, b:SideResult):Verdict {
		if (a.code != 0) {
			if (failure(a.log) != null)
				return {kind: "reference-failure", detail: failureSite(a.log)};
			return {kind: "invalid", detail: lane.a.label + " exit " + a.code + ": " + firstLine(a.log)};
		}
		if (b.code != 0)
			return {kind: crashed(b.code) ? "compile-crash" : "compile-fails", detail: lane.b.label + " exit " + b.code + ": " + lastLines(b.log)};
		var ra = lane.a.target.run == null ? 0 : a.runCode;
		var rb = lane.b.target.run == null ? 0 : b.runCode;
		var oa = programOutput(lane.a, a);
		var ob = programOutput(lane.b, b);
		if (ra != 0 && crashed(ra))
			return {kind: "invalid", detail: lane.a.label + " run exit " + ra};
		if (!sameOutput(oa, ob))
			return {kind: crashed(rb) ? "run-crash" : "run-differs", detail: firstDiff(oa, ob)};
		if (ra != rb)
			return {kind: "run-differs", detail: "exit " + ra + " vs " + rb};
		return {kind: "ok", detail: ""};
	}

	static function firstLine(s:String):String {
		for (l in s.split("\n"))
			if (StringTools.trim(l) != "")
				return l.length > 200 ? l.substr(0, 200) : l;
		return "";
	}

	static function lastLines(s:String):String {
		var ls = [for (l in s.split("\n")) if (StringTools.trim(l) != "") l];
		var r = ls.slice(ls.length > 3 ? ls.length - 3 : 0).join(" | ");
		return r.length > 300 ? r.substr(0, 300) : r;
	}

	/**
		An ulp from the math function, then up to about 2 more from one
		multiplication or division by a constant (the result's ulp can be
		half the operand's, relative to the value) and its rounding.
	**/
	static inline final MAX_ULPS = 4;

	static final FLOAT = ~/-?[0-9]+\.[0-9]+(e[+-]?[0-9]+)?/i;

	/**
		Program outputs compared, where printed floats may differ in the last
		places: the math functions (glibc's in the reference; in the port
		hxmc builds, hxmc's port of musl's, hxmc/std/hxmc/rt/LibM.hx) round
		some results an ulp apart (docs/plans/math.md), and the arithmetic
		after them can widen that: `100 * Math.sin(-2.5)` is 2 ulps apart
		(cases/interp-108625377). Two floats at the same place of a line match
		when at most `MAX_ULPS` apart (both finite, same sign); everything else
		must be identical.
	**/
	public static function sameOutput(a:String, b:String):Bool {
		if (a == b)
			return true;
		var la = a.split("\n"), lb = b.split("\n");
		if (la.length != lb.length)
			return false;
		for (i in 0...la.length)
			if (la[i] != lb[i] && !sameLine(la[i], lb[i]))
				return false;
		return true;
	}

	static function sameLine(x:String, y:String):Bool {
		while (true) {
			var mx = FLOAT.match(x), my = FLOAT.match(y);
			if (mx != my)
				return false;
			if (!mx)
				return x == y;
			FLOAT.match(x);
			var fx = FLOAT.matched(0), lx = FLOAT.matchedLeft(), rx = FLOAT.matchedRight();
			FLOAT.match(y);
			var fy = FLOAT.matched(0), ly = FLOAT.matchedLeft(), ry = FLOAT.matchedRight();
			if (lx != ly || !(fx == fy || ulps(Std.parseFloat(fx), Std.parseFloat(fy)) <= MAX_ULPS))
				return false;
			x = rx;
			y = ry;
		}
	}

	/** The distance in units in the last place between two finite floats of the same sign (large otherwise). **/
	static function ulps(a:Float, b:Float):Float {
		if (Math.isNaN(a) || Math.isNaN(b) || !Math.isFinite(a) || !Math.isFinite(b) || (a < 0) != (b < 0))
			return Math.POSITIVE_INFINITY;
		var d = haxe.io.FPHelper.doubleToI64(a) - haxe.io.FPHelper.doubleToI64(b);
		if (d < 0)
			d = -d;
		return d > MAX_ULPS ? MAX_ULPS + 1 : haxe.Int64.toInt(d);
	}

	static function firstDiff(a:String, b:String):String {
		var la = a.split("\n");
		var lb = b.split("\n");
		var n = la.length > lb.length ? la.length : lb.length;
		for (i in 0...n) {
			var x = i < la.length ? la[i] : "<eof>";
			var y = i < lb.length ? lb[i] : "<eof>";
			if (x != y)
				return "line " + (i + 1) + ": " + clip(x) + " <> " + clip(y) + " [" + region(x, y) + "]";
		}
		return "";
	}

	/** The differing middle of two lines (common prefix and suffix removed): what failures are grouped by. **/
	public static function region(x:String, y:String):String {
		var p = 0;
		while (p < x.length && p < y.length && x.charCodeAt(p) == y.charCodeAt(p))
			p++;
		var q = 0;
		while (q < x.length - p && q < y.length - p && x.charCodeAt(x.length - 1 - q) == y.charCodeAt(y.length - 1 - q))
			q++;
		function mid(s:String):String {
			var m = s.substr(p, s.length - p - q);
			return m.length > 40 ? m.substr(0, 40) + "..." : m;
		}
		return mid(x) + " <> " + mid(y);
	}

	static function clip(s:String):String
		return s.length > 120 ? s.substr(0, 120) + "..." : s;

	// ------------------------------------------------------------------
	// outputs

	/** Returns null when the outputs conform, otherwise a description of the first difference. **/
	public static function compareOutputs(spec:String, a:String, b:String):Null<String> {
		var colon = spec.indexOf(":");
		var kind = colon < 0 ? spec : spec.substr(0, colon);
		var path = colon < 0 ? "" : spec.substr(colon + 1);
		return switch kind {
			case "none": null;
			case "file": compareFiles(a + "/" + path, b + "/" + path, path);
			case "dir": compareDirs(listDir(a + "/" + path), listDir(b + "/" + path));
			case "zip": compareMaps(readZip(a + "/" + path), readZip(b + "/" + path), _ -> true);
			case "hxb": compareMaps(readZip(a + "/" + path), readZip(b + "/" + path), n -> StringTools.endsWith(n, ".hxb"));
			default: "unknown output kind " + kind;
		}
	}

	static function compareFiles(a:String, b:String, name:String):Null<String> {
		var ea = FileSystem.exists(a), eb = FileSystem.exists(b);
		if (!ea || !eb)
			return ea == eb ? null : name + " missing on " + (ea ? "port" : "reference") + " side";
		return compareBytes(name, File.getBytes(a), File.getBytes(b));
	}

	static function compareBytes(name:String, x:Bytes, y:Bytes):Null<String> {
		if (x.compare(y) == 0)
			return null;
		var n = x.length < y.length ? x.length : y.length;
		var i = 0;
		var line = 1;
		while (i < n && x.get(i) == y.get(i)) {
			if (x.get(i) == 10)
				line++;
			i++;
		}
		var detail = name + " differs at byte " + i + " (line " + line + "), sizes " + x.length + " vs " + y.length;
		if (!StringTools.endsWith(name, ".hxb") && i < n) {
			// text output: show the differing lines
			function lineAt(b:Bytes):String {
				var s = i, e = i;
				while (s > 0 && b.get(s - 1) != 10)
					s--;
				while (e < b.length && b.get(e) != 10)
					e++;
				return b.getString(s, e - s);
			}
			var a = lineAt(x), c = lineAt(y);
			detail += ": " + clip(a) + " <> " + clip(c) + " [" + region(a, c) + "]";
		}
		return detail;
	}

	// hl/c: the digest names that depend on the reference's machine code are
	// renamed on both sides first (haxe/test/HlcNames.hx)
	static function compareDirs(a:Map<String, Bytes>, b:Map<String, Bytes>):Null<String> {
		if (HlcNames.isHlc([for (k in a.keys()) k])) {
			var n = HlcNames.normalize(a, b);
			a = n.a;
			b = n.b;
		}
		return compareMaps(a, b, _ -> true);
	}

	static function compareMaps(a:Map<String, Bytes>, b:Map<String, Bytes>, compared:String->Bool):Null<String> {
		var onlyA = [for (k in a.keys()) if (!b.exists(k)) k];
		var onlyB = [for (k in b.keys()) if (!a.exists(k)) k];
		if (onlyA.length > 0 || onlyB.length > 0) {
			onlyA.sort(Reflect.compare);
			onlyB.sort(Reflect.compare);
			return "member set differs: reference-only " + onlyA.slice(0, 3) + ", port-only " + onlyB.slice(0, 3);
		}
		var keys = [for (k in a.keys()) k];
		keys.sort(Reflect.compare);
		var diffs = [];
		for (k in keys)
			if (compared(k)) {
				var d = compareBytes(k, a.get(k), b.get(k));
				if (d != null)
					diffs.push(d);
			}
		if (diffs.length == 0)
			return null;
		return diffs.length + "/" + keys.length + " differ: " + diffs.slice(0, 3).join("; ");
	}

	static function listDir(dir:String):Map<String, Bytes> {
		var m = new Map<String, Bytes>();
		function walk(d:String, prefix:String) {
			if (!FileSystem.exists(d))
				return;
			for (f in FileSystem.readDirectory(d)) {
				var p = d + "/" + f;
				if (FileSystem.isDirectory(p))
					walk(p, prefix + f + "/");
				else
					m.set(prefix + f, File.getBytes(p));
			}
		}
		walk(dir, "");
		return m;
	}

	static function inflateRaw(b:Bytes):Bytes {
		var z = new haxe.zip.InflateImpl(new haxe.io.BytesInput(b), false, false);
		var out = new haxe.io.BytesBuffer();
		var tmp = Bytes.alloc(65536);
		while (true) {
			var n = z.readBytes(tmp, 0, tmp.length);
			out.addBytes(tmp, 0, n);
			if (n < tmp.length)
				break;
		}
		return out.getBytes();
	}

	/**
		Uncompressed members of a ZIP archive, read through the central directory
		(local headers may defer their sizes to data descriptors). An unreadable
		archive yields a single `<unreadable ...>` member.
	**/
	public static function readZip(path:String):Map<String, Bytes> {
		var m = new Map<String, Bytes>();
		if (!FileSystem.exists(path))
			return m;
		try {
			var z = File.getBytes(path);
			// end of central directory record: signature 0x06054b50, searched backwards past a comment
			var eocd = z.length - 22;
			while (eocd >= 0 && z.getInt32(eocd) != 0x06054b50)
				eocd--;
			if (eocd < 0)
				throw "no end of central directory";
			var count = z.getUInt16(eocd + 10);
			var p = z.getInt32(eocd + 16);
			for (_ in 0...count) {
				if (z.getInt32(p) != 0x02014b50)
					throw "bad central directory entry";
				var method = z.getUInt16(p + 10);
				var csize = z.getInt32(p + 20);
				var nameLen = z.getUInt16(p + 28);
				var extraLen = z.getUInt16(p + 30);
				var commentLen = z.getUInt16(p + 32);
				var local = z.getInt32(p + 42);
				var name = z.getString(p + 46, nameLen);
				p += 46 + nameLen + extraLen + commentLen;
				var dataStart = local + 30 + z.getUInt16(local + 26) + z.getUInt16(local + 28);
				var raw = z.sub(dataStart, csize);
				var data = switch method {
					case 0: raw;
					case 8: inflateRaw(raw);
					default: throw "compression method " + method;
				}
				m.set(name, data);
			}
		} catch (e:Dynamic) {
			m = new Map();
			m.set("<unreadable: " + Std.string(e) + ">", Bytes.alloc(0));
		}
		return m;
	}
}
