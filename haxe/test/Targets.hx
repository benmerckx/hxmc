import Harness.*;
import haxe.io.Bytes;
import sys.FileSystem;
import sys.io.File;

using StringTools;

// Compile time and output of the target generators, for the website's target
// table (site/data/targets.json, or the bench-data branch's targets.json):
// the reference and the port compile the same projects to every target; the
// outputs must be identical.
//   bin/hxmc/hxmc -cp haxe/test --run Targets [-n RUNS] [-p formatter,self]
//       [-t js,lua,...] [--modes seq,par] [--port <exe>] [--reference <exe>]
//       [--bench <dir>] [--shard <n>] [--json <file>] [--merge]
//   bin/hxmc/hxmc -cp haxe/test --run Targets --join <out.json> <part.json>...
//   bin/hxmc/hxmc -cp haxe/test --run Targets --history <dir>
// Projects:
//   formatter  haxe-formatter with its libraries (Bench.hx's setup: <bench>/runner
//              and <bench>/libs, bin/bench by default, else bin/haxebench), the
//              HaxeBenchmarks formatter_noio case; -lib hxnodejs from Bench's
//              lix scope (<bench>/scope) when there is one, else haxelib
//   self       the port's own source (haxe/src, haxe.Main)
// Modes (--modes, both by default): `seq` runs each compiler with
// -D disable-parallelism (per-core efficiency: CPU time), `par` with its
// default parallelism (what users get: wall time). Each run is a fresh
// process, both compilers in the same directory (bin/bench-targets/cwd: some
// outputs embed it), one row's runs all on this machine. CPU is user + system
// time and the peak RSS that of /usr/bin/time; CPU and wall are the best of
// RUNS, the peak the largest. The outputs of the last runs are compared: files
// and directories byte for byte, JARs and HXB archives member by member (their
// order ignored); hl/c's digest names that depend on the reference's machine
// code are renamed on both sides first (HlcNames). A parallel output that
// differs from the reference's parallel output is `varies` when the
// reference's own parallel output differs from its sequential one (the
// generator's parallel order, e.g. genjvm's closures: not comparable byte for
// byte; reference_repeats, port_repeats: whether each one's first and last
// parallel runs agree), else different. --merge replaces only the measured project/target
// rows of an existing --json file.
//
// --join <out> <part>...: the parts of a sharded run (bench.yml: the targets
// in groups, each group on its own machine, both compilers of a row on the
// same one) into one file, the rows in project and target order, each with
// its part's `shard`, and the parts' machines in the meta.
// --history <dir>: <dir>/targets/*.json (one per run, the bench-data branch,
// named <date>-<commit>.json) into <dir>/targets-history.json (per run: date,
// commit, and per project/target the sequential CPU and parallel wall times of
// both compilers) and <dir>/targets.json (the newest run), which the website
// reads.
class Targets {
	static final WORK = "bin/bench-targets";
	static final FMT_CPS = ["formatter/src", "tokentree/src", "haxeparser/src", "hxparse/src", "json2object/src", "hxargs", "hxjsonast/src"];
	static final PROJECTS = ["formatter", "self"];
	static final TARGETS:Array<{name:String, args:Array<String>, output:String}> = [
		{name: "hxb", args: ["--interp", "--no-output", "--hxb", "out/out.zip"], output: "zip:out/out.zip"},
		{name: "js", args: ["--js", "out/main.js"], output: "file:out/main.js"},
		{name: "lua", args: ["--lua", "out/main.lua"], output: "file:out/main.lua"},
		{name: "python", args: ["--python", "out/main.py"], output: "file:out/main.py"},
		{name: "php", args: ["--php", "out/php"], output: "dir:out/php"},
		{name: "neko", args: ["--neko", "out/main.n"], output: "file:out/main.n"},
		{name: "hl", args: ["--hl", "out/main.hl"], output: "file:out/main.hl"},
		{name: "hlc", args: ["--hl", "out/hlc/main.c", "-D", "no-compilation"], output: "dir:out/hlc"},
		{name: "cpp", args: ["--cpp", "out/cpp", "-D", "no-compilation"], output: "dir:out/cpp"},
		{name: "jvm", args: ["--jvm", "out/main.jar"], output: "zip:out/main.jar"},
		{name: "swf", args: ["--swf", "out/main.swf"], output: "file:out/main.swf"},
	];

