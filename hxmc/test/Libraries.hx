import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using StringTools;

// -lib with the npm package's compiler (hxmc/src/hxmc/libs: lix's scopes,
// node_modules, haxelib without a process; `make test-libraries`; CI: after
// `make npm`, and in the npm job with the installed package's native
// compiler, run without node):
//   <haxe> -cp hxmc/test --run Libraries [--haxe <compiler>] [--dir <scratch>]
// (default: bin/npm/native/<this machine>/haxe[.exe], bin/test/libraries).
// The programs run with --interp and print what the libraries gave them.
// - node_modules: a project with node_modules/@hxmc/demo ("haxe": class
//   path, an hxml, dependencies), its dependency demo-dep (which depends on
//   @hxmc/demo again) and left-pad (no "haxe" field); cases: -lib, -L with
//   the package's name, --library name:version, nested hxml files, a
//   subdirectory (node_modules of a parent);
// - haxelib: a repository (HAXELIB_PATH) for a version node_modules does not
//   have and an unknown name;
// - lix's scopes (a .haxerc; HAXESHIM_ROOT in the scratch directory, with the
//   same repository as its haxelib): haxe_libraries/<name>.hxml before
//   node_modules, node_modules before the scope's error, mixed's haxelib, a
//   missing class path, a library once per part and once in each --next
//   part, the global scope;
// - the cpp generator's `haxelib path hxcpp` (Options.txt's hxcpp=, with
//   -D no-compilation): lix's haxe_libraries/hxcpp.hxml, haxelib's hxcpp.
// hxmc/test/LibResolution.hx compares the resolution with haxelib's and lix's.
class Libraries {
	static var haxe:String;
	static var failures = 0;

