import Harness.*;
import sys.FileSystem;
import sys.io.File;

using StringTools;

// Genesm layout checks (extern modules not emitted, shared $hx_exports):
//   bin/hxmc/hxmc -cp hxmc/test -cp haxe/test --run EsmGenesmCheck [--haxe <compiler>]
// Lane `genesm` of make esm (Esm.hx).
class EsmGenesmCheck {
	static final OUT = "bin/test/esm-genesm";
	static final DOL = String.fromCharCode(36);

	static function main() {
		var o = parseArgs(Sys.args(), ["--haxe"]);
		var haxe = FileSystem.fullPath(o.opts["--haxe"] ?? hostHaxe());
		if (!FileSystem.exists(haxe)) fail("compiler not found: $haxe (make npm natives or pass --haxe)");
		Sys.putEnv("HAXE_STD_PATH", root + "/haxe/upstream/std");
		rmrf(OUT);
		mkdirs(OUT);
		var failed = 0;
		if (!checkExternNoEmit(haxe)) failed++;
		if (!checkSharedHxExports(haxe)) failed++;
		if (!checkProdStaticImports(haxe)) failed++;
		if (!checkProdBundlerSmoke(haxe)) failed++;
		Sys.exit(failed > 0 ? 1 : 0);
	}

	static function compile(haxe:String, label:String, cp:String, main:String, js:String):Bool {
		var outJs = js.indexOf("/") == 0 ? js : root + "/" + js;
		var args = [haxe, "-cp", FileSystem.fullPath(cp), "-main", main, "-D", "esm", "-js", outJs];
		var log = '$OUT/$label-build.log';
		var r = exec(args, {merge: true, log: log});
		if (r.code != 0) {
			Sys.println('$label: compile failed\n' + tail(readText(log), 2000));
			return false;
		}
		return true;
	}

	static function checkExternNoEmit(haxe:String):Bool {
		var dir = '$OUT/extern';
		mkdirs(dir);
		var cp = "hxmc/test/esm/genesm/extern";
		var js = '$dir/main.mjs';
		if (!compile(haxe, "extern-no-emit", cp, "Main", js)) return false;
		var htmlDir = '$dir/hx/js/html';
		if (FileSystem.exists(htmlDir)) {
			Sys.println("extern-no-emit: unexpected $htmlDir");
			return false;
		}
		var symbol = '$dir/hx/js/lib/Symbol.mjs';
		if (FileSystem.exists(symbol)) {
			Sys.println("extern-no-emit: emitted pure extern module $symbol");
			return false;
		}
		var entry = readText(js);
		for (line in entry.split("\n")) {
			var t = StringTools.trim(line);
			if (StringTools.startsWith(t, "import ") && t.indexOf("js/html") >= 0) {
				Sys.println("extern-no-emit: entry imports js/html: $t");
				return false;
			}
		}
		Sys.println("extern-no-emit: ok");
		return true;
	}

