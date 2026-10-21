import Harness.*;
import sys.FileSystem;
import sys.io.File;

using StringTools;

// Upstream Haxe's runtime suites (haxe/upstream/tests: unit, sys, threads)
// built by hxmc and run, natively or as wasm32-wasi modules under node:
//   bin/hxmc/hxmc -cp hxmc/test -cp haxe/test --run UpstreamSuites [--target wasm32-wasi] [--summary <file>] [suite ...]
// Each suite is copied to bin/test/upstream-suites/<target>/<suite> (the
// submodule is never written), then
//   - hxmc/test/upstream/<suite>.patch, when there is one, is applied to the
//     copy (`patch -p1`): the conditionals that name the targets alike
//     (`#if (hl || cpp)`) given hxmc's branch, and the paths of the programs
//     the sys tests start; the reason of each file's change is in the
//     patch's header;
//   - the tests of hxmc/test/upstream/skips.txt are left out: a whole class
//     whose file the suite finds by its directory (unit's issues and
//     teststd, threads' cases) is removed from the copy, every
//     other entry is left out by utest's UTEST_PATTERN;
//   - hxmc/test/upstream/<suite>[-wasm].hxml is built in the copy by the tool
//     (`-cp bin/hxmc/std`, the target's std; the hxml names the output) with
//     utest from lix at UpstreamTargets' pin, and the program runs there
//     (sys: with EXISTS=1, as upstream's CI).
// utest announces each test (-D UTEST_PRINT_TESTS) and lists the failed ones
// in its report; a test announced and not listed passed. A suite fails when a
// test fails, when its build fails, or when the program ends before its report
// (a crash: the last test announced). The summary is the passed, failed and
// skipped tests (by category) of each suite.
class UpstreamSuites {
	static final OUT = "bin/test/upstream-suites";
	static final TIMEOUT = 1800.;
	static final SUITES = ["unit", "sys", "threads"];
	// the directories whose classes a suite finds itself (a class there can be removed)
	static final FOUND = [
		"unit" => ["src/unit/issues", "src/unit/teststd", "src/unit/hxcpp_issues"],
		"sys" => [],
		"threads" => ["src/cases"]
	];

	static function main() {
		var o = parseArgs(Sys.args(), ["--target", "--summary"]);
		var target = o.opts["--target"] ?? "native";
		var wasm = target.startsWith("wasm");
		var suites = o.rest.length > 0 ? o.rest : SUITES;
		for (s in suites)
			if (!SUITES.contains(s)) fail('unknown suite $s (${SUITES.join(", ")})');
		var tool = FileSystem.fullPath("bin/hxmc/hxmc");
		var std = FileSystem.fullPath("bin/hxmc/std");
		Sys.putEnv("HAXE_STD_PATH", root + "/haxe/upstream/std");
		if (Sys.getEnv("HXMC_RT_DIR") == null) Sys.putEnv("HXMC_RT_DIR", root + "/bin/hxmc/rt");
		UpstreamTargets.installLibs(["utest"], "bin/test/upstream-libs");
		if (UpstreamTargets.libsOk["utest"] != "") fail(UpstreamTargets.libsOk["utest"]);
		var skips = Skips.read("hxmc/test/upstream/skips.txt");
		var rows = [];
		var ok = true;
		for (suite in suites) {
			var r = run(suite, target, wasm, tool, std, skips);
			rows.push(r);
			if (!r.ok) ok = false;
		}
		var lines = ['upstream suites on hxmc ($target)', "", "| suite | passed | failed | skipped: BUG | TARGET | EXTERNAL | result |", "| --- | --- | --- | --- | --- | --- | --- |"];
		for (r in rows)
			lines.push('| ${r.suite} | ${r.passed} | ${r.failed} | ${r.skipped["BUG"]} | ${r.skipped["TARGET"]} | ${r.skipped["EXTERNAL"]} | ${r.result} |');
		var text = lines.join("\n") + "\n";
		Sys.println("\n" + text);
		summary(o.opts["--summary"], "\n" + text);
		Sys.exit(ok ? 0 : 1);
	}

