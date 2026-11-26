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
	public final prod:Bool;
	final collapsed:Map<String, String>;
	final emittedModules:Map<String, Bool>;
	final seen = new Map<String, Bool>();
	final importLines:Array<String> = [];
	public final importModules:Array<String> = [];
	final namedByOwner = new Map<String, Array<{sym:String, local:String}>>();
	final localNames = new Map<String, Bool>();
	final aliasCount = new Map<String, Int>();

	public function new(home:GlobalTypePath, stdModule:Map<String, Bool>, ?collapsedModules:Map<String, String>,
			?emittedModules:Map<String, Bool>, ?prodMode:Bool = false) {
		homeId = Globals.sTypePath(home);
		this.stdModule = stdModule;
		prod = prodMode;
		collapsed = collapsedModules ?? new Map();
		this.emittedModules = emittedModules ?? new Map();
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

	function localFor(ownerId:String, sym:String):String {
		for (item in namedByOwner.get(ownerId) ?? [])
			if (item.sym == sym) return item.local;
		return sym;
	}

	public function ensureNamedImport(ownerId:String, sym:String):String {
		var resolved = resolveModuleId(ownerId);
		if (resolved == "" || resolved == homeId) return sym;
		if (!emittedModules.exists(resolved)) return "$global." + sym;
		if (namedByOwner.exists(resolved))
			for (item in namedByOwner.get(resolved))
				if (item.sym == sym)
					return item.local;
		var local = sym;
		if (localNames.exists(local)) {
			var n = (aliasCount.get(sym) ?? 1) + 1;
			aliasCount.set(sym, n);
			local = sym + "__" + n;
		}
		localNames.set(local, true);
		if (!namedByOwner.exists(resolved)) namedByOwner.set(resolved, []);
		namedByOwner.get(resolved).push({sym: sym, local: local});
		if (!importModules.contains(resolved)) importModules.push(resolved);
		return local;
	}

	public function moduleFieldRef(m:ModuleDef, f:TClassField):String {
		var mf = Genjs.moduleField(m, f);
		return ensureNamedImport(Globals.sTypePath(m.mPath), mf);
	}

	public function typeAccessor(ctx:JsCtx, t:ModuleType):String {
		var ref = jsRef(ctx, t);
		if (isExternRef(t)) return "$global." + ref;
		var owner = resolveModuleId(Globals.sTypePath(Genesm.typeModule(t).mPath));
		if (owner == homeId) return ref;
		if (!prod) {
			if (owner != homeId && owner.indexOf(".") < 0 && isBuiltInRootName(owner) && stdModule.exists(owner))
				ensureRegistryImport(owner);
			return Genesm.reg() + "." + ref;
		}
		if (stdModule.exists(owner) && owner != homeId) {
			if (owner.indexOf(".") < 0 && isBuiltInRootName(owner)) ensureRegistryImport(owner);
			return "$global." + ref;
		}
		return ensureNamedImport(owner, ref);
	}

	public static function modAlias(ownerId:String):String {
		var s = StringTools.replace(ownerId, ".", "_");
		return ~/^[0-9]/.match(s) ? "m_" + s : s;
	}

	static function isBuiltInRootName(root:String):Bool return switch root {
		case "haxe" | "js" | "Std" | "String" | "Math" | "Array" | "Date" | "EReg" | "Enum" | "Class" | "Any" | "Int"
			| "Float" | "Bool" | "UInt" | "Null": true;
		case _: false;
	}

	public static function isBuiltInRoot(ref:String):Bool {
		if (isBuiltInRootName(ref.split(".")[0])) return true;
		return isBuiltInRootName(ref.split("_")[0]);
	}

	static function isExternRef(t:ModuleType):Bool return switch t {
		case TClassDecl(c): hasClassFlag(c, CExtern);
		case TEnumDecl(e): hasEnumFlag(e, EnExtern);
		case TTypeDecl(_) | TAbstractDecl(_): false;
		case _: true;
	};

	public function ensureRegistryImport(ownerId:String):Void {
		var resolved = resolveModuleId(ownerId);
		if (resolved == null || resolved == "" || resolved == homeId || seen.exists(resolved)) return;
		if (!emittedModules.exists(resolved) || !stdModule.exists(resolved)) return;
		seen.set(resolved, true);
		importModules.push(resolved);
		var rel = Genesm.relativeModuleImport(homeId, resolved);
		importLines.push('import "' + rel + '";\n');
	}

	public function importPreamble():String {
		if (!prod) {
			var b = new StringBuf();
			for (line in importLines) b.add(line);
			return b.toString();
		}
		var buf = new StringBuf();
		for (ownerId in namedByOwner.keys()) {
			var items = namedByOwner.get(ownerId);
			if (items.length == 0) continue;
			var rel = Genesm.relativeModuleImport(homeId, ownerId);
			var parts:Array<String> = [];
			for (i in items)
				parts.push(i.sym == i.local ? i.local : i.sym + " as " + i.local);
			buf.add('import { ' + parts.join(", ") + ' } from "' + rel + '";\n');
		}
		return buf.toString();
	}

	public function exportSuffix(ctx:JsCtx, types:Array<ModuleType>, body:String):String {
		var publish = if (prod) "" else Genesm.globalPublishLines(ctx, types);
		if (stdModule.exists(homeId) && homeId.indexOf(".") < 0 && !prod) return publish;
		var names = exportsFromBody(body);
		if (prod) names = names.filter(n -> !Genesm.isRuntimeExportName(n));
		if (names.length == 0) return publish;
		return publish + "export { " + names.join(", ") + " };\n";
	}
}