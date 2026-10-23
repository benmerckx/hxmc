import Harness.*;
import sys.FileSystem;

using StringTools;

// Mir macros as a smoke and speed check on a target's machine (the CI test
// job's Mir lane, docs/testing.md): two macro workloads of the HaxeBenchmarks
// cases, timed with the compiler built with -D hxmc.jit (-D hxmc.mir-macros)
// and with a compiler whose macros run on Eval (the release binary), on the
// same machine:
//   json       BMJsonCode.main() as an initialization macro (--macro, --no-output)
//   formatter  haxe-formatter's benchmark typed with json2object's macros
//              (--interp --no-output: the macros, nothing run)
//
//   <haxe> -cp hxmc/test -cp haxe/test --run MirBench --fetch <dir>
//   <haxe> -cp hxmc/test -cp haxe/test --run MirBench --dir <dir> --mir "<compiler> -D hxmc.mir-macros"
//       --eval <compiler> [-n RUNS] [--summary <file>]
// --fetch: the cases and the formatter's libraries (pinned as Bench's) into <dir>.
// Each workload runs RUNS times (default 3) per compiler, the compilers
// interleaved, the module cache off; reported: the median wall time. A run
// that fails fails the check.
@:access(Bench)
class MirBench {
	static function main() {
		var a = parseArgs(Sys.args(), ["--fetch", "--dir", "--mir", "--eval", "-n", "--summary"]);
		if (a.has("--fetch")) {
			var dir = a.get("--fetch");
			Bench.fetch(Bench.RUNNER.repo, Bench.RUNNER.commit, '$dir/runner');
			for (l in Bench.LIBS)
				if (l.dir != "crypto") Bench.fetch(l.repo, l.commit, '$dir/libs/${l.dir}');
			// (the checkouts packed without their repositories)
			for (x in ['$dir/runner'].concat([for (l in Bench.LIBS) if (l.dir != "crypto") '$dir/libs/${l.dir}']))
				rmrf('$x/.git');
			Sys.println('MirBench: the cases and libraries in $dir');
			return;
		}
		var dir = FileSystem.fullPath(a.get("--dir"));
		var runs = a.int("-n", 3);
		var compilers = [{name: "Mir macros", cmd: shellSplit(a.get("--mir"))}, {name: "Eval", cmd: shellSplit(a.get("--eval"))}];
		var cases = '$dir/runner/cases';
		var libs = [for (d in Bench.FORMATTER_CPS) ["-cp", '$dir/libs/$d']];
		var defines = [for (d in Bench.FORMATTER_CPS) ["-D", d.split("/")[0]]];
		var workloads = [
			{
				name: "json as a macro",
				cwd: '$cases/json/out',
				args: ["-cp", "..", "--macro", "BMJsonCode.main()", "--no-output"]
			},
			{
				name: "formatter build (json2object's macros)",
				cwd: '$cases/formatter_noio',
				args: Lambda.flatten(libs).concat(Lambda.flatten(defines)).concat(["-cp", ".", "-main", "BMFormatterNoIOCode", "--interp", "--no-output"])
			}
		];
		var bad = 0;
		var rows = [];
		for (w in workloads) {
			mkdirs(w.cwd);
			var times = [for (_ in compilers) []];
			for (r in 0...runs)
				for (k in 0...compilers.length) {
					var c = compilers[k];
					// (cold: the module cache off, which keeps the Mir macro context)
					var x = exec(c.cmd.concat(w.args), {cwd: w.cwd, merge: true, env: ["HXMC_MODULE_CACHE" => "0"]});
					if (x.code != 0) {
						bad++;
						Sys.println('${w.name}, ${c.name}: exit ${x.code}\n' + tail(x.out, 2000));
					} else
						times[k].push(x.seconds);
				}
			var meds = [for (t in times) median(t)];
			var line = '${pad(w.name, 40)} ' + [for (k in 0...compilers.length) '${compilers[k].name} ${fmt(meds[k])}'].join("   ");
			Sys.println(line);
			rows.push('| ${w.name} | ' + [for (m in meds) fmt(m)].join(" | ") + " |");
		}
		summary(a.get("--summary"),
			'### Mir macros on this machine (median of $runs, wall time)\n\n| | ' + [for (c in compilers) c.name].join(" | ") + " |\n| --- |"
			+ [for (_ in compilers) " --- |"].join("") + "\n" + rows.join("\n") + "\n\n");
		Sys.exit(bad > 0 ? 1 : 0);
	}

	static function median(xs:Array<Float>):Float {
		if (xs.length == 0) return -1;
		var s = xs.copy();
		s.sort((x, y) -> x < y ? -1 : x > y ? 1 : 0);
		return s[s.length >> 1];
	}

	static function fmt(s:Float):String
		return s < 0 ? "failed" : fixed(s, 2) + " s";
}
