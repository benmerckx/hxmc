import Harness.*;
import sys.FileSystem;
import sys.io.File;

using StringTools;

// HXB conformance of the port (docs/testing.md):
//   <haxe> -cp haxe/test --run Conformance [-j N] [--cases <list>] [--eval] [--hxb-lib]
//       [--parallel N [--parallel-reference]] [--target-only] [--known <case,...>] [--summary <file>] [name-substring ...]
// For every case of the list (default haxe/test/conformance-cases.txt):
// 1. the reference (HAXE_REFERENCE) compiles the case to HXB;
// 2. the port (HAXE_IN_HAXE_PORT, default bin/port/haxe) compiles the same invocation;
// 3. both archives must have the same member set and byte-identical
//    uncompressed .hxb payloads (ZIP container bytes are never compared);
// 4. the reference must consume the port's archive without the case's source
//    class path.
// --hxb-lib: both compilers also load every module of the reference archive
// back through --hxb-lib and write it again; the outputs must conform.
// --eval: the port executed by the reference on Eval, from an Eval HXB
// archive and from source, must reproduce the port's archive.
// --parallel N: the port runs N times per case without -D disable-parallelism;
// each archive must match the sequential reference archive after normalizing
// variable ids (the reference loads both through --hxb-lib and writes them
// again); --parallel-reference runs the reference itself the same way.
// --target-only: the macro context's modules (macro/) are not compared, for a
// port whose macro context is typed against another std (-D hxmc.macros=mir).
// --known <case,...>: cases known to fail (a port's documented differences):
// each still runs; its failure is KNOWN-FAIL, which does not fail the run, and
// its passing does (the list is out of date).
// `hxblib` cases first build a library archive with the reference and compile
// the case against it with --hxb-lib. A case the reference rejects is an
// expected failure: the port must reject it as well. Both use -D
// disable-parallelism: the reference allocates variable ids from a counter
// shared by parallel workers, so its own output is otherwise not reproducible.
// Case lists:
//   direct <name> <class-path> <main>
//   module <name> <class-path> <module>
//   hxml <name> <project-dir> <hxml> [argument ...]
//   hxblib <name> <dir> "<library arguments>" "<arguments>"
//   volatile <case> <member> <reason ...>   (the member depends on the time of compilation)
//   noeval <case> <reason ...>   (--eval does not apply: Eval as the host cannot run the case)
class Conformance {
	static final GENERATED = "bin/test/conformance";
	static final STACK = ["-D", "eval-call-stack-depth=10000"];
	static final COMMON = ["-D", "disable-parallelism", "--interp", "--no-output"];
	static final TIMEOUT = 900;

	static var reference:String;
	static var port:Array<String>;
	static var opts:Harness.Args;
	static var root:String;

