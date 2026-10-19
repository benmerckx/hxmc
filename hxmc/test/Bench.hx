import Harness.*;
import haxe.DynamicAccess;
import haxe.Json;
import sys.FileSystem;
import sys.io.File;

using StringTools;

// The HaxeBenchmarks cases (github.com/HaxeBenchmarks/benchmark-runner, pinned)
// on hxmc and the usual fast targets, side by side (`make bench`; the website's
// Benchmarks section, .github/workflows/bench.yml):
//   hxmc        the tool (bin/hxmc/hxmc) with hxmc's std: a static linux-x86_64 executable
//   hxmc-wasm   the same with -D hxmc.target=wasm32-wasi, run by node (hxmc/bootstrap/wasi.mjs)
//   hxmc-wasmgc the same as a WasmGC module (-D hxmc.wasm-gc, an experiment: the engine's
//               collector), run by node (hxmc/bootstrap/wasmgc.mjs)
//   cpp         the port (bin/port/haxe) --cpp, then hxcpp (lix, pinned) with g++
//   jvm         the port --jvm (with hxjava, lix, pinned), java -jar
//   js          the port --js with hxnodejs (lix, pinned), node
//   hlc         the port --hl to C (-D hl-ver), gcc -O3 against libhl (HashLink, pinned, built here)
//   hl          the port --hl, HashLink's JIT
// Every Haxe compilation is ours: hxmc for its targets, the port (byte-identical
// output to the reference compiler's for these targets) for the others.
//
//   bin/hxmc/hxmc -cp hxmc/test -cp haxe/test --run Bench [-n RUNS] [-t hxmc,js,...] [-c nbody,...]
//       [--out results.json] [--source ci|local] [--no-check] [--setup]
//   bin/hxmc/hxmc -cp hxmc/test -cp haxe/test --run Bench --history <dir>
//   bin/hxmc/hxmc -cp hxmc/test -cp haxe/test --run Bench --merge <out.json> <part.json>...
//
// Setup (bin/bench, kept between runs; --setup stops after it): the runner and
// the libraries the cases use (git, pinned), HashLink built from its release
// tag (libhl, hl), a lix scope with hxcpp and hxnodejs (bin/lix/lix), hxcpp's
// build tool compiled by the port.
//
// Measurement: each case is built for every target (cold: a fresh output
// directory), then run RUNS times, the targets interleaved round by round (drift
// of a shared machine spreads over all of them; a target whose first run takes
// over 10 s runs 3 times only). Per run: wall time, CPU time
// and peak RSS (/usr/bin/time). Reported: the median and the spread of the
// runs. Size: the artifact (native executables of C compilers stripped), and
// gzip -9 of it. Unless --no-check, each case's check program (hxmc/test/bench:
// its computation with the results printed; the cases print nothing) is built
// and run once per target, and the outputs are compared across targets.
// Failures are recorded, not fatal. The result is one JSON file (--out).
//
// Compile time, per case and target (wall time, seconds):
//   haxe_s   the Haxe compiler's run: for hxmc (both) the tool's whole build
//            (typing, lowering, machine code or wasm, link; its per-module object
//            cache empty, the typed runtime cached per tool as always); for the
//            others the port's (typing and the generator: the jar for jvm, the
//            script for js, the bytecode for hl, the C or C++ sources for hlc, cpp)
//   cc_s     cpp and hlc only: the C++ (hxcpp with g++, its runtime objects
//            compiled once beforehand by a warm-up build and shared through its
//            compile cache) or C (gcc -O3 against libhl) compilation and link
//   build_s  their sum
//
// --history <dir>: <dir>/results/*.json (one per run, the bench-data branch)
// into <dir>/history.json (per run, case and target an array: median, min,
// max, peak RSS, build_s, haxe_s, cc_s; null where a run lacks one: haxe_s
// and cc_s are recorded since 2026-10-16) and <dir>/latest.json (the newest CI run, else the newest
// measured one), which the website reads.
//
// --merge <out> <part>...: the results of one run's shards (bench.yml runs the
// cases in groups, each group on its own machine, every target of a case on
// the same one) into one results file of the same format, with `machines`: per
// case the machine (and `shard`, its group's index) it was measured on.
class Bench {
	static final RUNNER = {repo: "https://github.com/HaxeBenchmarks/benchmark-runner.git", commit: "d921d5c2a24d465188da9fb91842dbf019251d62"};
	// the cases' libraries: dir, repository, commit (as the runner pins them)
	static final LIBS = [
		{dir: "crypto", repo: "https://github.com/HaxeFoundation/crypto.git", commit: "9959143e1eeb2bc941eddae40d96c65e824581a5"},
		{dir: "formatter", repo: "https://github.com/HaxeCheckstyle/haxe-formatter.git", commit: "refs/tags/v1.9.1"},
		{dir: "tokentree", repo: "https://github.com/HaxeCheckstyle/tokentree.git", commit: "refs/tags/v1.0.23"},
		{dir: "haxeparser", repo: "https://github.com/Simn/haxeparser.git", commit: "e5746bfc55c09a3694db42738ff575b91441971a"},
		{dir: "hxparse", repo: "https://github.com/Simn/hxparse.git", commit: "876070ec62a4869de60081f87763e23457a3bda8"},
		{dir: "json2object", repo: "https://github.com/elnabo/json2object.git", commit: "a75859de1e966c09e73591b6c9186086c143fe60"},
		{dir: "hxargs", repo: "https://github.com/simn/hxargs.git", commit: "1d8ec84f641833edd6f0cb2e4290b7524fd27219"},
		{dir: "hxjsonast", repo: "https://github.com/nadako/hxjsonast.git", commit: "refs/tags/1.1.0"},
	];
	static final FORMATTER_CPS = ["formatter/src", "tokentree/src", "haxeparser/src", "hxparse/src", "json2object/src", "hxargs", "hxjsonast/src"];
	// HashLink: the release tag, the hl-ver the port generates for
	public static final HASHLINK = {tag: "1.16", ver: "1.16.0"};
	// lix libraries: name, repository, commit
	static final LIX_LIBS = [
		{name: "hxcpp", repo: "HaxeFoundation/hxcpp", commit: "e638733340fcf4589595da07898436146ee413ff"},
		{name: "hxnodejs", repo: "HaxeFoundation/hxnodejs", commit: "f88685a70b2e4f03dbe0a824ce90ea8b56b27753"},
		// --jvm adds -lib hxjava (its Java standard library)
		{name: "hxjava", repo: "HaxeFoundation/hxjava", commit: "f8c7dc6c56f4bf8f5912b4844a1b55ab094ee0cf"},
	];
	public static final TARGETS = ["hxmc", "hxmc-wasm", "cpp", "jvm", "js", "hlc", "hl", "hxmc-wasmgc"];
	// history.json: the fields of each run's per case and target array
	static final HISTORY_FIELDS = ["median", "min", "max", "rss_mb", "build_s", "haxe_s", "cc_s"];
	static final DIR = "bin/bench";
	// a target whose first run takes longer than SLOW_SECONDS runs SLOW_RUNS times only
	static final SLOW_SECONDS = 10.0;
	static final SLOW_RUNS = 3;

