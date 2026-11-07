import fuzz.Ast;
import fuzz.Gen;
import fuzz.Reduce;
import fuzz.Runner;
import sys.FileSystem;
import sys.io.File;
import sys.thread.Mutex;
import sys.thread.Thread;
import sys.thread.Lock;

/**
	Differential fuzzer: generates random, well-typed Haxe programs and checks
	that the port compiles them exactly like the pinned reference compiler.

	Build with hxmc: `make fuzz`, run `bin/fuzz/fuzz --help`.
	See docs/testing.md (the fuzzer).
**/
class Fuzz {
	static var USAGE = "Usage: fuzz [options]

Lanes (repeatable; default diff:hxb):
  --lane diff:<target>        reference and port compile the same target; diagnostics,
                              outputs (and with --run, program output) must be identical
  --lane exec:<a>,<b>         both run the program; program output must be identical
                              (a side is [ref:|port:]<target>; default compiler: ref)
Targets: hxb interp js lua python neko hl hlc php cpp jvm swf hxmc hxmc-checked hxmc-wasm, or --target-def.

Options:
  --ref CMD           reference compiler (default $HAXE_REFERENCE or bin/reference/haxe)
  --port CMD          port compiler (default $HAXE_IN_HAXE_PORT or bin/port/haxe)
  --run               diff lanes also run both outputs and compare program output
  -n, --count N       number of programs (default 100; 0: until --time)
  --time S            stop after S seconds
  --seed N            first seed (default: from the clock); program i uses seed + i
  -j N                parallel workers (default 1)
  --size N            program size, 1..8 (default 3)
  --portable          only constructs every target runs alike (implied by exec lanes)
  --feature F, --no-feature F
                      force a generator feature on or off (default: random per program)
  --mutate P          inject one compile error into P% of the programs; both compilers
                      must then report the same diagnostics
  --reduce N          reduce each new failure with up to N test runs (default 200; 0: off)
  --keep N            failures saved per signature (default 2)
  -D X                extra define for every compilation
  --out DIR           work and results directory (default bin/test/fuzz)
  --target-def SPEC   custom target name|args|output|run, args separated by spaces,
                      output none, file:P, dir:P, zip:P or hxb:P, run optional ({out} = output dir)
  --emit DIR          only write the programs to DIR/<seed>/ and exit
  --cases DIR         check the programs kept under DIR/<name>/ (main class Main) on the
                      lanes instead of generated ones (haxe/test/fuzz/cases: the failures
                      fixed since, reduced); no reduction
  --stop              stop at the first failure
  --list              list targets and features
  -v                  print every verdict
";

	static var mutex = new Mutex();
	static var next = 0;
	static var done = 0;
	static var counts = new Map<String, Int>();
	static var sigs = new Map<String, Int>();
	static var stop = false;
	static var start = 0.0;
	static var newFailures = 0;

	static var lanes:Array<Lane> = [];
	static var count = 100;
	static var jobs = 1;
	static var seconds = 0.0;
	static var seed = 0;
	static var size = 3;
	static var portable = false;
	static var forced = new Map<String, Bool>();
	static var reduceBudget = 200;
	static var mutate = 0;
	static var keep = 2;
	static var outDir = "";
	static var verbose = false;
	static var stopAtFirst = false;
	static var cases:Null<Array<{name:String, files:Array<{path:String, text:String}>}>> = null;

