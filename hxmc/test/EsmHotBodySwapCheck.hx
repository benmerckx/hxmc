import Harness.*;
import sys.FileSystem;
import sys.io.File;

using StringTools;

// In-process applyHotPatch body swap; lane body-swap of make esm
class EsmHotBodySwapCheck {
	static final TAG = "hot body-swap";
	static final OUT = "bin/test/esm/hot/body-swap";
	static final FIXTURE = "hxmc/test/esm/hot/body-swap";
	static final DOL = String.fromCharCode(36);

	static function main() {
		var o = parseArgs(Sys.args(), ["--haxe"]);
		var haxe = FileSystem.fullPath(o.opts["--haxe"] ?? hostHaxe());
		if (!FileSystem.exists(haxe)) fail("compiler not found: $haxe");
		rmrf(OUT);
		mkdirs(OUT);
		if (!compile(haxe, "v1")) Sys.exit(1);
		writeRunner('$OUT/run.mjs');
		Sys.println('$TAG: run patch');
		var r = exec(["node", FileSystem.fullPath('$OUT/run.mjs')], {merge: true});
		if (r.code != 0) {
			Sys.println('$TAG: patch failed');
			Sys.exit(1);
		}
		Sys.println('$TAG: ok');
	}

	static function compile(haxe:String, label:String):Bool {
		var cp = FileSystem.fullPath(FIXTURE);
		var js = root + "/" + OUT + "/main.mjs";
		var args = [haxe, "-cp", cp, "-main", "Main", "-D", "esm", "-D", "esm.hot", "-js", js];
		Sys.println('$TAG: compile $label');
		var log = '$OUT/$label-build.log';
		var r = exec(args, {merge: true, log: log});
		if (r.code != 0) {
			Sys.println('compile failed\n' + tail(readText(log), 2000));
			return false;
		}
		return true;
	}

	static function writeRunner(path:String):Void {
		var uid = "SwapTarget#version";
		var hx = DOL + "hx";
		var h = DOL + "h";
		var s = 'import * as ' + hx + ' from "./__hx_esm_runtime.mjs";\n'
			+ 'import "./hx/SwapTarget.mjs";\n'
			+ 'import "./hx/Main.mjs";\n'
			+ 'const before = ' + hx + '.' + h + '.SwapTarget.version();\n'
			+ 'if( before !== "v1" ) throw new Error("before: " + before);\n'
			+ hx + '.applyHotPatch({units:[{id:"' + uid + '",tier:1,hash:"v2",fn:function(){return "v2";}}]});\n'
			+ 'const after = ' + hx + '.' + h + '.SwapTarget.version();\n'
			+ 'if( after !== "v2" ) throw new Error("after: " + after);\n';
		File.saveContent(path, s);
	}
}