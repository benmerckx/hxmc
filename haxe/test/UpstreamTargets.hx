import Harness.*;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import sys.FileSystem;
import sys.io.File;

using StringTools;

// Upstream's target suites compiled by the reference and by the port, the
// outputs compared file by file (the programs are not run):
//   <haxe> -cp haxe/test --run UpstreamTargets [-j N] [--summary <file>] [name ...]
// Each line of SUITES is an upstream hxml (under haxe/upstream/tests) with
// the extra arguments it needs here; nothing in the submodule is edited.
// Both compilers run it in turn from its own directory with `-D
// disable-parallelism` (the reference allocates ids from counters shared by
// parallel workers otherwise); after each run its output directory (`bin/`)
// is moved to bin/test/upstream-targets/<name>/<side>/, so the submodule is
// left as it was (checked at the end). Every file of the two trees must exist
// on both sides and be identical: ZIP members (jars) by name and uncompressed
// bytes, SWF bodies inflated. Known time-dependent bytes are normalized:
// unit.TestMainNow embeds the compilation date (`Std.string(Date.now())`), so
// such a string is replaced by a placeholder when it parses to a time within
// the window the two compilers ran in, with the forms the generators derive
// from it (hxcpp's HX_ literal hash, the hl/c constant name).
// Libraries come from lix at upstream's pins (runci installs the default
// branches; pinned here): a scope in bin/test/upstream-libs, whose haxelib
// shim (bin/lix/haxelib on PATH, HAXESHIM_SCOPE) answers both compilers. A
// suite whose requirement cannot be met is reported as SKIP with the reason.
// The compiler-side suites (macro, display, server, sys on Eval) run in
// upstream's own RunCi (upstream-tests.yml).
class UpstreamTargets {
	static final OUT = "bin/test/upstream-targets";
	static final TIMEOUT = 3600;
	// name, hxml (under haxe/upstream/tests), extra arguments, requirement
	static final SUITES:Array<Suite> = [
		{name: "js", hxml: "unit/compile-js.hxml", extra: []},
		{name: "lua", hxml: "unit/compile-lua.hxml", extra: []},
		{name: "python", hxml: "unit/compile-python.hxml", extra: []},
		{name: "php", hxml: "unit/compile-php.hxml", extra: []},
		{name: "neko", hxml: "unit/compile-neko.hxml", extra: []},
		{name: "hl", hxml: "unit/compile-hl.hxml", extra: []},
		// hlgen.makefile=ci only writes a Makefile: generate the sources only
		{name: "hlc", hxml: "unit/compile-hlc.hxml", extra: ["-D", "no-compilation"]},
		// compiling the sources is hxcpp's job, not the compiler's
		{name: "cpp", hxml: "unit/compile-cpp.hxml", extra: ["-D", "no-compilation"], requires: "hxcpp"},
		{name: "cppia", hxml: "unit/compile-cppia.hxml", extra: []},
		{name: "cppia-host", hxml: "unit/compile-cppia-host.hxml", extra: ["-D", "no-compilation"], requires: "hxcpp"},
		// compile-jvm.hxml is compile-java-native.hxml (native.jar, built once with hxjava) then this
		{name: "jvm", hxml: "unit/compile-jvm-only.hxml", extra: [], requires: "native.jar"},
		// compile-flash.hxml also builds native_swf/lib.swc with the Flex SDK's compc
		{name: "flash", hxml: "unit/compile-flash-no-swc.hxml", extra: []},
	];
	// lix libraries: name, repository, commit
	static final LIBS = [
		{name: "utest", repo: "haxe-utest/utest", commit: "a055e05e2e872ae12a32b53d0200612345059c38"},
		{name: "hxcpp", repo: "HaxeFoundation/hxcpp", commit: "e638733340fcf4589595da07898436146ee413ff"},
		{name: "hxjava", repo: "HaxeFoundation/hxjava", commit: "f8c7dc6c56f4bf8f5912b4844a1b55ab094ee0cf"},
	];

	static var gen:String;
	public static var libsOk = new Map<String, String>(); // name -> "" or why not