	static function main() {
		opts = parseArgs(Sys.args(), ["-j", "--cases", "--parallel", "--summary", "--known"]);
		var known = [for (k in opts.get("--known", "").split(",")) if (k != "") k];
		var stale = [];
		root = Harness.root;
		reference = Sys.getEnv("HAXE_REFERENCE") ?? "bin/reference/haxe";
		if (!FileSystem.exists(reference)) fail("Conformance: no reference compiler at " + reference + " (make reference, or HAXE_REFERENCE)");
		reference = FileSystem.fullPath(reference);
		port = shellSplit(Sys.getEnv("HAXE_IN_HAXE_PORT") ?? "bin/port/haxe");
		if (FileSystem.exists(port[0])) port[0] = FileSystem.fullPath(port[0]);
		var std = root + "/haxe/upstream/std";
		Sys.putEnv("HAXE_STD_PATH", std);
		Sys.putEnv("HAXE_IN_HAXE_STD_PATH", std);
		var filters = opts.rest;
		var cases = [for (c in parseCases(opts.get("--cases", "haxe/test/conformance-cases.txt"))) if (filters.length == 0 || Lambda.exists(filters, f -> c.name.contains(f))) c];
		mkdirs(GENERATED);
		var compilerHxb = FileSystem.fullPath(GENERATED) + "/haxe-in-haxe.eval.hxb";
		if (opts.has("--eval")) {
			var r = exec([reference, "-cp", root + "/haxe/src", "-main", "haxe.Main", "--interp", "--no-output", "--hxb", compilerHxb], {log: GENERATED + "/build.log"});
			if (r.code != 0) fail("Building the port as Eval HXB failed; see " + GENERATED + "/build.log");
		}
		var parallelN = opts.int("--parallel", 0);
		var results = [];
		var counts = new Map<String, Int>();
		parallel(cases, opts.int("-j", cpus()), c -> {
			// (-D dump-dependencies and the like write dump/ next to the case: not into the submodule)
			var dump = c.cwd + "/dump", had = FileSystem.exists(dump);
			var r = parallelN > 0 ? runCaseParallel(c, parallelN) : runCase(c, compilerHxb);
			if (!had) rmrf(dump);
			r;
		}, (c, r) -> {
			if (known.contains(r.name)) {
				if (r.status == "FAIL") r.status = "KNOWN-FAIL" else stale.push(r.name);
			}
			results.push(r);
			counts[r.status] = (counts[r.status] ?? 0) + 1;
			Sys.println(pad(r.status, 17) + " " + pad(r.name, 40) + " " + fixed(r.seconds).lpad(" ", 6) + "s  " + r.detail);
		});
		var keys = [for (k in counts.keys()) k];
		keys.sort(compare);
		var line = 'Conformance: ${results.length} cases: ' + [for (k in keys) '$k ${counts[k]}'].join(", ");
		if (stale.length > 0) line += '; known to fail but did not (--known): ${stale.join(", ")}';
		Sys.println(line);
		File.saveContent(GENERATED + "/summary.tsv", [for (r in results) '${r.status}\t${r.name}\t${r.detail}\n'].join(""));
		var failed = [for (r in results) if (r.status == "FAIL") '- ${r.name}: ${r.detail}'];
		summary(opts.get("--summary"), '### ${opts.get("--cases", "haxe/test/conformance-cases.txt")}\n\n$line\n\n' + failed.slice(0, 30).join("\n") + "\n\n");
		Sys.exit(counts.exists("FAIL") || stale.length > 0 ? 1 : 0);
	}

	public static function parseCases(file:String):Array<ConfCase> {
		if (root == null) root = Harness.root;
		var cases:Array<ConfCase> = [];
		for (line in File.getContent(file).split("\n")) {
			line = line.trim();
			if (line == "" || line.startsWith("#")) continue;
			var p = shellSplit(line);
			var kind = p[0], name = p[1];
			switch kind {
				case "direct":
					cases.push({kind: kind, name: name, cwd: root, args: ["-cp", p[2], "--main", p[3]], hxml: false});
				case "module":
					cases.push({kind: kind, name: name, cwd: root, args: ["-cp", p[2], p[3]], hxml: false});
				case "hxblib":
					cases.push({kind: kind, name: name, cwd: root + "/" + p[2], lib: shellSplit(p[3]), args: shellSplit(p[4]), hxml: true});
				case "noeval":
					Lambda.find(cases, c -> c.name == name).noEval = p.slice(2).join(" ");
				case "volatile":
					var c = Lambda.find(cases, c -> c.name == name);
					if (c.volatile == null) c.volatile = [];
					c.volatile.push(p[2]);
				case "hxml":
					cases.push({kind: kind, name: name, cwd: root + "/" + p[2], args: p.slice(3), hxml: true});
				case _:
					fail("Unknown case kind: " + line);
			}
		}
		return cases;
	}

	static function run(cmd:Array<String>, cwd:String, log:String):{code:Int, seconds:Float, timedOut:Bool} {
		var r = exec(cmd, {cwd: cwd, log: FileSystem.fullPath(haxe.io.Path.directory(log)) + "/" + haxe.io.Path.withoutDirectory(log), timeout: TIMEOUT});
		return {code: r.code, seconds: r.seconds, timedOut: r.timedOut};
	}

	static function codeText(r:{code:Int, timedOut:Bool}):String return r.timedOut ? "timeout" : Std.string(r.code);

	public static function firstError(log:String):String {
		var text = readText(log);
		var lines = [for (l in text.split("\n")) if (l.trim() != "" && !l.startsWith("Called from")) l.trim()];
		for (l in lines)
			if (l.startsWith("|")) {
				var content = l.substr(1).trim();
				if (content != "" && !~/^[\^ ]+$/.match(content) && content != "[...]") return content.substr(0, 200);
			}
		return (lines.length > 0 ? lines[lines.length - 1] : "").substr(0, 200);
	}

