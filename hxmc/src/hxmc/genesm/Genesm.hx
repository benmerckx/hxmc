package hxmc.genesm;

import core.Define;
import core.Globals;
import core.Globals.*;
import core.Meta;
import core.TOther.TClassTools;
import core.TType;
import core.TFunctions.*;
import haxe.io.Path;
import generators.Gctx;
import generators.Genjs;
import generators.Genjs.JsCtx;

// Prod ESM on the Js platform (-D esm): one .mjs file per Haxe module, plus a
// shared runtime module and an entry at --js. Reuses Genjs for expressions and
// type layout; package globals link modules (entry imports every module).
class Genesm {
	public static var hotRegistry = false;

	public static inline function reg():String return hotRegistry ? "$h" : "$global";

	public static function generate(com:Gctx):Void {
		core.Path.mkdirFromPath(com.file);
		var esVersion = generators.Gctx.getEsVersion(com.defines);
		if (esVersion >= 6) filters.ES6Ctors.rewriteCtors(com);
		Genjs.setupKwds(com);
		var outDir = Path.directory(com.file);
		var modDir = Path.join([outDir, "hx"]);
		var packed = moduleGroups(com);
		var groups = packed.groups;
		var collapsedModules = packed.collapsed;
		var stdModule = GenesmLinks.buildStdSet(com, groups);
		var runtimeName = "__hx_esm_runtime.mjs";
		var esm = core.Define.rawDefined(com.defines, "esm");
		writeRuntime(Path.join([outDir, runtimeName]), com, esVersion, esm);
		if (com.includeFiles.length > 0)
			writeIncludes(Path.join([outDir, "__hx_includes.mjs"]), com, "./" + runtimeName);
		var moduleExports = new Map<String, Array<String>>();
		var symOwner = new Map<String, String>();
		var modDeps = new Map<String, Array<String>>();
		var emittedGroups:Array<{module:GlobalTypePath, types:Array<ModuleType>}> = [];
		var regCtx = allocCtx(com, esVersion);
		for (g in groups) registerModuleSymbols(symOwner, regCtx, g.types, Globals.sTypePath(g.module));
		for (g in groups) {
			var links = new GenesmLinks(g.module, stdModule, collapsedModules);
			var modCtx = allocCtx(com, esVersion);
			modCtx.typeAccessor = t -> links.typeAccessor(modCtx, t);
			modulePreamble(modCtx, com, g.types);
			if (!moduleGeneratesCode(modCtx, g.types)) continue;
			var hotTypes:Array<ModuleType> = [];
			for (t in sortModuleTypes(g.types)) {
				Genjs.generateType(modCtx, t);
				if (hotRegistry) hotTypes.push(t);
				else modCtx.buf.addString(Genesm.publishType(modCtx, t));
			}
			emitModuleInits(modCtx);
			if (hotRegistry)
				for (t in hotTypes) {
					GenesmHot.registerType(modCtx, t);
					modCtx.buf.addString(Genesm.publishType(modCtx, t));
				}
			for (name in GenesmLinks.exportsFromBody(modCtx.buf.contents()))
				if (!skipModuleGlobalPublish(name)) modCtx.buf.addString(publishGlobalBinding(name));
			var body = modCtx.buf.contents();
			var mid = Globals.sTypePath(g.module);
			moduleExports.set(mid, GenesmLinks.exportsFromBody(body));
			modDeps.set(mid, moduleGlobalDeps(body, symOwner, mid));
			emittedGroups.push(g);
			writeModule(modDir, g.module, runtimeRel(g.module, runtimeName), g.types, body, modCtx, links);
		}
		writeEntry(com, emittedGroups, stdModule, moduleExports, "./" + runtimeName, modDeps, collapsedModules);
	}

	static function moduleGroups(com:Gctx):{groups:Array<{module:GlobalTypePath, types:Array<ModuleType>}>, collapsed:Map<String, String>} {
		var lut = new Map<String, {module:GlobalTypePath, types:Array<ModuleType>}>();
		for (t in com.types) {
			var m = typeModule(t);
			var id = Globals.sTypePath(m.mPath);
			var g = lut.get(id);
			if (g == null) {
				g = {module: m.mPath, types: []};
				lut.set(id, g);
			}
			g.types.unshift(t);
		}
		var out:Array<{module:GlobalTypePath, types:Array<ModuleType>}> = [];
		for (id in lut.keys()) out.push(lut.get(id));
		return coalesceSubmoduleGroups(out);
	}

	public static function submoduleParentModuleId(id:String):Null<String> return subModuleParentId(pathFromId(id));

