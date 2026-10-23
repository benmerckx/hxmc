import Harness.*;
import sys.FileSystem;
import sys.io.File;

using StringTools;

// Mir macros as a smoke and speed check on a target's machine (the CI test
// job's Mir lane, docs/testing.md): macro workloads timed with the native
// compiler, `haxe` with hxmc built in (-D hxmc.macros=mir), and with a
// compiler whose macros run on Eval (the release binary), on the same machine:
//   json        BMJsonCode.main() as an initialization macro (--macro, --no-output)
//   mandelbrot  BMMandelbrotCode.main() so (only with --only: Eval takes
//               a minute and a half for it)
//   formatter   haxe-formatter's benchmark typed with json2object's macros
//               (--interp --no-output: the macros, nothing run)
//   trivial     a macro returning 1 called from main (--js)
// each cold (the module cache off, so nothing kept: typed, compiled and run
// from scratch) and, for the formatter and the trivial macro, warm: the
// caches on (the module cache, Mir macros' compiled functions:
// interp/BundleCache.hx), in a cache of each compiler's own filled by a
// first build, then each run after an edit: the main module (a comment: the
// trivial macro runs again, the formatter's do not), the formatter's
// configuration class (a declaration: json2object's macros run again), or
// none (a second run of the same build); the formatter with only the
// compiled functions kept (the module cache off: every macro runs again);
// and the trivial macro edited under the compilation server (--wait, then
// --connect after each edit of its body; not on Windows).
//
//   <haxe> -cp hxmc/test -cp haxe/test --run MirBench --fetch <dir>
//   <haxe> -cp hxmc/test -cp haxe/test --run MirBench --dir <dir> --mir "<compiler> -D hxmc.macros=mir"
//       --eval <compiler> [-n RUNS] [--only <name,...>] [--summary <file>]
// --fetch: the cases and the formatter's libraries (pinned as Bench's) into <dir>.
// Each workload runs RUNS times (default 3) per compiler, the compilers
// interleaved; reported: the median wall time. --only: the workloads whose
// names contain one of these (the default: all but mandelbrot). A run that
// fails fails the check.
@:access(Bench)
class MirBench {
	static function main() {
		var a = parseArgs(Sys.args(), ["--fetch", "--dir", "--mir", "--eval", "-n", "--summary", "--only"]);
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
		var only = a.has("--only") ? a.get("--only").split(",") : null;
		var compilers = [{name: "Mir macros", cmd: shellSplit(a.get("--mir"))}, {name: "Eval", cmd: shellSplit(a.get("--eval"))}];
		var cases = '$dir/runner/cases';
		var libs = [for (d in Bench.FORMATTER_CPS) ["-cp", '$dir/libs/$d']];
		var defines = [for (d in Bench.FORMATTER_CPS) ["-D", d.split("/")[0]]];
		var formatter = Lambda.flatten(libs).concat(Lambda.flatten(defines)).concat(["-cp", ".", "-main", "BMFormatterNoIOCode", "--interp", "--no-output"]);
		var fdir = '$cases/formatter_noio';
		var config = '$dir/libs/formatter/src/formatter/config/FormatterConfig.hx';
		var tdir = '$dir/trivial';
		mkdirs(tdir);
		File.saveContent('$tdir/Main.hx', TRIVIAL);
		var trivial = ["-cp", ".", "-main", "Main", "--js", "out.js"];
		var cold = ["HXMC_MODULE_CACHE" => "0"];
		var workloads:Array<Workload> = [
			{name: "json as a macro", cwd: '$cases/json/out', args: ["-cp", "..", "--macro", "BMJsonCode.main()", "--no-output"], env: cold},
			{name: "mandelbrot as a macro", cwd: '$cases/mandelbrot', args: ["-cp", ".", "--macro", "BMMandelbrotCode.main()", "--no-output"], env: cold, optional: true},
			{name: "formatter build, cold", cwd: fdir, args: formatter, env: cold},
			{name: "formatter build, warm, unchanged", cwd: fdir, args: formatter, warm: true},
			{name: "formatter build, warm, main module edited", cwd: fdir, args: formatter, warm: true, edit: {file: '$fdir/BMFormatterNoIOCode.hx', kind: Comment}},
			{name: "formatter build, warm, config edited (macros run)", cwd: fdir, args: formatter, warm: true, edit: {file: config, kind: Declaration}},
			{name: "formatter build, only compiled functions kept", cwd: fdir, args: formatter, warm: true, env: ["HXMC_MODULE_CACHE" => "0", "HXMC_MIR_CACHE" => "1"]},
			{name: "trivial macro, cold", cwd: tdir, args: trivial, env: cold},
			{name: "trivial macro, warm, main module edited", cwd: tdir, args: trivial, warm: true, edit: {file: '$tdir/Main.hx', kind: Comment}},
			{name: "trivial macro edited under the server", cwd: tdir, args: trivial, server: true, edit: {file: '$tdir/Main.hx', kind: MacroBody}}
		];
		var bad = 0;
		var rows = [];
		var port = 6417;
		for (w in workloads) {
			if (only != null ? !Lambda.exists(only, o -> w.name.indexOf(o) >= 0) : w.optional == true) continue;
			if (w.server == true && Sys.systemName() == "Windows") continue;
			mkdirs(w.cwd);
			var original = w.edit != null ? File.getContent(w.edit.file) : null;
			function edit(n:Int, k:Int) {
				if (w.edit == null) return;
				File.saveContent(w.edit.file, switch w.edit.kind {
					case Comment: original + '\n// MirBench edit $n $k\n';
					case Declaration: original + '\ntypedef MirBenchEdit_${n + 1}_$k = Int;\n';
					case MacroBody: original.replace("macro 1;", 'macro ${100 * (n + 1) + k};');
				});
			}
			var times = [for (_ in compilers) []];
			var servers = [];
			try {
				// (a cache of each compiler's own, filled by a first build; a server each,
				// its first two builds: the second one is slower than the next ones, both engines)
				for (k in 0...compilers.length) {
					var c = compilers[k];
					var env = envOf(w, dir, k);
					if (w.warm == true) rmrf(env.get("HXMC_CACHE"));
					if (w.server == true) {
						servers.push(server(c.cmd, w.cwd, env, port + k));
					}
					if (w.warm == true || w.server == true)
						for (i in 0...(w.server == true ? 2 : 1)) {
							edit(-i, k);
							var x = exec(command(w, c.cmd, port + k), {cwd: w.cwd, merge: true, env: env});
							if (x.code != 0) throw '${w.name}, ${c.name}: a first build: exit ${x.code}\n' + tail(x.out, 2000);
						}
				}
				for (r in 0...runs)
					for (k in 0...compilers.length) {
						var c = compilers[k];
						edit(r + 1, k);
						var x = exec(command(w, c.cmd, port + k), {cwd: w.cwd, merge: true, env: envOf(w, dir, k)});
						if (x.code != 0) {
							bad++;
							Sys.println('${w.name}, ${c.name}: exit ${x.code}\n' + tail(x.out, 2000));
						} else
							times[k].push(x.seconds);
					}
			} catch (e:Dynamic) {
				bad++;
				Sys.println(Std.string(e));
			}
			for (s in servers)
				s.kill();
			port += compilers.length;
			if (original != null) File.saveContent(w.edit.file, original);
			var meds = [for (t in times) median(t)];
			var line = '${pad(w.name, 52)} ' + [for (k in 0...compilers.length) '${compilers[k].name} ${fmt(meds[k])}'].join("   ");
			Sys.println(line);
			rows.push('| ${w.name} | ' + [for (m in meds) fmt(m)].join(" | ") + " |");
		}
		summary(a.get("--summary"),
			'### Mir macros on this machine (median of $runs, wall time)\n\n| | ' + [for (c in compilers) c.name].join(" | ") + " |\n| --- |"
			+ [for (_ in compilers) " --- |"].join("") + "\n" + rows.join("\n") + "\n\n");
		Sys.exit(bad > 0 ? 1 : 0);
	}

