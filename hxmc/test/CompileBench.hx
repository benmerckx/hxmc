import Harness.*;
import haxe.DynamicAccess;
import haxe.Json;
import sys.FileSystem;
import sys.io.File;

using StringTools;

// The compiler benchmarks (`make bench-compile`; the website's "The compiler"
// section, .github/workflows/bench.yml's compile job): the port built by hxmc
// against the pinned reference compiler, compiling three workloads to HXB with
// -D disable-parallelism:
//   hello    hxmc/test/bench/Hello.hx: start-up and the core std
//   stdlib   32 std modules as roots
//   self     the port's own source (haxe/src), std macros run by Eval
// Runners:
//   reference           bin/reference/haxe (HAXE_REFERENCE)
//   hxmc                the port, natively (bin/port/haxe, HAXE_IN_HAXE_PORT)
//   hxmc-wasm-node      the port as a wasm32-wasi module under node (bin/bench/haxe.wasm, built here)
//   hxmc-wasm-wasmtime  the same under wasmtime (when it is on the PATH)
//
//   bin/hxmc/hxmc -cp hxmc/test -cp haxe/test --run CompileBench [-n RUNS] [-w hello,self]
//       [-r reference,hxmc,...] [--once hxmc-wasm-node,...] [--build] [--build-runs N]
//       [--out bench.json] [--source ci|local] [--summary <file>]
//   bin/hxmc/hxmc -cp hxmc/test -cp haxe/test --run CompileBench --history <dir> [--seed <history.json>]
//
// Measurement: RUNS runs per workload and runner, the runners interleaved round
// by round (drift of a shared machine spreads over all of them); the runners in
// --once run once (context, not tracked). Per run: wall time, CPU time and
// peak RSS (/usr/bin/time). Every runner's archive is compared with the
// reference's (the same members, identical .hxb payloads) before its times
// count. Reported: median, min and max. The reference runs in every run on the
// same machine, so hxmc / reference is a ratio that a slower or faster runner
// mostly cancels out (the website's "vs. reference" view).
//
// --build: hxmc's cold builds of the port (native and wasm32-wasi; an empty
// object cache of their own), best of --build-runs (default RUNS): wall, CPU,
// size and gzip -9 size.
//
// The result is one JSON file (--out, default bin/bench/compile.json; the
// format of site/data/bench.json): meta, runners, results (per workload and
// runner: status, runs, verified, wall_median/min/max, cpu_median/min/max,
// maxrss_mb), builds.
//
// --history <dir>: <dir>/compile/*.json (one per run, the bench-data branch)
// and the runs of --seed (an earlier compile-history.json: the imported ones,
// measured before CI recorded them) into <dir>/compile-history.json (per run,
// workload and runner an array of FIELDS) and <dir>/compile-latest.json (the
// newest CI run, else the newest one).
class CompileBench {
	public static final RUNNERS = ["reference", "hxmc", "hxmc-wasm-node", "hxmc-wasm-wasmtime"];
	public static final WORKLOADS = ["hello", "stdlib", "self"];
	static final STDLIB = "haxe.Json haxe.Serializer haxe.Unserializer haxe.crypto.Sha256 haxe.crypto.Md5
		haxe.crypto.Base64 haxe.io.BytesBuffer haxe.zip.Reader haxe.zip.Writer haxe.ds.BalancedTree
		haxe.ds.GenericStack haxe.ds.ListSort haxe.xml.Parser haxe.xml.Printer haxe.Template
		haxe.format.JsonParser haxe.io.Path haxe.Int64Helper haxe.CallStack DateTools EReg StringTools
		Lambda haxe.ds.Vector haxe.EnumFlags haxe.http.HttpBase haxe.crypto.Hmac haxe.crypto.Crc32
		haxe.zip.Huffman haxe.zip.InflateImpl haxe.io.Float32Array haxe.ds.HashMap";
	// compile-history.json: the fields of each run's per workload and runner array
	public static final FIELDS = ["wall_median", "wall_min", "wall_max", "cpu_median", "cpu_min", "cpu_max", "maxrss_mb"];
	static final DIR = "bin/bench";

