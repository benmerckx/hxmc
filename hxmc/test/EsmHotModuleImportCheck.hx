import Harness.*;
import sys.FileSystem;
import sys.io.File;

using StringTools;

// Module emit diff → patch importModules + dev client — make esm-hot-m10
class EsmHotModuleImportCheck {
	static final OUT = "bin/test/esm-hot-m10";
	static final DOL = String.fromCharCode(36);

	static function main() {
		var o = parseArgs(Sys.args(), ["--haxe"]);
		var haxe = FileSystem.fullPath(o.opts["--haxe"] ?? defaultHaxe());
		if (!FileSystem.exists(haxe)) fail("compiler not found: $haxe");
		Sys.putEnv("HAXE_STD_PATH", root + "/haxe/upstream/std");
		rmrf(OUT);
		mkdirs(OUT);
		writeMain("v1");
		if (!compile(haxe, "v1")) Sys.exit(1);
		writeMain("v2");
		if (!compile(haxe, "v2")) Sys.exit(1);
		if (!checkPatch()) Sys.exit(1);
		if (!checkDevClient()) Sys.exit(1);
		Sys.println("esm-hot-m10: ok");
	}

	static function defaultHaxe():String {
		for (c in ["bin/npm/native/" + Sys.getEnv("HXMC_HOST") + "/haxe", "bin/haxe-js"])
			if (c.indexOf("null") < 0 && FileSystem.exists(c)) return FileSystem.fullPath(c);
		return FileSystem.fullPath("bin/npm/native/macos-arm64/haxe");
	}

	static function writeMain(label:String):Void {
		File.saveContent('$OUT/Main.hx',
			'class Main {\n'
			+ '\tstatic var label = "$label";\n'
			+ '\tstatic function main() { trace(label); }\n'
			+ '}\n');
	}

	static function compile(haxe:String, label:String):Bool {
		var js = root + "/" + OUT + "/main.mjs";
		var args = [haxe, "-cp", root + "/" + OUT, "-main", "Main", "-D", "esm", "-D", "esm.hot", "-js", js];
		var log = '$OUT/$label-build.log';
		Sys.println('esm-hot-m10: compile $label');
		var r = exec(args, {merge: true, log: log});
		if (r.code != 0) {
			Sys.println('compile failed\n' + tail(readText(log), 2000));
			return false;
		}
		return true;
	}

	static function checkPatch():Bool {
		if (!FileSystem.exists('$OUT/__hx_hot_patch.mjs')) {
			Sys.println("missing __hx_hot_patch.mjs after v2");
			return false;
		}
		var patch = readText('$OUT/__hx_hot_patch.mjs');
		if (!patch.contains("importModules") || !patch.contains("./hx/Main.mjs")) {
			Sys.println("patch must list changed module import path");
			return false;
		}
		if (!patch.contains("return applyHotPatch")) {
			Sys.println("applyHotPatchFromDev must return applyHotPatch result");
			return false;
		}
		Sys.println("esm-hot-m10: patch ok");
		return true;
	}

	static function checkDevClient():Bool {
		if (!FileSystem.exists('$OUT/__hx_esm_dev_client.mjs')) {
			Sys.println("missing __hx_esm_dev_client.mjs");
			return false;
		}
		var js = readText('$OUT/__hx_esm_dev_client.mjs');
		if (!js.contains("applyDevHotPatch") || !js.contains("__esmHotRemount")) {
			Sys.println("dev client must apply patch and call __esmHotRemount");
			return false;
		}
		Sys.println("esm-hot-m10: dev client ok");
		return true;
	}
}