	static function subModuleParentId(child:GlobalTypePath):Null<String> {
		var pack = child.pack;
		if (pack.length == 0) return null;
		var last = pack[pack.length - 1];
		if (!StringTools.startsWith(last, "_")) return null;
		var parentName = last.substr(1);
		var parentPack = pack.slice(0, pack.length - 1);
		return Globals.sTypePath({pack: parentPack, name: parentName});
	}

	static function coalesceSubmoduleGroups(groups:Array<{module:GlobalTypePath, types:Array<ModuleType>}>)
			:{groups:Array<{module:GlobalTypePath, types:Array<ModuleType>}>, collapsed:Map<String, String>} {
		var lut = new Map<String, {module:GlobalTypePath, types:Array<ModuleType>}>();
		for (g in groups) lut.set(Globals.sTypePath(g.module), g);
		var drop = new Map<String, Bool>();
		var collapsed = new Map<String, String>();
		for (g in groups) {
			var childId = Globals.sTypePath(g.module);
			var parentId = subModuleParentId(g.module);
			if (parentId == null || !lut.exists(parentId)) continue;
			var pg = lut.get(parentId);
			for (t in g.types) pg.types.unshift(t);
			drop.set(childId, true);
			collapsed.set(childId, parentId);
		}
		var out:Array<{module:GlobalTypePath, types:Array<ModuleType>}> = [];
		for (id in lut.keys())
			if (!drop.exists(id)) out.push(lut.get(id));
		return {groups: out, collapsed: collapsed};
	}

	public static function typeModule(t:ModuleType):ModuleDef return switch t {
		case TClassDecl(c): c.clModule;
		case TEnumDecl(e): e.eModule;
		case TTypeDecl(td): td.tModule;
		case TAbstractDecl(a): a.aModule;
	};

	static function allocCtx(com:Gctx, esVersion:Int):JsCtx {
		var ctx = Genjs.allocCtx(com, esVersion);
		ctx.noFlush = true;
		return ctx;
	}

	static function modulePreamble(ctx:JsCtx, com:Gctx, types:Array<ModuleType>):Void {
		function add(s:String) {
			ctx.buf.addString(s);
		}
		add("const " + reg() + " = $hx." + reg() + ";\n");
		if (hotRegistry) add("const $global = $hx.$global;\n");
		add("const $extend = $hx.$extend;\n");
		add("const $hx_exports = $hx.$hx_exports;\n");
		if (ctx.hasResolveClass || generators.Gctx.hasFeature(com, "Type.resolveEnum"))
			add("var $hxClasses = $hx.$hxClasses;\n");
		if (generators.Gctx.hasFeature(com, "has_enum"))
			add("function $estr() { return js_Boot.__string_rec(this,\"\"); }\n");
		if (!(generators.Gctx.defined(com, Define.JsEnumsAsArrays)) && (generators.Gctx.hasFeature(com, "has_enum") || generators.Gctx.hasFeature(com, "Type.resolveEnum")))
			add("var $hxEnums = $hx.$hxEnums;\n");
		var esm = core.Define.rawDefined(com.defines, "esm");
		if (esm || generators.Gctx.hasFeature(com, "use.$bind") || moduleHasUserEnum(types)) add("var $_;\n");
		if (esm || generators.Gctx.hasFeature(com, "use.$bind"))
			add("const $bind = $hx.$bind;\n");
		if (esm || generators.Gctx.hasFeature(com, "use.$iterator"))
			add("const $iterator = $hx.$iterator;\n");
		if (esm || generators.Gctx.hasFeature(com, "use.$getIterator"))
			add("const $getIterator = $hx.$getIterator;\n");
		if (esm || generators.Gctx.hasFeature(com, "use.$keyValueIterator"))
			add("const $keyValueIterator = $hx.$keyValueIterator;\n");
		if (esm || generators.Gctx.hasFeature(com, "use.$getKeyValueIterator"))
			add("const $getKeyValueIterator = $hx.$getKeyValueIterator;\n");
		if (esm || generators.Gctx.hasFeature(com, "use.$arrayPush"))
			add("const $arrayPush = $hx.$arrayPush;\n");
	}

	static function moduleHasUserEnum(types:Array<ModuleType>):Bool {
		for (t in types) switch t {
			case TEnumDecl(e) if (!hasEnumFlag(e, EnExtern)): return true;
			case _:
		}
		return false;
	}