	static function project(name:String, target:String):Array<String> {
		return switch name {
			case "self":
				["-cp", root + "/haxe/src", "-main", "haxe.Main"];
			case "formatter":
				var libs = benchDir + "/libs";
				var a = ["-cp", benchDir + "/runner/cases/formatter_noio", "-main", "BMFormatterNoIOCode"];
				for (d in FMT_CPS) a = a.concat(["-cp", '$libs/$d']);
				for (d in FMT_CPS) a = a.concat(["-D", d.split("/")[0]]);
				if (target == "js") a = a.concat(["-lib", "hxnodejs"]);
				a;
			case _: fail("unknown project " + name);
		}
	}

	static var root:String;
	static var benchDir:String;
	static var env:Map<String, Null<String>> = [];

	static function main() {
		var a = parseArgs(Sys.args(), ["-n", "-p", "-t", "--port", "--reference", "--json", "--modes", "--bench", "--shard", "--join", "--history"]);
		root = FileSystem.fullPath(".");
		if (a.has("--join")) {
			join(a.get("--join"), a.rest);
			return;
		}
		if (a.has("--history")) {
			history(a.get("--history"));
			return;
		}
		var runs = Std.parseInt(a.get("-n", "3"));
		var projects = a.get("-p", PROJECTS.join(",")).split(",");
		var targets = a.get("-t", [for (t in TARGETS) t.name].join(",")).split(",");
		var modes = a.get("--modes", "seq,par").split(",");
		for (m in modes) if (m != "seq" && m != "par") fail("unknown mode " + m + " (seq, par)");
		var seq = modes.contains("seq"), par = modes.contains("par");
		var port = FileSystem.fullPath(a.get("--port", Sys.getEnv("HAXE_IN_HAXE_PORT") ?? "bin/port/haxe"));
		var reference = FileSystem.fullPath(a.get("--reference", Sys.getEnv("HAXE_REFERENCE") ?? "bin/reference/haxe"));
		var json = a.get("--json");
		var shard = a.has("--shard") ? a.int("--shard", 0) : null;
		benchDir = FileSystem.fullPath(a.get("--bench", !FileSystem.exists("bin/bench/libs") && FileSystem.exists("bin/haxebench/libs") ? "bin/haxebench" : "bin/bench"));
		if (projects.contains("formatter") && !FileSystem.exists(benchDir + "/libs/formatter"))
			fail('$benchDir/libs is missing (bin/hxmc/hxmc -cp hxmc/test -cp haxe/test --run Bench --setup -t js)');
		// (Bench's lix scope: hxnodejs for -lib, as Bench resolves it)
		if (FileSystem.exists(benchDir + "/scope/.haxerc")) {
			env["HAXESHIM_ROOT"] = benchDir + "/scope/lix-root";
			env["HAXESHIM_SCOPE"] = benchDir + "/scope";
			env["PATH"] = root + "/bin/lix:" + Sys.getEnv("PATH");
		}
		var std = root + "/haxe/upstream/std";
		Sys.putEnv("HAXE_STD_PATH", std);
		Sys.putEnv("HAXE_IN_HAXE_STD_PATH", std);
		mkdirs(WORK);
		var results:Array<Dynamic> = [];
		var merge = a.has("--merge");
		var meta = () -> machineMeta(runs, modes, port, reference, shard);
		for (p in projects) for (tn in targets) {
			var t = [for (t in TARGETS) if (t.name == tn) t][0];
			if (t == null) fail("unknown target " + tn);
			var args = project(p, tn).concat(t.args);
			var row:Dynamic = {project: p, target: tn, reference: null, port: null, identical: null};
			var line = '${pad(p, 10)} ${pad(tn, 7)}';
			var refSeq:Null<Map<String, Bytes>> = null, portSeq:Null<Map<String, Bytes>> = null;
			var rejected = false;
			if (seq) {
				var s = side(reference, port, args.concat(["-D", "disable-parallelism"]), t.output, runs);
				row.reference = s.ref.row;
				row.port = s.ours == null ? null : s.ours.row;
				row.identical = s.identical;
				if (s.diff != null) row.diff = s.diff;
				refSeq = s.ref.out;
				portSeq = s.ours == null ? null : s.ours.out;
				rejected = s.ref.row.status != "ok";
				line += " seq " + s.line;
			}
			if (par && !rejected) {
				var s = side(reference, port, args, t.output, runs, "wall");
				var pr:Dynamic = {reference: s.ref.row, port: s.ours == null ? null : s.ours.row, identical: s.identical};
				if (s.diff != null) {
					pr.diff = s.diff;
					// (the reference's own parallel output against its sequential one, the port's likewise)
					if (refSeq != null) pr.reference_stable = compare(refSeq, s.ref.out) == null;
					if (portSeq != null && s.ours != null) pr.port_stable = compare(portSeq, s.ours.out) == null;
					// (its first run's against its last: the same from run to run?)
					if (s.ref.first != null) pr.reference_repeats = compare(s.ref.first, s.ref.out) == null;
					if (s.ours != null && s.ours.first != null) pr.port_repeats = compare(s.ours.first, s.ours.out) == null;
					pr.varies = pr.reference_stable == false;
				}
				if (!seq) {
					row.reference = s.ref.row;
					row.port = pr.port;
				}
				row.parallel = pr;
				line += "  par " + s.line + (pr.varies == true ? " (the reference's parallel output differs from its sequential one: varies)" : "");
			}
			Sys.println(line);
			results.push(row);
			if (json != null) write(json, results, merge, meta());
		}
		if (json != null) write(json, results, merge, meta());
	}

