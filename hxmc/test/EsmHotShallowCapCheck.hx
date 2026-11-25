import Harness.*;
import sys.FileSystem;
import sys.io.File;

using StringTools;

// Outer `var` locals assigned inside hot closures stay lexical — make esm-hot-m9
class EsmHotShallowCapCheck {
	static final OUT = "bin/test/esm-hot-m9";

	static function main() {
		var o = parseArgs(Sys.args(), ["--haxe"]);
		var haxe = FileSystem.fullPath(o.opts["--haxe"] ?? defaultHaxe());
		if (!FileSystem.exists(haxe)) fail("compiler not found: $haxe");
		Sys.putEnv("HAXE_STD_PATH", root + "/haxe/upstream/std");
		rmrf(OUT);
		mkdirs(OUT);
		if (!compile(haxe)) Sys.exit(1);
		if (!checkEmit()) Sys.exit(1);
		Sys.println("esm-hot-m9: ok");
	}

	static function defaultHaxe():String {
		for (c in ["bin/npm/native/" + Sys.getEnv("HXMC_HOST") + "/haxe", "bin/haxe-js"])
			if (c.indexOf("null") < 0 && FileSystem.exists(c)) return FileSystem.fullPath(c);
		return FileSystem.fullPath("bin/npm/native/macos-arm64/haxe");
	}

	static function compile(haxe:String):Bool {
		var js = root + "/" + OUT + "/main.mjs";
		File.saveContent('$OUT/Main.hx',
			'class Binder {\n'
			+ '\tpublic static function textNode(read:() -> String):String {\n'
			+ '\t\tvar acc = "";\n'
			+ '\t\tread();\n'
			+ '\t\tBinder.run(function() {\n'
			+ '\t\t\tacc = read();\n'
			+ '\t\t});\n'
			+ '\t\treturn acc;\n'
			+ '\t}\n'
			+ '\tstatic function run(fn:() -> Void) { fn(); }\n'
			+ '}\n'
			+ 'class Main { static function main() { trace(Binder.textNode(() -> "x")); } }\n');
		var args = [haxe, "-cp", root + "/" + OUT, "-main", "Main", "-D", "esm", "-D", "esm.hot", "-js", js];
		var log = '$OUT/build.log';
		Sys.println("esm-hot-m9: compile");
		var r = exec(args, {merge: true, log: log});
		if (r.code != 0) {
			Sys.println("compile failed\n" + tail(readText(log), 2000));
			return false;
		}
		return true;
	}

	static function checkEmit():Bool {
		var js = readText('$OUT/hx/Main.mjs');
		if (!js.contains("registerClosure") || !js.contains("textNode")) {
			Sys.println("expected hot closure in textNode");
			return false;
		}
		if (js.contains("var $env = {acc:acc") || js.contains("acc:acc,")) {
			Sys.println("outer var acc must not be copied into closure $env");
			return false;
		}
		if (!js.contains("acc = read()")) {
			Sys.println("expected direct acc assignment in closure body");
			return false;
		}
		Sys.println("esm-hot-m9: emit ok");
		return true;
	}
}