	// (also UpstreamSuites': the scope bin/test/upstream-libs)
	public static function installLibs(names:Array<String>, ?scope:String) {
		if (scope == null) scope = '$gen/../upstream-libs';
		mkdirs(scope);
		scope = FileSystem.fullPath(scope);
		var lix = FileSystem.fullPath("bin/lix/lix");
		var env:Map<String, Null<String>> = ["HAXESHIM_ROOT" => scope + "/lix-root"];
		if (!FileSystem.exists(scope + "/.haxerc")) exec([lix, "scope", "create"], {cwd: scope, env: env});
		for (l in LIBS) {
			if (!names.contains(l.name)) continue;
			if (FileSystem.exists('$scope/haxe_libraries/${l.name}.hxml')) {
				libsOk[l.name] = "";
				continue;
			}
			var r = exec([lix, "install", 'https://github.com/${l.repo}/archive/${l.commit}.tar.gz', "as", l.name], {cwd: scope, env: env, merge: true});
			if (r.code != 0) {
				// (a git checkout where the archive cannot be downloaded)
				var dir = '$scope/src/${l.name}';
				rmrf(dir);
				mkdirs(dir);
				var g = exec(["sh", "-c", 'git init -q && git fetch -q --depth 1 https://github.com/${l.repo}.git ${l.commit} && git checkout -q FETCH_HEAD'], {cwd: dir, merge: true});
				r = g.code == 0 ? exec([lix, "dev", l.name, dir], {cwd: scope, env: env, merge: true}) : g;
			}
			libsOk[l.name] = r.code == 0 ? "" : 'lix could not install ${l.name}: ' + tail(r.out.trim(), 200);
		}
		Sys.putEnv("HAXESHIM_ROOT", scope + "/lix-root");
		Sys.putEnv("HAXESHIM_SCOPE", scope);
		Sys.putEnv("PATH", FileSystem.fullPath("bin/lix") + ":" + Sys.getEnv("PATH"));
	}

	static function requirement(s:Suite, unit:String):Null<String> {
		var needs = ["utest"];
		if (s.requires == "hxcpp") needs.push("hxcpp");
		for (n in needs) if (libsOk[n] != "") return libsOk[n] ?? 'no $n';
		if (s.requires == "native.jar") {
			if (libsOk["hxjava"] != "") return libsOk["hxjava"];
			// compile-java-native.hxml: `haxelib run hxjava native_java/hxjava_build.txt --out native_java/native`
			var r = exec(["haxelib", "run", "hxjava", "native_java/hxjava_build.txt", "--out", "native_java/native"], {cwd: unit, merge: true, log: '$gen/native-jar.log'});
			if (r.code != 0 || !FileSystem.exists('$unit/native_java/native.jar')) return 'building native_java/native.jar failed (exit ${r.code}, $OUT/native-jar.log)';
		}
		return null;
	}