	static final FILES = [
		"proj/node_modules/@hxmc/demo/package.json" => '{"name": "@hxmc/demo", "version": "1.2.3", "haxe": {"name": "hxmc.demo", "classPath": "src", "hxml": "extra.hxml"}, "dependencies": {"demo-dep": "*", "left-pad": "*"}, "peerDependencies": {"@hxmc/cli": "*"}}',
		"proj/node_modules/@hxmc/demo/extra.hxml" => "# the extra hxml\n-D demo_extra=7\n",
		"proj/node_modules/@hxmc/demo/src/hxmc/demo/Demo.hx" => "package hxmc.demo;\nclass Demo {\n\tpublic static function hello() return 'demo and ' + demo.dep.Dep.name();\n}\n",
		"proj/node_modules/demo-dep/package.json" => '{"name": "demo-dep", "version": "0.1.0", "haxe": {"name": "demo.dep", "classPath": "lib"}, "dependencies": {"@hxmc/demo": "*"}}',
		"proj/node_modules/demo-dep/lib/demo/dep/Dep.hx" => "package demo.dep;\nclass Dep {\n\tpublic static function name() return 'dep';\n}\n",
		"proj/node_modules/left-pad/package.json" => '{"name": "left-pad", "version": "1.0.0"}',
		"proj/src/Main.hx" => "class Main {\n\tstatic function main() {\n\t\tSys.println(hxmc.demo.Demo.hello());\n\t\tSys.println(haxe.macro.Compiler.getDefine('hxmc.demo') + ' ' + haxe.macro.Compiler.getDefine('demo.dep') + ' ' + haxe.macro.Compiler.getDefine('demo_extra'));\n\t}\n}\n",
		"proj/src/Other.hx" => "class Other {\n\tstatic function main() Sys.println(other.Lib.name());\n}\n",
		"proj/build.hxml" => "-cp src\nlibs.hxml\n-main Main\n--interp\n",
		"proj/libs.hxml" => "# nested\n-lib hxmc.demo\n",
		"proj/sub/.keep" => "",
		// haxelib's repository
		"root/haxelib/.repo-version" => "1\n",
		"root/haxelib/hxmc,demo/.current" => "9.9.9",
		"root/haxelib/hxmc,demo/9,9,9/haxelib.json" => '{"name": "hxmc.demo", "version": "9.9.9", "classPath": "src"}',
		"root/haxelib/hxmc,demo/9,9,9/src/hxmc/demo/Demo.hx" => "package hxmc.demo;\nclass Demo {\n\tpublic static function hello() return 'haxelib demo 9.9.9';\n}\n",
		"root/haxelib/other/.current" => "1.0.0",
		"root/haxelib/other/1,0,0/other/Lib.hx" => "package other;\nclass Lib {\n\tpublic static function name() return 'haxelib other';\n}\n",
		"root/haxelib/hxcpp/.current" => "4.3.2",
		"root/haxelib/hxcpp/4,3,2/haxelib.json" => '{"name": "hxcpp", "version": "4.3.2"}',
		"proj/src/Plain.hx" => "class Plain {\n\tstatic function main() {}\n}\n",
		// lix's scope
		"lixproj/.haxerc" => '{"version": "4.3.7", "resolveLibs": "scoped"}',
		"lixproj/haxe_libraries/hxmc.demo.hxml" => "# @install: lix --silent download haxelib:/hxmc.demo#0.0.1\n-cp ${SCOPE_DIR}/lixlib/demo\n-D hxmc.demo=0.0.1\n",
		"lixproj/haxe_libraries/x.hxml" => "-cp ${SCOPE_DIR}/lixlib/x\n--macro Sys.println('x added')\n",
		"lixproj/haxe_libraries/y.hxml" => "-lib x\n-D y\n",
		"lixproj/haxe_libraries/broken.hxml" => "-cp ${SCOPE_DIR}/nowhere\n",
		"lixproj/lixlib/demo/hxmc/demo/Demo.hx" => "package hxmc.demo;\nclass Demo {\n\tpublic static function hello() return 'lix demo';\n}\n",
		"lixproj/haxe_libraries/hxcpp.hxml" => "-cp ${SCOPE_DIR}/fakehxcpp\n-D hxcpp=4.3.2\n",
		"lixproj/fakehxcpp/.keep" => "",
		"lixproj/src/Plain.hx" => "class Plain {\n\tstatic function main() {}\n}\n",
		"lixproj/lixlib/x/X.hx" => "class X {\n\tpublic static function name() return 'x';\n}\n",
		"lixproj/node_modules/@hxmc/demo/package.json" => '{"name": "@hxmc/demo", "version": "1.2.3", "haxe": {"name": "hxmc.demo", "classPath": "src"}}',
		"lixproj/node_modules/node-only/package.json" => '{"name": "node-only", "version": "1.0.0", "haxe": {"name": "node.only", "classPath": "src"}}',
		"lixproj/node_modules/node-only/src/node/only/N.hx" => "package node.only;\nclass N {\n\tpublic static function hi() return 'node only';\n}\n",
		"lixproj/src/Main.hx" => "class Main {\n\tstatic function main() Sys.println(hxmc.demo.Demo.hello());\n}\n",
		"lixproj/src/Node.hx" => "class Node {\n\tstatic function main() Sys.println(node.only.N.hi());\n}\n",
		"lixproj/src/Other.hx" => "class Other {\n\tstatic function main() Sys.println(other.Lib.name());\n}\n",
		"lixproj/src/UseX.hx" => "class UseX {\n\tstatic function main() Sys.println(X.name() + ' ' + haxe.macro.Compiler.getDefine('y'));\n}\n",
		"lixmixed/.haxerc" => '{"version": "4.3.7", "resolveLibs": "mixed"}',
		"lixmixed/src/Other.hx" => "class Other {\n\tstatic function main() Sys.println(other.Lib.name());\n}\n",
		"global/src/Other.hx" => "class Other {\n\tstatic function main() Sys.println(other.Lib.name() + ' ' + haxe.macro.Compiler.getDefine('global'));\n}\n",
	];

