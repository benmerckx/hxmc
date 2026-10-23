import Harness.*;
import sys.FileSystem;
import sys.io.File;

using StringTools;

// hxmc's output does not depend on the host it runs on: the tool built as a
// WebAssembly module (wasm32-wasi, run under node) must write the same bytes
// as the native tool.
//   <haxe> -cp hxmc/test -cp haxe/test --run Crosshost [--targets T,T,...] [--tool] [--wasm M] [-j N] [case ...]
// The native tool (bin/hxmc/hxmc) builds itself from source as a module
// (bin/hxmc-t/xhost/hxmc.wasm; --wasm reuses one, e.g. the stage0), then both
// build each corpus case (all when none is named) for each target (default:
// all seven, and Linux in the dynamic glibc mode: <target>-glibc) and the outputs are compared byte for byte; --tool also builds
// the tool itself both ways (for the host). Outputs that agree are deleted;
// differing ones stay in bin/hxmc-t/xhost/<target>/.
class Crosshost {
	static final OUT = "bin/hxmc-t/xhost";
	static final TARGETS = ["linux-x86_64", "linux-arm64", "windows-x86_64", "windows-arm64", "macos-x86_64", "macos-arm64", "wasm32-wasi",
		// the dynamic glibc mode (-D hxmc.libc=glibc)
		"linux-x86_64-glibc", "linux-arm64-glibc"];
	public static final TOOL_ARGS = ["-cp", "haxe/src", "-cp", "hxmc/src", "-main", "hxmc.Main", "-D", "disable-parallelism", "-D", "hih_no_generators"];

	static function main() {
		var a = parseArgs(Sys.args(), ["--targets", "--wasm", "-j"]);
		var cases = a.rest;
		if (cases.length == 0) {
			cases = [for (f in FileSystem.readDirectory("hxmc/test/cases")) if (f.endsWith(".hx")) f.substr(0, f.length - 3)];
			cases.sort(compare);
		}
		mkdirs(OUT);
		var t0 = now();
		var wasm = a.get("--wasm");
		if (wasm == null) {
			var b = build(["bin/hxmc/hxmc"], OUT + "/hxmc.wasm", TOOL_ARGS, "wasm32-wasi");
			if (b.err != null) fail("the tool as a module: " + b.err);
			wasm = b.out;
			Sys.println('the tool as a module: ${FileSystem.stat(wasm).size} bytes, ${fixed(now() - t0)}s');
		}
		wasm = FileSystem.fullPath(wasm);
		var jobs = [for (t in a.get("--targets", TARGETS.join(",")).split(",")) for (c in cases) {target: t, name: c}];
		if (a.has("--tool")) jobs.unshift({target: host(), name: "TOOL"});
		var bad = 0;
		parallel(jobs, a.int("-j", cpus()), j -> compareOne(wasm, j.target, j.name), (j, r) -> {
			if (!r.ok) bad++;
			Sys.println(pad(j.target, 15) + " " + pad(j.name, 15) + " " + (r.ok ? "ok  " : "FAIL") + " " + r.detail);
		});
		Sys.println('crosshost: ${jobs.length - bad}/${jobs.length} identical, ${Math.round(now() - t0)}s');
		Sys.exit(bad > 0 ? 1 : 0);
	}

	static function host():String {
		var m = exec(["uname", "-m"]).out.trim();
		var os = exec(["uname", "-s"]).out.trim() == "Darwin" ? "macos" : "linux";
		return os + "-" + (m == "aarch64" || m == "arm64" ? "arm64" : "x86_64");
	}

	public static function nodeWasm(wasm:String):Array<String>
		return ["node", "--no-warnings", "--stack-size=65500", FileSystem.fullPath("hxmc/bootstrap/wasi.mjs"), wasm];

	static function build(tool:Array<String>, out:String, args:Array<String>, target:String):{out:String, err:Null<String>} {
		for (p in [out, out + ".exe"]) if (FileSystem.exists(p)) FileSystem.deleteFile(p);
		rmrf(out + ".hxmc");
		var env:Map<String, Null<String>> = [];
		// the module's own path says nothing about where the runtime objects are
		if (target != "wasm32-wasi") env["HXMC_RT_OBJ"] = FileSystem.fullPath('bin/hxmc/rt/$target/rt.o');
		var glibc = target.endsWith("-glibc");
		var mode = glibc ? ["-D", "hxmc.target=" + target.substr(0, target.length - 6), "-D", "hxmc.libc=glibc"] : ["-D", 'hxmc.target=$target'];
		var r = exec(tool.concat([out]).concat(args).concat(["-cp", "bin/hxmc/std", "--custom-target", "hxmc"]).concat(mode), {env: env, merge: true});
		rmrf(out + ".hxmc");
		if (!FileSystem.exists(out) && FileSystem.exists(out + ".exe")) out += ".exe";
		if (r.code != 0 || !FileSystem.exists(out)) return {out: out, err: 'exit ${r.code}: ' + tail(r.out.trim(), 300)};
		return {out: out, err: null};
	}

	static function compareOne(wasm:String, target:String, name:String):{ok:Bool, detail:String} {
		var d = '$OUT/$target';
		mkdirs(d);
		var args = name == "TOOL" ? TOOL_ARGS : ["-cp", "hxmc/test/cases", "-main", name];
		if (name != "TOOL") {
			args = args.concat(Corpus.caseDefines("hxmc/test/cases/" + name + ".hx")).concat(Corpus.caseResources("hxmc/test/cases/" + name + ".hx"));
			// a case's C companions (Corpus.nativeInputs: built with zig, or skipped)
			var glibc = target.endsWith("-glibc");
			if (!glibc && Corpus.GLIBC_ONLY.exists(name)) return {ok: true, detail: "skipped: " + Corpus.GLIBC_ONLY[name]};
			var native = Corpus.nativeInputs({name: name, cps: ["hxmc/test/cases"], main: name}, glibc ? target.substr(0, target.length - 6) : target, d, glibc ? "glibc" : null);
			if (native.skip != null) return {ok: true, detail: "skipped: " + native.skip};
			if (native.links.length > 0) args = args.concat(["-D", "hxmc.link=" + native.links.join(",")]);
		}
		var n = build(["bin/hxmc/hxmc"], '$d/$name-n', args, target);
		if (n.err != null) return {ok: false, detail: "native tool: " + n.err};
		var w = build(nodeWasm(wasm), '$d/$name-w', args, target);
		if (w.err != null) return {ok: false, detail: "module: " + w.err};
		var x = File.getBytes(n.out), y = File.getBytes(w.out);
		if (x.compare(y) == 0) {
			FileSystem.deleteFile(n.out);
			FileSystem.deleteFile(w.out);
			return {ok: true, detail: '${x.length} bytes, identical'};
		}
		return {ok: false, detail: 'DIFFER: ${x.length} / ${y.length} bytes, first at offset ${firstDiff(x, y)} (${n.out}, ${w.out})'};
	}
}