	/** both compilers on one mode: the reference first, the port when the reference compiles the project; `metric`: the time printed **/
	static function side(reference:String, port:String, args:Array<String>, output:String, runs:Int, metric = "cpu") {
		var keep = metric == "wall";
		var ref = bench(reference, args, output, runs, keep);
		if (ref.row.status != "ok")
			return {ref: ref, ours: null, identical: null, diff: null, line: 'reference fails: ${tail(ref.row.status, 120)}'};
		var ours = bench(port, args, output, runs, keep);
		if (ours.row.status != "ok")
			return {ref: ref, ours: ours, identical: false, diff: null, line: 'port fails: ${tail(ours.row.status, 120)}'};
		var d = compare(ref.out, ours.out);
		var r:Float = Reflect.field(ref.row, metric), o:Float = Reflect.field(ours.row, metric);
		return {
			ref: ref,
			ours: ours,
			identical: d == null,
			diff: d,
			line: 'ref ${fixed(r, 2)}s ${Math.round(ref.row.rss_mb)} MB  port ${fixed(o, 2)}s ${Math.round(ours.row.rss_mb)} MB  ${fixed(o / r, 2)}x ($metric)  '
				+ (d == null ? "identical" : "DIFFERENT (" + d + ")")
		};
	}

	/** `first`: the output of the first run too (with RUNS > 1), for whether the compiler repeats itself **/
	static function bench(compiler:String, args:Array<String>, output:String, runs:Int, keepFirst = false):{row:Dynamic, out:Null<Map<String, Bytes>>, first:Null<Map<String, Bytes>>} {
		var cwd = FileSystem.fullPath(WORK) + "/cwd";
		var log = FileSystem.fullPath(WORK) + "/log.txt";
		var best:Dynamic = null;
		var first = null;
		for (i in 0...runs) {
			rmrf(cwd);
			mkdirs(cwd + "/out");
			var time = FileSystem.exists("/usr/bin/time") ? ["/usr/bin/time", "-f", "MEASURE %M %U %S"] : [];
			var r = exec(time.concat([compiler]).concat(args), {cwd: cwd, log: log, env: env});
			var text = readText(log);
			if (r.code != 0) {
				var lines = [for (l in text.split("\n")) if (l.trim() != "" && l.trim() != "|" && !l.startsWith("MEASURE ") && !l.startsWith("Command exited with non-zero status")) l.trim()];
				return {row: {status: 'exit ${r.code}: ' + lines.slice(lines.length > 3 ? lines.length - 3 : 0).join(" | ")}, out: null, first: null};
			}
			var cpu = 0.0, rss = 0.0;
			var m = ~/MEASURE ([0-9]+) ([0-9.]+) ([0-9.]+)/;
			if (m.match(text)) {
				rss = Std.parseFloat(m.matched(1)) / 1024;
				cpu = Std.parseFloat(m.matched(2)) + Std.parseFloat(m.matched(3));
			}
			if (best == null) best = {cpu: cpu, wall: r.seconds, rss_mb: rss} else {
				best.cpu = Math.min(best.cpu, cpu);
				best.wall = Math.min(best.wall, r.seconds);
				best.rss_mb = Math.max(best.rss_mb, rss);
			}
			if (keepFirst && i == 0 && runs > 1) first = snapshot(output, cwd);
		}
		var out = snapshot(output, cwd);
		best.status = "ok";
		best.members = out == null ? 0 : [for (k in out.keys()) k].length;
		var bytes = 0;
		if (out != null) for (v in out) bytes += v.length;
		best.bytes = bytes;
		return {row: best, out: out, first: first};
	}