	static var cases:Array<Case>;
	static var tool:String;
	static var port:String;
	static var bench:String;
	static var hashlink:String;
	static var scope:String;
	static var hxcppDir:String;
	static var env:Map<String, Null<String>>;
	static var log:Array<String> = [];

	static function main() {
		var a = parseArgs(Sys.args(), ["-n", "-t", "-c", "--out", "--source", "--history", "--summary", "--merge", "--shard"]);
		if (a.has("--history")) {
			history(a.get("--history"));
			return;
		}
		if (a.has("--merge")) {
			merge(a.get("--merge"), a.rest, a.get("--summary"));
			return;
		}
		Sys.putEnv("HAXE_STD_PATH", root + "/haxe/upstream/std");
		tool = FileSystem.fullPath("bin/hxmc/hxmc");
		port = FileSystem.fullPath(Sys.getEnv("HAXE_IN_HAXE_PORT") ?? "bin/port/haxe");
		mkdirs(DIR);
		bench = FileSystem.fullPath(DIR);
		cases = caseList('$bench/libs');
		var runs = a.int("-n", 5);
		var targets = a.has("-t") ? a.get("-t").split(",") : TARGETS;
		for (t in targets) if (!TARGETS.contains(t)) fail('unknown target $t (${TARGETS.join(", ")})');
		var only = a.has("-c") ? a.get("-c").split(",") : [for (c in cases) c.name];
		for (n in only) if (!Lambda.exists(cases, c -> c.name == n)) fail('unknown case $n (${[for (c in cases) c.name].join(", ")})');
		var check = !a.has("--no-check");
		var t0 = now();
		setup(targets);
		if (a.has("--setup")) return;
		var doc:Dynamic = {
			schema: 1,
			source: a.get("--source", Sys.getEnv("GITHUB_ACTIONS") == "true" ? "ci" : "local"),
			date: isoNow(),
			commit: git(["rev-parse", "HEAD"]),
			short: git(["rev-parse", "--short=7", "HEAD"]),
			ref: Sys.getEnv("GITHUB_REF_NAME") ?? git(["rev-parse", "--abbrev-ref", "HEAD"]),
			run_url: Sys.getEnv("GITHUB_RUN_ID") != null ? '${Sys.getEnv("GITHUB_SERVER_URL")}/${Sys.getEnv("GITHUB_REPOSITORY")}/actions/runs/${Sys.getEnv("GITHUB_RUN_ID")}' : null,
			machine: machine(),
			versions: versions(),
			runs: runs,
			method: 'median of $runs runs per target, interleaved ($SLOW_RUNS when a run takes over $SLOW_SECONDS s); wall time of the whole process (start-up, JIT and module compilation included); peak RSS from getrusage; builds cold, compile time as haxe_s (the Haxe compiler: hxmc\'s whole build, the port\'s generation for the others) and cc_s (cpp, hlc: the C++ or C compiler), build_s their sum',
			targets: targets,
			cases: [],
			results: {},
			checks: {},
		};
		// (one shard of a sharded run: its index, for --merge)
		if (a.has("--shard")) doc.shard = a.int("--shard", 0);
		var results:DynamicAccess<DynamicAccess<Dynamic>> = doc.results;
		var checks:DynamicAccess<Dynamic> = doc.checks;
		for (c in cases) {
			if (!only.contains(c.name)) continue;
			(doc.cases : Array<String>).push(c.name);
			var row = new DynamicAccess<Dynamic>();
			results[c.name] = row;
			var built = new Map<String, Array<String>>();
			for (t in targets) {
				var r:DynamicAccess<Dynamic> = {};
				row[t] = r;
				var out = '$bench/out/${c.name}/$t';
				rmrf(out);
				mkdirs(out);
				try {
					var b = build(t, c, out, c.main);
					r["build_s"] = round(b.seconds, 2);
					r["haxe_s"] = round(b.haxe, 2);
					if (b.cc != null) r["cc_s"] = round(b.cc, 2);
					var s = sizes(t, b.artifact);
					r["size"] = s.size;
					r["gzip"] = s.gzip;
					built[t] = b.run;
				} catch (e:Dynamic) {
					r["error"] = "build: " + tail(Std.string(e).trim(), 600);
					say('${pad(c.name, 16)} ${pad(t, 10)} build FAILED: ${lastLine(Std.string(e))}');
				}
			}
			// the runs, round by round
			var samples = new Map<String, Array<Sample>>();
			for (round in 0...runs)
				for (t in targets) {
					if (!built.exists(t) || row[t].error != null) continue;
					// (a slow target: SLOW_RUNS runs are enough)
					if (round >= SLOW_RUNS && samples.exists(t) && samples[t][0].wall > SLOW_SECONDS) continue;
					var s = runOnce(built[t], c, '$bench/out/${c.name}/$t', 600);
					if (s.error != null) {
						Reflect.setField(row[t], "error", "run: " + s.error);
						say('${pad(c.name, 16)} ${pad(t, 10)} run FAILED: ${lastLine(s.error)}');
						continue;
					}
					if (!samples.exists(t)) samples[t] = [];
					samples[t].push(s);
				}
			for (t in targets) {
				var r:DynamicAccess<Dynamic> = row[t];
				var ss = samples[t];
				if (r["error"] != null || ss == null || ss.length == 0) continue;
				var wall = [for (s in ss) s.wall], cpu = [for (s in ss) s.cpu], rss = [for (s in ss) s.rssMb];
				r["times"] = [for (w in wall) round(w, 3)];
				r["median"] = round(median(wall), 3);
				r["min"] = round(Lambda.fold(wall, Math.min, wall[0]), 3);
				r["max"] = round(Lambda.fold(wall, Math.max, wall[0]), 3);
				r["cpu"] = round(median(cpu), 3);
				r["rss_mb"] = round(median(rss), 1);
				say('${pad(c.name, 16)} ${pad(t, 10)} ${fixed(r["median"], 3)} s (${fixed(r["min"], 3)}-${fixed(r["max"], 3)}), ${fixed(r["rss_mb"], 0)} MB, build ${fixed(r["build_s"], 2)} s (Haxe ${fixed(r["haxe_s"], 2)} s${r["cc_s"] != null ? ', C/C++ ' + fixed(r["cc_s"], 2) + ' s' : ""}), ${Std.int(r["size"] / 1024)} KB');
			}
			if (check) {
				var outs = new DynamicAccess<String>();
				for (t in targets) {
					var out = '$bench/out/${c.name}/$t-check';
					rmrf(out);
					mkdirs(out);
					try {
						var b = build(t, c, out, c.check);
						var s = runOnce(b.run, c, out, 600);
						outs[t] = s.error != null ? "error: " + s.error : s.output;
					} catch (e:Dynamic) {
						outs[t] = "error: build: " + tail(Std.string(e).trim(), 300);
					}
					rmrf(out);
				}
				// the output most targets agree on; the others differ
				var count = new Map<String, Int>(), best = null;
				for (t => o in outs) if (!o.startsWith("error: ")) count[o] = (count[o] ?? 0) + 1;
				for (o => n in count) if (best == null || n > count[best]) best = o;
				var differ = [for (t => o in outs) if (o != best) t];
				differ.sort(compare);
				var others = new DynamicAccess<String>();
				for (t => o in outs) if (o != best) others[t] = o;
				checks[c.name] = {output: best, differ: differ, outputs: others};
				for (t in targets) if (row[t] != null) Reflect.setField(row[t], "check", outs[t] == best ? "ok" : outs[t].startsWith("error: ") ? "error" : "differs");
				say('${pad(c.name, 16)} check: ${differ.length == 0 ? "identical on every target" : "DIFFERS on " + differ.join(", ")}');
			}
			if (!a.has("--keep")) rmrf('$bench/out/${c.name}');
		}
		doc.seconds = Math.round(now() - t0);
		var outFile = a.get("--out", '$DIR/results.json');
		File.saveContent(outFile, Json.stringify(doc, null, " ") + "\n");
		say('wrote $outFile (${doc.seconds} s)');
		summary(a.get("--summary"), markdown(doc));
	}

