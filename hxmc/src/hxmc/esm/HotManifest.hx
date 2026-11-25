package hxmc.esm;

import core.Define;
import haxe.crypto.Md5;
import haxe.Json;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
using StringTools;

// M1: per-unit emit hashes, manifest on disk, diff + patch chunk for dev transport.
// M3: class/enum type units + tier-2 classification; M4: tier-3 when layout is not append-only.
typedef ManifestUnit = {
	id: String,
	kind: String,
	tier: Int,
	?codeHash: String,
	emitHash: String,
	?structureHash: String,
	?layoutHash: String,
	?superId: String,
	?enumTableHash: String,
	?policy: String,
}

typedef HotPatchDiff = {
	changed: Array<String>,
	tiers: Map<String, Int>,
}

typedef ManifestModule = {
	id: String,
	path: String,
	emitHash: String,
}

typedef TypeEmitRec = {
	emitHash: String,
	regJs: String,
}

class HotManifest {
	public static var fnBodies = new Map<String, {emitHash:String, fnJs:String}>();
	public static var typeBodies = new Map<String, TypeEmitRec>();
	public static var moduleBodies = new Map<String, {path:String, emitHash:String}>();

	public static function reset():Void {
		fnBodies = new Map();
		typeBodies = new Map();
		moduleBodies = new Map();
	}

	public static function recordModule(id:String, relPath:String, source:String):Void {
		moduleBodies.set(id, {path: relPath, emitHash: Md5.encode(source)});
	}

	public static function recordEmit(uid:String, fnJs:String):String {
		var emitHash = Md5.encode(fnJs);
		fnBodies.set(uid, {emitHash: emitHash, fnJs: fnJs});
		var unit = HotIds.units.get(uid);
		if (unit != null) unit.emitHash = emitHash;
		return emitHash;
	}

	public static function recordTypeEmit(uid:String, regJs:String):String {
		var emitHash = Md5.encode(regJs);
		typeBodies.set(uid, {emitHash: emitHash, regJs: regJs});
		var unit = HotIds.units.get(uid);
		if (unit != null) unit.emitHash = emitHash;
		return emitHash;
	}

	public static function finishGenerate(com:generators.Gctx):Void {
		if (!Define.rawDefined(com.defines, "esm.hot")) return;
		var outDir = Path.directory(com.file);
		var manifestPath = Path.join([outDir, "__hx_hot_manifest.json"]);
		var prev:Null<{units:Null<Array<ManifestUnit>>, ?modules:Null<Array<ManifestModule>>}> = null;
		if (FileSystem.exists(manifestPath)) {
			try {
				prev = Json.parse(File.getContent(manifestPath));
			} catch (_:Dynamic) {}
		}
		var cur = buildManifest();
		var curMods = buildModuleManifest();
		var diff = diffManifest(prev != null ? prev.units : null, cur);
		var moduleImports = diffModules(prev != null ? prev.modules : null, curMods);
		File.saveContent(manifestPath, Json.stringify({units: cur, modules: curMods}, null, "\t"));
		if (prev != null && (diff.changed.length > 0 || moduleImports.length > 0))
			writePatchMjs(outDir, diff, moduleImports);
		writeDevClient(outDir);
	}

	static function buildModuleManifest():Array<ManifestModule> {
		var out:Array<ManifestModule> = [];
		for (id => rec in moduleBodies)
			out.push({id: id, path: rec.path, emitHash: rec.emitHash});
		out.sort((a, b) -> Reflect.compare(a.id, b.id));
		return out;
	}

	static function diffModules(prev:Null<Array<ManifestModule>>, cur:Array<ManifestModule>):Array<String> {
		var prevMap = new Map<String, ManifestModule>();
		if (prev != null)
			for (m in prev) prevMap.set(m.id, m);
		var paths:Array<String> = [];
		for (m in cur) {
			var p = prevMap.get(m.id);
			if (p == null || p.emitHash != m.emitHash)
				paths.push(m.path);
		}
		paths.sort(Reflect.compare);
		return paths;
	}

	static function writeDevClient(outDir:String):Void {
		var body = 'import * as ' + String.fromCharCode(36) + 'hx from "./__hx_esm_runtime.mjs";\n'
			+ "export async function applyDevHotPatch(patchModule, cacheBust) {\n"
			+ "\tconst t = cacheBust != null ? cacheBust : Date.now();\n"
			+ "\tvar result = null;\n"
			+ "\tif( typeof patchModule.applyHotPatchFromDev === \"function\" )\n"
			+ "\t\tresult = patchModule.applyHotPatchFromDev();\n"
			+ "\tif( result != null && result.reload ) {\n"
			+ "\t\tlocation.reload();\n"
			+ "\t\treturn result;\n"
			+ "\t}\n"
			+ "\tvar mods = patchModule.importModules;\n"
			+ "\tif( mods != null )\n"
			+ "\t\tfor( var i = 0; i < mods.length; i++ )\n"
			+ "\t\t\tawait import(mods[i] + \"?t=\" + t);\n"
			+ "\tvar rm = " + String.fromCharCode(36) + "hx." + String.fromCharCode(36) + "h.__esmHotRemount;\n"
			+ "\tif( typeof rm === \"function\" ) rm();\n"
			+ "\treturn result;\n"
			+ "}\n";
		File.saveContent(Path.join([outDir, "__hx_esm_dev_client.mjs"]), body);
	}