	// the output as member => bytes
	static function snapshot(output:String, cwd:String):Null<Map<String, Bytes>> {
		var i = output.indexOf(":");
		var kind = output.substr(0, i), p = cwd + "/" + output.substr(i + 1);
		if (!FileSystem.exists(p)) return null;
		return switch kind {
			case "file": ["" => File.getBytes(p)];
			case "dir": [for (f in walk(p)) f => File.getBytes('$p/$f')];
			case _:
				var z = readZip(p);
				[for (n in z.names) if (!n.endsWith("/")) n => z.data[n]];
		}
	}

	static function compare(a:Null<Map<String, Bytes>>, b:Null<Map<String, Bytes>>):Null<String> {
		if (a == null || b == null) return a == b ? null : "no output on one side";
		if (HlcNames.isHlc([for (k in a.keys()) k])) {
			var n = HlcNames.normalize(a, b);
			a = n.a;
			b = n.b;
		}
		var names = [for (k in a.keys()) k];
		for (k in b.keys()) if (!a.exists(k)) names.push(k);
		names.sort(Harness.compare);
		var bad = [for (n in names) if (!a.exists(n) || !b.exists(n) || a[n].compare(b[n]) != 0) n];
		return bad.length == 0 ? null : '${bad.length} of ${names.length} differ: ${bad.slice(0, 3).join(", ")}';
	}

	/** this run's facts: the machine, the compilers, how it measured **/
	static function machineMeta(runs:Int, modes:Array<String>, port:String, reference:String, shard:Null<Int>):Array<{k:String, v:Dynamic}> {
		var cpu = null;
		if (FileSystem.exists("/proc/cpuinfo")) for (l in File.getContent("/proc/cpuinfo").split("\n")) if (l.startsWith("model name")) {
			cpu = l.substr(l.indexOf(":") + 1).trim();
			break;
		}
		var version = exec([reference, "--version"]).out.trim().split("\n")[0];
		var meta:Array<{k:String, v:Dynamic}> = [
			{k: "date", v: DateTools.format(Date.now(), "%Y-%m-%dT%H:%M:%S")},
			{k: "commit", v: exec(["git", "-C", root, "rev-parse", "--short", "HEAD"]).out.trim()},
			{k: "cpu", v: cpu},
			{k: "cores", v: cpus()},
			{k: "runs", v: runs},
			{k: "modes", v: modes},
			{k: "port", v: port.startsWith(root + "/") ? port.substr(root.length + 1) : port},
			{k: "reference", v: version.split("+")[0]},
			{k: "platform", v: [for (o in ["-s", "-r", "-m"]) exec(["uname", o]).out.trim()].join("-")}
		];
		if (Sys.getEnv("GITHUB_RUN_ID") != null) {
			meta.push({k: "runner", v: (Sys.getEnv("ImageOS") ?? "github") + " " + (Sys.getEnv("ImageVersion") ?? "")});
			meta.push({k: "run_url", v: '${Sys.getEnv("GITHUB_SERVER_URL")}/${Sys.getEnv("GITHUB_REPOSITORY")}/actions/runs/${Sys.getEnv("GITHUB_RUN_ID")}'});
		}
		if (shard != null) meta.push({k: "shard", v: shard});
		return meta;
	}