	/** the cases, in their order (`libs`: the directory of their libraries) */
	static function caseList(libs:String):Array<Case> {
		return [
			{name: "alloc", dir: "alloc", main: "BMAllocCode", cps: [], defines: [], check: "CheckAlloc"},
			{name: "bcrypt", dir: "bcrypt", main: "BMBCryptCode", cps: ['$libs/crypto/src'], defines: [], check: "CheckBcrypt"},
			{name: "binarytrees", dir: "binarytrees", main: "BMBinaryTreesCode", cps: [], defines: [], check: "CheckBinarytrees"},
			{name: "json", dir: "json", main: "BMJsonCode", cps: [], defines: [], check: "CheckJson"},
			{name: "mandelbrot", dir: "mandelbrot", main: "BMMandelbrotCode", cps: [], defines: [], check: "CheckMandelbrot"},
			{name: "mandelbrot_anon", dir: "mandelbrot_anon_objects", main: "BMMandelbrotCode", cps: ["../mandelbrot"], defines: ["anon_objects"], check: "CheckMandelbrot"},
			{name: "nbody", dir: "nbody", main: "BMNBodyCode", cps: [], defines: [], check: "CheckNbody"},
			{name: "sha256", dir: "sha256", main: "BMSHA256Code", cps: [], defines: [], check: "CheckSha256"},
			{name: "sha512", dir: "sha512", main: "BMSHA512Code", cps: ['$libs/crypto/src'], defines: [], check: "CheckSha512"},
			// haxe-formatter 1.9.1 formatting its own src/ (60 times)
			{name: "formatter_noio", dir: "formatter_noio", main: "BMFormatterNoIOCode", cps: [for (d in FORMATTER_CPS) '$libs/$d'],
				defines: [for (d in FORMATTER_CPS) d.split("/")[0]], check: "CheckFormatter"},
		];
	}