	// Match Genjs.generateType: no file for modules that only carry type-only externs / typedefs.
	static function typeGeneratesCode(ctx:JsCtx, t:ModuleType):Bool return switch t {
		case TClassDecl(c):
			switch TClassTools.getClInit(c) {
				case null:
				case _: return true;
			}
			var p = Genjs.sPath(ctx, c.clPath);
			if (p == "Math") return true;
			if (p == "Std" && c.clStatics.length == 0) return false;
			if (!hasClassFlag(c, CExtern)) {
				if (hasClassFlag(c, CInterface) && !Genjs.needToGenerateInterface(ctx, c)) return false;
				return true;
			}
			if (Meta.has(Meta.JsRequire, c.clMeta) && Gctx.isDirectlyUsed(ctx.com, c.clMeta)) return true;
			if (!ctx.jsFlatten && Meta.has(Meta.InitPackage, c.clMeta)) return switch c.clPath {
				case {pack: []}: false;
				case _: true;
			};
			return false;
		case TEnumDecl(e):
			if (hasEnumFlag(e, EnExtern))
				return Meta.has(Meta.JsRequire, e.eMeta) && Gctx.isDirectlyUsed(ctx.com, e.eMeta);
			return true;
		case TTypeDecl(_) | TAbstractDecl(_):
			return false;
	};

	static function moduleGeneratesCode(ctx:JsCtx, types:Array<ModuleType>):Bool {
		for (t in types) if (typeGeneratesCode(ctx, t)) return true;
		return false;
	}

	static function emitModuleInits(ctx:JsCtx):Void {
		var inits = ctx.inits.copy();
		inits.reverse();
		for (e in inits) Genjs.genBlockElement(true, ctx.esVersion >= 6, ctx, e);
		var sts = ctx.statics.copy();
		sts.reverse();
		for (s in sts) {
			var clPath = Genjs.getGeneratedClassPath(s.c);
			if (hotRegistry && generators.EsmHotEmit.tryEmitClassStatic != null
				&& generators.EsmHotEmit.tryEmitClassStatic(ctx, s.c, clPath, s.f))
				continue;
			if (hotRegistry && hxmc.esm.EsmHotMeta.isSwappable(s.f))
				GenesmHot.emitSwappableStatic(ctx, s);
			else {
				if (hotRegistry) {
					hxmc.esm.HotLowering.prepareFieldCells(ctx.com, s.c, s.f);
					s = {c: s.c, f: s.f, e: s.f.cfExpr};
				}
				Genjs.generateStatic(ctx, s);
			}
		}
	}

	static function writeModule(outDir:String, module:GlobalTypePath, runtimeRel:String, types:Array<ModuleType>, body:String, ctx:JsCtx, links:GenesmLinks):Void {
		var path = Path.join([outDir, moduleFilePath(module)]);
		core.Path.mkdirFromPath(path);
		var text = "import * as $hx from \"" + runtimeRel + "\";\n" + links.importPreamble() + body + links.exportSuffix(ctx, types, body);
		sys.io.File.saveContent(path, text);
		if (hotRegistry)
			hxmc.esm.HotManifest.recordModule(Globals.sTypePath(module), "./hx/" + moduleFilePath(module), text);
	}

	public static function publishType(ctx:JsCtx, t:ModuleType):String {
		return switch t {
			case TClassDecl(c) if (!hasClassFlag(c, CExtern)):
				var dotp = Genjs.dotPath(c.clPath);
				if (StringTools.endsWith(dotp, "_Fields_")) "";
				else if (hasClassFlag(c, CInterface) && !Genjs.needToGenerateInterface(ctx, c)) "";
				else {
					var p = Genjs.sPath(ctx, Genjs.getGeneratedClassPath(c));
					if (p == "Std" && c.clStatics.length == 0) "" else reg() + "." + p + " = " + p + ";\n";
				}
			case TEnumDecl(e) if (!hasEnumFlag(e, EnExtern)):
				var p = Genjs.sPath(ctx, e.ePath);
				reg() + "." + p + " = " + p + ";\n";
			default:
				"";
		}
	}

	public static function globalPublishLines(ctx:JsCtx, types:Array<ModuleType>):String {
		var buf = new StringBuf();
		for (t in types) buf.add(publishType(ctx, t));
		return buf.toString();
	}

	public static function relativeModuleImport(homeId:String, ownerId:String):String {
		var home = moduleFilePath(pathFromId(homeId));
		var owner = moduleFilePath(pathFromId(ownerId));
		return relPath(Path.directory(home), owner);
	}

	static function pathFromId(id:String):GlobalTypePath {
		var dot = id.lastIndexOf(".");
		if (dot < 0) return {pack: [], name: id};
		return {pack: id.substr(0, dot).split("."), name: id.substr(dot + 1)};
	}

	static function relPath(fromDir:String, toFile:String):String {
		var from = fromDir == "" || fromDir == "." ? [] : fromDir.split("/");
		var to = toFile.split("/");
		var i = 0;
		while (i < from.length && i < to.length && from[i] == to[i]) i++;
		var ups:Array<String> = [];
		var j = i;
		while (j < from.length) {
			ups.push("..");
			j++;
		}
		var rel = ups.concat(to.slice(i));
		var s = if (rel.length == 0) toFile else rel.join("/");
		return if (StringTools.startsWith(s, ".") || StringTools.startsWith(s, "/")) s else "./" + s;
	}

