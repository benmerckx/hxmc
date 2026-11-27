import Harness.*;
import sys.FileSystem;
import sys.io.File;

using StringTools;

// Static methods with inner closures via registerFunction; lane static-fn of make esm
class EsmHotStaticFnCheck {
	static final TAG = "hot static-fn";
	static final OUT = "bin/test/esm/hot/static-fn-out";
	static final DOL = String.fromCharCode(36);

	static function main() {
		var o = parseArgs(Sys.args(), ["--haxe"]);
		var haxe = FileSystem.fullPath(o.opts["--haxe"] ?? hostHaxe());
		if (!FileSystem.exists(haxe)) fail("compiler not found: $haxe");
		Sys.putEnv("HAXE_STD_PATH", root + "/haxe/upstream/std");
		rmrf(OUT);
		mkdirs(OUT);
		if (!compile(haxe)) Sys.exit(1);
		if (!checkEmit()) Sys.exit(1);
		if (!runImport()) Sys.exit(1);
		Sys.println('$TAG: ok');
	}

	static function compile(haxe:String):Bool {
		var cp = FileSystem.fullPath("hxmc/test/esm/hot/static-fn");
		var js = root + "/" + OUT + "/main.mjs";
		File.saveContent('$OUT/Main.hx',
			'class Main {\n\tstatic function main() {\n\t\tRootNodeMini.create(function(_) {});\n\t\ttrace("ok");\n\t}\n}\n');
		var args = [haxe, "-cp", cp, "-cp", root + "/" + OUT, "-main", "Main", "-D", "esm", "-D", "esm.hot", "-js", js];
		var log = '$OUT/build.log';
		Sys.println('$TAG: compile');
		var r = exec(args, {merge: true, log: log});
		if (r.code != 0) {
			Sys.println("compile failed\n" + tail(readText(log), 2000));
			return false;
		}
		return true;
	}

	static function checkEmit():Bool {
		var js = readText('$OUT/hx/RootNodeMini.mjs');
		if (!js.contains("create = function") && !js.contains("registerFunction")) {
			Sys.println("expected full static create function emit");
			return false;
		}
		if (js.contains("create = (" + DOL + "h.registerClosure")) {
			Sys.println("static create must not be closure-only assignment");
			return false;
		}
		if (js.contains("create = function(" + DOL + "env")) {
			Sys.println("static create must not be hot-wrapped as a closure");
			return false;
		}
		Sys.println('$TAG: emit ok');
		return true;
	}

	static function runImport():Bool {
		var runner = '$OUT/run.mjs';
		File.saveContent(runner, 'import "./main.mjs";\nconsole.log("hot static-fn: ok");\n');
		var r = exec([Sys.getEnv("NODE") ?? "node", FileSystem.fullPath(runner)], {merge: true, cwd: FileSystem.fullPath(OUT)});
		if (r.code != 0) {
			Sys.println("import failed\n" + r.out);
			return false;
		}
		return r.out.indexOf("hot static-fn: ok") >= 0;
	}
}