	// ---- setup

	static function setup(targets:Array<String>) {
		var runner = '$bench/runner';
		fetch(RUNNER.repo, RUNNER.commit, runner);
		for (l in LIBS) fetch(l.repo, l.commit, '$bench/libs/${l.dir}');
		var data = '$runner/cases/formatter_noio/data';
		if (!FileSystem.exists(data)) copyTree('$bench/libs/formatter/src', data);
		env = new Map();
		if (targets.contains("hl") || targets.contains("hlc")) {
			hashlink = '$bench/hashlink-${HASHLINK.tag}';
			if (!FileSystem.exists('$hashlink/hl') || !FileSystem.exists('$hashlink/libhl.so')) {
				fetch("https://github.com/HaxeFoundation/hashlink.git", "refs/tags/" + HASHLINK.tag, hashlink);
				var r = exec(["make", "-j" + cpus(), "libhl.so", "hl"], {cwd: hashlink, merge: true, log: '$bench/hashlink-build.log'});
				if (r.code != 0) fail("HashLink's build failed: " + tail(readText('$bench/hashlink-build.log'), 2000));
			}
		}
		if (targets.contains("cpp") || targets.contains("js") || targets.contains("jvm")) {
			scope = '$bench/scope';
			mkdirs(scope);
			var lix = FileSystem.fullPath("bin/lix/lix");
			if (!FileSystem.exists(lix)) fail("bin/lix/lix is missing (make lix)");
			var lixEnv:Map<String, Null<String>> = ["HAXESHIM_ROOT" => '$scope/lix-root'];
			if (!FileSystem.exists('$scope/.haxerc')) exec([lix, "scope", "create"], {cwd: scope, env: lixEnv});
			for (l in LIX_LIBS) {
				if (FileSystem.exists('$scope/haxe_libraries/${l.name}.hxml')) continue;
				var r = exec([lix, "install", 'https://github.com/${l.repo}/archive/${l.commit}.tar.gz', "as", l.name], {cwd: scope, env: lixEnv, merge: true});
				if (r.code != 0) {
					// (where the archive cannot be downloaded: a git checkout as a dev library)
					var dir = '$scope/src/${l.name}';
					fetch('https://github.com/${l.repo}.git', l.commit, dir);
					r = exec([lix, "dev", l.name, dir], {cwd: scope, env: lixEnv, merge: true});
				}
				if (r.code != 0) fail('lix could not install ${l.name}: ' + tail(r.out, 400));
			}
			env["HAXESHIM_ROOT"] = '$scope/lix-root';
			env["HAXESHIM_SCOPE"] = scope;
			env["PATH"] = FileSystem.fullPath("bin/lix") + ":" + Sys.getEnv("PATH");
			// (the haxelib shim downloads neko on its first call and says so on stdout:
			// not in the compiler's -lib resolution)
			exec(["haxelib", "path", "hxnodejs"], {env: env, merge: true});
			if (targets.contains("cpp")) {
				// hxcpp's build tool (hxcpp.n, which `haxelib run hxcpp` runs), compiled by the port
				var p = exec(["haxelib", "path", "hxcpp"], {env: env, merge: true});
				// (the class path: the line naming a directory; lix may first report a neko download)
				hxcppDir = [for (l in p.out.split("\n")) if (l.trim() != "" && !l.startsWith("-") && FileSystem.exists(l.trim())) haxe.io.Path.removeTrailingSlashes(l.trim())][0];
				if (hxcppDir == null || !FileSystem.exists('$hxcppDir/run.n')) fail("hxcpp not found: " + p.out);
				if (!FileSystem.exists('$hxcppDir/hxcpp.n')) {
					var r = exec([port, "compile.hxml"], {cwd: '$hxcppDir/tools/hxcpp', merge: true});
					if (r.code != 0) fail("hxcpp's build tool: " + r.out);
				}
				// hxcpp's runtime, compiled once into its compile cache by a warm-up build
				// (emptied first: the cases' own objects are never reused from an earlier
				// run), so that the cases' build times are their own code's
				env["HXCPP_COMPILE_CACHE"] = '$bench/hxcpp-cache';
				rmrf('$bench/hxcpp-cache');
				mkdirs('$bench/hxcpp-cache');
				var warm = '$bench/warmup';
				rmrf(warm);
				mkdirs(warm);
				File.saveContent('$warm/Main.hx', 'class Main { static function main() Sys.println("warm"); }\n');
				var r = exec(["sh", "-c", 'ulimit -s unlimited 2>/dev/null; exec "$$@"', "sh", port, "-main", "Main", "--cpp", "cpp"], {cwd: warm, env: env, merge: true});
				if (r.code != 0) fail("hxcpp's warm-up build failed: " + tail(r.out, 3000));
				say('hxcpp: its runtime compiled in ${fixed(r.seconds, 1)} s');
			}
		}
	}

