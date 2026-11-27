import Harness.*;
import sys.FileSystem;
import sys.io.File;

using StringTools;

// Inner hot closures get distinct runtime instance ids per registration; lane closure-per-invoke of make esm
class EsmHotClosurePerInvokeCheck {
	static final TAG = "hot closure per-invoke";
	static final OUT = "bin/test/esm/hot/closure-per-invoke";
	static final SRC = "hxmc/test/esm/hot/closure-per-invoke";
	static final DOL = String.fromCharCode(36);

	static function main() {
		var o = parseArgs(Sys.args(), ["--haxe"]);
		var haxe = FileSystem.fullPath(o.opts["--haxe"] ?? hostHaxe());
		if (!FileSystem.exists(haxe)) fail("compiler not found: $haxe");
		Sys.putEnv("HAXE_STD_PATH", root + "/" + "haxe/upstream/std");
		rmrf(OUT);
		mkdirs(OUT);
		if (!compile(haxe)) Sys.exit(1);
		if (!checkEmit()) Sys.exit(1);
		if (!runNode()) Sys.exit(1);
		Sys.println('$TAG: ok');
	}

	static function compile(haxe:String):Bool {
		var cp = FileSystem.fullPath(SRC);
		var esmStd = FileSystem.fullPath("hxmc/std/esm");
		var js = root + "/" + OUT + "/main.mjs";
		var args = [haxe, "-cp", esmStd, "-cp", cp, "-main", "Main", "-D", "esm", "-D", "esm.hot", "-dce", "no", "-js", js];
		var log = '$OUT/build.log';
		Sys.println('$TAG: compile');
		var r = exec(args, {merge: true, log: log});
		if (r.code != 0) {
			Sys.println('compile failed\n' + tail(readText(log), 4000));
			return false;
		}
		return true;
	}

	static function checkEmit():Bool {
		var js = readText('$OUT/hx/HotClosurePerInvoke.mjs');
		var reg = DOL + "h.registerClosure";
		var mk = DOL + "h.makeClosure";
		if (js.indexOf(reg) < 0) {
			Sys.println("expected registerClosure in HotClosurePerInvoke emit");
			return false;
		}
		if (js.indexOf(mk + "(" + reg) < 0) {
			Sys.println("expected makeClosure(registerClosure(...)) emit");
			return false;
		}
		if (js.indexOf(mk + '("HotClosurePerInvoke#textNode/λ1"') >= 0) {
			Sys.println("textNode closure must not hard-code lexical id into makeClosure");
			return false;
		}
		Sys.println('$TAG: emit ok');
		return true;
	}

	static function runNode():Bool {
		var run = root + "/" + OUT + "/run.mjs";
		File.saveContent(run,
			'import "./main.mjs";\n');
		var r = exec(["node", run], {merge: true, cwd: root + "/" + OUT});
		if (r.code != 0) {
			Sys.println("node run failed\n" + tail(r.out, 2000));
			return false;
		}
		return true;
	}
}