	static function main() {
		var args = Sys.args();
		var root = Sys.getEnv("HAXE_IN_HAXE_ROOT");
		if (root == null)
			root = Sys.getCwd();
		root = FileSystem.absolutePath(root);
		if (StringTools.endsWith(root, "/"))
			root = root.substr(0, root.length - 1);
		Runner.root = root;
		var ref = Sys.getEnv("HAXE_REFERENCE");
		if (ref == null)
			ref = root + "/bin/reference/haxe";
		var port = Sys.getEnv("HAXE_IN_HAXE_PORT");
		if (port == null)
			port = root + "/bin/port/haxe";
		var laneSpecs = [];
		var run = false;
		var defines = [];
		var custom = [];
		var emit:Null<String> = null;
		var casesDir:Null<String> = null;
		seed = Std.int(Sys.time() * 1000) & 0x3FFFFFFF;
		outDir = root + "/bin/test/fuzz";
		var i = 0;
		function arg():String {
			if (i + 1 >= args.length) {
				Sys.println("missing value for " + args[i]);
				Sys.exit(2);
			}
			return args[++i];
		}
		function int():Int {
			var s = arg();
			var v = Std.parseInt(s);
			if (v == null) {
				Sys.println("not a number: " + s);
				Sys.exit(2);
			}
			return v;
		}
		while (i < args.length) {
			switch args[i] {
				case "--lane": laneSpecs.push(arg());
				case "--ref": ref = arg();
				case "--port": port = arg();
				case "--run": run = true;
				case "-n" | "--count": count = int();
				case "--time": seconds = int();
				case "--seed": seed = int();
				case "-j": Fuzz.jobs = int();
				case "--size": size = int();
				case "--portable": portable = true;
				case "--feature": forced.set(arg(), true);
				case "--no-feature": forced.set(arg(), false);
				case "--reduce": reduceBudget = int();
				case "--mutate": mutate = int();
				case "--keep": keep = int();
				case "-D": defines.push(arg());
				case "--out": outDir = FileSystem.absolutePath(arg());
				case "--target-def": custom.push(arg());
				case "--emit": emit = arg();
				case "--cases": casesDir = FileSystem.absolutePath(arg());
				case "--stop": stopAtFirst = true;
				case "-v": verbose = true;
				case "--list":
					Sys.println("targets: " + [for (k in Runner.targets(ref).keys()) k].join(" "));
					Sys.println("features: " + Gen.FEATURES.join(" "));
					return;
				case "-h" | "--help":
					Sys.print(USAGE);
					return;
				case a:
					Sys.println("unknown argument " + a + "\n");
					Sys.print(USAGE);
					Sys.exit(2);
			}
			i++;
		}
		for (f in forced.keys())
			if (!Gen.FEATURES.contains(f)) {
				Sys.println("unknown feature " + f + " (see --list)");
				Sys.exit(2);
			}
		if (casesDir != null) {
			cases = readCases(casesDir);
			count = cases.length;
			reduceBudget = 0;
		}
		if (emit != null) {
			for (k in 0...count) {
				var p = Gen.generate(seed + k, portable, size, forced, mutate);
				Runner.writeProgram(p.files(), emit + "/" + (seed + k));
			}
			Sys.println("wrote " + count + " programs to " + emit);
			return;
		}
		var targets = Runner.targets(ref);
		for (c in custom) {
			var p = c.split("|");
			if (p.length < 3) {
				Sys.println("bad --target-def " + c);
				Sys.exit(2);
			}
			targets.set(p[0], {
				name: p[0],
				args: [for (a in p[1].split(" ")) if (a != "") a],
				output: p[2],
				run: p.length > 3 && p[3] != "" ? p[3] : null
			});
		}
		if (laneSpecs.length == 0)
			laneSpecs.push("diff:hxb");
		for (spec in laneSpecs)
			lanes.push(parseLane(spec, targets, ref, port, run));
		for (l in lanes)
			if (l.exec)
				portable = true;
		Runner.common = ["-D", "disable-parallelism"];
		for (d in defines)
			Runner.common = Runner.common.concat(["-D", d]);
		FileSystem.createDirectory(outDir + "/work");
		FileSystem.createDirectory(outDir + "/failures");
		if (cases != null)
			Sys.println("fuzz: " + count + " kept programs of " + casesDir + ", " + jobs + " jobs");
		else Sys.println("fuzz: seed " + seed + ", " + (count == 0 ? "unbounded" : count + " programs") + (seconds > 0 ? ", " + seconds + " s" : "") + ", " + jobs
			+ " jobs, size " + size + (portable ? ", portable" : ""));
		for (l in lanes)
			Sys.println("  lane " + l.name + ": " + Runner.commandLine(l.a, "out") + "  <>  " + Runner.commandLine(l.b, "out"));
		start = Sys.time();
		if (jobs <= 1)
			worker(0);
		else {
			var lock = new Lock();
			for (w in 0...jobs)
				Thread.create(() -> {
					worker(w);
					lock.release();
				});
			for (_ in 0...jobs)
				lock.wait();
		}
		report(true);
		Sys.exit(newFailures > 0 ? 1 : 0);
	}