	static function main() {
		var a = parseArgs(Sys.args(), ["-n", "-w", "-r", "--once", "--build-runs", "--out", "--source", "--summary", "--history", "--seed"]);
		if (a.has("--history")) {
			history(a.get("--history"), a.get("--seed"));
			return;
		}
		var runs = a.int("-n", 5);
		var workloads = a.has("-w") ? a.get("-w").split(",") : WORKLOADS;
		for (w in workloads) if (!WORKLOADS.contains(w)) fail('unknown workload $w (${WORKLOADS.join(", ")})');
		var once = a.has("--once") ? a.get("--once").split(",") : [];
		var names = a.has("-r") ? a.get("-r").split(",") : RUNNERS;
		for (o in once) if (!names.contains(o)) names.push(o);
		for (n in names) if (!RUNNERS.contains(n)) fail('unknown runner $n (${RUNNERS.join(", ")})');
		// (the reference's output is what the others are checked against)
		names = ["reference"].concat([for (n in RUNNERS) if (n != "reference" && names.contains(n)) n]);
		if (names.contains("hxmc-wasm-wasmtime") && exec(["sh", "-c", "command -v wasmtime"]).code != 0) {
			Sys.println("wasmtime is not on the PATH: hxmc-wasm-wasmtime skipped");
			names.remove("hxmc-wasm-wasmtime");
		}
		mkdirs(DIR);
		var std = Sys.getEnv("HAXE_STD_PATH") ?? root + "/haxe/upstream/std";
		Sys.putEnv("HAXE_STD_PATH", std);
		if (Sys.getEnv("HXMC_RT_DIR") == null && FileSystem.exists("bin/hxmc/rt")) Sys.putEnv("HXMC_RT_DIR", FileSystem.fullPath("bin/hxmc/rt"));
		var reference = FileSystem.fullPath(Sys.getEnv("HAXE_REFERENCE") ?? "bin/reference/haxe");
		var port = FileSystem.fullPath(Sys.getEnv("HAXE_IN_HAXE_PORT") ?? "bin/port/haxe");
		var wasm = FileSystem.fullPath(DIR) + "/haxe.wasm";
		var table:Map<String, Array<String>> = [
			"reference" => [reference],
			"hxmc" => [port],
			// (node 22: exception handling with exnref behind a flag; no fast API calls for WASI's fd_write)
			"hxmc-wasm-node" => ["node", "--experimental-wasm-exnref", "--no-turbo-fast-api-calls", "--no-warnings", "--stack-size=8000", root + "/hxmc/bootstrap/wasi.mjs", wasm],
			"hxmc-wasm-wasmtime" => ["wasmtime", "run", "-W", "exceptions=y", "-W", "max-wasm-stack=67108864", "--dir", "/", "--env", "HAXE_STD_PATH", "--env", "PWD", wasm],
		];
		var meta = metadata(reference, a.get("--source", Sys.getEnv("GITHUB_ACTIONS") == "true" ? "ci" : "local"), runs);
		var builds = new DynamicAccess<Dynamic>();
		var wantWasm = names.contains("hxmc-wasm-node") || names.contains("hxmc-wasm-wasmtime");
		if (a.has("--build")) {
			var n = a.int("--build-runs", runs);
			builds["native"] = build(DIR + "/port", [], n);
			Sys.println('build native ${Json.stringify(builds["native"])}');
			builds["wasm"] = build(wasm, ["-D", "hxmc.target=wasm32-wasi"], n);
			Sys.println('build wasm ${Json.stringify(builds["wasm"])}');
		} else if (wantWasm)
			build(wasm, ["-D", "hxmc.target=wasm32-wasi"], 1);
		var hello = root + "/hxmc/test/bench";
		var args:Map<String, {cwd:String, args:Array<String>}> = [
			"hello" => {cwd: hello, args: ["-cp", ".", "--main", "Hello"]},
			"stdlib" => {cwd: root, args: [for (s in ~/\s+/g.split(STDLIB.trim())) s]},
			"self" => {cwd: root, args: ["-cp", "haxe/src", "-main", "haxe.Main"]},
		];
		var tmp = FileSystem.fullPath(DIR) + "/compile-runs";
		var results = [];
		for (w in workloads) {
			rmrf(tmp);
			mkdirs(tmp);
			var samples = new Map<String, Array<Sample>>();
			var status = new Map<String, String>();
			var expected = '$tmp/expected.hxb';
			var count = (r:String) -> once.contains(r) && r != "reference" ? 1 : runs;
			for (round in 0...runs)
				for (r in names) {
					if (round >= count(r) || (status.exists(r) && status[r] != "ok")) continue;
					// (the reference's first archive is the expected one)
					var out = r == "reference" && round == 0 ? expected : '$tmp/$r-$round.hxb';
					var s = runOnce(table[r].concat(args[w].args).concat(["-D", "disable-parallelism", "--interp", "--no-output", "--hxb", out]), args[w].cwd, '$tmp/log.txt');
					if (s.error != null) {
						status[r] = s.error;
						Sys.println('${pad(w, 8)} ${pad(r, 20)} FAILED: ${s.error}');
						continue;
					}
					if (out != expected) {
						var d = compareHxb(expected, out);
						if (d != null) {
							status[r] = "output differs from reference: " + d;
							Sys.println('${pad(w, 8)} ${pad(r, 20)} ${status[r]}');
							continue;
						}
						FileSystem.deleteFile(out);
					}
					status[r] = "ok";
					if (!samples.exists(r)) samples[r] = [];
					samples[r].push(s);
				}
			for (r in names) {
				var ss = samples[r] ?? [];
				var ok = status[r] == "ok" && ss.length > 0;
				var wall = [for (s in ss) s.wall], cpu = [for (s in ss) s.cpu];
				var e:Dynamic = {
					workload: w,
					runner: r,
					status: status[r] ?? "not run",
					runs: ss.length,
					verified: ok && r != "reference",
					wall_min: ok ? round(min(wall), 3) : null,
					wall_median: ok ? round(median(wall), 3) : null,
					wall_max: ok ? round(max(wall), 3) : null,
					cpu_min: ok ? round(min(cpu), 3) : null,
					cpu_median: ok ? round(median(cpu), 3) : null,
					cpu_max: ok ? round(max(cpu), 3) : null,
					maxrss_mb: ok ? round(max([for (s in ss) s.rssMb]), 1) : null,
					date: meta.date,
				};
				results.push(e);
				if (ok)
					Sys.println('${pad(w, 8)} ${pad(r, 20)} ${fixed(e.wall_median, 3)} s (${fixed(e.wall_min, 3)}-${fixed(e.wall_max, 3)}), CPU ${fixed(e.cpu_median, 3)} s, ${fixed(e.maxrss_mb, 0)} MB, ${ss.length} runs');
			}
		}
		rmrf(tmp);
		var runners = new DynamicAccess<String>();
		for (r in names) runners[r] = [for (x in table[r]) x.startsWith(root + "/") ? x.substr(root.length + 1) : x].join(" ");
		var doc = {meta: meta, runners: runners, results: results, builds: builds};
		var outFile = a.get("--out", '$DIR/compile.json');
		File.saveContent(outFile, Json.stringify(doc, null, " ") + "\n");
		Sys.println('wrote $outFile');
		summary(a.get("--summary"), markdown(doc));
	}

