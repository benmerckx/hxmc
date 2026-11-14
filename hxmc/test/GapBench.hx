import Harness.*;
import haxe.Json;
import sys.FileSystem;
import sys.io.File;

using StringTools;

// The native back end against LLVM (docs/plans/native-perf.md): each benchmark
// (as `make bench` runs it) and the tool's self-compile, built cold in each
// mode, then run interleaved. Per case and mode: build seconds and the best run.
//   native        the tool's own back end
//   llvm          -D hxmc.llvm=O2 -D hxmc.llvm-rt (one clang process per module)
//   llvm-release  the same with -D hxmc.llvm-release (one module, the numbers as constants)
//
//   bin/hxmc/hxmc -cp hxmc/test -cp haxe/test --run GapBench [-n RUNS] [-m native,llvm,...]
//       [-c nbody,...,self] [--tool <hxmc>] [--src <checkout>] [--out <json>]
// --src: the sources the self-compile's tools are built from (default this checkout).
// Results merge into the --out file (bin/gap/gap.json) by case and mode.
//
// The benchmarks' sources: bin/gap/runner (HaxeBenchmarks/benchmark-runner) and
// bin/gap/libs, as Bench.hx pins them. clang: HXMC_LLVM_CLANG or `clang`.
// Every mode's output must be the first's; the self-compile's archives identical.
class GapBench {
	static final MODES:Map<String, Array<String>> = [
		"native" => [],
		"llvm" => ["-D", "hxmc.llvm=O2", "-D", "hxmc.llvm-rt"],
		"llvm-release" => ["-D", "hxmc.llvm=O2", "-D", "hxmc.llvm-rt", "-D", "hxmc.llvm-release"],
	];
	static final MODE_ORDER = ["native", "llvm", "llvm-release"];
	static final DIR = "bin/gap";

	static function main() {
		var a = parseArgs(Sys.args(), ["-n", "-m", "-c", "--tool", "--out", "--src"]);
		Sys.putEnv("HAXE_STD_PATH", root + "/haxe/upstream/std");
		var src = FileSystem.fullPath(a.get("--src", "."));
		var tool = FileSystem.fullPath(a.get("--tool", "bin/hxmc/hxmc" + (windows ? ".exe" : "")));
		var runs = a.int("-n", 5);
		var modes = a.has("-m") ? a.get("-m").split(",") : MODE_ORDER;
		var cases = cases();
		var only = a.has("-c") ? a.get("-c").split(",") : [for (c in cases) c.name].concat(["self"]);
		// (merged into the results file: a run of some modes keeps the others')
		var out = a.get("--out", '$DIR/gap.json');
		var results:Dynamic = FileSystem.exists(out) ? Json.parse(File.getContent(out)) : {};
		function save(name:String, row:Dynamic) {
			var old:Dynamic = Reflect.field(results, name) ?? {};
			for (m in Reflect.fields(row)) Reflect.setField(old, m, Reflect.field(row, m));
			Reflect.setField(results, name, old);
			File.saveContent(out, Json.stringify(results, null, " ") + "\n");
			say(name, old);
		}
		for (c in cases.filter(c -> only.contains(c.name))) {
			var row:Dynamic = {};
			var exes = new Map<String, String>();
			for (m in modes) {
				var exe = '${FileSystem.fullPath(DIR)}/out/${c.name}-$m/main';
				var args = [tool, exe, "-cp", "."].concat([for (p in c.cps) for (x in ["-cp", p]) x]);
				args = args.concat(["-main", c.main, "-D", "hxmc.symbols"]).concat([for (d in c.defines) for (x in ["-D", d]) x]);
				var b = coldBuild(args.concat(MODES[m]).concat(["-cp", root + "/bin/hxmc/std", "--custom-target", "hxmc"]),
					'$DIR/runner/cases/${c.dir}');
				Reflect.setField(row, m, {build: b});
				exes[m] = exe + (windows ? ".exe" : "");
			}
			timeRuns(row, [for (m in modes) m => [exes[m]]], runs, runDir('$DIR/runner/cases/${c.dir}/out'), null, c.name);
			save(c.name, row);
		}
		if (only.contains("self")) {
			var row:Dynamic = {};
			var cmds = new Map<String, Array<String>>();
			for (m in modes) {
				var exe = '${FileSystem.fullPath(DIR)}/tool-$m/hxmc';
				var b = coldBuild([tool, exe, "-cp", "haxe/src", "-cp", "hxmc/src", "-main", "hxmc.Main", "-D", "disable-parallelism", "-D", "hih_no_generators",
					"-cp", root + "/bin/hxmc/std", "-D", "hxmc.gc-prefault"].concat(MODES[m]).concat(["--custom-target", "hxmc"]), src);
				Reflect.setField(row, m, {build: b});
				// the port's self-compile to HXB, as Measure.hx's
				cmds[m] = [exe + (windows ? ".exe" : ""), "-cp", "haxe/src", "-main", "haxe.Main", "-D", "disable-parallelism", "--interp", "--no-output",
					"--hxb", '$DIR/self-$m.hxb'];
			}
			timeRuns(row, cmds, runs, root, ["HXMC_MODULE_CACHE" => "0"], "self");
			for (m in modes) if (File.getBytes('$DIR/self-$m.hxb').compare(File.getBytes('$DIR/self-${modes[0]}.hxb')) != 0) fail('self: $m\'s archive differs');
			save("self", row);
		}
		File.saveContent(a.get("--out", '$DIR/gap.json'), Json.stringify(results, null, " ") + "\n");
	}

