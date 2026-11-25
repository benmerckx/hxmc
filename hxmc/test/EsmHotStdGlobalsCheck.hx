import Harness.*;
import sys.FileSystem;
import sys.io.File;

using StringTools;

// Cross-module std static inits via $h reg(); lane std-globals of make esm
class EsmHotStdGlobalsCheck {
	static final TAG = "hot std-globals";
	static final OUT = "bin/test/esm/hot/std-globals";

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
		var js = root + "/" + OUT + "/main.mjs";
		var src = '$OUT/Main.hx';
		File.saveContent(src, 'class Util {\n\tpublic static function add(a:Int, b:Int):Int return a + b;\n}\nclass Main {\n\tstatic function main() {\n\t\ttrace(StringTools.winMetaCharacters.length);\n\t\ttrace(Util.add(1, 2));\n\t}\n}\n');
		var args = [haxe, "-cp", OUT, "-main", "Main", "-D", "esm", "-D", "esm.hot", "-js", js];
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
		var st = readText('$OUT/hx/StringTools.mjs');
		if (st.contains("$global.haxe_SysTools.winMetaCharacters")) {
			Sys.println("emit still uses $global for cross-module static (expected $h)");
			return false;
		}
		if (!st.contains(".haxe_SysTools.winMetaCharacters")) {
			Sys.println("missing SysTools winMetaCharacters static link");
			return false;
		}
		Sys.println('$TAG: emit ok');
		return true;
	}

	static function runImport():Bool {
		var runner = '$OUT/run.mjs';
		var dol = String.fromCharCode(36);
		File.saveContent(runner, 'import "./main.mjs";\nimport * as hxrt from "./__hx_esm_runtime.mjs";\n'
			+ 'var reg = hxrt.' + dol + 'h;\n'
			+ 'if( typeof reg.Util?.add !== "function" ) throw new Error("missing static on Util");\n'
			+ 'if( reg.Util.add(1, 2) !== 3 ) throw new Error("static add failed");\n'
			+ 'console.log("hot std-globals: ok");\n');
		var r = exec([Sys.getEnv("NODE") ?? "node", FileSystem.fullPath(runner)], {merge: true, cwd: FileSystem.fullPath(OUT)});
		if (r.code != 0) {
			Sys.println("import failed\n" + r.out);
			return false;
		}
		if (r.out.indexOf("hot std-globals: ok") < 0) {
			Sys.println("unexpected run output\n" + r.out);
			return false;
		}
		return true;
	}
}