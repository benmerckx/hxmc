import Harness.*;
import sys.FileSystem;
import sys.io.File;

using StringTools;

// -L/--library conformance of the port:
//   <haxe> -cp haxe/test --run Haxelib [--server] [--summary <file>]
// A scratch project with a lix scope and two development libraries
// (`lix dev`, no network): hihlib (class path, define, extraParams.hxml) and
// hihdep, which depends on hihlib; `haxelib` is lix's shim (bin/lix/haxelib on
// PATH), which both compilers call for `haxelib path`. Exit codes, stderr and
// the HXB archives must agree. Cases: one library, a library with a
// dependency, several -L in a row, --haxelib-global, a missing library, -L in
// an hxml file; --server also runs each through --connect.
class Haxelib {
	static final GENERATED = "bin/test/haxelib";
	static final FILES = [
		"libs/hihlib/haxelib.json" => '{"name":"hihlib","version":"1.2.3","classPath":"src","license":"MIT","contributors":["x"],"releasenote":"","dependencies":{}}',
		"libs/hihlib/extraParams.hxml" => "-D hihlib_extra=7\n",
		"libs/hihlib/src/hihlib/Tool.hx" => "package hihlib;\nclass Tool {\n\tpublic static function twice(x:Int) return x * 2;\n\t#if hihlib_extra public static var extra = 1; #end\n}\n",
		"libs/hihdep/haxelib.json" => '{"name":"hihdep","version":"0.1.0","classPath":"src","license":"MIT","contributors":["x"],"releasenote":"","dependencies":{"hihlib":""}}',
		"libs/hihdep/src/hihdep/Dep.hx" => "package hihdep;\nclass Dep {\n\tpublic static function run() return hihlib.Tool.twice(21);\n}\n",
		"proj/src/Main.hx" => "class Main {\n\tstatic function main() {\n\t\ttrace(hihlib.Tool.twice(2));\n\t\t#if hihdep trace(hihdep.Dep.run()); #end\n\t}\n}\n",
		"proj/build.hxml" => "-cp src\n-L hihlib\n--main Main\n",
	];
	static final CASES = [
		{name: "one-lib", args: ["-cp", "src", "-L", "hihlib", "--main", "Main"]},
		{name: "dependency", args: ["-cp", "src", "--library", "hihdep", "--main", "Main"]},
		{name: "several", args: ["-cp", "src", "-L", "hihlib", "-L", "hihdep", "--main", "Main"]},
		{name: "lib-flag", args: ["-cp", "src", "-lib", "hihlib", "--main", "Main"]},
		{name: "global", args: ["-cp", "src", "--haxelib-global", "-L", "hihlib", "--main", "Main"]},
		{name: "missing", args: ["-cp", "src", "-L", "nosuchlib", "--main", "Main"]},
		{name: "hxml", args: ["build.hxml"]},
	];

	static function main() {
		var o = parseArgs(Sys.args(), ["--summary"]);
		var ref = [FileSystem.fullPath(Sys.getEnv("HAXE_REFERENCE") ?? "bin/reference/haxe")];
		var port = shellSplit(Sys.getEnv("HAXE_IN_HAXE_PORT") ?? "bin/port/haxe");
		if (FileSystem.exists(port[0])) port[0] = FileSystem.fullPath(port[0]);
		if (!FileSystem.exists("bin/lix/lix")) fail("Haxelib: bin/lix/lix is missing (node make.mjs lix)");
		var lixDir = FileSystem.fullPath("bin/lix");
		var std = root + "/haxe/upstream/std";
		Sys.putEnv("HAXE_STD_PATH", std);
		Sys.putEnv("HAXE_IN_HAXE_STD_PATH", std);
		Sys.putEnv("PATH", lixDir + ":" + Sys.getEnv("PATH"));
		rmrf(GENERATED);
		for (name => text in FILES) {
			mkdirs(haxe.io.Path.directory('$GENERATED/$name'));
			File.saveContent('$GENERATED/$name', text);
		}
		var gen = FileSystem.fullPath(GENERATED);
		var proj = '$gen/proj';
		Sys.putEnv("HAXESHIM_ROOT", '$gen/lix-root');
		for (cmd in [["scope", "create"], ["dev", "hihlib", '$gen/libs/hihlib'], ["dev", "hihdep", '$gen/libs/hihdep']]) {
			var r = exec(['$lixDir/lix'].concat(cmd), {cwd: proj, merge: true});
			if (r.code != 0) fail("lix " + cmd.join(" ") + ": " + r.out);
		}
		// (the scope for haxelib calls from any working directory: the servers')
		Sys.putEnv("HAXESHIM_SCOPE", proj);
		var servers = null;
		Server.gen = gen;
		if (o.has("--server")) servers = {r: Server.startServer("reference", ref, '$gen/reference-server.log'), p: Server.startServer("port", port, '$gen/port-server.log')};
		var failures = 0, lines = [];
		for (c in CASES)
			for (mode in (servers == null ? ["batch"] : ["batch", "server"])) {
				var outs = new Map<String, {o:Server.ServerOut, hxb:String}>();
				for (x in [{who: "ref", cmd: ref}, {who: "port", cmd: port}]) {
					var hxb = '$gen/${c.name}-$mode-${x.who}.hxb';
					var cache = mode == "server" ? ["-D", "disable-hxb-cache"] : [];
					var full = ["--hxb", hxb, "-D", "disable-parallelism"].concat(cache).concat(["--interp", "--no-output"]).concat(c.args);
					var res:Server.ServerOut = if (mode == "batch") {
						var r = exec(x.cmd.concat(full), {cwd: proj});
						{code: Std.string(r.code), out: r.out, err: r.err};
					} else Server.client(x.cmd, x.who == "ref" ? servers.r.port : servers.p.port, full, proj);
					var tag = '-${x.who}.hxb';
					outs[x.who] = {o: {code: res.code, out: res.out.replace(tag, "-X.hxb"), err: res.err.replace(tag, "-X.hxb")}, hxb: hxb};
				}
				var detail = @:privateAccess Server.compareOutputs(outs["ref"].o, outs["port"].o, outs["ref"].hxb, outs["port"].hxb, gen);
				var status = detail == null ? "PASS" : "FAIL";
				if (detail == null) detail = outs["ref"].o.code != "0" ? "both reject: " + outs["ref"].o.err.trim().split("\n")[0].substr(0, 100) : readZip(outs["ref"].hxb).names.length + " members identical";
				if (status == "FAIL") failures++;
				var line = pad(status, 6) + " " + pad(c.name + "/" + mode, 24) + " " + detail;
				Sys.println(line);
				lines.push(line);
			}
		if (servers != null) {
			Server.stopServer(servers.r);
			Server.stopServer(servers.p);
		}
		summary(o.get("--summary"), "### -L (haxelib through lix)\n\n```\n" + lines.join("\n") + "\n```\n\n");
		Sys.exit(failures > 0 ? 1 : 0);
	}
}