	/** (the cases read ../data/...) **/
	static function runDir(dir:String):String {
		mkdirs(dir);
		return FileSystem.fullPath(dir);
	}

	/** a build with an empty cache (the typed runtime's too); its seconds **/
	static function coldBuild(cmd:Array<String>, cwd:String):Float {
		var cache = FileSystem.fullPath(DIR) + "/cache";
		rmrf(cache);
		mkdirs(haxe.io.Path.directory(cmd[1]));
		var log = cmd[1] + ".log";
		var r = exec(cmd, {cwd: cwd, env: ["HXMC_CACHE" => cache], log: log});
		if (r.code != 0) fail('build failed ($log): ' + [for (l in readText(log).split("
")) if (l.contains("ERROR") || l.contains("hxmc:")) l].join("
"));
		return r.seconds;
	}

	/** RUNS rounds of every mode in turn; each mode's best run, its output the first mode's **/
	static function timeRuns(row:Dynamic, cmds:Map<String, Array<String>>, runs:Int, cwd:String, env:Null<Map<String, Null<String>>>, name:String) {
		var modes = [for (m in MODE_ORDER) if (cmds.exists(m)) m];
		var out:Null<String> = null;
		for (i in 0...runs)
			for (m in modes) {
				var r = exec(cmds[m], {cwd: cwd, env: env, merge: true});
				if (r.code != 0) fail('$name ($m) failed: ${tail(r.out, 2000)}');
				if (out == null) out = r.out;
				else if (out != r.out) fail('$name ($m): the output differs\n${r.out}\n${out}');
				var o = Reflect.field(row, m);
				if (o.run == null || r.seconds < o.run) o.run = r.seconds;
			}
	}

	static function say(name:String, row:Dynamic) {
		var modes = [for (m in MODE_ORDER) if (Reflect.hasField(row, m)) m];
		var native = Reflect.field(row, "native");
		Sys.println(pad(name, 16) + [for (m in modes) {
			var o = Reflect.field(row, m);
			pad('$m ${fixed(o.run, 3)} s' + (native != null && m != "native" ? ' (${fixed(native.run / o.run, 2)}x)' : "") + ', build ${fixed(o.build, 1)} s', 44);
		}].join(""));
	}

	static function cases() {
		var libs = FileSystem.fullPath('$DIR/libs');
		var fmt = ["formatter/src", "tokentree/src", "haxeparser/src", "hxparse/src", "json2object/src", "hxargs", "hxjsonast/src"];
		return [
			{name: "alloc", dir: "alloc", main: "BMAllocCode", cps: [], defines: []},
			{name: "bcrypt", dir: "bcrypt", main: "BMBCryptCode", cps: ['$libs/crypto/src'], defines: []},
			{name: "binarytrees", dir: "binarytrees", main: "BMBinaryTreesCode", cps: [], defines: []},
			{name: "json", dir: "json", main: "BMJsonCode", cps: [], defines: []},
			{name: "mandelbrot", dir: "mandelbrot", main: "BMMandelbrotCode", cps: [], defines: []},
			{name: "mandelbrot_anon", dir: "mandelbrot_anon_objects", main: "BMMandelbrotCode", cps: ["../mandelbrot"], defines: ["anon_objects"]},
			{name: "nbody", dir: "nbody", main: "BMNBodyCode", cps: [], defines: []},
			{name: "sha256", dir: "sha256", main: "BMSHA256Code", cps: [], defines: []},
			{name: "sha512", dir: "sha512", main: "BMSHA512Code", cps: ['$libs/crypto/src'], defines: []},
			{name: "formatter", dir: "formatter_noio", main: "BMFormatterNoIOCode", cps: [for (d in fmt) '$libs/$d'], defines: [for (d in fmt) d.split("/")[0]]},
		];
	}
}