	static function hxbNames(path:String):Array<String> return [for (n in readZip(path).names) if (n.endsWith(".hxb") && compared(n)) n];

	static function compared(member:String):Bool return !(opts.has("--target-only") && member.startsWith("macro/"));

	static function rootsOf(names:Array<String>):{target:Array<String>, roots:Array<String>} {
		var target = Lambda.exists(names, n -> n.startsWith("eval/")) ? ["--interp", "--no-output"] : ["--no-output"];
		var roots = [for (n in names) n.substring(n.indexOf("/") + 1, n.length - 4).replace("/", ".")];
		return {target: target, roots: roots};
	}

	static function prepare(c:ConfCase):{out:String, c:ConfCase, ?fail:ConfResult} {
		var out = FileSystem.fullPath(GENERATED) + "/" + c.name;
		rmrf(out);
		mkdirs(out);
		if (c.lib != null) {
			var libHxb = out + "/lib.hxb";
			var lr = run([reference, "--hxb", libHxb, "-D", "disable-parallelism", "--no-output"].concat(c.lib), c.cwd, out + "/lib.log");
			if (lr.code != 0) return {out: out, c: c, fail: {name: c.name, seconds: 0, status: "FAIL", detail: "reference cannot build the library: " + firstError(out + "/lib.log")}};
			c = Reflect.copy(c);
			c.args = ["--hxb-lib", libHxb].concat(c.args);
		}
		return {out: out, c: c};
	}

	static function runCase(c0:ConfCase, compilerHxb:String):ConfResult {
		var p = prepare(c0);
		if (p.fail != null) return p.fail;
		var out = p.out, c = p.c, cwd = c.cwd;
		var refHxb = out + "/reference.hxb", portHxb = out + "/port.hxb", srcHxb = out + "/source.hxb";
		// An HXML configuration may end in --run, which takes all following
		// arguments, so the output and defines precede it; --no-output keeps
		// the reference from executing the program.
		function invocation(hxb:String):Array<String>
			return c.hxml ? ["--hxb", hxb, "-D", "disable-parallelism", "--no-output"].concat(c.args) : COMMON.concat(c.args).concat(["--hxb", hxb]);
		var rr = run([reference].concat(invocation(refHxb)), cwd, out + "/reference.log");
		var pr = run(port.concat(invocation(portHxb)), cwd, out + "/port.log");
		var result:ConfResult = {name: c.name, seconds: rr.seconds + pr.seconds, status: "", detail: ""};
		inline function done(status:String, detail:String) {
			result.status = status;
			result.detail = detail;
			return result;
		}
		if (rr.code != 0) {
			if (pr.code == 0) return done("FAIL", 'reference rejects (${firstError(out + "/reference.log")}) but port accepts');
			return done("EXPECTED-FAILURE", "both reject: " + firstError(out + "/reference.log"));
		}
		if (pr.code != 0) return done("FAIL", 'port failed (${codeText(pr)}): ' + firstError(out + "/port.log"));
		var diff = compareHxb(refHxb, portHxb, c.volatile, compared);
		if (diff != null) return done("FAIL", diff);
		// Every module of the archive is a root: the reference must load all of
		// them from the archive alone, without the case's source class path.
		var names = hxbNames(portHxb);
		var t = rootsOf(names);
		var note = "";
		var cr = run([reference, "--hxb-lib", portHxb].concat(t.target).concat(t.roots), root, out + "/consume.log");
		if (cr.code != 0) {
			// Modules built by macros need the macro's source to load; that
			// only counts against the port if the reference's own archive loads.
			var rc = run([reference, "--hxb-lib", refHxb].concat(t.target).concat(t.roots), root, out + "/consume-reference.log");
			if (rc.code == 0) return done("FAIL", "reference cannot consume port archive: " + firstError(out + "/consume.log"));
			note = " (neither archive loads without the case's source: " + firstError(out + "/consume-reference.log") + ")";
		}
		if (opts.has("--hxb-lib")) {
			function roundtrip(hxb:String) return ["--hxb-lib", refHxb, "-D", "disable-parallelism"].concat(t.target).concat(t.roots).concat(["--hxb", hxb]);
			var rtRef = out + "/roundtrip-reference.hxb", rtPort = out + "/roundtrip-port.hxb";
			var a = run([reference].concat(roundtrip(rtRef)), root, out + "/roundtrip-reference.log");
			var b = run(port.concat(roundtrip(rtPort)), root, out + "/roundtrip-port.log");
			result.seconds += a.seconds + b.seconds;
			if (a.code != 0) {
				if (b.code == 0) return done("FAIL", 'reference rejects the --hxb-lib round trip (${firstError(out + "/roundtrip-reference.log")}) but port accepts');
				note += " (--hxb-lib round trip rejected by both: " + firstError(out + "/roundtrip-reference.log") + ")";
			} else if (b.code != 0) {
				return done("FAIL", 'port failed the --hxb-lib round trip (${codeText(b)}): ' + firstError(out + "/roundtrip-port.log"));
			} else {
				var d = compareHxb(rtRef, rtPort);
				if (d != null) return done("FAIL", "--hxb-lib round trip: " + d);
				note += " (--hxb-lib round trip identical)";
			}
		}
		if (opts.has("--eval") && c.noEval != null) note += " (--eval not applicable: " + c.noEval + ")";
		else if (opts.has("--eval")) {
			var evalHxb = out + "/eval-hxb.hxb";
			var e = run([reference].concat(STACK).concat(["--hxb-lib", compilerHxb, "--run", "haxe.Main"]).concat(invocation(evalHxb)), cwd, out + "/eval-hxb.log");
			var s = run([reference].concat(STACK).concat(["-cp", root + "/haxe/src", "--run", "haxe.Main"]).concat(invocation(srcHxb)), cwd, out + "/source.log");
			result.seconds += e.seconds + s.seconds;
			for (x in [{r: e, hxb: evalHxb, what: "Eval-HXB-executed", log: "eval-hxb.log"}, {r: s, hxb: srcHxb, what: "source-executed", log: "source.log"}]) {
				if (x.r.code != 0) return done("FAIL", '${x.what} port failed: ' + firstError(out + "/" + x.log));
				var d = compareHxb(portHxb, x.hxb, c.volatile);
				if (d != null) return done("FAIL", '${x.what} port differs from the port: $d');
			}
		}
		var members = readZip(refHxb).names.filter(compared).length;
		if (c.volatile != null) note = ' (${c.volatile.length} volatile not compared)' + note;
		return done("PASS", '$members members identical' + note);
	}