	static function writeRuntime(path:String, com:Gctx, esVersion:Int, esm:Bool):Void {
		var buf = new StringBuf();
		buf.add("export const $global = typeof globalThis !== \"undefined\" ? globalThis : window;\n");
		buf.add("if( $global.$hx_exports == null ) $global.$hx_exports = {};\n");
		buf.add("export const $hx_exports = $global.$hx_exports;\n");
		buf.add("$global.$hx_$exports = $hx_exports;\n");
		buf.add("export function $extend(from, fields) {\n");
		buf.add("	var proto = Object.create(from);\n");
		buf.add("	for (var name in fields) proto[name] = fields[name];\n");
		buf.add("	if( fields.toString !== Object.prototype.toString ) proto.toString = fields.toString;\n");
		buf.add("	return proto;\n");
		buf.add("}\n");
		buf.add(publishGlobalBinding("$extend"));
		if (generators.Gctx.hasFeature(com, "Type.resolveClass") || generators.Gctx.hasFeature(com, "Type.resolveEnum"))
			buf.add("export var $hxClasses = {};\n");
		if (generators.Gctx.hasFeature(com, "has_enum"))
			buf.add("export function $estr() { return js_Boot.__string_rec(this,\"\"); }\n");
		if (!(generators.Gctx.defined(com, Define.JsEnumsAsArrays)) && (generators.Gctx.hasFeature(com, "has_enum") || generators.Gctx.hasFeature(com, "Type.resolveEnum")))
			buf.add("export var $hxEnums = {};\n");
		if (esm || generators.Gctx.hasFeature(com, "use.$bind")) {
			buf.add("$global.$haxeUID |= 0;\n");
			buf.add("export function $bind(o,m) { if( m == null ) return null; if( m.__id__ == null ) m.__id__ = $global.$haxeUID++; var f; if( o.hx__closures__ == null ) o.hx__closures__ = {}; else f = o.hx__closures__[m.__id__]; if( f == null ) { f = m.bind(o); o.hx__closures__[m.__id__] = f; } return f; }\n");
			buf.add(publishGlobalBinding("$bind"));
			buf.add("export var $_;\n");
			buf.add(publishGlobalBinding("$_"));
		}
		if (esm || generators.Gctx.hasFeature(com, "use.$iterator")) {
			buf.add("export function $iterator(o) { if( o instanceof Array ) return function() { return new haxe_iterators_ArrayIterator(o); }; return typeof(o.iterator) == 'function' ? $bind(o,o.iterator) : o.iterator; }\n");
			buf.add(publishGlobalBinding("$iterator"));
		}
		if (esm || generators.Gctx.hasFeature(com, "use.$getIterator")) {
			buf.add("export function $getIterator(o) { if( o instanceof Array ) return new haxe_iterators_ArrayIterator(o); else return o.iterator(); }\n");
			buf.add(publishGlobalBinding("$getIterator"));
		}
		if (esm || generators.Gctx.hasFeature(com, "use.$keyValueIterator")) {
			buf.add("export function $keyValueIterator(o) { if( o instanceof Array ) return function() { return HxOverrides.keyValueIter(o); }; return typeof(o.keyValueIterator) == 'function' ? $bind(o,o.keyValueIterator) : o.keyValueIterator; }\n");
			buf.add(publishGlobalBinding("$keyValueIterator"));
		}
		if (esm || generators.Gctx.hasFeature(com, "use.$getKeyValueIterator")) {
			buf.add("export function $getKeyValueIterator(o) { if( o instanceof Array ) return HxOverrides.keyValueIter(o); else return o.keyValueIterator(); }\n");
			buf.add(publishGlobalBinding("$getKeyValueIterator"));
		}
		if (esm || generators.Gctx.hasFeature(com, "use.$arrayPush")) {
			buf.add("export function $arrayPush(x) { return this.push(x); }\n");
			buf.add(publishGlobalBinding("$arrayPush"));
		}
		if (generators.Gctx.hasFeature(com, "$global.$haxeUID"))
			buf.add("$global.$haxeUID |= 0;\n");
		if (hotRegistry) appendHotRuntime(buf);
		sys.io.File.saveContent(path, buf.toString());
	}

