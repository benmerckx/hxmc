import sys.FileSystem;
import sys.io.File;
import sys.io.Process;

using StringTools;

// -D hxmc.wasm-gc (hxmc/src/hxmc/wasmgc): each program of hxmc/test/wasmgc,
// and the corpus cases of CASES (hxmc/test/cases, as they are), built
// natively and as a WasmGC module (run by node, hxmc/bootstrap/wasmgc.mjs),
// their outputs and exit codes compared (`make wasmgc-check`); a program's `// define:`
// lines apply to both builds, as in the corpus.
// With --bench, also as linear-memory wasm (hxmc/bootstrap/wasi.mjs), each
// run RUNS times: the median time, node's peak RSS and the module's size,
// side by side.
//   bin/hxmc/hxmc -cp hxmc/test --run GcCheck [--bench] [-n RUNS] [names...]
class GcCheck {
	static final out = "bin/wasmgc";
	static final common = ["-cp", "bin/hxmc/std", "--custom-target", "hxmc"];
	// (the corpus cases that need nothing WasmGC lacks: the others' counterparts
	// are in hxmc/test/wasmgc, without the collector's API and raw memory)
	static final CASES = ["AnonFields", "ClosureElements", "CreateInstance", "DateValues", "EnumIdentity", "MapTables", "ObjectMapGc", "NativeArrayBoundsSilent", "NullAccess", "NullAccessThreads", "ResourceBytes", "Resources", "Utf8Bytes", "VectorLength"];

	static function run(cmd:String, args:Array<String>):{code:Int, out:String, err:String} {
		var p = new Process(cmd, args);
		var o = p.stdout.readAll().toString(), e = p.stderr.readAll().toString();
		var c = p.exitCode();
		p.close();
		return {code: c, out: o, err: e};
	}

	static function build(name:String, dir:String, file:String, extra:Array<String>):Null<String> {
		var r = run("bin/hxmc/hxmc", [file, "-main", name, "-cp", dir].concat(common).concat(Corpus.caseDefines('$dir/$name.hx')).concat(Corpus.caseResources('$dir/$name.hx')).concat(extra));
		return r.code == 0 ? null : (r.out + r.err).trim();
	}

	// node's peak RSS and the wall time, from a preloaded script
	static function rssScript():String {
		var f = out + "/rss.cjs";
		File.saveContent(f,
			"const t0 = process.hrtime.bigint();\nprocess.on('exit', () => process.stderr.write('hxmc-stats ' + Number(process.hrtime.bigint() - t0) / 1e9 + ' ' + process.resourceUsage().maxRSS / 1024 + '\\n'));\n");
		return FileSystem.absolutePath(f);
	}

	static function median(xs:Array<Float>):Float {
		var a = xs.copy();
		a.sort(Reflect.compare);
		return a[a.length >> 1];
	}

	static function main() {
		var args = Sys.args(), bench = false, runs = 3, only = [];
		var i = 0;
		while (i < args.length) {
			switch args[i] {
				case "--bench": bench = true;
				case "-n": runs = Std.parseInt(args[++i]);
				case a: only.push(a);
			}
			i++;
		}
		FileSystem.createDirectory(out);
		var rss = rssScript();
		var names = [for (f in FileSystem.readDirectory("hxmc/test/wasmgc")) if (f.endsWith(".hx")) f.substr(0, f.length - 3)];
		var dirs = [for (n in names) n => "hxmc/test/wasmgc"];
		for (c in CASES) {
			names.push(c);
			dirs.set(c, "hxmc/test/cases");
		}
		names.sort(Reflect.compare);
		if (only.length > 0) names = names.filter(n -> only.indexOf(n) >= 0);
		var failed = 0;
		var rows = [];
		for (n in names) {
			var nat = '$out/$n', gc = '$out/$n.gc.wasm', lin = '$out/$n.wasm', dir = dirs.get(n);
			var err = build(n, dir, nat, []);
			if (err == null) err = build(n, dir, gc, ["-D", "hxmc.target=wasm32-wasi", "-D", "hxmc.wasm-gc"]);
			if (err == null && bench) err = build(n, dir, lin, ["-D", "hxmc.target=wasm32-wasi"]);
			if (err != null) {
				Sys.println('GcCheck: $n: build failed\n$err');
				failed++;
				continue;
			}
			// (the same output and exit code: a program may end with an uncaught exception)
			var native = run(nat, []);
			var expected = native.out;
			var got = run("node", ["hxmc/bootstrap/wasmgc.mjs", gc]);
			if (got.code != native.code || got.out != expected) {
				Sys.println('GcCheck: $n: FAILED (exit ${got.code})');
				Sys.println("  expected: " + expected.split("\n").slice(0, 5).join(" | "));
				Sys.println("  got:      " + got.out.split("\n").slice(0, 5).join(" | ") + " " + got.err.trim());
				failed++;
				continue;
			}
			Sys.println('GcCheck: $n: ok');
			if (!bench) continue;
			function measure(cmd:String, a:Array<String>, viaNode:Bool):{t:Float, rss:Float} {
				var ts = [], rs = [];
				for (_ in 0...runs) {
					var t0 = Sys.time();
					var r = run(cmd, viaNode ? ["-r", rss].concat(a) : a);
					var t = Sys.time() - t0;
					for (l in r.err.split("\n"))
						if (l.startsWith("hxmc-stats ")) {
							var p = l.split(" ");
							t = Std.parseFloat(p[1]);
							rs.push(Std.parseFloat(p[2]));
						}
					ts.push(t);
				}
				return {t: median(ts), rss: rs.length > 0 ? median(rs) : Math.NaN};
			}
			var mn = measure(nat, [], false);
			var mg = measure("node", ["hxmc/bootstrap/wasmgc.mjs", gc], true);
			var ml = measure("node", ["hxmc/bootstrap/wasi.mjs", lin], true);
			rows.push({
				name: n,
				native: mn.t,
				gc: mg.t,
				gcRss: mg.rss,
				gcSize: FileSystem.stat(gc).size,
				lin: ml.t,
				linRss: ml.rss,
				linSize: FileSystem.stat(lin).size
			});
		}
		if (rows.length > 0) {
			inline function f(x:Float, d = 2):String
				return Std.string(Math.round(x * Math.pow(10, d)) / Math.pow(10, d));
			Sys.println("\n| program | native s | WasmGC s | linear s | WasmGC RSS MB | linear RSS MB | WasmGC KB | linear KB |");
			Sys.println("| --- | --- | --- | --- | --- | --- | --- | --- |");
			for (r in rows)
				Sys.println('| ${r.name} | ${f(r.native)} | ${f(r.gc)} | ${f(r.lin)} | ${f(r.gcRss, 0)} | ${f(r.linRss, 0)} | ${f(r.gcSize / 1024, 1)} | ${f(r.linSize / 1024, 1)} |');
		}
		if (failed > 0) {
			Sys.println('GcCheck: $failed FAILED');
			Sys.exit(1);
		}
	}
}
