import Harness.*;
import sys.FileSystem;
import sys.io.File;

using StringTools;

// Upstream tests/unit built with -D esm (Genesm) and run under node (lane `unit` of make esm):
//   bin/hxmc/hxmc -cp hxmc/test -cp haxe/test --run EsmSuites [--haxe <compiler>] [--summary <file>]
// Needs the npm-style compiler (HaxeMain + Genesm): build or use
//   bin/npm/native/$(HOST)/haxe  (make npm natives)
// Logs: bin/test/esm-upstream/unit/
class EsmSuites {
	static final OUT = "bin/test/esm-upstream";
	static final TIMEOUT = 3600.;

	static function main() {
		var o = parseArgs(Sys.args(), ["--haxe", "--summary"]);
		var haxe = FileSystem.fullPath(o.opts["--haxe"] ?? hostHaxe());
		if (!FileSystem.exists(haxe)) fail("compiler not found: $haxe (make npm natives or pass --haxe)");
		Sys.putEnv("HAXE_STD_PATH", root + "/haxe/upstream/std");
		UpstreamTargets.installLibs(["utest"], "bin/test/upstream-libs");
		if (UpstreamTargets.libsOk["utest"] != "") fail(UpstreamTargets.libsOk["utest"]);
		var skips = EsmSkips.read("hxmc/test/esm/exclusions.txt");
		var r = runUnit(haxe, skips);
		var lines = [
			"upstream unit on Genesm (-D esm)",
			"",
			"| passed | failed | skipped | result |",
			"| --- | --- | --- | --- |",
			'| ${r.passed} | ${r.failed} | ${r.skipped} | ${r.result} |'
		];
		var text = lines.join("\n") + "\n";
		Sys.println(text);
		summary(o.opts["--summary"], text);
		Sys.exit(r.ok ? 0 : 1);
	}

	static function runUnit(haxe:String, skips:EsmSkips):{ok:Bool, passed:Int, failed:Int, skipped:Int, result:String} {
		var dir = '$OUT/unit';
		rmrf(dir);
		mkdirs(dir);
		var src = 'haxe/upstream/tests/unit';
		for (n in FileSystem.readDirectory(src))
			if (n != "bin" && n != "export") copyTree('$src/$n', '$dir/$n');
		dir = FileSystem.fullPath(dir);
		var patch = 'hxmc/test/upstream/unit.patch';
		if (FileSystem.exists(patch)) {
			var p = exec(["patch", "-p1", "--no-backup-if-mismatch", "-d", dir, "-i", FileSystem.fullPath(patch)], {merge: true});
			if (p.code != 0) return {ok: false, passed: 0, failed: 0, skipped: skips.count, result: "patch failed"};
		}
		for (s in skips.tests) {
			var rel = "src/" + s.className.replace(".", "/") + ".hx";
			if (s.method == null && FileSystem.exists('$dir/$rel')) FileSystem.deleteFile('$dir/$rel');
		}
		var patterns = skips.utestPatterns();
		// Js + -D esm: upstream std via HAXE_STD_PATH; hxmc/std/esm from HaxeMain when -D esm.
		var args = [haxe];
		if (patterns != "") args = args.concat(["-D", "UTEST_PATTERN=" + patterns]);
		args.push(FileSystem.fullPath("hxmc/test/upstream/unit-esm.hxml"));
		Sys.println("unit (esm): building");
		var b = exec(args, {cwd: dir, merge: true, log: '$dir/build.log'});
		if (b.code != 0) {
			Sys.println(tail(readText('$dir/build.log'), 4000));
			return {ok: false, passed: 0, failed: 0, skipped: skips.count, result: "build failed"};
		}
		Sys.println("unit (esm): running");
		var x = exec([Sys.getEnv("NODE") ?? "node", "bin/unit/main.mjs"], {cwd: dir, merge: true, log: '$dir/run.log', timeout: TIMEOUT});
		var out = readText('$dir/run.log');
		var res = UpstreamSuites.parse(out);
		var failed = res.failed.length;
		if (res.ran == 0) {
			Sys.println(tail(out, 2000));
			return {ok: false, passed: 0, failed: failed > 0 ? failed : 1, skipped: skips.count, result: "no tests ran"};
		}
		if (!res.complete) {
			failed++;
			Sys.println(tail(out, 2000));
			return {ok: false, passed: res.ran - failed, failed: failed, skipped: skips.count, result: "crash"};
		}
		for (f in res.failed) Sys.println('  FAIL ${f.name}: ${f.detail}');
		if (failed > 0) return {ok: false, passed: res.ran - failed, failed: failed, skipped: skips.count, result: '$failed failed'};
		return {ok: true, passed: res.ran, failed: 0, skipped: skips.count, result: "ok"};
	}
}

@:structInit
class EsmSkips {
	public var tests:Array<{className:String, method:Null<String>, reason:String}> = [];
	public var count = 0;

	public function new() {}

	public static function read(path:String):EsmSkips {
		var s = new EsmSkips();
		if (!FileSystem.exists(path)) return s;
		for (line in File.getContent(path).split("\n")) {
			line = StringTools.trim(line);
			if (line == "" || StringTools.startsWith(line, "#")) continue;
			var sp = line.indexOf(" ");
			var pat = sp < 0 ? line : StringTools.trim(line.substr(0, sp));
			var reason = sp < 0 ? "" : StringTools.trim(line.substr(sp + 1));
			var parts = pat.split(".");
			var method:Null<String> = null;
			var cls = pat;
			if (parts.length > 1) {
				var last = parts[parts.length - 1];
				if (last != "" && last.charAt(0) == last.toLowerCase().charAt(0)) {
					method = last;
					cls = parts.slice(0, -1).join(".");
				}
			}
			s.tests.push({className: cls, method: method, reason: reason});
			s.count++;
		}
		return s;
	}

	public function utestPatterns():String {
		var patterns = [];
		for (t in tests)
			if (t.method == null)
				patterns.push(EReg.escape(t.className) + "\\.\\w+");
			else
				patterns.push(EReg.escape(t.className + "." + t.method));
		return patterns.length == 0 ? "" : "^(?!(?:" + patterns.join("|") + ")$)[\\w.]*\\.(?:test|spec)\\w*$";
	}
}