	static function main() {
		var o = parseArgs(Sys.args(), ["-j", "--summary"]);
		var reference = FileSystem.fullPath(Sys.getEnv("HAXE_REFERENCE") ?? "bin/reference/haxe");
		var port = shellSplit(Sys.getEnv("HAXE_IN_HAXE_PORT") ?? "bin/port/haxe");
		if (FileSystem.exists(port[0])) port[0] = FileSystem.fullPath(port[0]);
		var std = root + "/haxe/upstream/std";
		Sys.putEnv("HAXE_STD_PATH", std);
		Sys.putEnv("HAXE_IN_HAXE_STD_PATH", std);
		var suites = [for (s in SUITES) if (o.rest.length == 0 || o.rest.contains(s.name)) s];
		rmrf(OUT);
		mkdirs(OUT);
		gen = FileSystem.fullPath(OUT);
		installLibs(["utest"].concat(Lambda.exists(suites, s -> s.requires == "hxcpp") ? ["hxcpp"] : []).concat(Lambda.exists(suites, s -> s.requires == "native.jar") ? ["hxjava"] : []));
		var tests = root + "/haxe/upstream/tests";
		var before = exec(["git", "-C", "haxe/upstream", "status", "--porcelain", "--ignored"]).out;
		var skipped = new Map<String, String>();
		var jobs = [];
		for (s in suites) {
			var dir = haxe.io.Path.directory('$tests/${s.hxml}');
			var why = requirement(s, dir);
			if (why != null) skipped[s.name] = why else jobs.push(s);
		}
		// the suites of one directory share its bin/: one at a time
		var results = new Map<String, Array<{side:String, r:Harness.ExecResult, start:Float, end:Float}>>();
		for (s in jobs) {
			var dir = haxe.io.Path.directory('$tests/${s.hxml}');
			var file = haxe.io.Path.withoutDirectory(s.hxml);
			var runs = [];
			for (side in ["reference", "port"]) {
				var cmd = (side == "reference" ? [reference] : port).concat(["-D", "disable-parallelism"]).concat(s.extra).concat([file]);
				var start = Sys.time();
				var r = exec(cmd, {cwd: dir, timeout: TIMEOUT, log: '$gen/${s.name}-$side.log'});
				var end = Sys.time();
				var out = '$gen/${s.name}/$side';
				mkdirs(haxe.io.Path.directory(out));
				if (FileSystem.exists('$dir/bin')) FileSystem.rename('$dir/bin', out) else mkdirs(out);
				runs.push({side: side, r: r, start: start, end: end});
				Sys.println('  ${pad(s.name, 13)} ${pad(side, 9)} exit ${r.timedOut ? "timeout" : Std.string(r.code)} ${fixed(r.seconds).lpad(" ", 7)}s');
			}
			results[s.name] = runs;
		}
		// what the requirements wrote into the submodule (hxjava: native_java/native.jar, cmd, obj)
		for (l in exec(["git", "-C", "haxe/upstream", "status", "--porcelain", "--ignored"]).out.split("\n"))
			if (l.length > 3 && !before.contains(l) && l.substr(3).startsWith("tests/unit/native_java/")) rmrf("haxe/upstream/" + l.substr(3));
		var passed = [], failed = [], lines = [];
		Sys.println("");
		for (s in suites) {
			var line;
			if (skipped.exists(s.name)) {
				line = 'SKIP  ${pad(s.name, 13)} ${skipped[s.name]}';
			} else {
				var runs = results[s.name];
				var ref = runs[0], got = runs[1];
				if (ref.r.code != 0) {
					failed.push(s.name);
					line = 'FAIL  ${pad(s.name, 13)} reference exit ${ref.r.code} ($OUT/${s.name}-reference.log)\n' + lastLines('$gen/${s.name}-reference.log');
				} else if (got.r.code != 0) {
					failed.push(s.name);
					line = 'FAIL  ${pad(s.name, 13)} port exit ${got.r.code} ($OUT/${s.name}-port.log)\n' + lastLines('$gen/${s.name}-port.log');
				} else {
					var window = {from: Math.min(ref.start, got.start), to: Math.max(ref.end, got.end)};
					var d = compareTrees('$gen/${s.name}/reference', '$gen/${s.name}/port', window);
					if (d != null) {
						failed.push(s.name);
						line = 'FAIL  ${pad(s.name, 13)} $d';
					} else {
						passed.push(s.name);
						line = 'PASS  ${pad(s.name, 13)} ${walk('$gen/${s.name}/reference').length} files identical' + (renamedNames > 0 ? ' ($renamedNames hl/c digest names renamed)' : '');
					}
				}
			}
			Sys.println(line);
			lines.push(line);
		}
		var after = exec(["git", "-C", "haxe/upstream", "status", "--porcelain", "--ignored"]).out;
		if (after != before) {
			failed.push("submodule");
			var l = "FAIL  the submodule changed:\n" + after;
			Sys.println(l);
			lines.push(l);
		}
		var total = 'upstream targets: ${passed.length} passed, ${failed.length} failed, ${[for (k in skipped.keys()) k].length} skipped' + (failed.length > 0 ? ' (failed: ${failed.join(" ")})' : "");
		Sys.println("\n" + total);
		summary(o.get("--summary"), '### upstream target suites (reference and port outputs)\n\n$total\n\n```\n${lines.join("\n")}\n```\n\n');
		Sys.exit(failed.length > 0 ? 1 : 0);
	}