	static function parseLane(spec:String, targets:Map<String, TargetSpec>, ref:String, port:String, run:Bool):Lane {
		function target(name:String):TargetSpec {
			var t = targets.get(name);
			if (t == null) {
				Sys.println("unknown target " + name + " (see --list)");
				Sys.exit(2);
			}
			return t;
		}
		function side(s:String, defaultCompiler:String, label:String):Side {
			var compiler = defaultCompiler;
			if (StringTools.startsWith(s, "ref:")) {
				compiler = ref;
				s = s.substr(4);
			} else if (StringTools.startsWith(s, "port:")) {
				compiler = port;
				s = s.substr(5);
			}
			return {label: label, compiler: compiler, target: target(s)};
		}
		if (StringTools.startsWith(spec, "diff:")) {
			var t = target(spec.substr(5));
			return {
				name: spec,
				a: {label: "ref", compiler: ref, target: t},
				b: {label: "port", compiler: port, target: t},
				exec: false,
				run: run
			};
		}
		if (StringTools.startsWith(spec, "exec:")) {
			var p = spec.substr(5).split(",");
			if (p.length != 2) {
				Sys.println("bad lane " + spec);
				Sys.exit(2);
			}
			return {
				name: spec,
				a: side(p[0], ref, "a"),
				b: side(p[1], ref, "b"),
				exec: true,
				run: true
			};
		}
		Sys.println("bad lane " + spec + " (diff:<target> or exec:<a>,<b>)");
		Sys.exit(2);
		return null;
	}

	static function take():Int {
		mutex.acquire();
		var k = -1;
		var timeUp = seconds > 0 && Sys.time() - start >= seconds;
		if (!stop && !timeUp && (count == 0 || next < count))
			k = next++;
		mutex.release();
		return k;
	}

	static function worker(w:Int) {
		var work = outDir + "/work/w" + w;
		var lastReport = Sys.time();
		while (true) {
			var k = take();
			if (k < 0)
				break;
			var s = seed + k;
			var p = if (cases != null) {
				var kept = new Program(k);
				kept.kept = cases[k].files;
				kept;
			} else Gen.generate(s, portable, size, forced, mutate);
			var name = cases != null ? cases[k].name : "" + s;
			Runner.writeProgram(p.files(), work + "/src");
			for (lane in lanes) {
				var v = Runner.check(lane, work);
				record(lane, name, p, v, work);
			}
			mutex.acquire();
			done++;
			mutex.release();
			if (w == 0 && Sys.time() - lastReport > 10) {
				lastReport = Sys.time();
				report(false);
			}
		}
	}