	static function appendHotRuntime(buf:StringBuf):Void {
		buf.add("export const $h = typeof globalThis !== \"undefined\" ? (globalThis.$h = globalThis.$h || {units: {}, cells: {}, scopes: [], instances: {}}) : {units: {}, cells: {}, scopes: [], instances: {}};\n");
		buf.add("$h.units = $h.units || {};\n");
		buf.add("$h.cells = $h.cells || {};\n");
		buf.add("$h.scopes = $h.scopes || [];\n");
		buf.add("$h.instances = $h.instances || {};\n");
		buf.add("$h.registerFunction = function(id, hash, fn) { $h.units[id] = {kind: \"function\", hash: hash, fn: fn}; };\n");
		buf.add("$h.registerClass = function(id, layoutHash, superId, policy, C) {\n");
		buf.add("	var u = $h.units[id];\n");
		buf.add("	var insts = u != null ? u.instances : null;\n");
		buf.add("	$h.units[id] = {kind: \"class\", layoutHash: layoutHash, superId: superId, policy: policy || \"reset\", C: C, instances: insts || []};\n");
		buf.add("	if( insts == null ) $h.instances[id] = $h.units[id].instances;\n");
		buf.add("};\n");
		buf.add("$h.registerEnum = function(id, tableHash, policy, E) {\n");
		buf.add("	var enumNames = [];\n");
		buf.add("	var cs = E.__constructs__;\n");
		buf.add("	if( cs != null ) for( var i = 0; i < cs.length; i++ ) {\n");
		buf.add("		var c = cs[i];\n");
		buf.add("		enumNames.push(typeof c === \"string\" ? c : c._hx_name);\n");
		buf.add("	}\n");
		buf.add("	$h.units[id] = {kind: \"enum\", tableHash: tableHash, policy: policy || \"reset\", E: E, names: enumNames};\n");
		buf.add("};\n");
		buf.add("$h.trackInstance = function(id, o) {\n");
		buf.add("	var u = $h.units[id];\n");
		buf.add("	if( u == null || u.kind !== \"class\" ) return;\n");
		buf.add("	if( u.instances.indexOf(o) < 0 ) u.instances.push(o);\n");
		buf.add("	if( o != null && o.__hotClassId == null ) o.__hotClassId = id;\n");
		buf.add("};\n");
		buf.add("$h.publishClass = function(id, layoutHash, superId, policy, C) {\n");
		buf.add("	$h.registerClass(id, layoutHash, superId, policy, C);\n");
		buf.add("	var u = $h.units[id];\n");
		buf.add("	if( u == null || !u.__wrapped ) {\n");
		buf.add("		var Orig = C;\n");
		buf.add("		var W = function() {\n");
		buf.add("			var o = (typeof Reflect !== \"undefined\" && Reflect.construct)\n");
		buf.add("				? Reflect.construct(Orig, arguments, new.target || W)\n");
		buf.add("				: (new.target ? (Orig.apply(this, arguments), this) : Object.assign(Object.create(Orig.prototype), new Orig(...arguments)));\n");
		buf.add("			$h.trackInstance(id, o);\n");
		buf.add("			return o;\n");
		buf.add("		};\n");
		buf.add("		W.prototype = Orig.prototype;\n");
		buf.add("		W.__name__ = Orig.__name__;\n");
		buf.add("		W.__super__ = Orig.__super__;\n");
		buf.add("		W.__wrapped = true;\n");
		buf.add("		u.C = W; u.Wrapped = W;\n");
		buf.add("		var _names = Object.getOwnPropertyNames(Orig);\n");
		buf.add("		for( var _i = 0; _i < _names.length; _i++ ) {\n");
		buf.add("			var _k = _names[_i];\n");
		buf.add("			if( _k === \"prototype\" || _k === \"length\" || _k === \"name\" ) continue;\n");
		buf.add("			var _d = Object.getOwnPropertyDescriptor(Orig, _k);\n");
		buf.add("			if( _d != null ) Object.defineProperty(W, _k, _d);\n");
		buf.add("		}\n");
		buf.add("		return W;\n");
		buf.add("	}\n");
		buf.add("	u.C = C;\n");
		buf.add("	return u.Wrapped || C;\n");
		buf.add("};\n");
		buf.add("$h.publishEnum = function(id, tableHash, policy, E) { $h.registerEnum(id, tableHash, policy, E); return E; };\n");
		buf.add("$h.classLayoutAppendOnly = function(prev, next) {\n");
		buf.add("	return prev != null && next != null && next.length >= prev.length && next.slice(0, prev.length) === prev;\n");
		buf.add("};\n");
		buf.add("$h.migrateClassInstances = function(id, prevLayout, nextLayout, nextC) {\n");
		buf.add("	var u = $h.units[id];\n");
		buf.add("	if( u == null ) return {ok: false, reload: true};\n");
		buf.add("	if( !$h.classLayoutAppendOnly(prevLayout, nextLayout) && prevLayout !== nextLayout ) return {ok: false, reload: true};\n");
		buf.add("	var added = prevLayout === nextLayout ? \"\" : nextLayout.slice(prevLayout.length);\n");
		buf.add("	u.layoutHash = nextLayout;\n");
		buf.add("	u.C = nextC;\n");
		buf.add("	var proto = nextC.prototype;\n");
		buf.add("	for( var i = 0; i < u.instances.length; i++ ) {\n");
		buf.add("		var o = u.instances[i];\n");
		buf.add("		if( o == null ) continue;\n");
		buf.add("		o.__proto__ = proto;\n");
		buf.add("		$h.initAppendedFields(o, added);\n");
		buf.add("	}\n");
		buf.add("	return {ok: true, reload: false};\n");
		buf.add("};\n");
		buf.add("$h.initAppendedFields = function(o, addedSpec) {\n");
		buf.add("	if( addedSpec == null || addedSpec === \"\" ) return;\n");
		buf.add("	var parts = addedSpec.split(\";\");\n");
		buf.add("	for( var i = 0; i < parts.length; i++ ) {\n");
		buf.add("		var p = parts[i];\n");
		buf.add("		if( p === \"\" ) continue;\n");
		buf.add("		var q = p.indexOf(\":\");\n");
		buf.add("		if( q < 0 ) continue;\n");
		buf.add("		var name = p.slice(0, q);\n");
		buf.add("		var ty = p.slice(q + 1);\n");
		buf.add("		var opt = ty.charAt(ty.length - 1) === \"?\";\n");
		buf.add("		if( !opt ) continue;\n");
		buf.add("		if( o[name] != null ) continue;\n");
		buf.add("		if( ty.indexOf(\"Int\") >= 0 ) o[name] = 0;\n");
		buf.add("		else if( ty.indexOf(\"Float\") >= 0 ) o[name] = 0.0;\n");
		buf.add("		else if( ty.indexOf(\"Bool\") >= 0 ) o[name] = false;\n");
		buf.add("		else o[name] = null;\n");
		buf.add("	}\n");
		buf.add("};\n");
		buf.add("$h.enumTableStable = function(prevHash, names) {\n");
		buf.add("	if( prevHash == null || names == null ) return false;\n");
		buf.add("	return prevHash === $h.hashEnumNames(names);\n");
		buf.add("};\n");
		buf.add("$h.hashEnumNames = function(names) {\n");
		buf.add("	var s = \"\";\n");
		buf.add("	for( var i = 0; i < names.length; i++ ) s += names[i] + \",\";\n");
		buf.add("	return $h.md5(s);\n");
		buf.add("};\n");
		buf.add("$h.md5 = function(s) {\n");
		buf.add("	var h = 0;\n");
		buf.add("	for( var i = 0; i < s.length; i++ ) h = ((h << 5) - h + s.charCodeAt(i)) | 0;\n");
		buf.add("	return String(h);\n");
		buf.add("};\n");
		buf.add("$h.invoke = function(id, args) { var u = $h.units[id]; if( u == null || u.stale ) return null; return u.fn.apply(null, args || []); };\n");
		buf.add("$h.registerClosure = function(id, capHash, hash, fn) {\n");
		buf.add("	var u = $h.units[id];\n");
		buf.add("	if( u != null && u.capHash != null && u.capHash !== capHash ) { u.stale = true; }\n");
		buf.add("	$h.units[id] = {kind: \"closure\", hash: hash, capHash: capHash, fn: fn, stale: false};\n");
		buf.add("};\n");
		buf.add("$h.makeClosure = function(id, env) {\n");
		buf.add("	var f = function() { return $h.invokeClosure(id, env, arguments); };\n");
		buf.add("	f.__hotClosureId = id;\n");
		buf.add("	f.__hotClosureEnv = env;\n");
		buf.add("	return f;\n");
		buf.add("};\n");
		buf.add("$h.invokeClosure = function(id, env, args) {\n");
		buf.add("	var u = $h.units[id];\n");
		buf.add("	if( u == null || u.stale ) return null;\n");
		buf.add("	if( u.capHash == null || u.capHash === \"\" ) return u.fn.apply(null, args || []);\n");
		buf.add("	var a = [env];\n");
		buf.add("	for( var i = 0; i < (args ? args.length : 0); i++ ) a.push(args[i]);\n");
		buf.add("	return u.fn.apply(null, a);\n");
		buf.add("};\n");
		buf.add("export function $new(id, initHash, initFn) { return $h.cell(id, initHash, initFn); }\n");
		buf.add("$h.cell = function(id, initHash, initFn) {\n");
		buf.add("	var c = $h.cells[id];\n");
		buf.add("	if( c == null ) { c = {v: initFn(), initHash: initHash}; $h.cells[id] = c; return c.v; }\n");
		buf.add("	if( initHash != null && initHash !== \"same\" && c.initHash !== initHash ) { c.v = initFn(); c.initHash = initHash; }\n");
		buf.add("	return c.v;\n");
		buf.add("};\n");
		buf.add("export function cell(id, initHash, initFn) {\n");
		buf.add("	return $h.cell(id, initHash != null ? initHash : \"\", initFn);\n");
		buf.add("}\n");
		buf.add("$h.scopeEnter = function(id, key) {\n");
		buf.add("	$h.scopes.push({id: id, key: key != null ? key : null});\n");
		buf.add("};\n");
		buf.add("$h.scopeExit = function() { $h.scopes.pop(); };\n");
		buf.add("export function scopeEnter(id, key) { $h.scopeEnter(id, key); }\n");
		buf.add("export function scopeExit() { $h.scopeExit(); }\n");
		buf.add("export function trackInstance(typeId, inst) { $h.trackInstance(typeId, inst); }\n");
		hxmc.esm.HotRuntimeSerializer.append(buf);
		buf.add("$h.enumNamesPrefix = function(oldNames, newNames) {\n");
		buf.add("	if( oldNames == null || newNames == null ) return false;\n");
		buf.add("	if( newNames.length < oldNames.length ) return false;\n");
		buf.add("	for( var i = 0; i < oldNames.length; i++ ) if( oldNames[i] !== newNames[i] ) return false;\n");
		buf.add("	return true;\n");
		buf.add("};\n");
	}