	/** One run, with an unlimited stack: wall (s), CPU (user + system, s) and peak RSS (MB) of the process tree **/
	static function runOnce(cmd:Array<String>, cwd:String, log:String):Sample {
		var timeFile = log + ".time";
		var r = exec(["sh", "-c", 'ulimit -s unlimited 2>/dev/null; exec /usr/bin/time -f "%M %U %S" -o "$$0" "$$@"', timeFile].concat(cmd), {cwd: cwd, env: ["PWD" => cwd], log: log});
		if (r.code != 0) return {wall: 0, cpu: 0, rssMb: 0, error: 'exit ${r.code}: ' + tail(readText(log).trim(), 300).replace("\n", " | ")};
		var m = ~/([0-9]+) ([0-9.]+) ([0-9.]+)\s*$/;
		var s:Sample = {wall: r.seconds, cpu: 0, rssMb: 0, error: null};
		if (m.match(readText(timeFile))) {
			s.rssMb = Std.parseFloat(m.matched(1)) / 1024;
			s.cpu = Std.parseFloat(m.matched(2)) + Std.parseFloat(m.matched(3));
		}
		return s;
	}

	/** hxmc's cold build of the port to `out` (an empty object cache of its own), best of `n` **/
	static function build(out:String, extra:Array<String>, n:Int):Dynamic {
		var walls = [], cpus = [];
		var cache = FileSystem.fullPath(DIR) + "/build-cache";
		var log = FileSystem.fullPath(DIR) + "/build.log";
		// (out need not exist yet: fullPath fails on a missing file, so only its directory)
		var target = FileSystem.fullPath(haxe.io.Path.directory(out)) + "/" + haxe.io.Path.withoutDirectory(out);
		for (_ in 0...n) {
			rmrf(cache);
			rmrf(out + ".hxmc");
			var s = runOnce([FileSystem.fullPath("bin/hxmc/hxmc"), target, "-cp", "haxe/src", "-main", "haxe.Main", "-D", "disable-parallelism",
				"-D", "hxmc.gc-prefault", "-cp", "bin/hxmc/std", "--custom-target", "hxmc"].concat(extra), root, log);
			rmrf(cache);
			if (s.error != null) fail('hxmc failed to build $out: ${s.error}');
			walls.push(s.wall);
			cpus.push(s.cpu);
		}
		var gz = Std.parseInt(exec(["sh", "-c", 'gzip -9c "$$0" | wc -c', out]).out.trim());
		return {wall: round(min(walls), 2), cpu: round(min(cpus), 2), size: FileSystem.stat(out).size, gzip: gz};
	}

