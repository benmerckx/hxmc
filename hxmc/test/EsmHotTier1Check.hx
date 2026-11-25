import Harness.*;
import sys.FileSystem;
import sys.io.File;

using StringTools;

// Tier-1 hot body swap (in-process applyHotPatch): make esm-hot-m0
class EsmHotTier1Check {
	static final OUT = "bin/test/esm-hot-m0";
	static final DOL = String.fromCharCode(36);

	static function main() {
		var o = parseArgs(Sys.args(), ["--haxe"]);
		var haxe = FileSystem.fullPath(o.opts["--haxe"] ?? defaultHaxe());
		if (!FileSystem.exists(haxe)) fail("compiler not found: $haxe");
		rmrf(OUT);
		mkdirs(OUT);
		if (!compile(haxe, "v1")) Sys.exit(1);
		writeRunner('$OUT/run.mjs');
		Sys.println("esm-hot-m0: run tier-1 patch");
		var r = exec(["node", FileSystem.fullPath('$OUT/run.mjs')], {merge: true});
		if (r.code != 0) {
			Sys.println("EsmHotTier1Check: tier-1 patch failed");
			Sys.exit(1);
		}
		Sys.println("esm-hot-m0: ok");
	}

	static function defaultHaxe():String {
		for (c in ["bin/npm/native/" + Sys.getEnv("HXMC_HOST") + "/haxe", "bin/haxe-js"])
			if (c.indexOf("null") < 0 && FileSystem.exists(c)) return FileSystem.fullPath(c);
		return FileSystem.fullPath("bin/npm/native/macos-arm64/haxe");
	}

	static function compile(haxe:String, label:String):Bool {
		var cp = FileSystem.fullPath("hxmc/test/esm/hot/tier1");
		var js = root + "/" + OUT + "/main.mjs";
		var args = [haxe, "-cp", cp, "-main", "Main", "-D", "esm", "-D", "esm.hot", "-js", js];
		Sys.println('esm-hot-m0: compile $label');
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