	static function sortModuleTypes(types:Array<ModuleType>):Array<ModuleType> {
		var prefix:Array<ModuleType> = [];
		var classes:Array<ModuleType> = [];
		var lut = new Map<String, ModuleType>();
		for (t in types) switch t {
			case TClassDecl(c):
				classes.push(t);
				lut.set(Globals.sTypePath(c.clPath), t);
			default:
				prefix.push(t);
		}
		function superId(c:TClass):Null<String> return c.clSuper == null ? null : Globals.sTypePath(c.clSuper.cls.clPath);
		var sorted:Array<ModuleType> = [];
		var done = new Map<String, Bool>();
		var pending = new Map<String, Bool>();
		function emitClass(t:ModuleType):Void {
			var c = switch t { case TClassDecl(x): x; case _: return; }
			var id = Globals.sTypePath(c.clPath);
			if (done.exists(id)) return;
			if (pending.exists(id)) return;
			pending.set(id, true);
			for (impl in c.clImplements) {
				var it = lut.get(Globals.sTypePath(impl.cls.clPath));
				if (it != null) emitClass(it);
			}
			var sid = superId(c);
			if (sid != null) {
				var sup = lut.get(sid);
				if (sup != null) emitClass(sup);
			}
			pending.remove(id);
			done.set(id, true);
			sorted.push(t);
		}
		for (t in classes) emitClass(t);
		return prefix.concat(sorted);
	}