	static function lastLines(log:String, n = 6):String {
		var lines = [for (l in readText(log).split("\n")) if (l.trim() != "") "    " + l.substr(0, 200)];
		return lines.slice(lines.length > n ? lines.length - n : 0).join("\n");
	}

	static function isZip(p:String) return p.endsWith(".jar") || p.endsWith(".zip");

	// the hl/c digest names the last compareTrees renamed (HlcNames)
	static var renamedNames = 0;

	static function compareTrees(a:String, b:String, window:{from:Float, to:Float}):Null<String> {
		var fa = walk(a), fb = walk(b);
		renamedNames = 0;
		if (fa.length == 0) return "reference wrote no files";
		// hl/c: the digest names that depend on the reference's machine code are
		// renamed on both sides first (HlcNames)
		var hlc:Null<{a:Map<String, Bytes>, b:Map<String, Bytes>, renamed:Int}> = null;
		if (HlcNames.isHlc(fa)) {
			hlc = HlcNames.normalize([for (f in fa) f => File.getBytes('$a/$f')], [for (f in fb) f => File.getBytes('$b/$f')]);
			fa = [for (f in hlc.a.keys()) f];
			fb = [for (f in hlc.b.keys()) f];
			fa.sort(compare);
			fb.sort(compare);
			renamedNames = hlc.renamed;
		}
		if (fa.join("\n") != fb.join("\n")) {
			var onlyA = [for (f in fa) if (!fb.contains(f)) f], onlyB = [for (f in fb) if (!fa.contains(f)) f];
			return 'file set differs (reference-only ${onlyA.length} ${onlyA.slice(0, 3)}, port-only ${onlyB.length} ${onlyB.slice(0, 3)})';
		}
		var differing = [], first = null, members = 0;
		for (name in fa) {
			var x = hlc != null ? hlc.a[name] : File.getBytes('$a/$name'), y = hlc != null ? hlc.b[name] : File.getBytes('$b/$name');
			if (isZip(name)) {
				var za, zb;
				try {
					za = readZip('$a/$name');
					zb = readZip('$b/$name');
				} catch (e:Dynamic) {
					differing.push(name);
					if (first == null) first = '$name: unreadable archive: $e';
					continue;
				}
				var na = za.names.copy(), nb = zb.names.copy();
				na.sort(compare);
				nb.sort(compare);
				if (na.join("\n") != nb.join("\n")) {
					differing.push(name);
					if (first == null) first = '$name: member set differs';
					continue;
				}
				for (m in na) {
					members++;
					var p = normalize(m, za.data[m], window), q = normalize(m, zb.data[m], window);
					if (p.compare(q) != 0) {
						differing.push(name + "!" + m);
						if (first == null) first = '$name!$m: ' + describe(p, q);
					}
				}
				continue;
			}
			if (x.compare(y) != 0) {
				var p = normalize(name, x, window), q = normalize(name, y, window);
				if (p.compare(q) != 0) {
					differing.push(name);
					if (first == null) first = '$name: ' + describe(p, q);
				}
			}
		}
		if (differing.length > 0) return '${differing.length}/${fa.length + members} files differ: ${differing.slice(0, 4).join(" ")}\n  first: $first';
		return null;
	}

	static function describe(a:Bytes, b:Bytes):String {
		var i = firstDiff(a, b);
		var lo = i > 40 ? i - 40 : 0;
		function around(x:Bytes) return haxe.Json.stringify(x.getString(lo, (i + 40 < x.length ? i + 40 : x.length) - lo, RawNative));
		return 'sizes ${a.length}/${b.length}, first difference at byte $i\n    reference ${around(a)}\n    port      ${around(b)}';
	}

	static final PLACEHOLDER = "YYYY-MM-DD HH:MM:SS";

	static function isDigit(c:Int) return c >= "0".code && c <= "9".code;

