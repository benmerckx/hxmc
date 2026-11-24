package hxmc.genesm;

import core.Globals;
import core.Globals.*;
import core.TType;
import core.TFunctions.*;
import generators.Gctx;
import generators.Genjs;
import generators.Genjs.JsCtx;

// Per-module import/export wiring for Genesm (-D esm).
class GenesmLinks {
	public final homeId:String;
	public final stdModule:Map<String, Bool>;
	final collapsed:Map<String, String>;
	final seen = new Map<String, Bool>();
	final importLines:Array<String> = [];

	public function new(home:GlobalTypePath, stdModule:Map<String, Bool>, ?collapsedModules:Map<String, String>) {
		homeId = Globals.sTypePath(home);
		this.stdModule = stdModule;
		collapsed = collapsedModules ?? new Map();
	}

	function resolveModuleId(id:String):String {
		var cur = id;
		while (true) {
			if (collapsed.exists(cur)) {
				cur = collapsed.get(cur);
				continue;
			}
			var parent = Genesm.submoduleParentModuleId(cur);
			if (parent == null || parent == cur) break;
			cur = parent;
		}
		return cur;
	}

	public static function buildStdSet(com:Gctx, groups:Array<{module:GlobalTypePath, types:Array<ModuleType>}>):Map<String, Bool> {
		var m = new Map<String, Bool>();
		for (g in groups) {
			var mod = findModule(com, g.module);
			if (mod != null && isStdModulePath(com, mod)) m.set(Globals.sTypePath(g.module), true);
		}
		return m;
	}

	public static function isStdModulePath(com:Gctx, m:ModuleDef):Bool {
		var f = core.Path.UniqueKey.lazyPath(m.mExtra.mFile);
		var up = Sys.getEnv("HAXE_STD_PATH");
		if (up != null) {
			var u = haxe.io.Path.removeTrailingSlashes(up);
			if (StringTools.startsWith(f, u) && (f.length == u.length || f.charAt(u.length) == "/")) return true;
		}
		for (mark in ["/haxe/upstream/std/", "/bin/hxmc/std/", "/hxmc-std/", "/hxmc/std/"])
			if (StringTools.contains(f, mark)) return true;
		return false;
	}

	static function findModule(com:Gctx, path:GlobalTypePath):Null<ModuleDef> {
		for (m in com.modules)
			if (Globals.sTypePath(m.mPath) == Globals.sTypePath(path)) return m;
		return null;
	}

	public static function exportsFromBody(body:String):Array<String> {
		var names = new Map<String, Bool>();
		var varRe = ~/^var ([A-Za-z_$][\w$]*)(?:\s*=|;\s*$)/;
		var letRe = ~/^(?:let|const) ([A-Za-z_$][\w$]*)(?:\s*=|;\s*$)/;
		var fnRe = ~/^function ([A-Za-z_$][\w$]*)\(/;
		var depth = 0;
		for (line in body.split("\n")) {
			var t = StringTools.trim(line);
			if (depth == 0) {
				if (varRe.match(t)) names.set(varRe.matched(1), true);
				else if (letRe.match(t)) names.set(letRe.matched(1), true);
				else if (fnRe.match(t)) names.set(fnRe.matched(1), true);
			}
			for (i in 0...t.length) {
				var c = t.charAt(i);
				if (c == "{") depth++;
				else if (c == "}") depth = if (depth > 0) depth - 1 else 0;
			}
		}
		return [for (k in names.keys()) k];
	}

	public static function jsRef(ctx:JsCtx, t:ModuleType):String return switch t {
		case TClassDecl(c) if (Genjs.isAbstractImpl(c)): Genjs.sPath(ctx, Genjs.getGeneratedClassPath(c));
		default: Genjs.sPath(ctx, tPath(t));
	};

	public function typeAccessor(ctx:JsCtx, t:ModuleType):String {
		var ref = jsRef(ctx, t);
		if (isExternRef(t)) return "$global." + ref;
		var owner = resolveModuleId(Globals.sTypePath(Genesm.typeModule(t).mPath));
		if (owner == homeId) return ref;
		return "$global." + ref;
	}

	public static function modAlias(ownerId:String):String {
		var s = StringTools.replace(ownerId, ".", "_");
		return ~/^[0-9]/.match(s) ? "m_" + s : s;
	}

	public static inline function modAliasForEntry(ownerId:String):String return modAlias(ownerId);

	static function isBuiltInRootName(root:String):Bool return switch root {
		case "haxe" | "js" | "Std" | "String" | "Math" | "Array" | "Date" | "EReg" | "Enum" | "Class" | "Any" | "Int"
			| "Float" | "Bool" | "UInt" | "Null": true;
		case _: false;
	}

	public static function isBuiltInRoot(ref:String):Bool {
		if (isBuiltInRootName(ref.split(".")[0])) return true;
		return isBuiltInRootName(ref.split("_")[0]);
	}

	public static function isExternRefForEntry(t:ModuleType):Bool return isExternRef(t);

	static function isExternRef(t:ModuleType):Bool return switch t {
		case TClassDecl(c): hasClassFlag(c, CExtern);
		case TEnumDecl(e): hasEnumFlag(e, EnExtern);
		case TTypeDecl(_) | TAbstractDecl(_): false;
		case _: true;
	};

	public function ensureImport(ownerId:String):Void {
		var resolved = resolveModuleId(ownerId);
		if (resolved == null || resolved == "" || resolved == homeId || seen.exists(resolved)) return;
		seen.set(resolved, true);
		var rel = Genesm.relativeModuleImport(homeId, resolved);
		importLines.push('import * as ' + modAlias(resolved) + ' from "' + rel + '";\n');
	}

	public function importPreamble():String {
		var b = new StringBuf();
		for (line in importLines) b.add(line);
		return b.toString();
	}

	public function exportSuffix(ctx:JsCtx, types:Array<ModuleType>, body:String):String {
		var publish = Genesm.globalPublishLines(ctx, types);
		// Top-level std modules (Std, String, …): $global publish only; nested std gets exports too.
		if (stdModule.exists(homeId) && homeId.indexOf(".") < 0) return publish;
		var names = exportsFromBody(body);
		if (names.length == 0) return publish;
		return publish + "export { " + names.join(", ") + " };\n";
	}
}