	static function registerModuleSymbols(symOwner:Map<String, String>, ctx:JsCtx, types:Array<ModuleType>, moduleId:String):Void {
		for (t in types) switch t {
			case TClassDecl(c) if (!hasClassFlag(c, CExtern)):
				symOwner.set(Genjs.sPath(ctx, Genjs.getGeneratedClassPath(c)), moduleId);
			case TEnumDecl(e) if (!hasEnumFlag(e, EnExtern)):
				symOwner.set(Genjs.sPath(ctx, e.ePath), moduleId);
			case _:
		}
	}

	static function moduleGlobalDeps(body:String, symOwner:Map<String, String>, homeId:String):Array<String> {
		var dep = new Map<String, Bool>();
		var re = hotRegistry ? ~/\$h\.([A-Za-z_$][\w$]*)/ : ~/\$global\.([A-Za-z_$][\w$]*)/;
		for (line in body.split("\n")) {
			var t = line;
			var pos = 0;
			while (pos < t.length) {
				var sub = t.substr(pos);
				if (!re.match(sub)) break;
				var sym = re.matched(1);
				var owner = symOwner.get(sym);
				if (owner != null && owner != homeId) dep.set(owner, true);
				var mp = re.matchedPos();
				pos += mp.pos + mp.len;
			}
		}
		return [for (k in dep.keys()) k];
	}

