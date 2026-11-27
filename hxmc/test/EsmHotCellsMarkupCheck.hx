import Harness.*;
import sys.FileSystem;
import sys.io.File;

using StringTools;

// Regression: @:esm.hot.cell must lower when the entry module uses markup/@:build.
class EsmHotCellsMarkupCheck {
	static final TAG = "hot cells markup";
	static final OUT = "bin/test/esm/hot/cells-markup";
	static final SRC = "hxmc/test/esm/hot/cells-markup";

	static function main() {
		var o = parseArgs(Sys.args(), ["--haxe"]);
		var haxe = FileSystem.fullPath(o.opts["--haxe"] ?? hostHaxe());
		if (!FileSystem.exists(haxe)) fail("compiler not found: $haxe");
		rmrf(OUT);
		mkdirs(OUT);
		if (!compile(haxe, "Main")) Sys.exit(1);
		assertBumpHasCell('$OUT/hx/GraphCells.mjs');
		if (!compile(haxe, "GraphCells")) Sys.exit(1);
		assertBumpHasCell('$OUT/hx/GraphCells-only.mjs');
		Sys.println('$TAG: ok');
	}

	static function assertBumpHasCell(path:String):Void {
		var full = root + "/" + path;
		if (!FileSystem.exists(full)) fail("missing emit: " + full);
		var src = File.getContent(full);
		if (src.indexOf(".cell(") < 0 && src.indexOf("$h.cell") < 0) fail("GraphCells emit missing $h.cell lowering:\n" + src);
	}

	static function compile(haxe:String, main:String):Bool {
		var cp = FileSystem.fullPath(SRC);
		var esmStd = FileSystem.fullPath("hxmc/std/esm");
		var js = root + "/" + OUT + (main == "Main" ? "/main.mjs" : "/graph-only.mjs");
		var args = [
			haxe, "-cp", esmStd, "-cp", cp, "-main", main, "-D", "esm", "-D", "esm.hot",
			"-D", "hxmc.no-module-cache", "-D", "hxmc.markup-braces", "-dce", "no", "-js", js
		];
		Sys.println('$TAG: compile --main $main');
		var log = '$OUT/$main-build.log';
		var r = exec(args, {merge: true, log: log});
		if (r.code != 0) {
			Sys.println('compile failed\n' + tail(readText(log), 4000));
			return false;
		}
		if (main == "GraphCells") {
			var src = root + "/" + OUT + "/hx/GraphCells.mjs";
			var dst = root + "/" + OUT + "/hx/GraphCells-only.mjs";
			if (!FileSystem.exists(src)) fail("missing GraphCells emit");
			File.copy(src, dst);
		}
		return true;
	}
}