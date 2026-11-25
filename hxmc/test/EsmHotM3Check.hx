import Harness.*;
import haxe.Json;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using StringTools;

// M3: tier-2 class layout migration, enum table stability, extends reload fallback.
class EsmHotM3Check {
	static final OUT = "bin/test/esm-hot-m3";
	static final SRC = "hxmc/test/esm/hot/m3";
	static final DOL = String.fromCharCode(36);

	static function main() {
		var o = parseArgs(Sys.args(), ["--haxe"]);
		var haxe = FileSystem.fullPath(o.opts["--haxe"] ?? defaultHaxe());
		if (!FileSystem.exists(haxe)) fail("compiler not found: $haxe");
		rmrf(OUT);
		mkdirs(OUT);
		if (!checkLayoutTier(haxe)) Sys.exit(1);
		if (!checkEnumTier(haxe)) Sys.exit(1);
		if (!checkExtendsReload(haxe)) Sys.exit(1);
		var layouts = Json.parse(File.getContent('$OUT/layout-hashes.json'));
		writeRunner('$OUT/run.mjs', layouts.v1, layouts.v2);
		Sys.println("esm-hot-m3: run integration");
		var r = exec(["node", FileSystem.fullPath('$OUT/run.mjs')], {merge: true});
		if (r.code != 0) {
			Sys.println("EsmHotM3Check: failed");
			Sys.exit(1);
		}
		Sys.println("esm-hot-m3: ok");
	}

	static function defaultHaxe():String {
		for (c in ["bin/npm/native/" + Sys.getEnv("HXMC_HOST") + "/haxe", "bin/haxe-js"])
			if (c.indexOf("null") < 0 && FileSystem.exists(c)) return FileSystem.fullPath(c);
		return FileSystem.fullPath("bin/npm/native/macos-arm64/haxe");
	}

	static function checkLayoutTier(haxe:String):Bool {
		var dir = '$OUT/layout';
		rmrf(dir);
		mkdirs(dir);
		prepareLayoutV1();
		if (!compileModule(haxe, dir, "Main", "layout-v1")) return false;
		prepareLayoutV2();
		if (!compileModule(haxe, dir, "Main", "layout-v2")) return false;
		var patchPath = dir + "/__hx_hot_patch.mjs";
		if (!FileSystem.exists(patchPath)) {
			Sys.println("esm-hot-m3: missing patch after layout v2");
			return false;
		}
		var patch = File.getContent(patchPath);
		if (patch.indexOf("HotLayout") < 0 || patch.indexOf("tier: 2") < 0) {
			Sys.println("esm-hot-m3: expected tier-2 HotLayout patch");
			return false;
		}
		var v2Layout = layoutHashFromManifest(dir + "/__hx_hot_manifest.json", "HotLayout");
		if (v2Layout == null) {
			Sys.println("esm-hot-m3: missing v2 HotLayout layoutHash");
			return false;
		}
		// Snapshot v2 emit beside v1 output for runner.
		var v2Src = dir + "/hx/HotLayout.mjs";
		var snap = dir + "/hx/HotLayout.v2.mjs";
		if (!FileSystem.exists(v2Src)) fail("missing v2 HotLayout emit");
		snapshotV2HotLayout(v2Src, snap);
		prepareLayoutV1();
		if (!compileModule(haxe, dir, "Main", "layout-v1b")) return false;
		var v1Layout = layoutHashFromManifest(dir + "/__hx_hot_manifest.json", "HotLayout");
		if (v1Layout == null) {
			Sys.println("esm-hot-m3: missing v1 HotLayout layoutHash");
			return false;
		}
		File.saveContent('$OUT/layout-hashes.json', Json.stringify({v1: v1Layout, v2: v2Layout}));
		return true;
	}

	static function checkExtendsReload(haxe:String):Bool {
		var dir = '$OUT/extends';
		rmrf(dir);
		mkdirs(dir);
		prepareExtendsV1();
		if (!compileModule(haxe, dir, "MainExtends", "ext-v1")) return false;
		prepareExtendsV2();
		if (!compileModule(haxe, dir, "MainExtends", "ext-v2")) return false;
		var patch = File.getContent(dir + "/__hx_hot_patch.mjs");
		if (patch.indexOf("HotExtends") < 0 || patch.indexOf("tier: 2") < 0) {
			Sys.println("esm-hot-m3: expected tier-2 HotExtends patch");
			return false;
		}
		prepareExtendsV1();
		if (!compileModule(haxe, dir, "MainExtends", "ext-v1b")) return false;
		return true;
	}

	static function prepareLayoutV1():Void {
		copyFixture("HotLayout.v1.hx", "HotLayout.hx");
		copyFixture("HotEnum.v1.hx", "HotEnum.hx");
	}