	static function runCaseParallel(c0:ConfCase, n:Int):ConfResult {
		var p = prepare(c0);
		if (p.fail != null) return p.fail;
		var out = p.out, c = p.c, cwd = c.cwd;
		function invocation(hxb:String, par:Bool):Array<String> {
			var d = par ? [] : ["-D", "disable-parallelism"];
			return c.hxml ? ["--hxb", hxb].concat(d).concat(["--no-output"]).concat(c.args) : d.concat(["--interp", "--no-output"]).concat(c.args).concat(["--hxb", hxb]);
		}
		var refHxb = out + "/reference.hxb";
		var rr = run([reference].concat(invocation(refHxb, false)), cwd, out + "/reference.log");
		var seconds = rr.seconds;
		function finish(status:String, detail:String):ConfResult return {name: c.name, seconds: seconds, status: status, detail: detail};
		if (rr.code != 0) {
			for (i in 0...n) {
				var pr = run(port.concat(invocation(out + '/parallel-$i.hxb', true)), cwd, out + '/parallel-$i.log');
				seconds += pr.seconds;
				if (pr.code == 0 || pr.timedOut) return finish("FAIL", 'reference rejects but parallel run $i: ${codeText(pr)}');
			}
			return finish("EXPECTED-FAILURE", 'all $n parallel runs reject: ' + firstError(out + "/reference.log"));
		}
		var names = hxbNames(refHxb);
		var t = rootsOf(names);
		var words = c.args.copy();
		for (a in c.args) if (a.endsWith(".hxml") && FileSystem.exists(cwd + "/" + a)) words = words.concat(shellSplit(File.getContent(cwd + "/" + a), true));
		var cps = [for (i in 1...words.length) if (["-cp", "-p", "--class-path"].contains(words[i - 1])) words[i]];
		if (cps.length == 0) cps = ["."];
		// one normalization per output directory: macro-context modules (macro/,
		// eval/) load with --interp, the others for the cross target
		var groups = new Map<String, Array<String>>();
		for (nm in names) {
			var prefix = nm.substr(0, nm.indexOf("/"));
			if (!groups.exists(prefix)) groups[prefix] = [];
			groups[prefix].push(nm.substring(nm.indexOf("/") + 1, nm.length - 4).replace("/", "."));
		}
		var prefixes = [for (k in groups.keys()) k];
		prefixes.sort(compare);
		var failedLog = "";
		function normalize(hxb:String, tag:String):Null<Array<String>> {
			var norms = [];
			for (prefix in prefixes) {
				var norm = out + '/normalized-$tag-$prefix.hxb';
				var gt = prefix == "eval" || prefix == "macro" ? ["--interp", "--no-output"] : ["--no-output"];
				var cmd = [reference, "--hxb-lib", hxb, "-D", "disable-parallelism"].concat(gt).concat(groups[prefix]).concat(["--hxb", norm]);
				var log = out + '/normalize-$tag-$prefix.log';
				var r = run(cmd, root, log);
				if (r.code != 0) {
					var withCp = [reference];
					for (cp in cps) withCp = withCp.concat(["-cp", cp]);
					r = run(withCp.concat(cmd.slice(1)), cwd, log);
				}
				if (r.code != 0) {
					failedLog = log;
					return null;
				}
				norms.push(norm);
			}
			return norms;
		}
		var refNorm = normalize(refHxb, "reference");
		var refConsumes:Null<Bool> = null;
		var runs = [for (i in 0...n) {who: "port", cmd: port, i: i}];
		if (opts.has("--parallel-reference")) runs = runs.concat([for (i in 0...n) {who: "reference", cmd: [reference], i: i}]);
		var rawSame = ["port" => 0, "reference" => 0], normSame = ["port" => 0, "reference" => 0];
		var diffs = [];
		for (run_ in runs) {
			var tag = '${run_.who}-${run_.i}';
			var hxb = out + '/parallel-$tag.hxb';
			var pr = run(run_.cmd.concat(invocation(hxb, true)), cwd, out + '/parallel-$tag.log');
			seconds += pr.seconds;
			if (pr.code != 0) return finish("FAIL", 'parallel ${run_.who} run ${run_.i} failed (${codeText(pr)}): ' + firstError(out + '/parallel-$tag.log'));
			if (compareHxb(refHxb, hxb) == null) rawSame[run_.who]++;
			var cr = run([reference, "--hxb-lib", hxb].concat(t.target).concat(t.roots), root, out + '/consume-$tag.log');
			if (cr.code != 0 && refConsumes == null)
				refConsumes = run([reference, "--hxb-lib", refHxb].concat(t.target).concat(t.roots), root, out + "/consume-reference.log").code == 0;
			if (cr.code != 0 && refConsumes == true)
				return finish("FAIL", 'reference cannot consume parallel ${run_.who} archive ${run_.i}: ' + firstError(out + '/consume-$tag.log'));
			if (refNorm == null) continue;
			var norm = normalize(hxb, tag);
			if (norm == null) return finish("FAIL", 'reference cannot normalize parallel ${run_.who} archive ${run_.i}: ' + firstError(failedLog));
			var d = null;
			for (k in 0...refNorm.length) {
				d = compareHxb(refNorm[k], norm[k]);
				if (d != null) break;
			}
			if (d != null) {
				diffs.push('${run_.who} run ${run_.i}: $d');
				continue;
			}
			normSame[run_.who]++;
		}
		var members = readZip(refHxb).names.length;
		var detail = '$members members; port: ${normSame["port"]}/$n runs identical after normalizing, ${rawSame["port"]} raw-identical';
		if (opts.has("--parallel-reference")) detail += '; reference: ${normSame["reference"]}/$n normalized, ${rawSame["reference"]} raw';
		if (refNorm == null) detail += " (no normalization: the reference cannot load its own archive without the case's source: " + firstError(failedLog) + ")";
		if (Lambda.exists(diffs, d -> d.startsWith("port"))) return finish("FAIL", detail + "; differs after normalizing: " + diffs.slice(0, 3).join(" | "));
		if (diffs.length > 0) detail += "; the parallel reference itself differs: " + diffs.slice(0, 2).join(" | ");
		return finish("PASS", detail);
	}
}

typedef ConfCase = {kind:String, name:String, cwd:String, args:Array<String>, hxml:Bool, ?lib:Array<String>, ?volatile:Array<String>, ?noEval:String}
typedef ConfResult = {name:String, seconds:Float, status:String, detail:String}
