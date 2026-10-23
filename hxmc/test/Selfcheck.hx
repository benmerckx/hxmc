import Harness.*;
import sys.FileSystem;
import sys.io.File;

using StringTools;

// The port built by hxmc compiles its own source to HXB; the archive must be
// the reference compiler's, member by member (HxbCmp).
//
// On the machine of a target (CI), with an archive the reference wrote on Linux:
//   <haxe> -cp hxmc/test -cp haxe/test --run Selfcheck --port <exe> --src <src dir> --std <std dir>
//       --ref <self-ref.hxb> --ref-root <dir> --root <dir> [--summary <file>] [--runner <command>]
// The source and std are copied to <root>/src and <root>/std and the port runs
// in <root> (HAXE_STD_PATH=std), as the reference did in <ref-root>. With
// relative class paths only each module's own file is an absolute path, so
// with the same root the archives must be byte-identical, and with another
// one (Windows: D:\...) identical once each root is replaced by the same
// placeholder. A WebAssembly port runs under --runner.
//
// Here (`make check PORT=1`, `make full`): --local builds bin/hxmc-t/port/s with the tool
// and compares its self-compile with the reference's (bin/reference/haxe,
// written once and again when haxe/src is newer); --small also runs it with
// a 256 KB nursery.
class Selfcheck {
	static function main() {
		var a = parseArgs(Sys.args(), ["--port", "--src", "--std", "--ref", "--ref-root", "--root", "--summary", "--runner", "--reference"]);
		Sys.exit(a.has("--local") ? local(a) : remote(a) ? 0 : 1);
	}

	static function remote(a:Harness.Args):Bool {
		var root = a.get("--root");
		var port = FileSystem.fullPath(a.get("--port"));
		if (!windows) exec(["chmod", "+x", port]);
		mkdirs(root);
		for (n in ["src", "std"]) {
			rmrf('$root/$n');
			copyTree(a.get("--" + n), '$root/$n');
		}
		var out = '$root/self.hxb';
		var runner = shellSplit(a.get("--runner", ""));
		var full = FileSystem.fullPath(root);
		// (PWD: a WebAssembly port resolves relative paths against it)
		var r = exec(runner.concat([port, "-cp", "src", "-main", "haxe.Main", "-D", "disable-parallelism", "--interp", "--no-output", "--hxb", out]),
			{cwd: root, env: ["HAXE_STD_PATH" => "std", "PWD" => full], merge: true});
		Sys.print(r.out);
		var ok = r.code == 0 && FileSystem.exists(out);
		var line = 'self-compile: exit ${r.code}, ${fixed(r.seconds)} s';
		if (ok) {
			var sameRoot = root == a.get("--ref-root");
			var c = HxbCmp.compareArchives(a.get("--ref"), out, sameRoot ? null : a.get("--ref-root"), sameRoot ? null : root);
			ok = c.ok;
			line += "; " + c.line + (sameRoot && ok ? " (byte-identical)" : "");
		}
		Sys.println(line);
		var runnerName = a.has("--runner") ? " (" + shellSplit(a.get("--runner"))[0] + ")" : "";
		summary(a.get("--summary"), '### port self-compile$runnerName: ${ok ? "ok" : "FAILED"}\n\n```\n$line\n```\n\n');
		return ok;
	}

	static function local(a:Harness.Args):Int {
		var tool = FileSystem.fullPath(Sys.getEnv("HXMC_TOOL") ?? "bin/hxmc/hxmc");
		var reference = a.get("--reference", "bin/reference/haxe");
		if (!FileSystem.exists(reference)) return fail('Selfcheck: no reference compiler at $reference (make reference)');
		mkdirs("bin/hxmc-t/port");
		var ref = "bin/hxmc-t/self-ref.hxb";
		if (!FileSystem.exists(ref) || mtime(ref) < newest(["haxe/src"])) {
			var r = exec([FileSystem.fullPath(reference), "-cp", "haxe/src", "-main", "haxe.Main", "-D", "disable-parallelism", "--interp", "--no-output", "--hxb", ref], {merge: true});
			if (r.code != 0) return fail("the reference's self-compile failed:\n" + r.out);
		}
		var r = exec([tool, "bin/hxmc-t/port/s", "-cp", "haxe/src", "-main", "haxe.Main", "-D", "disable-parallelism", "-cp", "bin/hxmc/std", "--custom-target", "hxmc"], {merge: true});
		if (r.code != 0) return fail("building the port failed:\n" + r.out);
		var ok = true;
		var runs = [["self-compile", null]];
		if (a.has("--small")) runs.push(["self-compile, 256 KB nursery", "256"]);
		if (a.has("--verify")) runs.push(["self-compile, 256 KB nursery, RT_VERIFY", "256v"]);
		for (run in runs) {
			var out = "bin/hxmc-t/self-hxmc.hxb";
			var env:Map<String, Null<String>> = [];
			if (run[1] != null) env["RT_MINOR_KB"] = "256";
			if (run[1] == "256v") env["RT_VERIFY"] = "1";
			var r = exec(["bin/hxmc-t/port/s", "-cp", "haxe/src", "-main", "haxe.Main", "-D", "disable-parallelism", "--interp", "--no-output", "--hxb", out], {env: env, merge: true});
			if (r.code != 0) {
				Sys.println('${run[0]} FAILED:\n' + tail(r.out, 2000));
				ok = false;
				continue;
			}
			var c = HxbCmp.compareArchives(ref, out, null, null);
			Sys.println('${run[0]} ${fixed(r.seconds)} s: ${c.line}');
			ok = ok && c.ok;
		}
		return ok ? 0 : 1;
	}
}