	static function metadata(reference:String, source:String, runs:Int):Dynamic {
		var first = (cmd:Array<String>) -> {
			var r = exec(cmd, {merge: true});
			var lines = [for (l in r.out.split("\n")) if (l.trim() != "") l.trim()];
			r.code == 0 && lines.length > 0 ? lines[0] : null;
		};
		var cpuinfo = readText("/proc/cpuinfo");
		var model = ~/model name\s*:\s*(.*)/;
		var mem = ~/MemTotal:\s*([0-9]+) kB/;
		var versions = new DynamicAccess<String>();
		versions["reference"] = first([reference, "-version"]);
		versions["node"] = first(["node", "--version"]);
		var wt = first(["sh", "-c", "command -v wasmtime >/dev/null && wasmtime --version"]);
		if (wt != null) versions["wasmtime"] = wt;
		var runId = Sys.getEnv("GITHUB_RUN_ID");
		return {
			date: DateTools.format(Date.fromTime(Date.now().getTime() + Date.now().getTimezoneOffset() * 60000), "%Y-%m-%d %H:%M UTC"),
			commit: exec(["git", "rev-parse", "--short=7", "HEAD"]).out.trim(),
			source: source,
			runs: runs,
			run_url: runId != null ? '${Sys.getEnv("GITHUB_SERVER_URL")}/${Sys.getEnv("GITHUB_REPOSITORY")}/actions/runs/$runId' : null,
			cpu: model.match(cpuinfo) ? model.matched(1).trim() : null,
			cores: cpus(),
			memory_gb: mem.match(readText("/proc/meminfo")) ? round(Std.parseFloat(mem.matched(1)) / 1048576, 1) : null,
			os: exec(["uname", "-sr"]).out.trim(),
			runner: Sys.getEnv("RUNNER_NAME") != null ? (Sys.getEnv("ImageOS") ?? "github") + " " + (Sys.getEnv("ImageVersion") ?? "") : null,
			versions: versions,
		};
	}

