import Harness.*;
import haxe.Json;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using StringTools;

// M4: heap serializer, tier-3 class migration, transactional rollback — make esm-hot-m4
class EsmHotM4Check {
	static final OUT = "bin/test/esm-hot-m4";
	static final SRC = "hxmc/test/esm/hot/m4";
	static final M3SRC = "hxmc/test/esm/hot/m3";
	static final DOL = String.fromCharCode(36);

	static function main() {
		var o = parseArgs(Sys.args(), ["--haxe"]);
		var haxe = FileSystem.fullPath(o.opts["--haxe"] ?? defaultHaxe());
		if (!FileSystem.exists(haxe)) fail("compiler not found: $haxe");
		rmrf(OUT);
		mkdirs(OUT);
		if (!checkTier3Manifest(haxe)) Sys.exit(1);
		writeRunner('$OUT/run.mjs');
		Sys.println("esm-hot-m4: run integration");
		var r = exec(["node", FileSystem.fullPath('$OUT/run.mjs')], {merge: true});
		if (r.code != 0) {
			Sys.println("EsmHotM4Check: failed");
			Sys.exit(1);
		}
		Sys.println("esm-hot-m4: ok");
	}

	static function defaultHaxe():String {
		for (c in ["bin/npm/native/" + Sys.getEnv("HXMC_HOST") + "/haxe", "bin/haxe-js"])
			if (c.indexOf("null") < 0 && FileSystem.exists(c)) return FileSystem.fullPath(c);
		return FileSystem.fullPath("bin/npm/native/macos-arm64/haxe");
	}

	static function checkTier3Manifest(haxe:String):Bool {
		var dir = '$OUT/heap';
		rmrf(dir);
		mkdirs(dir);
		copyFrom("HotHeap.v1.hx", "HotHeap.hx", SRC);
		copyFrom("HotEnum.v1.hx", "HotEnum.hx", M3SRC);
		if (!compile(haxe, dir, "heap-v1")) return false;
		copyFrom("HotHeap.v2.hx", "HotHeap.hx", SRC);
		if (!compile(haxe, dir, "heap-v2")) return false;
		var patchPath = dir + "/__hx_hot_patch.mjs";
		if (!FileSystem.exists(patchPath)) {
			Sys.println("esm-hot-m4: missing tier-3 patch");
			return false;
		}
		var patch = File.getContent(patchPath);
		if (patch.indexOf("HotHeap") < 0 || patch.indexOf("tier: 3") < 0) {
			Sys.println("esm-hot-m4: expected tier-3 HotHeap patch");
			return false;
		}
		var v2Layout = layoutHashFromManifest(dir + "/__hx_hot_manifest.json", "HotHeap");
		var v2Src = dir + "/hx/HotHeap.mjs";
		var snap = dir + "/hx/HotHeap.v2.mjs";
		if (!FileSystem.exists(v2Src)) fail("missing v2 HotHeap emit");
		File.copy(v2Src, snap);
		copyFrom("HotHeap.v1.hx", "HotHeap.hx", SRC);
		if (!compile(haxe, dir, "heap-v1b")) return false;
		var v1Layout = layoutHashFromManifest(dir + "/__hx_hot_manifest.json", "HotHeap");
		if (v1Layout == null || v2Layout == null) {
			Sys.println("esm-hot-m4: missing layout hashes");
			return false;
		}
		File.saveContent('$OUT/layout-hashes.json', Json.stringify({v1: v1Layout, v2: v2Layout}));
		return true;
	}

	static function copyFrom(from:String, to:String, base:String):Void {
		var srcRoot = FileSystem.fullPath(base);
		var dstRoot = FileSystem.fullPath(SRC);
		File.saveContent(Path.join([dstRoot, to]), File.getContent(Path.join([srcRoot, from])));
	}