	static function buildManifest():Array<ManifestUnit> {
		var out:Array<ManifestUnit> = [];
		for (uid => rec in fnBodies) {
			var unit = HotIds.units.get(uid);
			out.push({
				id: uid,
				kind: unit != null ? unit.kind : "function",
				tier: 1,
				codeHash: unit != null ? unit.codeHash : null,
				emitHash: rec.emitHash,
				structureHash: null,
				policy: unit != null ? unit.policy : "reset",
			});
		}
		for (uid => rec in typeBodies) {
			var unit = HotIds.units.get(uid);
			out.push({
				id: uid,
				kind: unit != null ? unit.kind : "class",
				tier: 2,
				codeHash: unit != null ? unit.codeHash : null,
				emitHash: rec.emitHash,
				structureHash: unit != null ? unit.structureHash : null,
				layoutHash: unit != null ? unit.layoutHash : null,
				superId: unit != null ? unit.superId : null,
				enumTableHash: unit != null ? unit.enumTableHash : null,
				policy: unit != null ? unit.policy : "reset",
			});
		}
		out.sort((a, b) -> Reflect.compare(a.id, b.id));
		return out;
	}

	public static function diffManifest(prev:Null<Array<ManifestUnit>>, cur:Array<ManifestUnit>):HotPatchDiff {
		var prevMap = new Map<String, ManifestUnit>();
		if (prev != null)
			for (u in prev) prevMap.set(u.id, u);
		var changed:Array<String> = [];
		var tiers = new Map<String, Int>();
		for (u in cur) {
			var p = prevMap.get(u.id);
			var isType = u.kind == "class" || u.kind == "enum";
			if (isType) {
				var structChanged = p == null
					|| structureOf(u) != structureOf(p)
					|| (u.kind == "class" && classStructureChanged(p, u));
				if (structChanged) {
					changed.push(u.id);
					tiers.set(u.id, typePatchTier(p, u));
				}
			} else {
				if (p == null || p.emitHash != u.emitHash) {
					changed.push(u.id);
					tiers.set(u.id, 1);
				}
			}
		}
		changed.sort(Reflect.compare);
		return {changed: changed, tiers: tiers};
	}

	static function structureOf(u:ManifestUnit):String {
		if (u.structureHash != null) return u.structureHash;
		if (u.kind == "enum" && u.enumTableHash != null) return u.enumTableHash;
		return u.codeHash ?? "";
	}

	static function classStructureChanged(p:ManifestUnit, u:ManifestUnit):Bool {
		if (p.layoutHash != u.layoutHash) return true;
		var ps = p.superId != null ? p.superId : "";
		var us = u.superId != null ? u.superId : "";
		return ps != us;
	}

	static function typePatchTier(p:Null<ManifestUnit>, u:ManifestUnit):Int {
		if (u.kind == "class" && p != null && p.layoutHash != null && u.layoutHash != null && p.layoutHash != u.layoutHash
			&& !classLayoutAppendOnly(p.layoutHash, u.layoutHash))
			return 3;
		return 2;
	}

	static function classLayoutAppendOnly(prev:String, next:String):Bool {
		return prev != null && next != null && next.length >= prev.length && next.substr(0, prev.length) == prev;
	}

	static function writePatchMjs(outDir:String, diff:HotPatchDiff, moduleImports:Array<String>):Void {
		var entries:Array<String> = [];
		for (id in diff.changed) {
			var tier = diff.tiers.exists(id) ? diff.tiers.get(id) : 1;
			var fn = fnBodies.get(id);
			if (fn != null) {
				entries.push('\t\t{ id: ${jsString(id)}, kind: "function", tier: $tier, hash: ${jsString(fn.emitHash)}, fn: ${fn.fnJs} }');
				continue;
			}
			var ty = typeBodies.get(id);
			var unit = HotIds.units.get(id);
			if (ty == null || unit == null) continue;
			if (unit.kind == "enum")
				entries.push('\t\t{ id: ${jsString(id)}, kind: "enum", tier: $tier, hash: ${jsString(ty.emitHash)}, enumTableHash: ${jsString(unit.enumTableHash ?? "")}, policy: ${jsString(unit.policy)}, reg: ${ty.regJs} }');
			else
				entries.push('\t\t{ id: ${jsString(id)}, kind: "class", tier: $tier, hash: ${jsString(ty.emitHash)}, layoutHash: ${jsString(unit.layoutHash ?? "")}, superId: ${jsString(unit.superId ?? "")}, policy: ${jsString(unit.policy)}, reg: ${ty.regJs} }');
		}
		var tiersObj:Dynamic = {};
		for (id => tier in diff.tiers) Reflect.setField(tiersObj, id, tier);
		var importsJs = "[" + [for (p in moduleImports) jsString(p)].join(",") + "]";
		var body = 'import { applyHotPatch } from "./__hx_esm_runtime.mjs";\n'
			+ "export const manifest = "
			+ Json.stringify({changed: diff.changed, tiers: tiersObj})
			+ ";\n"
			+ "export const importModules = " + importsJs + ";\n"
			+ "export function applyHotPatchFromDev() {\n"
			+ "\treturn applyHotPatch({ units: [\n"
			+ entries.join(",\n")
			+ "\n\t]});\n"
			+ "}\n";
		File.saveContent(Path.join([outDir, "__hx_hot_patch.mjs"]), body);
	}

	static function jsString(s:String):String {
		return '"' + StringTools.replace(StringTools.replace(s, "\\", "\\\\"), '"', '\\"') + '"';
	}
}