	/** a checkout of `rev` (a commit or a ref) of `repo` in `dir`, once */
	static function fetch(repo:String, rev:String, dir:String) {
		if (FileSystem.exists('$dir/.bench-rev') && readText('$dir/.bench-rev') == rev) return;
		rmrf(dir);
		mkdirs(dir);
		var r = exec(["sh", "-c", 'git init -q && git fetch -q --depth 1 "$$1" "$$2" && git checkout -q FETCH_HEAD', "sh", repo, rev], {cwd: dir, merge: true});
		if (r.code != 0) fail('git: $repo $rev: ${r.out}');
		File.saveContent('$dir/.bench-rev', rev);
	}

	// ---- building and running

	static function build(target:String, c:Case, out:String, main:String):Built {
		var cwd = '$bench/runner/cases/${c.dir}';
		var cps = c.cps.copy();
		if (main != c.main) cps.push(root + "/hxmc/test/bench");
		var args = ["-cp", "."];
		for (p in cps) args = args.concat(["-cp", p]);
		args = args.concat(["-main", main]);
		for (d in c.defines) args = args.concat(["-D", d]);
		// each step: its command, its directory (default: the case's) and whether it is the C/C++ compilation
		var steps:Array<{cmd:Array<String>, ?cwd:String, ?cc:Bool}> = [];
		var art:String, run:Array<String>;
		switch target {
			case "hxmc" | "hxmc-wasm" | "hxmc-wasmgc":
				var wasm = target != "hxmc", gc = target == "hxmc-wasmgc";
				art = '$out/${wasm ? "main.wasm" : "main"}';
				steps.push({cmd: [tool, art].concat(args).concat(["-cp", root + "/bin/hxmc/std", "--custom-target", "hxmc"]).concat(wasm ? ["-D", "hxmc.target=wasm32-wasi"] : []).concat(gc ? ["-D", "hxmc.wasm-gc"] : [])});
				run = wasm ? ["node", "--stack-size=65500", root + (gc ? "/hxmc/bootstrap/wasmgc.mjs" : "/hxmc/bootstrap/wasi.mjs"), art] : [art];
			case "cpp":
				art = '$out/cpp/$main';
				// the sources, then hxcpp as the compiler would run it (`haxelib run hxcpp Build.xml haxe`,
				// the defines from the Options.txt it writes), timed apart
				steps.push({cmd: [port].concat(args).concat(["-D", "no-compilation", "--cpp", '$out/cpp'])});
				steps.push({cmd: ["haxelib", "run", "hxcpp", "Build.xml", "haxe"], cwd: '$out/cpp', cc: true});
				run = [art];
			case "jvm":
				art = '$out/main.jar';
				steps.push({cmd: [port].concat(args).concat(["--jvm", art])});
				run = ["java", "-jar", art];
			case "js":
				// .cjs: CommonJS whatever package.json a directory above has
				art = '$out/main.cjs';
				steps.push({cmd: [port].concat(args).concat(["-lib", "hxnodejs", "--js", art])});
				run = ["node", art];
			case "hlc":
				art = '$out/hlc/main';
				steps.push({cmd: [port].concat(args).concat(["-D", "hl-ver=" + HASHLINK.ver, "-D", "no-compilation", "--hl", '$out/hlc/main.c'])});
				// as HaxeBenchmarks builds HL/C
				steps.push({cmd: ["gcc", "-O3", "-std=c11", "-w", "-o", art, '$out/hlc/main.c', "-I", '$hashlink/src', "-I", '$out/hlc', "-L", hashlink, "-lhl", "-lm",
					'-Wl,-rpath,$hashlink'], cc: true});
				run = [art];
			case "hl":
				art = '$out/main.hl';
				steps.push({cmd: [port].concat(args).concat(["-D", "hl-ver=" + HASHLINK.ver, "--hl", art])});
				run = ['$hashlink/hl', art];
			case _:
				throw 'unknown target $target';
		}
		var seconds = 0.0, haxeSeconds = 0.0, cc:Null<Float> = null;
		var logFile = '$out/build.log';
		var text = new StringBuf();
		for (s in steps) {
			// the tool and the port recurse deeply: an unlimited stack, as the Makefile runs them
			var r = exec(["sh", "-c", 'ulimit -s unlimited 2>/dev/null; exec "$$@"', "sh"].concat(s.cmd), {cwd: s.cwd ?? cwd, env: env, merge: true, log: logFile});
			seconds += r.seconds;
			if (s.cc == true) cc = (cc ?? 0.0) + r.seconds else haxeSeconds += r.seconds;
			text.add("$ " + s.cmd.join(" ") + "\n" + readText(logFile));
			if (r.code != 0) {
				File.saveContent(logFile, text.toString());
				throw 'exit ${r.code}: ' + tail(text.toString(), 1500);
			}
		}
		File.saveContent(logFile, text.toString());
		if (!FileSystem.exists(art)) throw 'no $art: ' + tail(text.toString(), 1500);
		return {run: run, seconds: seconds, haxe: haxeSeconds, cc: cc, artifact: art};
	}