	static function checkSharedHxExports(haxe:String):Bool {
		var dir = '$OUT/expose';
		mkdirs(dir);
		var cp = "hxmc/test/esm/genesm/expose";
		var js = '$dir/main.mjs';
		if (!compile(haxe, "shared-hx-exports", cp, "Main", js)) return false;
		var runtime = readText('$dir/__hx_esm_runtime.mjs');
		var rtExport = "export const " + DOL + "hx_exports = " + DOL + "global." + DOL + "hx_exports";
		if (!runtime.contains(rtExport))
			return failMsg("shared-hx-exports: runtime missing shared hx_exports export");
		var bind = "const " + DOL + "hx_exports = " + DOL + "hx." + DOL + "hx_exports";
		var reassign = DOL + "global." + DOL + "hx_exports = " + DOL + "hx_exports";
		var emptyLocal = "var " + DOL + "hx_exports = {}";
		var hxExports = DOL + "hx_exports";
		for (rel in walk('$dir/hx', ".mjs")) {
			var text = readText('$dir/hx/$rel');
			if (text.contains(reassign))
				return failMsg("shared-hx-exports: module reassigns global hx_exports: hx/" + rel);
			if (text.contains(emptyLocal))
				return failMsg("shared-hx-exports: module uses local empty hx_exports: hx/" + rel);
			if (text.contains(hxExports) && !text.contains(bind))
				return failMsg("shared-hx-exports: module does not bind hx_exports from runtime: hx/" + rel);
		}
		var runner = '$dir/run-exports.mjs';
		File.saveContent(runner, "import * as " + DOL + 'hx from "./__hx_esm_runtime.mjs";\n'
			+ 'import "./hx/ExposeA.mjs";\n'
			+ 'import "./hx/ExposeB.mjs";\n'
			+ "if (" + DOL + "hx." + DOL + 'hx_exports.genesmA !== 1) throw new Error("genesmA");\n'
			+ "if (" + DOL + "hx." + DOL + 'hx_exports.genesmB !== 2) throw new Error("genesmB");\n');
		var r = exec([Sys.getEnv("NODE") ?? "node", FileSystem.fullPath(runner)], {cwd: dir, merge: true});
		if (r.code != 0) {
			Sys.println("shared-hx-exports: runtime check failed\n" + r.out);
			return false;
		}
		Sys.println("shared-hx-exports: ok");
		return true;
	}

	static function failMsg(msg:String):Bool {
		Sys.println(msg);
		return false;
	}

	static function checkProdStaticImports(haxe:String):Bool {
		var dir = '$OUT/prod-imports';
		mkdirs(dir);
		var cp = "hxmc/test/esm/src";
		var js = '$dir/main.mjs';
		if (!compile(haxe, "prod-static-imports", cp, "Main", js)) return false;
		var mainHx = readText('$dir/hx/Main.mjs');
		if (!mainHx.contains('import { Util }'))
			return failMsg("prod-static-imports: Main.mjs missing static Util import");
		if (mainHx.contains(DOL + "global.Util"))
			return failMsg("prod-static-imports: Main.mjs still uses " + DOL + "global for sibling types");
		var entry = readText(js);
		if (!entry.contains('import { Main }'))
			return failMsg("prod-static-imports: entry missing Main named import");
		var r = exec([Sys.getEnv("NODE") ?? "node", FileSystem.fullPath(js)], {cwd: dir, merge: true});
		if (r.code != 0) {
			Sys.println("prod-static-imports: run failed\n" + r.out);
			return false;
		}
		Sys.println("prod-static-imports: ok");
		return true;
	}

	static function checkProdBundlerSmoke(haxe:String):Bool {
		var dir = '$OUT/bundler-smoke';
		mkdirs(dir);
		var cp = "hxmc/test/esm/src";
		var js = '$dir/main.mjs';
		if (!compile(haxe, "prod-bundler", cp, "Main", js)) return false;
		var absJs = FileSystem.fullPath(js);
		var npxR = exec(["which", "npx"], {merge: true});
		var npx = npxR.code == 0 ? StringTools.trim(npxR.out).split("\n")[0] : "npx";
		var b = exec([npx, "--yes", "esbuild", absJs, "--bundle", "--platform=node", "--format=esm", "--outfile=bundle.mjs"],
			{cwd: dir, merge: true});
		if (b.code != 0) {
			Sys.println("prod-bundler: esbuild failed\n" + tail(b.out, 2000));
			return false;
		}
		var bundle = '$dir/bundle.mjs';
		var r = exec([Sys.getEnv("NODE") ?? "node", FileSystem.fullPath(bundle)], {cwd: dir, merge: true});
		if (r.code != 0) {
			Sys.println("prod-bundler: run failed\n" + r.out);
			return false;
		}
		Sys.println("prod-bundler: ok");
		return true;
	}
}