	static function markdown(doc:Dynamic):String {
		var b = new StringBuf();
		b.add('### Compiler benchmarks (${doc.meta.commit}, median wall time of ${doc.meta.runs} runs)\n\n| workload | runner | wall | min-max | CPU | peak RSS | vs. reference |\n| --- | --- | ---: | ---: | ---: | ---: | ---: |\n');
		var ref = new Map<String, Float>();
		for (e in (doc.results : Array<Dynamic>)) if (e.runner == "reference" && e.wall_median != null) ref[e.workload] = e.wall_median;
		for (e in (doc.results : Array<Dynamic>)) {
			if (e.wall_median == null) {
				b.add('| ${e.workload} | ${e.runner} | ${e.status} | | | | |\n');
				continue;
			}
			var r = ref[e.workload];
			b.add('| ${e.workload} | ${e.runner} | ${fixed(e.wall_median, 3)} s | ${fixed(e.wall_min, 2)}-${fixed(e.wall_max, 2)} | ${fixed(e.cpu_median, 3)} s | ${fixed(e.maxrss_mb, 0)} MB | ${r != null ? fixed(e.wall_median / r, 2) + "x" : ""} |\n');
		}
		var bs:DynamicAccess<Dynamic> = doc.builds;
		for (k => v in bs) b.add('\nbuild $k: ${v.wall} s wall, ${v.cpu} s CPU, ${v.size} bytes (${v.gzip} gzipped)');
		return b.toString() + "\n\n";
	}

	// ---- history (the bench-data branch)

	static function history(dir:String, seed:Null<String>) {
		var files = FileSystem.exists('$dir/compile') ? [for (f in FileSystem.readDirectory('$dir/compile')) if (f.endsWith(".json")) f] : [];
		var runs:Array<Dynamic> = [];
		var latest = null, latestAny = null;
		var docs = [for (f in files) {file: f, doc: (Json.parse(File.getContent('$dir/compile/$f')) : Dynamic)}];
		docs.sort((x, y) -> compare(x.doc.meta.date, y.doc.meta.date));
		for (d in docs) {
			runs.push(entry("compile/" + d.file, d.doc));
			if (d.doc.meta.source == "ci") latest = d.file;
			latestAny = d.file;
		}
		// the seed's runs that no file of the directory has (the same commit and date)
		if (seed != null && FileSystem.exists(seed)) {
			var seen = [for (r in runs) r.commit + " " + r.date => true];
			for (r in (Json.parse(File.getContent(seed)).runs : Array<Dynamic>)) if (!seen.exists(r.commit + " " + r.date)) runs.push(r);
		}
		runs.sort((x, y) -> compare(x.date, y.date));
		File.saveContent('$dir/compile-history.json', Json.stringify({schema: 1, fields: FIELDS, runners: RUNNERS, workloads: WORKLOADS, runs: runs}) + "\n");
		if (latest == null) latest = latestAny;
		if (latest != null) File.copy('$dir/compile/$latest', '$dir/compile-latest.json');
		Sys.println('$dir/compile-history.json: ${runs.length} runs' + (latest != null ? ', compile-latest.json: $latest' : ""));
	}

	/** a results file (the format of site/data/bench.json) as a run of compile-history.json **/
	public static function entry(file:String, doc:Dynamic):Dynamic {
		var res = new DynamicAccess<DynamicAccess<Array<Null<Float>>>>();
		for (e in (doc.results : Array<Dynamic>)) {
			if (e.wall_median == null) continue;
			if (!res.exists(e.workload)) res[e.workload] = new DynamicAccess();
			res[e.workload][e.runner] = [for (f in FIELDS) (Reflect.field(e, f) : Null<Float>)];
		}
		var m = doc.meta;
		return {
			file: file,
			date: m.date,
			commit: m.commit,
			source: m.source ?? "local",
			machine: m.cpu == null ? null : m.cpu + (m.cores != null ? ', ${m.cores} cores' : ""),
			runs: m.runs,
			run_url: m.run_url,
			results: res,
			builds: doc.builds,
		};
	}

	static function median(xs:Array<Float>):Float {
		var s = xs.copy();
		s.sort((a, b) -> a < b ? -1 : a > b ? 1 : 0);
		var n = s.length;
		return n % 2 == 1 ? s[n >> 1] : (s[(n >> 1) - 1] + s[n >> 1]) / 2;
	}

	static function min(xs:Array<Float>):Float return Lambda.fold(xs, Math.min, xs[0]);

	static function max(xs:Array<Float>):Float return Lambda.fold(xs, Math.max, xs[0]);

	static function round(x:Float, digits:Int):Float {
		var m = Math.pow(10, digits);
		return Math.round(x * m) / m;
	}
}

typedef Sample = {wall:Float, cpu:Float, rssMb:Float, error:Null<String>};