	/** One run: the cases read ../data/..., so they run in a directory of the case. The usual 8 MB stack. **/
	static function runOnce(cmd:Array<String>, c:Case, out:String, timeout:Float):Sample {
		var cwd = '$bench/runner/cases/${c.dir}/out';
		mkdirs(cwd);
		var timeFile = '$out/time.txt', logFile = '$out/run.log';
		var runEnv = env.copy();
		if (hashlink != null) runEnv["LD_LIBRARY_PATH"] = hashlink;
		var r = exec(["sh", "-c", 'ulimit -s 8192; exec /usr/bin/time -f "%M %U %S" -o "$$0" "$$@"', timeFile].concat(cmd), {cwd: cwd, env: runEnv, merge: true, log: logFile, timeout: timeout});
		// (a JVM announces JAVA_TOOL_OPTIONS on stderr)
		var output = [for (l in readText(logFile).split("\n")) if (!l.startsWith("Picked up ")) l].join("\n");
		if (r.code != 0) return {wall: 0, cpu: 0, rssMb: 0, output: output, error: (r.timedOut ? 'timed out after ${timeout} s' : 'exit ${r.code}') + ": " + tail(output.trim(), 600)};
		var m = ~/([0-9]+) ([0-9.]+) ([0-9.]+)\s*$/;
		var t = readText(timeFile);
		var s:Sample = {wall: r.seconds, cpu: 0, rssMb: 0, output: output, error: null};
		if (m.match(t)) {
			s.rssMb = Std.parseFloat(m.matched(1)) / 1024;
			s.cpu = Std.parseFloat(m.matched(2)) + Std.parseFloat(m.matched(3));
		}
		return s;
	}

	/** the artifact's size (native executables of C compilers stripped) and its gzip -9 size **/
	static function sizes(target:String, art:String):{size:Int, gzip:Int} {
		var file = art;
		if (target == "cpp" || target == "hlc") {
			file = art + ".stripped";
			File.copy(art, file);
			exec(["strip", file]);
		}
		var size = FileSystem.stat(file).size;
		var gz = Std.parseInt(exec(["sh", "-c", 'gzip -9c "$$0" | wc -c', file]).out.trim());
		if (file != art) FileSystem.deleteFile(file);
		return {size: size, gzip: gz ?? 0};
	}

	// ---- facts

	static function machine():Dynamic {
		var cpuinfo = readText("/proc/cpuinfo");
		var model = ~/model name\s*:\s*(.*)/;
		var mem = ~/MemTotal:\s*([0-9]+) kB/;
		return {
			cpu: model.match(cpuinfo) ? model.matched(1).trim() : null,
			cores: cpus(),
			memory_gb: mem.match(readText("/proc/meminfo")) ? round(Std.parseFloat(mem.matched(1)) / 1048576, 1) : null,
			os: exec(["uname", "-sr"]).out.trim(),
			runner: Sys.getEnv("RUNNER_NAME") != null ? (Sys.getEnv("ImageOS") ?? "github") + " " + (Sys.getEnv("ImageVersion") ?? "") : null,
			// (the runner itself: tells the virtual machines of a sharded run apart)
			host: Sys.getEnv("RUNNER_NAME"),
		};
	}