	static function main() {
		var args = Sys.args();
		function opt(name:String, def:String) {
			var i = args.indexOf(name);
			return i >= 0 && i + 1 < args.length ? args[i + 1] : def;
		}
		var windows = Sys.systemName() == "Windows";
		var host = (switch Sys.systemName() {
			case "Windows": "windows";
			case "Mac": "macos";
			case _: "linux";
		}) + "-" + (Sys.getEnv("PROCESSOR_ARCHITECTURE") == "ARM64" || ~/arm64|aarch64/i.match(uname()) ? "arm64" : "x86_64");
		haxe = FileSystem.fullPath(opt("--haxe", 'bin/npm/native/$host/haxe' + (windows ? ".exe" : "")));
		var dir = opt("--dir", "bin/test/libraries");
		// (the repository's std, unless the compiler finds its own)
		if (Sys.getEnv("HAXE_STD_PATH") == null && FileSystem.exists("haxe/upstream/std"))
			Sys.putEnv("HAXE_STD_PATH", FileSystem.fullPath("haxe/upstream/std"));
		rmrf(dir);
		for (name => text in FILES) {
			FileSystem.createDirectory(Path.directory('$dir/$name'));
			File.saveContent('$dir/$name', text);
		}
		dir = FileSystem.fullPath(dir);
		// (lix's root here, without a global .haxerc until the last case)
		Sys.putEnv("HAXESHIM_ROOT", '$dir/root');
		Sys.putEnv("HAXESHIM_SCOPE", null);
		Sys.putEnv("HAXELIB_PATH", '$dir/root/haxelib');
		var demo = ["demo and dep", "1.2.3 0.1.0 7"];
		var proj = '$dir/proj';
		check("-lib", proj, ["-cp", "src", "-lib", "hxmc.demo", "-main", "Main", "--interp"], demo);
		check("-L with the package's name", proj, ["-cp", "src", "-L", "@hxmc/demo", "-main", "Main", "--interp"], demo);
		check("--library name:version", proj, ["-cp", "src", "--library", "hxmc.demo:1.2.3", "-main", "Main", "--interp"], demo);
		check("nested hxml", proj, ["build.hxml"], demo);
		check("a parent's node_modules", '$proj/sub', ["-cp", "../src", "-lib", "hxmc.demo", "-main", "Main", "--interp"], demo);
		check("another version: haxelib", proj, ["-cp", "src", "-lib", "hxmc.demo:9.9.9", "-main", "Main", "--interp"], ["haxelib demo 9.9.9", "9.9.9 null null"]);
		check("an unknown name: haxelib", proj, ["-cp", "src", "-lib", "other", "-main", "Other", "--interp"], ["haxelib other"]);
		check("node_modules and haxelib together", proj, ["-cp", "src", "-lib", "other", "-lib", "hxmc.demo", "-main", "Main", "--interp"], demo);
		checkHxcpp("the cpp generator's hxcpp: haxelib's", proj, "hxcpp/4,3,2/");
		check("haxelib's error", proj, ["-cp", "src", "-lib", "nothing", "-main", "Other", "--interp"], null, "Error: Library nothing is not installed");
		var lix = '$dir/lixproj';
		check("lix: haxe_libraries before node_modules", lix, ["-cp", "src", "-lib", "hxmc.demo", "-main", "Main", "--interp"], ["lix demo"]);
		check("lix: node_modules before the scope's error", lix, ["-cp", "src", "-lib", "node.only", "-main", "Node", "--interp"], ["node only"]);
		// (the messages' paths: LibResolution compares them with lix's)
		check("lix: scoped, a missing library", lix, ["-cp", "src", "-lib", "other", "-main", "Other", "--interp"], null, "-lib other is missing ");
		check("lix: a missing class path", lix, ["-cp", "src", "-lib", "broken", "-main", "Main", "--interp"], null,
			"nowhere is not a directory or cannot be read from");
		check("lix: a library once per part", lix, ["-lib", "x", "-cp", "src", "-lib", "y", "-main", "UseX", "--interp"], ["x added", "x 1"]);
		check("lix: and in each --next part", lix, ["-lib", "y", "-cp", "src", "-main", "UseX", "--interp", "--next", "--cwd", lix, "-lib", "x", "-lib", "y", "-cp", "src", "-main", "UseX", "--interp"],
			["x added", "x 1", "x added", "x 1"]);
		checkHxcpp("lix: the cpp generator's hxcpp", lix, "fakehxcpp/");
		check("lix: mixed, haxelib's", '$dir/lixmixed', ["-cp", "src", "-lib", "other", "-main", "Other", "--interp"], ["haxelib other"]);
		File.saveContent('$dir/root/.haxerc', '{"version": "4.3.7"}');
		FileSystem.createDirectory('$dir/root/haxe_libraries');
		File.saveContent('$dir/root/haxe_libraries/other.hxml', "-D global\n-lib other:1.0.0\n");
		check("lix: the global scope (mixed)", '$dir/global', ["-cp", "src", "-lib", "other", "-main", "Other", "--interp"], ["haxelib other 1"]);
		Sys.println(failures == 0 ? "Libraries: all passed" : 'Libraries: $failures failed');
		Sys.exit(failures == 0 ? 0 : 1);
	}