	static function compile(haxe:String, outDir:String, label:String):Bool {
		var cp = FileSystem.fullPath(SRC);
		var m3 = FileSystem.fullPath(M3SRC);
		var esmStd = FileSystem.fullPath("hxmc/std/esm");
		var js = outDir + "/main.mjs";
		var args = [haxe, "-cp", esmStd, "-cp", m3, "-cp", cp, "-main", "Main", "-D", "esm", "-D", "esm.hot", "-D", "hxmc.no-module-cache", "-dce", "no", "-js", js];
		Sys.println('esm-hot-m4: compile $label');
		var log = '$outDir/$label-build.log';
		var r = exec(args, {merge: true, log: log});
		if (r.code != 0) {
			Sys.println('compile failed\n' + tail(readText(log), 4000));
			return false;
		}
		return true;
	}

	static function layoutHashFromManifest(path:String, id:String):Null<String> {
		var m:Dynamic = Json.parse(File.getContent(path));
		for (u in (m.units : Array<Dynamic>))
			if (u.id == id && u.layoutHash != null) return u.layoutHash;
		return null;
	}

	static function writeRunner(path:String):Void {
		var layouts = Json.parse(File.getContent('$OUT/layout-hashes.json'));
		var hx = DOL + "hx";
		var h = DOL + "h";
		var s = 'import * as ' + hx + ' from "./heap/__hx_esm_runtime.mjs";\n'
			+ 'import "./heap/hx/HotHeap.mjs";\n'
			+ 'import "./heap/hx/HotEnum.mjs";\n'
			+ 'import "./heap/hx/HotSerial.mjs";\n'
			+ 'import "./heap/hx/HotHeapCell.mjs";\n'
			+ 'const v2mod = await import("./heap/hx/HotHeap.v2.mjs");\n'
			+ 'const o = new ' + hx + '.' + h + '.HotHeap();\n'
			+ 'o.x = 9;\n'
			+ 'const beforeCell = ' + hx + '.' + h + '.HotHeapCell.bump();\n'
			+ 'if( beforeCell !== 1 ) throw new Error("cell before patch: "+beforeCell);\n'
			+ 'const serial = { tag: ' + hx + '.' + h + '.HotSerial.pick(), f: ' + hx + '.' + h + '.HotSerial.cycleFn() };\n'
			+ 'const wire = ' + hx + '.esmSerialize({o, serial, loop: serial.f});\n'
			+ 'const back = ' + hx + '.esmUnserialize(wire);\n'
			+ 'if( back.o.x !== 9 ) throw new Error("serialize instance");\n'
			+ 'if( back.serial.tag == null ) throw new Error("serialize enum");\n'
			+ 'if( back.serial.f() !== "cycle" ) throw new Error("serialize closure");\n'
			+ 'if( back.loop !== back.serial.f ) throw new Error("serialize shared ref");\n'
			+ 'const nextLayout = ' + Json.stringify(layouts.v2) + ';\n'
			+ 'var r = ' + hx + '.applyHotPatch({heap:true,units:[{id:"HotHeap",kind:"class",tier:3,layoutHash:nextLayout,superId:"",policy:"reset",C:v2mod.HotHeap}]});\n'
			+ 'if( r == null || r.reload || r.rolledBack ) throw new Error("tier3 migrate: "+JSON.stringify(r));\n'
			+ 'if( typeof o.x !== "number" || o.x !== 9 ) throw new Error("tier3 keep x typed: "+o.x);\n'
			+ 'const midCell = ' + hx + '.' + h + '.HotHeapCell.bump();\n'
			+ 'if( midCell !== 2 ) throw new Error("cell after tier3: "+midCell);\n'
			+ 'r = ' + hx + '.applyHotPatch({heap:true,units:[{id:"HotHeap",kind:"class",tier:3,layoutHash:' + Json.stringify(layouts.v1) + ',superId:"BadSuper",policy:"reset",C:v2mod.HotHeap}]});\n'
			+ 'if( r == null || !r.rolledBack || r.tier !== 4 ) throw new Error("rollback expected: "+JSON.stringify(r));\n'
			+ 'if( r.reload ) throw new Error("rollback clears reload");\n'
			+ 'if( typeof o.x !== "number" || o.x !== 9 ) throw new Error("rollback kept instance: "+o.x);\n'
			+ 'const afterCell = ' + hx + '.' + h + '.HotHeapCell.bump();\n'
			+ 'if( afterCell !== 3 ) throw new Error("rollback kept cell: "+afterCell);\n';
		File.saveContent(path, s);
	}
}