	static function firstLine(cmd:Array<String>):Null<String> {
		var r = exec(cmd, {merge: true});
		var lines = [for (l in r.out.split("\n")) if (l.trim() != "" && !l.startsWith("Picked up")) l.trim()];
		return r.code == 0 && lines.length > 0 ? lines[0] : null;
	}

	static function versions():Dynamic {
		var v:DynamicAccess<Dynamic> = {
			node: firstLine(["node", "--version"]),
			java: firstLine(["java", "-version"]),
			gcc: firstLine(["gcc", "--version"]),
			runner: RUNNER.commit.substr(0, 7),
		};
		if (hashlink != null) v["hashlink"] = HASHLINK.tag + " (hl-ver " + HASHLINK.ver + ")";
		for (l in LIX_LIBS) v[l.name] = l.commit.substr(0, 7);
		return v;
	}

	static function git(args:Array<String>):String return exec(["git"].concat(args)).out.trim();

	static function isoNow():String {
		return DateTools.format(Date.fromTime(Date.now().getTime() + Date.now().getTimezoneOffset() * 60000), "%Y-%m-%dT%H:%M:%SZ");
	}

	// ---- reporting

	static function markdown(doc:Dynamic):String {
		var targets:Array<String> = doc.targets;
		var b = new StringBuf();
		b.add('### Benchmarks (${doc.short}, median of ${doc.runs} runs, seconds)\n\n| case | ${targets.join(" | ")} |\n| --- |${[for (_ in targets) " ---: |"].join("")}\n');
		var results:DynamicAccess<DynamicAccess<Dynamic>> = doc.results;
		for (c in (doc.cases : Array<String>)) {
			var row = results[c];
			b.add('| $c |');
			for (t in targets) {
				var r = row[t];
				b.add(" " + (r == null ? "-" : r.error != null ? "failed" : fixed(r.median, 3) + (r.check == "differs" ? " (check differs)" : "")) + " |");
			}
			b.add("\n");
		}
		b.add('\nCompile time (seconds: the Haxe compiler, + the C/C++ compiler for cpp and hlc)\n\n| case | ${targets.join(" | ")} |\n| --- |${[for (_ in targets) " ---: |"].join("")}\n');
		for (c in (doc.cases : Array<String>)) {
			var row = results[c];
			b.add('| $c |');
			for (t in targets) {
				var r = row[t];
				b.add(" " + (r == null || r.haxe_s == null ? "-" : fixed(r.haxe_s, 2) + (r.cc_s != null ? " + " + fixed(r.cc_s, 2) : "")) + " |");
			}
			b.add("\n");
		}
		return b.toString() + "\n";
	}

	static function say(s:String) {
		Sys.println(s);
	}

	static function lastLine(s:String):String {
		var lines = [for (l in s.split("\n")) if (l.trim() != "") l.trim()];
		return lines.length == 0 ? "" : lines[lines.length - 1];
	}

	static function median(xs:Array<Float>):Float {
		var s = xs.copy();
		s.sort((a, b) -> a < b ? -1 : a > b ? 1 : 0);
		var n = s.length;
		return n % 2 == 1 ? s[n >> 1] : (s[(n >> 1) - 1] + s[n >> 1]) / 2;
	}

	static function round(x:Float, digits:Int):Float {
		var m = Math.pow(10, digits);
		return Math.round(x * m) / m;
	}

	// ---- merge (a run sharded by case: .github/workflows/bench.yml)

