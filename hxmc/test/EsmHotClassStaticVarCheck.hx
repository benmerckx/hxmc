import Harness.*;
import sys.FileSystem;
import sys.io.File;

using StringTools;

// Class static vars init before publishClass; lane class-static of make esm
class EsmHotClassStaticVarCheck {
	static final TAG = "hot class-static";
	static final OUT = "bin/test/esm/hot/class-static";
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
		var js = root + "/" + OUT + "/main.mjs";
		File.saveContent('$OUT/Main.hx',
			'class StackRuntime {\n'
			+ '\tpublic static var items:Array<Int> = [];\n'
			+ '\tpublic static function push(x:Int) {\n'
			+ '\t\titems.push(x);\n'
			+ '\t}\n'
			+ '}\n'
			+ 'class Main {\n'
			+ '\tstatic function main() {\n'
			+ '\t\tStackRuntime.push(7);\n'
			+ '\t\ttrace("len=" + StackRuntime.items.length);\n'
			+ '\t}\n'
			+ '}\n');
		var args = [haxe, "-cp", root + "/" + OUT, "-main", "Main", "-D", "esm", "-D", "esm.hot", "-js", js];
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
		var js = readText('$OUT/hx/Main.mjs');
		var pub = js.indexOf("publishClass");
		var init = js.indexOf(".items = ");
		if (pub < 0 || init < 0) {
			Sys.println("missing publishClass or static init");
			return false;
		}
		if (init > pub) {
			Sys.println("static var init must appear before publishClass");
			return false;
		}
		Sys.println('$TAG: emit ok');
		return true;
	}

	static function runImport():Bool {
		var runner = '$OUT/run.mjs';
		File.saveContent(runner,
			'import "./hx/Main.mjs";\n'
			+ 'import * as rt from "./__hx_esm_runtime.mjs";\n'
			+ 'const G = rt.' + DOL + 'h.StackRuntime;\n'
			+ 'G.push(3);\n'
			+ 'if (!G.items || G.items.length !== 1) throw new Error("push failed");\n'
			+ 'console.log("hot class-static: ok");\n');
		var r = exec([Sys.getEnv("NODE") ?? "node", FileSystem.fullPath(runner)], {merge: true, cwd: FileSystem.fullPath(OUT)});
		if (r.code != 0) {
			Sys.println("import failed\n" + r.out);
			return false;
		}
		return r.out.indexOf("hot class-static: ok") >= 0;
	}
}