	static final TRIVIAL = "class Main {\n\tstatic macro function one() return macro 1;\n\n\tstatic function main() trace(one());\n}\n";

	// the environment of compiler k's builds of w: cold, or its own cache
	static function envOf(w:Workload, dir:String, k:Int):Map<String, Null<String>> {
		var env:Map<String, Null<String>> = w.env != null ? w.env.copy() : [];
		if (w.warm == true || w.server == true) env.set("HXMC_CACHE", '$dir/cache-$k');
		return env;
	}

	static function command(w:Workload, cmd:Array<String>, port:Int):Array<String>
		return w.server == true ? [cmd[0], "--connect", Std.string(port)].concat(w.args) : cmd.concat(w.args);

	// a compilation server (cmd's defines are its own: -D hxmc.macros=mir), ready
	static function server(cmd:Array<String>, cwd:String, env:Map<String, Null<String>>, port:Int):sys.io.Process {
		var script = new StringBuf();
		script.add('cd ${quote(cwd)} || exit 126; ');
		for (k => v in env)
			script.add(v == null ? 'unset $k; ' : 'export $k=${quote(v)}; ');
		script.add('exec ' + [for (c in cmd.concat(["--wait", Std.string(port)])) quote(c)].join(" ") + ' >/dev/null 2>&1');
		var p = new sys.io.Process("/bin/sh", ["-c", script.toString()]);
		// (listening: a client that connects)
		for (_ in 0...100) {
			if (exec([cmd[0], "--connect", Std.string(port), "-version"], {cwd: cwd, merge: true}).code == 0) return p;
			Sys.sleep(0.05);
		}
		p.kill();
		throw 'MirBench: no server on port $port';
	}

	static function median(xs:Array<Float>):Float {
		if (xs.length == 0) return -1;
		var s = xs.copy();
		s.sort((x, y) -> x < y ? -1 : x > y ? 1 : 0);
		return s[s.length >> 1];
	}

	static function fmt(s:Float):String
		return s < 0 ? "failed" : fixed(s, s < 1 ? 3 : 2) + " s";
}

enum EditKind {
	Comment;
	Declaration;
	MacroBody;
}

typedef Workload = {
	name:String,
	cwd:String,
	args:Array<String>,
	?env:Map<String, Null<String>>,
	?warm:Bool,
	?server:Bool,
	?optional:Bool,
	?edit:{file:String, kind:EditKind}
}
