import Harness.*;
import sys.FileSystem;
import sys.io.File;

using StringTools;

// Hot cells, closures, keyed call ordinals; lane cells of make esm
class EsmHotCellsCheck {
	static final TAG = "hot cells";
	static final OUT = "bin/test/esm/hot/cells";
	static final SRC = "hxmc/test/esm/hot/cells";
	static final DOL = String.fromCharCode(36);

	static function main() {
		var o = parseArgs(Sys.args(), ["--haxe"]);
		var haxe = FileSystem.fullPath(o.opts["--haxe"] ?? hostHaxe());
		if (!FileSystem.exists(haxe)) fail("compiler not found: $haxe");
		rmrf(OUT);
		mkdirs(OUT);
		prepareKeyedSiteV1();
		if (!compile(haxe, "v1")) Sys.exit(1);
		assertCellEmitIds();
		snapshotKeyedSiteV1();
		writeRunner('$OUT/run-v1.mjs');
		prepareKeyedSiteV2();
		if (!compile(haxe, "v2")) Sys.exit(1);
		writeRunnerV2('$OUT/run-v2.mjs');
		writeOrchestrator('$OUT/run.mjs');
		Sys.println('$TAG: run integration');
		var r = exec(["node", FileSystem.fullPath('$OUT/run.mjs')], {merge: true});
		if (r.code != 0) {
			Sys.println('$TAG: failed');
			Sys.exit(1);
		}
		Sys.println('$TAG: ok');
	}

	static function assertCellEmitIds():Void {
		var keyed = readText(root + "/" + OUT + "/hx/KeyedSite.mjs");
		if (keyed.indexOf("#cell.n") < 0) fail("KeyedSite emit missing #cell.n suffix:\n" + keyed);
		if (keyed.indexOf("??") < 0 && keyed.indexOf("__hotId") < 0)
			fail("KeyedSite keyed cell id should use hotId ?? unitId:\n" + keyed);
		var multi = readText(root + "/" + OUT + "/hx/KeyedMultiCell.mjs");
		if (multi.indexOf("#cell.n") < 0 || multi.indexOf("#cell.m") < 0)
			fail("KeyedMultiCell emit missing per-var #cell.* ids:\n" + multi);
		var fixed = readText(root + "/" + OUT + "/hx/HotCellFixed.mjs");
		if (fixed.indexOf("app.counter") < 0) fail("HotCellFixed emit missing explicit cell id:\n" + fixed);
	}

	static function prepareKeyedSiteV1():Void {
		var dst = FileSystem.fullPath(SRC + "/KeyedSite.hx");
		File.saveContent(dst, File.getContent(FileSystem.fullPath(SRC + "/KeyedSite.v1.hx")));
	}

	static function prepareKeyedSiteV2():Void {
		var dst = FileSystem.fullPath(SRC + "/KeyedSite.hx");
		File.saveContent(dst, File.getContent(FileSystem.fullPath(SRC + "/KeyedSite.v2.hx")));
	}

	static function snapshotKeyedSiteV1():Void {
		var src = root + "/" + OUT + "/hx/KeyedSite.mjs";
		var dst = root + "/" + OUT + "/hx/KeyedSite.v1.mjs";
		if (!FileSystem.exists(src)) fail('missing KeyedSite emit after compile: $src');
		File.copy(src, dst);
	}

	static function writeOrchestrator(path:String):Void {
		File.saveContent(path, 'import { spawnSync } from "node:child_process";\n'
			+ 'const a = spawnSync("node", ["run-v1.mjs"], { cwd: import.meta.dirname, stdio: "inherit" });\n'
			+ 'if( a.status !== 0 ) process.exit(a.status ?? 1);\n'
			+ 'const b = spawnSync("node", ["run-v2.mjs"], { cwd: import.meta.dirname, stdio: "inherit" });\n'
			+ 'process.exit(b.status ?? 0);\n');
	}

	static function compile(haxe:String, label:String):Bool {
		var cp = FileSystem.fullPath(SRC);
		var esmStd = FileSystem.fullPath("hxmc/std/esm");
		var js = root + "/" + OUT + "/main.mjs";
		var args = [haxe, "-cp", esmStd, "-cp", cp, "-main", "Main", "-D", "esm", "-D", "esm.hot", "-D", "hxmc.no-module-cache", "-dce", "no", "-js", js];
		Sys.println('$TAG: compile $label');
		var log = '$OUT/$label-build.log';
		var r = exec(args, {merge: true, log: log});
		if (r.code != 0) {
			Sys.println('compile failed\n' + tail(readText(log), 4000));
			return false;
		}
		return true;
	}

	static function writeRunnerV2(path:String):Void {
		var hx = DOL + "hx";
		var h = DOL + "h";
		var s = 'import * as ' + hx + ' from "./__hx_esm_runtime.mjs";\n'
			+ 'import "./hx/KeyedSite.mjs";\n'
			+ 'const v = ' + hx + '.' + h + '.KeyedSite.run();\n'
			+ 'if( v !== 11 ) throw new Error("ordinal insert reset expected 11 got " + v);\n';
		File.saveContent(path, s);
	}

	static function writeRunner(path:String):Void {
		var hx = DOL + "hx";
		var h = DOL + "h";
		var s = 'import * as ' + hx + ' from "./__hx_esm_runtime.mjs";\n'
			+ 'import "./hx/HotClosure.mjs";\n'
			+ 'import "./hx/HotCell.mjs";\n'
			+ 'import "./hx/KeyedSite.v1.mjs";\n'
			+ 'const f = ' + hx + '.' + h + '.HotClosure.make();\n'
			+ 'if( f("a") !== "v1:a" ) throw new Error("closure before");\n'
			+ hx + '.applyHotPatch({units:[{id:"HotClosure#make/λ1",tier:1,hash:"v2",fn:function(s){return "v2:"+s;}}]});\n'
			+ 'if( f("a") !== "v2:a" ) throw new Error("closure after patch: "+f("a"));\n'
			+ 'if( ' + hx + '.' + h + '.HotCell.tick() !== 1 ) throw new Error("cell tick1");\n'
			+ 'if( ' + hx + '.' + h + '.HotCell.tick() !== 2 ) throw new Error("cell tick2");\n'
			+ hx + '.applyHotPatch({units:[{id:"HotCell#tick",tier:1,hash:"body2",fn:function(){var n=' + hx + '.cell("HotCell#tick#cell.n","same",function(){return 0;});return n+10;}}]});\n'
			+ 'if( ' + hx + '.' + h + '.HotCell.tick() !== 12 ) throw new Error("cell kept state: "+' + hx + '.' + h + '.HotCell.tick());\n'
			+ 'if( ' + hx + '.' + h + '.KeyedSite.run() !== 11 ) throw new Error("keyed v1 run");\n'
			+ 'if( ' + hx + '.' + h + '.KeyedSite.run() !== 22 ) throw new Error("keyed v1 run2");\n';
		File.saveContent(path, s);
	}
}