	// The file as Python's `json.dump(..., indent=1)` wrote it (the format it has
	// had): with --merge, the measured rows and the meta replace theirs in the
	// existing text and every other row stays as it is.
	static function write(path:String, results:Array<Dynamic>, merge:Bool, meta:Array<{k:String, v:Dynamic}>) {
		var metaText = obj(meta, 1);
		var rows = [for (r in results) rowText(r)];
		var text = merge && FileSystem.exists(path) ? File.getContent(path) : null;
		if (text == null) {
			text = '{\n "meta": $metaText,\n "results": [\n' + [for (r in rows) "  " + r].join(",\n") + "\n ]\n}";
		} else {
			var m = text.indexOf('"meta": {'), e = text.indexOf("\n }", m);
			if (m < 0 || e < 0) fail(path + ": no meta");
			text = text.substr(0, m) + '"meta": ' + metaText + text.substr(e + 3);
			for (i in 0...results.length) {
				var r = results[i];
				var head = '\n  {\n   "project": ${haxe.Json.stringify(r.project)},\n   "target": ${haxe.Json.stringify(r.target)},';
				var s = text.indexOf(head);
				if (s >= 0) {
					var end = text.indexOf("\n  }", s + head.length);
					text = text.substr(0, s + 3) + rows[i] + text.substr(end + 4);
				} else {
					var end = text.lastIndexOf("\n ]");
					text = text.substr(0, end) + ",\n  " + rows[i] + text.substr(end);
				}
			}
		}
		File.saveContent(path, text);
	}

	static function sideText(s:Dynamic, level:Int):Dynamic {
		if (s == null) return null;
		if (s.status != "ok") return new Raw(obj([{k: "status", v: s.status}], level));
		return new Raw(obj([
			{k: "cpu", v: s.cpu}, {k: "wall", v: s.wall}, {k: "rss_mb", v: s.rss_mb}, {k: "status", v: s.status},
			{k: "members", v: s.members}, {k: "bytes", v: s.bytes}
		], level));
	}

	/** the fields present in `o` of `keys` **/
	static function present(o:Dynamic, keys:Array<String>):Array<{k:String, v:Dynamic}> {
		return [for (k in keys) if (Reflect.hasField(o, k) && Reflect.field(o, k) != null) {k: k, v: Reflect.field(o, k)}];
	}

	static function rowText(r:Dynamic):String {
		var fields:Array<{k:String, v:Dynamic}> = [
			{k: "project", v: r.project}, {k: "target", v: r.target}, {k: "reference", v: sideText(r.reference, 3)}, {k: "port", v: sideText(r.port, 3)},
			{k: "identical", v: r.identical}
		];
		fields = fields.concat(present(r, ["diff"]));
		if (r.parallel != null) {
			var p:Dynamic = r.parallel;
			var pf:Array<{k:String, v:Dynamic}> = [
				{k: "reference", v: sideText(p.reference, 4)}, {k: "port", v: sideText(p.port, 4)}, {k: "identical", v: p.identical}
			];
			fields.push({k: "parallel", v: new Raw(obj(pf.concat(present(p, ["diff", "reference_stable", "port_stable", "reference_repeats", "port_repeats", "varies"])), 3))});
		}
		return obj(fields.concat(present(r, ["shard"])), 2);
	}

	// ---- a sharded run's parts as one file