	static function signature(lane:Lane, v:Verdict):String {
		// group by the differing fragment when there is one; names and numbers vary from program to program
		var d = v.detail;
		var lb = d.lastIndexOf(" [");
		if (lb >= 0 && StringTools.endsWith(d, "]"))
			d = d.substr(lb + 2, d.length - lb - 3);
		d = ~/[A-Za-z_]*[0-9]+/g.replace(d, "#");
		d = ~/[^\x00-\x7F]+/g.replace(d, "~");
		d = ~/"[^"]*"/g.replace(d, "\"\"");
		if (d.length > 80)
			d = d.substr(0, 80);
		return lane.name + " " + v.kind + " " + d;
	}

	static function slug(s:String):String {
		var r = ~/[^A-Za-z0-9]+/g.replace(s, "-");
		return r.length > 60 ? r.substr(0, 60) : r;
	}

	/** Port (or side b) failures: they decide the exit code. **/
	static function failing(kind:String):Bool
		return kind != "ok" && kind != "invalid" && kind != "rejected-alike" && kind != "reference-failure";

	/** Saved, grouped and reduced: port failures and crashes of the reference itself. **/
	static function notable(kind:String):Bool
		return failing(kind) || kind == "reference-failure";

	/** The kept programs: one per subdirectory, its .hx files by path, in name order. **/
	static function readCases(dir:String):Array<{name:String, files:Array<{path:String, text:String}>}> {
		var names = [for (n in FileSystem.readDirectory(dir)) if (FileSystem.isDirectory(dir + "/" + n)) n];
		names.sort(Reflect.compare);
		return [
			for (n in names) {
				var files = [];
				function walk(rel:String) {
					var entries = FileSystem.readDirectory(dir + "/" + n + rel);
					entries.sort(Reflect.compare);
					for (e in entries) {
						var path = rel + "/" + e;
						if (FileSystem.isDirectory(dir + "/" + n + path))
							walk(path);
						else if (StringTools.endsWith(e, ".hx"))
							files.push({path: path.substr(1), text: File.getContent(dir + "/" + n + path)});
					}
				}
				walk("");
				{name: n, files: files};
			}
		];
	}

	static function record(lane:Lane, name:String, p:Program, v:Verdict, work:String) {
		// an injected error both compilers report alike is a pass
		if (v.kind == "invalid" && Lambda.exists(p.features, f -> StringTools.startsWith(f, "mutated:")))
			v = {kind: "rejected-alike", detail: v.detail};
		mutex.acquire();
		counts.set(v.kind, (counts.exists(v.kind) ? counts.get(v.kind) : 0) + 1);
		var sig = signature(lane, v);
		var seen = 0;
		var save = false;
		if (notable(v.kind)) {
			seen = sigs.exists(sig) ? sigs.get(sig) : 0;
			sigs.set(sig, seen + 1);
			save = seen < keep;
			if (seen == 0 && failing(v.kind))
				newFailures++;
			if (stopAtFirst && failing(v.kind))
				stop = true;
		} else if (v.kind == "invalid") {
			// keep a few programs the reference rejects: they point at generator bugs
			var n = counts.get("invalid");
			save = n <= 5;
		}
		mutex.release();
		if (verbose || notable(v.kind))
			Sys.println((cases != null ? "case " : "seed ") + name + " " + lane.name + ": " + v.kind + (v.detail == "" ? "" : " - " + v.detail));
		if (!save)
			return;
		var dir = outDir + "/" + (v.kind == "invalid" ? "invalid" : (failing(v.kind) ? "failures/" : "reference-failures/") + slug(sig)) + "/" + name;
		saveCase(dir, lane, name, p, v, work);
		if (notable(v.kind) && seen == 0 && reduceBudget > 0) {
			var t0 = Sys.time();
			var reduceWork = work + "-reduce";
			// the same signature, not just the same kind: the reduced program must keep the same bug
			var n = Reduce.run(p, cand -> {
				Runner.writeProgram(cand.files(), reduceWork + "/src");
				var cv = Runner.check(lane, reduceWork);
				return cv.kind == v.kind && signature(lane, cv) == sig;
			}, reduceBudget);
			// the final program, checked once more for its logs
			Runner.writeProgram(p.files(), reduceWork + "/src");
			var rv = Runner.check(lane, reduceWork);
			saveCase(dir + "/reduced", lane, name, p, rv, reduceWork);
			var lines = 0;
			for (f in p.files())
				lines += f.text.split("\n").length;
			Sys.println("  reduced " + name + " in " + n + " tests, " + Std.int(Sys.time() - t0) + " s: " + lines + " lines, " + dir + "/reduced");
		}
	}

	static function copyFile(from:String, to:String) {
		if (FileSystem.exists(from))
			File.copy(from, to);
	}

	static function saveCase(dir:String, lane:Lane, name:String, p:Program, v:Verdict, work:String) {
		Runner.writeProgram(p.files(), dir + "/src");
		for (side in [lane.a, lane.b]) {
			for (f in ["compile.log", "compile.code", "run.log", "run.code"])
				copyFile(work + "/" + side.label + "/" + f, dir + "/" + side.label + "-" + f);
		}
		var b = new StringBuf();
		b.add("lane: " + lane.name + (cases != null ? "\ncase: " : "\nseed: ") + name + "\nkind: " + v.kind + "\ndetail: " + v.detail + "\nfeatures: " + p.features.join(" ") + "\n");
		File.saveContent(dir + "/verdict.txt", b.toString());
		var sh = new StringBuf();
		sh.add("#!/bin/sh\n# Re-runs both sides of lane " + lane.name + " from this directory.\ncd \"$(dirname \"$0\")\"\n");
		sh.add("export HAXE_STD_PATH=" + Runner.root + "/haxe/upstream/std HAXE_IN_HAXE_STD_PATH=" + Runner.root + "/haxe/upstream/std\n");
		for (side in [lane.a, lane.b]) {
			sh.add("rm -rf " + side.label + " && mkdir -p " + side.label + "/out && (cd " + side.label + " && " + Runner.commandLine(side, "out") + ")");
			sh.add("; echo \"" + side.label + ": exit $?\"\n");
			if (side.target.run != null && (lane.run || lane.exec))
				sh.add("(cd " + side.label + " && " + StringTools.replace(side.target.run, "{out}", "out") + ")\n");
		}
		File.saveContent(dir + "/repro.sh", sh.toString());
	}

	static function report(final_:Bool) {
		mutex.acquire();
		var elapsed = Sys.time() - start;
		var parts = [for (k in counts.keys()) k + " " + counts.get(k)];
		parts.sort(Reflect.compare);
		Sys.println((final_ ? "done: " : "") + done + " programs in " + Std.int(elapsed) + " s (" + Std.int(done / (elapsed > 0 ? elapsed : 1) * 60)
			+ "/min): " + parts.join(", "));
		if (final_) {
			var ks = [for (k in sigs.keys()) k];
			ks.sort(Reflect.compare);
			for (k in ks)
				Sys.println("  " + sigs.get(k) + "x " + k);
			if (ks.length > 0)
				Sys.println("cases saved under " + outDir + "/failures and " + outDir + "/reference-failures");
		}
		mutex.release();
	}
}
