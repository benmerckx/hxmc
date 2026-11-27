import Harness.*;
import sys.FileSystem;
import sys.io.File;

using StringTools;

// -D esm and -D esm.hot together; lane dual-flavor of make esm
class EsmHotDualCheck {
	static final TAG = "hot dual-flavor";
	static final OUT = "bin/test/esm/hot/dual-flavor";
	static final DOL = String.fromCharCode(36);

	static function main() {
		var o = parseArgs(Sys.args(), ["--haxe"]);
		var haxe = FileSystem.fullPath(o.opts["--haxe"] ?? hostHaxe());
		if (!FileSystem.exists(haxe)) fail("compiler not found: $haxe");
		Sys.putEnv("HAXE_STD_PATH", root + "/haxe/upstream/std");
		rmrf(OUT);
		mkdirs(OUT);
		if (!compileDual(haxe)) Sys.exit(1);
		if (!checkHotRuntime()) Sys.exit(1);
		if (!checkDualEntry()) Sys.exit(1);
		writeRunner('$OUT/run-dual.mjs');
		if (!runDual('$OUT/run-dual.mjs')) Sys.exit(1);
		Sys.println('$TAG: ok');
	}

	static function compileDual(haxe:String):Bool {
		var cp = FileSystem.fullPath("hxmc/test/esm/hot/dual");
		var js = root + "/" + OUT + "/main.mjs";
		var args = [haxe, "-cp", cp, "-main", "Main", "-D", "esm", "-D", "esm.hot", "-js", js];
		var log = '$OUT/dual-build.log';
		Sys.println('$TAG: compile');
		var r = exec(args, {merge: true, log: log});
		if (r.code != 0) {
			Sys.println("dual-flavor: compile failed\n" + tail(readText(log), 2000));
			return false;
		}
		if (!FileSystem.exists('$OUT/main.mjs')) {
			Sys.println("dual-flavor: missing entry main.mjs");
			return false;
		}
		Sys.println("dual-flavor: compile ok");
		return true;
	}

	static function checkHotRuntime():Bool {
		var rt = readText('$OUT/__hx_esm_runtime.mjs');
		var h = DOL + "h";
		if (!rt.contains("export const " + h))
			return failMsg("dual-flavor: runtime missing $" + "h export");
		if (!rt.contains("applyHotPatch"))
			return failMsg("dual-flavor: runtime missing applyHotPatch");
		if (!rt.contains(h + ".registerFunction"))
			return failMsg("dual-flavor: runtime missing hot function registry");
		Sys.println("dual-flavor: hot runtime ok");
		return true;
	}

	static function checkDualEntry():Bool {
		var entry = readText('$OUT/main.mjs');
		var h = DOL + "h";
		if (!entry.contains(h + ".Main.main()")) {
			Sys.println("dual-flavor: entry must call $" + "h.Main.main()");
			return false;
		}
		Sys.println("dual-flavor: entry ok");
		return true;
	}

	static function writeRunner(path:String):Void {
		var hx = DOL + "hx";
		var h = DOL + "h";
		var s = 'import * as ' + hx + ' from "./__hx_esm_runtime.mjs";\n'
			+ 'import "./hx/Main.mjs";\n'
			+ 'if( typeof ' + hx + '.' + h + '.Main === "undefined" ) throw new Error("dual-flavor: missing hot Main");\n'
			+ hx + '.' + h + '.Main.main();\n'
			+ 'console.log("dual-flavor-ok");\n';
		File.saveContent(path, s);
	}

	static function runDual(runner:String):Bool {
		var r = exec([Sys.getEnv("NODE") ?? "node", FileSystem.fullPath(runner)], {merge: true});
		if (r.code != 0) {
			Sys.println("dual-flavor: run failed\n" + r.out);
			return false;
		}
		if (r.out.indexOf("dual-flavor-ok") < 0) {
			Sys.println("dual-flavor: unexpected output:\n" + r.out);
			return false;
		}
		Sys.println("dual-flavor: run ok");
		return true;
	}

	static function failMsg(msg:String):Bool {
		Sys.println(msg);
		return false;
	}
}