	/**
		The results of the shards of one run (each a run of some cases, every
		target, on its own machine) as one results file in the format of an
		unsharded run: the cases in their order, the first shard's facts (its
		machine's CPU: the shards' CPUs, where they differ), the earliest date,
		the slowest shard's seconds, and `machines`: per case the machine it ran
		on (with `shard`, its shard's --shard: a row's targets always share one
		machine).
	**/
	static function merge(out:String, files:Array<String>, summaryPath:Null<String>) {
		if (files.length == 0) fail("--merge: no results to merge");
		var order = [for (c in caseList("")) c.name];
		var rank = (n:String) -> {
			var i = order.indexOf(n);
			i < 0 ? order.length : i;
		};
		var parts:Array<Dynamic> = [for (f in files) Json.parse(File.getContent(f))];
		var firstRank = (p:Dynamic) -> {
			var cs:Array<String> = p.cases;
			var r = order.length + 1;
			for (c in cs) if (rank(c) < r) r = rank(c);
			r;
		};
		parts.sort((x, y) -> firstRank(x) - firstRank(y));
		var base:Dynamic = parts[0];
		var results = new DynamicAccess<Dynamic>(), checks = new DynamicAccess<Dynamic>(), machines = new DynamicAccess<Dynamic>();
		var cases:Array<String> = [];
		var date:String = base.date, seconds = 0.0;
		for (i => p in parts) {
			for (k in ["commit", "source", "runs"])
				if (Std.string(Reflect.field(p, k)) != Std.string(Reflect.field(base, k)))
					fail('--merge: the shards differ in $k (${Reflect.field(base, k)}, ${Reflect.field(p, k)})');
			if ((p.targets : Array<String>).join(",") != (base.targets : Array<String>).join(","))
				fail('--merge: the shards differ in their targets');
			if (compare(p.date, date) < 0) date = p.date;
			if (p.seconds != null && p.seconds > seconds) seconds = p.seconds;
			var pr:DynamicAccess<Dynamic> = p.results, pc:DynamicAccess<Dynamic> = p.checks ?? {};
			for (c in (p.cases : Array<String>)) {
				if (cases.contains(c)) fail('--merge: case $c is in two shards');
				cases.push(c);
				results[c] = pr[c];
				if (pc.exists(c)) checks[c] = pc[c];
				var m:DynamicAccess<Dynamic> = p.machine != null ? Reflect.copy(p.machine) : {};
				m["shard"] = p.shard ?? i;
				machines[c] = m;
			}
		}
		cases.sort((x, y) -> rank(x) - rank(y));
		// the machine: the first shard's, its CPU the shards' CPUs where they differ
		var machine:Null<DynamicAccess<Dynamic>> = base.machine != null ? Reflect.copy(base.machine) : null;
		var cpus:Array<String> = [];
		for (p in parts) if (p.machine != null && p.machine.cpu != null && !cpus.contains(p.machine.cpu)) cpus.push(p.machine.cpu);
		if (machine != null && cpus.length > 1) machine["cpu"] = cpus.join(" / ");
		if (machine != null && parts.length > 1) machine.remove("host");
		// (the fields in the order of an unsharded run's, then machines)
		var doc:Dynamic = {
			schema: base.schema,
			source: base.source,
			date: date,
			commit: base.commit,
			short: base.short,
			ref: base.ref,
			run_url: base.run_url,
			machine: machine,
			versions: base.versions,
			runs: base.runs,
			method: base.method,
			targets: base.targets,
			cases: cases,
			results: {},
			checks: {},
		};
		var dr:DynamicAccess<Dynamic> = doc.results, dc:DynamicAccess<Dynamic> = doc.checks;
		for (c in cases) {
			dr[c] = results[c];
			if (checks.exists(c)) dc[c] = checks[c];
		}
		doc.seconds = Math.round(seconds);
		doc.machines = {};
		var dm:DynamicAccess<Dynamic> = doc.machines;
		for (c in cases) dm[c] = machines[c];
		File.saveContent(out, Json.stringify(doc, null, " ") + "\n");
		say('wrote $out: ${cases.length} cases from ${parts.length} shards');
		summary(summaryPath, markdown(doc));
	}

	// ---- history (the bench-data branch)

	static function history(dir:String) {
		var files = FileSystem.exists('$dir/results') ? [for (f in FileSystem.readDirectory('$dir/results')) if (f.endsWith(".json")) f] : [];
		var docs:Array<{file:String, doc:Dynamic}> = [for (f in files) {file: f, doc: Json.parse(File.getContent('$dir/results/$f'))}];
		docs.sort((a, b) -> compare(a.doc.date, b.doc.date));
		var runs = [];
		var latest = null, latestOther = null;
		for (d in docs) {
			var doc = d.doc;
			var res = new DynamicAccess<DynamicAccess<Array<Null<Float>>>>();
			var results:DynamicAccess<DynamicAccess<Dynamic>> = doc.results;
			for (c => row in results) {
				var out = new DynamicAccess<Array<Null<Float>>>();
				// (a build without a run keeps its compile time)
				for (t => r in row)
					if (r.median != null || r.build_s != null)
						out[t] = ([r.median, r.min, r.max, r.rss_mb, r.build_s, r.haxe_s, r.cc_s] : Array<Null<Float>>);
				res[c] = out;
			}
			var m = doc.machine;
			runs.push({
				file: "results/" + d.file,
				date: doc.date,
				commit: doc.short,
				source: doc.source,
				machine: m == null ? null : (m.cpu ?? "?") + (m.cores != null ? ', ${m.cores} cores' : ""),
				runs: doc.runs,
				stat: doc.stat ?? "median",
				note: doc.note,
				run_url: doc.run_url,
				results: res,
			});
			if (doc.source == "ci") latest = d else if (doc.source != "imported") latestOther = d;
		}
		if (latest == null) latest = latestOther;
		File.saveContent('$dir/history.json', Json.stringify({schema: 2, fields: HISTORY_FIELDS, targets: TARGETS, runs: runs}) + "\n");
		if (latest != null) File.copy('$dir/results/${latest.file}', '$dir/latest.json');
		Sys.println('$dir/history.json: ${runs.length} runs' + (latest != null ? ', latest.json: ${latest.file}' : ""));
	}
}

typedef Case = {name:String, dir:String, main:String, cps:Array<String>, defines:Array<String>, check:String};
typedef Built = {run:Array<String>, seconds:Float, haxe:Float, cc:Null<Float>, artifact:String};
typedef Sample = {wall:Float, cpu:Float, rssMb:Float, output:String, error:Null<String>};
