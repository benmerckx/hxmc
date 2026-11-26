import Harness.*;
import sys.FileSystem;
import sys.io.File;

using StringTools;

// Registry std (Std via $h) must init before cross-module use (shek-dom Dom.attrStr).
// Lane std-registry of make esm.
class EsmHotStdRegistryCheck {
	static final TAG = "hot std-registry";
	static final OUT = "bin/test/esm/hot/std-registry";
	static final SRC = "hxmc/test/esm/hot/std-registry";

	static function main() {
		var o = parseArgs(Sys.args(), ["--haxe"]);
		var haxe = FileSystem.fullPath(o.opts["--haxe"] ?? hostHaxe());
		if (!FileSystem.exists(haxe)) fail("compiler not found: $haxe");
		Sys.putEnv("HAXE_STD_PATH", root + "/haxe/upstream/std");
		rmrf(OUT);
		mkdirs(OUT);
		copyTree(root + "/" + SRC, OUT);
		if (!compile(haxe)) Sys.exit(1);
		if (!checkEmit()) Sys.exit(1);
		if (!runImport()) Sys.exit(1);
		Sys.println('$TAG: ok');
	}

	static function copyTree(src:String, dst:String):Void {
		for (name in FileSystem.readDirectory(src)) {
			var from = src + "/" + name, to = dst + "/" + name;
			if (FileSystem.isDirectory(from)) {
				mkdirs(to);
				copyTree(from, to);
			} else
				File.copy(from, to);
		}
	}

	static function compile(haxe:String):Bool {
		var js = root + "/" + OUT + "/main.mjs";
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
		var entry = readText('$OUT/main.mjs');
		if (!entry.contains('"./hx/Std.mjs"'))
			return failEmit("entry missing side-effect import of Std.mjs");
		var dom = readText('$OUT/hx/Dom.mjs');
		if (dom.indexOf("Std.mjs") < 0)
			return failEmit("Dom must side-effect-import Std.mjs (cross-module registry Std)");
		if (!dom.contains("$h.Std.string"))
			return failEmit("Dom emit missing $h.Std.string");
		Sys.println('$TAG: emit ok');
		return true;
	}

	static function failEmit(msg:String):Bool {
		Sys.println(msg);
		return false;
	}

	static function runImport():Bool {
		var runner = '$OUT/run.mjs';
		File.saveContent(runner, 'import "./main.mjs";\n');
		var r = exec([Sys.getEnv("NODE") ?? "node", FileSystem.fullPath(runner)], {merge: true, cwd: FileSystem.fullPath(OUT)});
		if (r.code != 0) {
			Sys.println("import failed\n" + r.out);
			return false;
		}
		if (r.out.indexOf("42") < 0) {
			Sys.println("unexpected run output\n" + r.out);
			return false;
		}
		return true;
	}
}