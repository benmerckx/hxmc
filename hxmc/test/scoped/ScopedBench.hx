import Harness.*;
import sys.FileSystem;

using StringTools;

// Scoped memory against ordinary hxmc Haxe (docs/plans/lowlevel.md, "Scoped
// memory"): each program has a scoped version and a GC one, which must print
// the same. Table: the maps' index (hxmc.rt.MapIndex) on both faces.
//   bin/hxmc/hxmc -cp hxmc/test/scoped -cp haxe/test --run ScopedBench [-n RUNS] [--wasm] [--large] [case ...]
// Reported per program, size and version: the median wall time of RUNS runs
// and the peak RSS (/usr/bin/time), Linux; with --large a larger size too.
class ScopedBench {
	static final CASES = [{name: "Table", sizes: [1000000, 8000000]}];
	static final OUT = "bin/scoped-bench";

	static function main() {
		var a = parseArgs(Sys.args(), ["-n"]);
		var runs = a.int("-n", 5);
		var wasm = a.has("--wasm"), large = a.has("--large");
		var cases = a.rest.length == 0 ? CASES : CASES.filter(c -> a.rest.contains(c.name));
		mkdirs(OUT);
		var rows = [];
		for (c in cases) {
			var exe = OUT + "/" + c.name;
			var b = exec(["bin/hxmc/hxmc", exe, "-cp", "hxmc/test/scoped", "-cp", "bin/hxmc/std", "-main", c.name, "--custom-target", "hxmc"]);
			if (b.code != 0) fail(c.name + ": " + b.out + b.err);
			if (wasm) {
				var w = exec(["bin/hxmc/hxmc", exe + ".wasm", "-cp", "hxmc/test/scoped", "-cp", "bin/hxmc/std", "-main", c.name, "--custom-target", "hxmc", "-D", "hxmc.target=wasm32-wasi"]);
				if (w.code != 0) fail(c.name + " (wasm32): " + w.out + w.err);
			}
			for (size in (large ? c.sizes : [c.sizes[0]])) {
				var n = Std.string(size);
				var cmds = [["scoped", exe, "scoped", n], ["gc", exe, "gc", n]];
				if (wasm) {
					var node = ["node", "--no-warnings", FileSystem.fullPath("hxmc/bootstrap/wasi.mjs"), exe + ".wasm"];
					cmds.push(["scoped wasm32"].concat(node).concat(["scoped", n]));
					cmds.push(["gc wasm32"].concat(node).concat(["gc", n]));
				}
				var expected:Null<String> = null;
				for (cmd in cmds) {
					var times = [], rss = 0;
					for (_ in 0...runs) {
						var r = exec(["/usr/bin/time", "-f", "@@ %e %M"].concat(cmd.slice(1)), {env: ["RT_DATA_STACK_MB" => "400"]});
						var at = r.err.lastIndexOf("@@ ");
						if (r.code != 0 || at < 0) fail(cmd.join(" ") + ": " + r.out + r.err);
						var f = r.err.substr(at + 3).trim().split(" ");
						times.push(Std.parseFloat(f[0]));
						rss = Std.int(Math.max(rss, Std.parseInt(f[1])));
						if (expected == null) expected = r.out else if (r.out != expected) fail(c.name + " " + cmd[0] + " prints something else:\n" + r.out);
					}
					times.sort(Reflect.compare);
					rows.push({name: c.name, size: n, version: cmd[0], time: times[times.length >> 1], rss: rss});
					Sys.println('${pad(c.name, 12)} ${pad(n, 9)} ${pad(cmd[0], 14)} ${fixed(times[times.length >> 1], 2)} s  ${Std.int(rss / 1024)} MB');
				}
			}
		}
		Sys.println("\n| Program | Size | Version | Time (s) | Peak RSS (MB) |\n| --- | ---: | --- | ---: | ---: |");
		for (r in rows)
			Sys.println('| ${r.name} | ${r.size} | ${r.version} | ${fixed(r.time, 2)} | ${Std.int(r.rss / 1024)} |');
	}
}