	// the date as Std.string(Date) prints it, or with every separator as `_`
	static function dateAt(d:Bytes, i:Int):Null<String> {
		if (i + 19 > d.length) return null;
		var sep = d.get(i + 4);
		if (sep != "-".code && sep != "_".code) return null;
		for (k in [0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18]) if (!isDigit(d.get(i + k))) return null;
		if (d.get(i + 7) != sep) return null;
		var sp = d.get(i + 10), c1 = d.get(i + 13), c2 = d.get(i + 16);
		if (sp != " ".code && sp != "_".code) return null;
		if (c1 != ":".code && c1 != "_".code) return null;
		if (c2 != ":".code && c2 != "_".code) return null;
		var s = d.getString(i, 19);
		return s.substr(0, 4) + "-" + s.substr(5, 2) + "-" + s.substr(8, 2) + " " + s.substr(11, 2) + ":" + s.substr(14, 2) + ":" + s.substr(17, 2);
	}

	static function replaceAll(d:Bytes, from:String, to:String):Bytes {
		var f = Bytes.ofString(from), t = Bytes.ofString(to);
		var out = new BytesBuffer(), i = 0, last = 0;
		while (i + f.length <= d.length) {
			if (d.get(i) == f.get(0) && d.sub(i, f.length).compare(f) == 0) {
				out.addBytes(d, last, i - last);
				out.add(t);
				i += f.length;
				last = i;
			} else
				i++;
		}
		out.addBytes(d, last, d.length - last);
		return out.getBytes();
	}

	// hxcpp's HX_("<date>",xx,xx,xx,xx) literal: its hash too
	static function replaceHx(d:Bytes, date:String):Bytes {
		var head = Bytes.ofString('HX_("$date"');
		var out = new BytesBuffer(), i = 0, last = 0;
		while (i + head.length + 13 <= d.length) {
			if (d.get(i) == "H".code && d.sub(i, head.length).compare(head) == 0) {
				var j = i + head.length, ok = true;
				for (_ in 0...4) {
					if (d.get(j) != ",".code || !isHex(d.get(j + 1)) || !isHex(d.get(j + 2))) ok = false;
					j += 3;
				}
				if (ok && d.get(j) == ")".code) {
					out.addBytes(d, last, i - last);
					out.addString('HX_("$PLACEHOLDER",hh,hh,hh,hh)');
					i = j + 1;
					last = i;
					continue;
				}
			}
			i++;
		}
		out.addBytes(d, last, d.length - last);
		return out.getBytes();
	}

	static function isHex(c:Int) return isDigit(c) || (c >= "a".code && c <= "f".code);

	static function normalize(path:String, d:Bytes, window:{from:Float, to:Float}):Bytes {
		if (path.endsWith(".swf") && d.length > 8 && d.getString(0, 3) == "CWS") {
			// the dates sit in the compressed body: compare the inflated body (with an
			// FWS header); the deflate output itself is the fuzzer's diff:swf lane's
			var body = haxe.zip.Uncompress.run(d.sub(8, d.length - 8));
			var b = new BytesBuffer();
			b.addString("FWS");
			b.addBytes(d, 3, 5);
			b.add(body);
			d = b.getBytes();
		}
		var dates = [];
		for (i in 0...(d.length - 18 > 0 ? d.length - 18 : 0)) {
			if (!isDigit(d.get(i))) continue;
			var s = dateAt(d, i);
			if (s == null || dates.contains(s)) continue;
			var t = try Date.fromString(s).getTime() / 1000 catch (_:Dynamic) -1.0;
			if (t >= window.from - 1 && t <= window.to + 1) dates.push(s);
		}
		for (s in dates) {
			d = replaceHx(d, s);
			d = replaceAll(d, ~/[- :]/g.replace(s, "_"), ~/[- :]/g.replace(PLACEHOLDER, "_"));
			d = replaceAll(d, s, PLACEHOLDER);
		}
		return d;
	}
}

typedef Suite = {name:String, hxml:String, extra:Array<String>, ?requires:String}