	static function join(out:String, parts:Array<String>) {
		if (parts.length == 0) fail("--join: no parts");
		var docs:Array<Dynamic> = [for (p in parts) haxe.Json.parse(File.getContent(p))];
		docs.sort((a, b) -> (a.meta.shard ?? 0) - (b.meta.shard ?? 0));
		var rows:Array<Dynamic> = [];
		for (d in docs) for (r in (d.results : Array<Dynamic>)) {
			if (d.meta.shard != null) r.shard = d.meta.shard;
			rows = rows.filter(x -> x.project != r.project || x.target != r.target);
			rows.push(r);
		}
		function order(r:Dynamic):Int {
			var t = 0;
			for (i => x in TARGETS) if (x.name == r.target) t = i;
			return PROJECTS.indexOf(r.project) * 100 + t;
		}
		rows.sort((a, b) -> order(a) - order(b));
		var first:Dynamic = docs[0].meta;
		var cpus = [];
		for (d in docs) if (d.meta.cpu != null && !cpus.contains(d.meta.cpu)) cpus.push(d.meta.cpu);
		var meta:Array<{k:String, v:Dynamic}> = present(first, ["date", "commit"]);
		meta.push({k: "cpu", v: cpus.join(" / ")});
		meta = meta.concat(present(first, ["cores", "runs", "modes", "port", "reference", "platform", "runner", "run_url"]));
		meta.push({
			k: "machines",
			v: new Raw("[" + [for (d in docs) obj(present(d.meta, ["shard", "cpu", "cores", "runner"]).concat([{
				k: "rows",
				v: [for (r in (d.results : Array<Dynamic>)) r.project + "/" + r.target]
			}]), 3)].join(", ") + "]")
		});
		write(out, rows, false, meta);
		Sys.println('$out: ${rows.length} rows from ${docs.length} parts (${cpus.join(" / ")})');
	}

	// ---- the history (the bench-data branch)

	static function history(dir:String) {
		var files = FileSystem.exists('$dir/targets') ? [for (f in FileSystem.readDirectory('$dir/targets')) if (f.endsWith(".json")) f] : [];
		if (files.length == 0) fail('$dir/targets: no results');
		files.sort(Harness.compare);
		var runs = [];
		for (f in files) {
			var d:Dynamic = haxe.Json.parse(File.getContent('$dir/targets/$f'));
			var rows:haxe.DynamicAccess<Dynamic> = {};
			for (r in (d.results : Array<Dynamic>)) {
				function t(s:Dynamic, k:String):Null<Float> return s == null || s.status != "ok" ? null : Reflect.field(s, k);
				var p:Dynamic = r.parallel;
				// sequential CPU (reference, port), parallel wall (reference, port), outputs identical (sequential, parallel)
				var v:Array<Dynamic> = [
					t(r.reference, "cpu"), t(r.port, "cpu"), p == null ? null : t(p.reference, "wall"), p == null ? null : t(p.port, "wall"),
					r.identical, p == null ? null : p.identical
				];
				if (v[0] != null || v[2] != null) rows[r.project + "/" + r.target] = v;
			}
			runs.push({
				file: f,
				date: d.meta.date,
				commit: d.meta.commit,
				cpu: d.meta.cpu,
				run_url: d.meta.run_url,
				rows: rows
			});
		}
		File.saveContent('$dir/targets-history.json', haxe.Json.stringify({
			fields: ["seq_reference_cpu", "seq_port_cpu", "par_reference_wall", "par_port_wall", "seq_identical", "par_identical"],
			runs: runs
		}));
		File.copy('$dir/targets/${files[files.length - 1]}', '$dir/targets.json');
		Sys.println('$dir: targets.json from ${files[files.length - 1]}, targets-history.json of ${runs.length} runs');
	}

	static function obj(fields:Array<{k:String, v:Dynamic}>, level:Int):String {
		var ind = "".lpad(" ", level + 1);
		return "{\n" + [for (f in fields) ind + haxe.Json.stringify(f.k) + ": " + value(f.v)].join(",\n") + "\n" + "".lpad(" ", level) + "}";
	}

	static function value(v:Dynamic):String {
		if (Std.isOfType(v, Raw)) return (v : Raw).text;
		// a measured time or size: 6 decimals (the parsed rows keep their text)
		if (Std.isOfType(v, Float) && !Std.isOfType(v, Int)) {
			var f:Float = v;
			var n = Std.string(Math.round(Math.abs(f) * 1e6)).lpad("0", 7);
			var s = n.substr(0, n.length - 6) + "." + n.substr(n.length - 6);
			while (s.endsWith("0") && !s.endsWith(".0")) s = s.substr(0, s.length - 1);
			return (f < 0 ? "-" : "") + s;
		}
		return haxe.Json.stringify(v);
	}
}

private class Raw {
	public final text:String;

	public function new(text:String) this.text = text;
}