	static function run(suite:String, target:String, wasm:Bool, tool:String, std:String, skips:Skips) {
		var tag = wasm ? "wasm" : "native";
		var dir = '$OUT/$tag/$suite';
		rmrf(dir);
		mkdirs(dir);
		var src = 'haxe/upstream/tests/$suite';
		for (n in FileSystem.readDirectory(src))
			if (n != "bin" && n != "export") copyTree('$src/$n', '$dir/$n');
		dir = FileSystem.fullPath(dir);
		var r = {
			suite: suite,
			passed: 0,
			failed: 0,
			skipped: ["BUG" => 0, "TARGET" => 0, "EXTERNAL" => 0],
			result: "",
			ok: true
		};
		function failWith(why:String) {
			r.ok = false;
			r.result = why;
			return r;
		}
		var patch = 'hxmc/test/upstream/$suite.patch';
		if (FileSystem.exists(patch)) {
			var p = exec(["patch", "-p1", "--no-backup-if-mismatch", "-d", dir, "-i", FileSystem.fullPath(patch)], {merge: true});
			if (p.code != 0) {
				Sys.println(p.out);
				return failWith('$patch does not apply');
			}
		}
		// the skips: classes removed, tests left out by pattern
		var mine = skips.of(suite, tag);
		var patterns = [];
		for (s in mine) {
			r.skipped[s.category]++;
			// (every suite's class path is src)
			var rel = "src/" + s.test.replace(".", "/") + ".hx";
			var removed = s.method == null && FileSystem.exists('$dir/$rel') && Lambda.exists(FOUND[suite], d -> rel.startsWith(d + "/"));
			if (removed) FileSystem.deleteFile('$dir/$rel');
			if (!removed) patterns.push(EReg.escape(s.test) + (s.method == null ? "\\.\\w+" : "\\." + EReg.escape(s.method)));
		}
		var args = [tool, "-cp", std];
		if (patterns.length > 0) args = args.concat(["-D", "UTEST_PATTERN=^(?!(?:" + patterns.join("|") + ")$)[\\w.]*\\.(?:test|spec)\\w*$"]);
		args.push(FileSystem.fullPath('hxmc/test/upstream/$suite${wasm ? "-wasm" : ""}.hxml'));
		Sys.println('$suite ($tag): building');
		var b = exec(args, {cwd: dir, merge: true, log: '$dir/build.log'});
		if (b.code != 0) {
			Sys.println(tail(readText('$dir/build.log'), 4000));
			return failWith("build failed");
		}
		// (sys: ExitCode.getNative() compiles src/ExitCode.c with gcc into
		// bin/ExitCode unless it is there; hxmc's ExitCode does the same)
		if (suite == "sys" && !wasm) exec(["cp", '$dir/bin/hxmc/ExitCode', '$dir/bin/ExitCode']);
		var exe = 'bin/hxmc/$suite${wasm ? ".wasm" : ""}';
		var cmd = wasm ? [Sys.getEnv("NODE") ?? "node", "--stack-size=65500", root + "/hxmc/bootstrap/wasi.mjs", exe] : ['./$exe'];
		Sys.println('$suite ($tag): running');
		var x = exec(cmd, {cwd: dir, merge: true, log: '$dir/run.log', timeout: TIMEOUT, env: ["EXISTS" => "1"]});
		var out = readText('$dir/run.log');
		var res = parse(out);
		r.failed = res.failed.length;
		r.passed = res.ran - res.failed.length;
		for (f in res.failed)
			Sys.println('  FAIL ${f.name}: ${f.detail}');
		if (!res.complete) {
			r.failed++;
			Sys.println('  CRASH: the program ended (exit ${x.code}${x.timedOut ? ", timed out" : ""}) before its report, in ${res.last ?? "?"}:');
			Sys.println(tail(out, 2000));
			return failWith('crash in ${res.last ?? "?"}');
		}
		if (r.failed > 0) return failWith('${r.failed} failed');
		r.result = "ok";
		return r;
	}

	// utest's output: "Running <class>..." and "    <test>" as tests start; then
	// the report, where "<class>" lines list the classes with failed tests and
	// "  <test>: FAILURE|ERROR|WARNING ..." the tests, their messages below
	public static function parse(out:String) {
		var ran = 0, last:Null<String> = null, cls:Null<String> = null;
		var failed:Array<{name:String, detail:String}> = [];
		var lines = out.split("\n");
		var i = 0;
		var complete = false;
		var startRe = ~/^Running ([\w.]+)\.\.\.$/;
		var testRe = ~/^    (\w+)$/;
		while (i < lines.length) {
			var l = lines[i++];
			if (startRe.match(l)) {
				cls = startRe.matched(1);
			} else if (cls != null && testRe.match(l)) {
				ran++;
				last = cls + "." + testRe.matched(1);
			} else if (l.startsWith("results: ")) {
				complete = true;
				break;
			}
		}
		var fixRe = ~/^  (\w+): (FAILURE|ERROR|WARNING) /;
		var clsRe = ~/^([\w.]+)$/;
		cls = null;
		while (i < lines.length) {
			var l = lines[i++];
			if (clsRe.match(l)) cls = clsRe.matched(1) else if (fixRe.match(l)) {
				var detail = [];
				while (i < lines.length && lines[i].startsWith("    ") && detail.length < 3)
					detail.push(lines[i++].trim());
				failed.push({name: '$cls.${fixRe.matched(1)}', detail: detail.join(" / ")});
			}
		}
		return {ran: ran, failed: failed, complete: complete, last: last};
	}
}

// hxmc/test/upstream/skips.txt: one test per line,
//   <suite> <native|wasm|*> <class>[.<method>] <BUG|TARGET|EXTERNAL> <reason>
// BUG: an hxmc bug not fixed yet; TARGET: a behaviour hxmc chooses (that of
// the static targets where it can); EXTERNAL: a service or another target's
// natives the test needs.
class Skips {
	public var entries:Array<{suite:String, where:String, test:String, method:Null<String>, category:String, reason:String}> = [];

	public function new() {}

	public static function read(path:String):Skips {
		var s = new Skips();
		var n = 0;
		for (l in File.getContent(path).split("\n")) {
			n++;
			l = l.trim();
			if (l == "" || l.startsWith("#")) continue;
			var w = ~/\s+/g.split(l);
			if (w.length < 5 || !["BUG", "TARGET", "EXTERNAL"].contains(w[3]) || !["native", "wasm", "*"].contains(w[1]))
				throw '$path:$n: <suite> <native|wasm|*> <class>[.<method>] <BUG|TARGET|EXTERNAL> <reason>';
			var name = w[2];
			// (a method starts with a lower-case letter, a class with an upper-case one)
			var dot = name.lastIndexOf(".");
			var last = name.substr(dot + 1);
			var isMethod = last.charAt(0) == last.charAt(0).toLowerCase() && last.charAt(0) != last.charAt(0).toUpperCase();
			s.entries.push({
				suite: w[0],
				where: w[1],
				test: isMethod ? name.substr(0, dot) : name,
				method: isMethod ? last : null,
				category: w[3],
				reason: w.slice(4).join(" ")
			});
		}
		return s;
	}

	public function of(suite:String, where:String)
		return [for (e in entries) if (e.suite == suite && (e.where == "*" || e.where == where)) e];
}