	static function prepareLayoutV2():Void copyFixture("HotLayout.v2.hx", "HotLayout.hx");

	static function checkEnumTier(haxe:String):Bool {
		var dir = '$OUT/enum';
		rmrf(dir);
		mkdirs(dir);
		copyFixture("HotEnum.v1.hx", "HotEnum.hx");
		copyFixture("HotLayout.v1.hx", "HotLayout.hx");
		if (!compileModule(haxe, dir, "Main", "enum-v1")) return false;
		copyFixture("HotEnum.v2.hx", "HotEnum.hx");
		if (!compileModule(haxe, dir, "Main", "enum-v2")) return false;
		var patch = File.getContent(dir + "/__hx_hot_patch.mjs");
		if (patch.indexOf("HotEnum") < 0 || patch.indexOf("tier: 2") < 0) {
			Sys.println("esm-hot-m3: expected tier-2 HotEnum patch");
			return false;
		}
		return true;
	}

	static function prepareExtendsV1():Void copyFixture("HotExtends.v1.hx", "HotExtends.hx");

	static function prepareExtendsV2():Void copyFixture("HotExtends.v2.hx", "HotExtends.hx");

	static function copyFixture(from:String, to:String):Void {
		var base = FileSystem.fullPath(SRC);
		File.saveContent(Path.join([base, to]), File.getContent(Path.join([base, from])));
	}

	static function compileModule(haxe:String, outDir:String, mainType:String, label:String):Bool {
		return compileModuleWithMain(haxe, outDir, mainType, label);
	}

	static function compileModuleWithMain(haxe:String, outDir:String, mainType:String, label:String):Bool {
		var cp = FileSystem.fullPath(SRC);
		var esmStd = FileSystem.fullPath("hxmc/std/esm");
		var js = outDir + "/main.mjs";
		var args = [haxe, "-cp", esmStd, "-cp", cp, "-main", mainType, "-D", "esm", "-D", "esm.hot", "-D", "hxmc.no-module-cache", "-dce", "no", "-js", js];
		Sys.println('esm-hot-m3: compile $label');
		var log = '$outDir/$label-build.log';
		var r = exec(args, {merge: true, log: log});
		if (r.code != 0) {
			Sys.println('compile failed\n' + tail(readText(log), 4000));
			return false;
		}
		return true;
	}

	static function snapshotV2HotLayout(src:String, dst:String):Void {
		var s = File.getContent(src);
		var re = ~/HotLayout = \$h\.publishClass[^\n]*\n/;
		s = re.replace(s, "");
		File.saveContent(dst, s);
	}

	static function layoutHashFromManifest(path:String, id:String):Null<String> {
		var m:Dynamic = Json.parse(File.getContent(path));
		for (u in (m.units : Array<Dynamic>))
			if (u.id == id && u.layoutHash != null) return u.layoutHash;
		return null;
	}

	static function writeRunner(path:String, v1Layout:String, v2Layout:String):Void {
		var hx = DOL + "hx";
		var h = DOL + "h";
		var s = 'import * as ' + hx + ' from "./layout/__hx_esm_runtime.mjs";\n'
			+ 'import "./layout/hx/HotLayout.mjs";\n'
			+ 'const v2mod = await import("./layout/hx/HotLayout.v2.mjs");\n'
			+ 'const o = new ' + hx + '.' + h + '.HotLayout();\n'
			+ 'o.x = 9;\n'
			+ 'const prevLayout = ' + Json.stringify(v1Layout) + ';\n'
			+ 'const nextLayout = ' + Json.stringify(v2Layout) + ';\n'
			+ 'var r = ' + hx + '.applyHotPatch({units:[{id:"HotLayout",kind:"class",tier:2,layoutHash:nextLayout,superId:"",policy:"reset",C:v2mod.HotLayout}]});\n'
			+ 'if( r == null || r.reload ) throw new Error("layout migration failed: "+JSON.stringify(r));\n'
			+ 'if( o.x !== 9 ) throw new Error("layout keep x: "+o.x);\n'
			+ 'if( o.y !== 0 ) throw new Error("layout init optional y: "+o.y);\n'
			+ 'import "./extends/hx/HotExtends.mjs";\n'
			+ 'if( ' + hx + '.$h.units["HotExtends"] == null ) throw new Error("HotExtends not registered");\n'
			+ 'r = ' + hx + '.applyHotPatch({units:[{id:"HotExtends",kind:"class",tier:2,layoutHash:' + hx + '.$h.units["HotExtends"].layoutHash,superId:"HotOther",policy:"reset",C:' + hx + '.$h.units["HotExtends"].C}]});\n'
			+ 'if( r == null || !r.reload ) throw new Error("extends change must request reload");\n';
		File.saveContent(path, s);
	}
}