	static function topoModuleImports(groups:Array<{module:GlobalTypePath, types:Array<ModuleType>}>,
			deps:Map<String, Array<String>>):Array<{module:GlobalTypePath, types:Array<ModuleType>}> {
		var std = groups;
		var out:Array<{module:GlobalTypePath, types:Array<ModuleType>}> = [];
		var done = new Map<String, Bool>();
		while (out.length < std.length) {
			var progress = false;
			for (g in std) {
				var id = Globals.sTypePath(g.module);
				if (done.exists(id)) continue;
				var ok = true;
				for (d in deps.get(id) ?? [])
					if (!done.exists(d)) {
						ok = false;
						break;
					}
				if (!ok) continue;
				out.push(g);
				done.set(id, true);
				progress = true;
			}
			if (progress) continue;
			for (g in std) {
				var id = Globals.sTypePath(g.module);
				if (!done.exists(id)) {
					out.push(g);
					done.set(id, true);
				}
			}
			break;
		}
		return out;
	}

	static function skipModuleGlobalPublish(name:String):Bool {
		if (name == "$global" || name == "$h" || name == "$extend" || name == "$hx_exports") return true;
		return runtimeHelperGlobalName(name);
	}

	static function runtimeHelperGlobalName(name:String):Bool return switch name {
		case "$bind" | "$iterator" | "$getIterator" | "$keyValueIterator" | "$getKeyValueIterator" | "$arrayPush" | "$_": true;
		case _: false;
	};

	// Genjs.sPath / Path.flatPath escapes underscores in a single-segment name; top-level
	// vars keep the source spelling (e.g. @:native or js.Syntax.code) but field access uses flatPath.
	static function publishGlobalBinding(localName:String):String {
		var flat = core.Path.flatPath({pack: [], name: localName});
		// Runtime helpers always live on $global even in esm.hot (user types use reg()).
		var g = "$global";
		if (flat == localName) return g + '.' + localName + ' = ' + localName + ';\n';
		return g + '.' + localName + ' = ' + localName + ';\n' + g + '.' + flat + ' = ' + localName + ';\n';
	}

	static function writeIncludes(path:String, com:Gctx, runtimeRel:String):Void {
		var buf = new StringBuf();
		buf.add("import * as $hx from \"" + runtimeRel + "\";\n");
		buf.add("const " + reg() + " = $hx." + reg() + ";\n");
		if (hotRegistry) buf.add("const $global = $hx.$global;\n");
		var re = ~/var ([A-Za-z_$][\w$]*)\s*=/;
		for (file in com.includeFiles) switch file.position {
			case "top" | "closure":
				var content = sys.io.File.getContent(file.file);
				buf.add(content);
				if (!StringTools.endsWith(content, "\n")) buf.add("\n");
				if (re.match(content)) buf.add(publishGlobalBinding(re.matched(1)));
			case _:
		}
		sys.io.File.saveContent(path, buf.toString());
	}

	static function writeEntry(com:Gctx, groups:Array<{module:GlobalTypePath, types:Array<ModuleType>}>, stdModule:Map<String, Bool>,
			moduleExports:Map<String, Array<String>>, runtimeRel:String, modDeps:Map<String, Array<String>>,
			collapsedModules:Map<String, String>):Void {
		var buf = new StringBuf();
		buf.add("import * as $hx from \"" + runtimeRel + "\";\n");
		if (com.includeFiles.length > 0) buf.add("import \"./__hx_includes.mjs\";\n");
		buf.add("const " + reg() + " = $hx." + reg() + ";\n");
		if (hotRegistry) buf.add("const $global = $hx.$global;\n");
		for (g in topoModuleImports(groups, modDeps))
			buf.add('import "./hx/' + moduleFilePath(g.module) + '";\n');
		switch com.main.mainExpr {
			case null:
			case e:
				var mp:GlobalTypePath = com.main.mainPath != null ? com.main.mainPath : new GlobalTypePath([], "Main");
				var links = new GenesmLinks(mp, stdModule, collapsedModules);
				var entryCtx = allocCtx(com, generators.Gctx.getEsVersion(com.defines));
				entryCtx.typeAccessor = t -> {
					var ref = GenesmLinks.jsRef(entryCtx, t);
					return reg() + "." + ref;
				};
				buf.add(Genjs.genSingleExpr(entryCtx, e, false));
				buf.add("\n");
				if (hotRegistry) {
					buf.add("$hx.$h.__esmHotRemount = function() {\n");
					buf.add(Genjs.genSingleExpr(entryCtx, e, false));
					buf.add("\n};\n");
				}
		}
		sys.io.File.saveContent(com.file, buf.toString());
	}

	static function moduleFilePath(p:GlobalTypePath):String return Path.join(p.pack.concat([p.name])) + ".mjs";

	static function runtimeRel(module:GlobalTypePath, runtimeName:String):String {
		var parts = ("hx/" + moduleFilePath(module)).split("/");
		var depth = parts.length - 1;
		var up = "";
		for (i in 0...depth) up += "../";
		return up + runtimeName;
	}
}