	// expect: the program's output lines; or null and error: a line of the
	// compiler's error output
	static function check(name:String, cwd:String, args:Array<String>, expect:Null<Array<String>>, ?error:String) {
		var p = new sys.io.Process(haxe, ["--cwd", cwd].concat(args));
		var out = p.stdout.readAll().toString().replace("\r", "");
		var err = p.stderr.readAll().toString().replace("\r", "");
		var code = p.exitCode();
		p.close();
		var ok = if (expect == null) code != 0 && Lambda.exists(err.split("\n"), l -> l.contains(error)) else code == 0
			&& out.trim().split("\n").join("|") == expect.join("|");
		Sys.println((ok ? "ok   " : "FAIL ") + name);
		if (!ok) {
			failures++;
			Sys.println('  haxe ${args.join(" ")} (in $cwd): exit $code\n  expected: ${expect == null ? "an error: " + error : expect.join("|")}\n  stdout: ${out.trim()}\n  stderr: ${err.trim()}');
		}
	}

	// a cpp build without the native compilation: Options.txt's hxcpp= ends with suffix
	static function checkHxcpp(name:String, cwd:String, suffix:String) {
		var out = '$cwd/cpp-out';
		var p = new sys.io.Process(haxe, ["--cwd", cwd, "-cp", "src", "-main", "Plain", "--cpp", out, "-D", "no-compilation"]);
		var err = p.stderr.readAll().toString().replace("\r", "");
		p.stdout.readAll();
		var code = p.exitCode();
		p.close();
		var options = try File.getContent('$out/Options.txt').replace("\r", "") catch (_:Dynamic) "";
		var line = Lambda.find(options.split("\n"), l -> l.startsWith("hxcpp="));
		var ok = code == 0 && line != null && line.endsWith(suffix);
		Sys.println((ok ? "ok   " : "FAIL ") + name);
		if (!ok) {
			failures++;
			Sys.println('  haxe --cpp (in $cwd): exit $code\n  expected: hxcpp=...$suffix\n  got: $line\n  stderr: ${err.trim()}');
		}
	}

	static function uname():String {
		if (Sys.systemName() == "Windows") return "";
		try {
			var p = new sys.io.Process("uname", ["-m"]);
			var s = p.stdout.readAll().toString();
			p.close();
			return s;
		} catch (_:Dynamic) return "";
	}

	static function rmrf(path:String) {
		if (!FileSystem.exists(path)) return;
		if (FileSystem.isDirectory(path)) {
			for (e in FileSystem.readDirectory(path)) rmrf('$path/$e');
			FileSystem.deleteDirectory(path);
		} else FileSystem.deleteFile(path);
	}
}
