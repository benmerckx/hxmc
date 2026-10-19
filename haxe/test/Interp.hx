import Harness.*;
import sys.FileSystem;
import sys.io.File;

using StringTools;

// Execution conformance of the port's Eval (--interp / --run):
//   <haxe> -cp haxe/test --run Interp [-j N] [--cases FILE]... [--skip CASE]... [--summary <file>] [name-substring ...]
// Every case of the lists (default the HXB and macro lists) is executed by
// the reference and by the port; exit code, stdout and stderr must agree.
// direct/module cases get --interp appended; hxml cases run as written when
// they execute (--interp, --run, -x), in a scratch copy of their directory
// (nothing is written into the submodule), and are skipped otherwise; hxblib
// cases run against a library archive the reference builds first, when they
// use --interp. Times are summed per side (Eval against Eval).
class Interp {
	static final GENERATED = "bin/test/interp";
	static final TIMEOUT = 300;

	static function main() {
		var o = parseArgs(Sys.args(), ["-j", "--summary"]);
		var files = [], skips = [];
		var args = Sys.args();
		for (i in 0...args.length) if (args[i] == "--cases") files.push(args[i + 1]) else if (args[i] == "--skip") skips.push(args[i + 1]);
		var rest = [for (r in o.rest) if (!files.contains(r) && !skips.contains(r)) r];
		if (files.length == 0) files = ["haxe/test/conformance-cases.txt", "haxe/test/conformance-macro-cases.txt"];
		var reference = FileSystem.fullPath(Sys.getEnv("HAXE_REFERENCE") ?? "bin/reference/haxe");
		var port = shellSplit(Sys.getEnv("HAXE_IN_HAXE_PORT") ?? "bin/port/haxe");
		if (FileSystem.exists(port[0])) port[0] = FileSystem.fullPath(port[0]);
		var std = root + "/haxe/upstream/std";
		Sys.putEnv("HAXE_STD_PATH", std);
		Sys.putEnv("HAXE_IN_HAXE_STD_PATH", std);
		var cases = [for (f in files) for (c in Conformance.parseCases(f)) if ((rest.length == 0 || Lambda.exists(rest, x -> c.name.contains(x))) && !skips.contains(c.name)) c];
		mkdirs(GENERATED);
		var gen = FileSystem.fullPath(GENERATED);
		var executes = ~/^\s*(--interp|--run|-x)\b/m;
		var counts = new Map<String, Int>();
		var tr = 0.0, tp = 0.0;
		parallel(cases, o.int("-j", cpus()), c -> {
			var cwd = c.cwd, cargs = c.args, scratch = null;
			if (c.lib != null) {
				if (!c.args.contains("--interp")) return {status: "SKIP", detail: "does not execute", tr: 0.0, tp: 0.0};
				mkdirs('$gen/${c.name}');
				var lib = '$gen/${c.name}/lib.hxb';
				exec([reference, "--hxb", lib, "--no-output"].concat(c.lib), {cwd: c.cwd, timeout: TIMEOUT});
				cargs = ["--hxb-lib", lib].concat(c.args);
			} else if (c.hxml) {
				var first = c.cwd + "/" + c.args[0];
				var text = FileSystem.exists(first) && !FileSystem.isDirectory(first) ? File.getContent(first) : c.args.join("\n");
				if (!executes.match(text)) return {status: "SKIP", detail: "does not execute", tr: 0.0, tp: 0.0};
				scratch = tempName();
				cwd = scratch + "/" + haxe.io.Path.withoutDirectory(c.cwd);
				copyTree(c.cwd, cwd);
			} else
				cargs = c.args.concat(["--interp"]);
			var ref = exec([reference].concat(cargs), {cwd: cwd, timeout: TIMEOUT});
			if (scratch != null) {
				// the same files for the port as the reference saw
				rmrf(cwd);
				copyTree(c.cwd, cwd);
			}
			var got = exec(port.concat(cargs), {cwd: cwd, timeout: TIMEOUT});
			if (scratch != null) rmrf(scratch);
			var out = '$gen/${c.name}';
			mkdirs(out);
			for (x in [{side: "reference", r: ref}, {side: "port", r: got}]) {
				File.saveContent('$out/${x.side}.stdout', x.r.out);
				File.saveContent('$out/${x.side}.stderr', x.r.err);
			}
			var diffs = [];
			if (ref.code != got.code || ref.timedOut != got.timedOut) diffs.push("exit");
			if (ref.out != got.out) diffs.push("stdout");
			if (ref.err != got.err) diffs.push("stderr");
			if (diffs.length == 0) return {status: "PASS", detail: 'exit ${ref.code}, ${ref.out.length} bytes out', tr: ref.seconds, tp: got.seconds};
			var detail = 'differs: ${diffs.join(", ")} (reference exit ${ref.code}, port exit ${got.code})';
			if (diffs.contains("stdout") || diffs.contains("stderr")) {
				var so = diffs.contains("stdout");
				var a = (so ? ref.out : ref.err).split("\n"), b = (so ? got.out : got.err).split("\n");
				var n = 0;
				while (n < a.length && n < b.length && a[n] == b[n]) n++;
				detail += ' | line ${n + 1}: ref ${haxe.Json.stringify((a[n] ?? "").substr(0, 80))} port ${haxe.Json.stringify((b[n] ?? "").substr(0, 80))}';
			}
			{status: "FAIL", detail: detail, tr: ref.seconds, tp: got.seconds};
		}, (c, r) -> {
			counts[r.status] = (counts[r.status] ?? 0) + 1;
			if (r.status != "SKIP") {
				tr += r.tr;
				tp += r.tp;
			}
			var timing = r.status == "SKIP" ? "" : fixed(r.tr, 2).lpad(" ", 6) + "s " + fixed(r.tp, 2).lpad(" ", 6) + "s  ";
			Sys.println(pad(r.status, 6) + " " + pad(c.name, 46) + " " + timing + r.detail);
		});
		var keys = [for (k in counts.keys()) k];
		keys.sort(compare);
		var line = 'Interp: ${cases.length} cases: ' + [for (k in keys) '$k ${counts[k]}'].join(", ");
		Sys.println(line);
		Sys.println('Time (compile + run, summed): reference ${fixed(tr)}s, port ${fixed(tp)}s');
		summary(o.get("--summary"), '### --interp\n\n$line\n\n');
		Sys.exit(counts.exists("FAIL") ? 1 : 0);
	}
}
