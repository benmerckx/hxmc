/*
	The Haxe Compiler
	Copyright (C) 2005-2019  Haxe Foundation

	This program is free software; you can redistribute it and/or
	modify it under the terms of the GNU General Public License
	as published by the Free Software Foundation; either version 2
	of the License, or (at your option) any later version.

	This program is distributed in the hope that it will be useful,
	but WITHOUT ANY WARRANTY; without even the implied warranty of
	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
	GNU General Public License for more details.

	You should have received a copy of the GNU General Public License
	along with this program; if not, write to the Free Software
	Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
*/

package context.display;

import core.Globals;
import core.Globals.Pos;
import core.Globals.GlobalTypePath;
import core.TFunctions.*;
import core.Timer;
import core.WithType as WithTypeTools;
import core.WithType.WithTypeValue;
import core.ClassPath.IClassPath;
import core.ds.OcamlHash;
import core.ds.OcamlHashtbl;
import core.display.DisplayPosition;
import compiler.CompilationCache;
import context.Common;
import context.CommonCache;
import context.Typecore;
import context.Typecore.Typer;
import core.MetaList.StrictMeta as MetaTag;
import core.Ast;
import core.Meta;
import core.DisplayTypes;
import core.TType;
import core.display.CompletionItem;
import core.ds.VectorTools.vector;

using core.ds.VectorTools;

class ExploreClassPathTask extends ServerTask {
	final com:CommonContext;
	final checked:haxe.ds.StringMap<Bool>;
	final recursive:Bool;
	final fPack:GlobalTypePath->Void;
	final fModule:String->GlobalTypePath->Void;
	final dir:String;
	final pack:Array<String>;
	final platformStr:String;

	public function new(com:CommonContext, checked:haxe.ds.StringMap<Bool>, recursive:Bool, fPack:GlobalTypePath->Void,
			fModule:String->GlobalTypePath->Void, dir:String, pack:Array<String>) {
		super(["explore", dir], 50);
		this.com = com;
		this.checked = checked;
		this.recursive = recursive;
		this.fPack = fPack;
		this.fModule = fModule;
		this.dir = dir;
		this.pack = pack;
		platformStr = Common.platformNameMacro(com);
	}

	function execute():Void {
		var uniqueDir = core.Path.UniqueKey.create(dir);
		var revPack = pack.copy();
		revPack.reverse();
		var dotPath = revPack.join(".");
		if (DisplayToplevel.exclude.contains(dotPath) || checked.exists(uniqueDir)) return;
		try {
			checked.set(uniqueDir, true);
			var entries = try sys.FileSystem.readDirectory(dir) catch (_:Dynamic) throw new SysError();
			iterEntries(entries, revPack, dotPath);
		} catch (_:SysError) {}
	}

	function iterEntries(entries:Array<String>, revPack:Array<String>, dotPath:String):Void {
		for (file in entries) {
			switch file {
				case "." | "..":
				case _
					if (isDirectory(dir + file)
						&& StringTools.fastCodeAt(file, 0) >= "a".code
						&& StringTools.fastCodeAt(file, 0) <= "z".code):
					if (!com.packageRules.exists(file)) {
						fPack({pack: revPack, name: file});
						if (recursive) new ExploreClassPathTask(com, checked, recursive, fPack, fModule, dir + file + "/",
							[file].concat(pack)).run();
					}
				case _:
					var l = file.length;
					if (l > 3 && file.substr(l - 3, 3) == ".hx") {
						try {
							var name = {
								var name = file.substr(0, l - 3);
								var dotPos = name.lastIndexOf(".");
								if (dotPos >= 0) {
									/* The second extension without the dot, e.g. "js" for Foo.js.hx. */
									var secondExt = file.substr(dotPos + 1, name.length - dotPos - 1);
									if ((com.customExt != null && com.customExt == secondExt)
										|| platformStr == secondExt) file.substr(0, dotPos);
									else throw core.ds.Exit.raise();
								} else name;
							};
							var path:GlobalTypePath = {pack: revPack, name: name};
							var dotPath = dotPath == "" ? name : dotPath + "." + name;
							if (!DisplayToplevel.exclude.contains(dotPath)) fModule(dir + file, path);
						} catch (_:Dynamic) {}
					}
			}
		}
	}

	static function isDirectory(path:String):Bool {
		// port: Sys.is_directory raises Sys_error for a dangling entry; that aborts the directory like upstream
		if (!sys.FileSystem.exists(path)) throw new SysError();
		return sys.FileSystem.isDirectory(path);
	}
}

// port: OCaml's `Sys_error` raised by directory functions.
private class SysError extends haxe.Exception {
	public function new() super("Sys_error");
}

@:structInit class CollectionContext {
	public var ctx:Typer;
	public var items:Array<CompletionItemData>;
	public var names:haxe.ds.StringMap<CompletionItemData>;
	public var paths:haxe.ds.StringMap<Bool>;

	public inline function new(ctx:Typer, items:Array<CompletionItemData>, names:haxe.ds.StringMap<CompletionItemData>,
			paths:haxe.ds.StringMap<Bool>) {
		this.ctx = ctx;
		this.items = items;
		this.names = names;
		this.paths = paths;
	}

	public static function create(ctx:Typer):CollectionContext return {
		ctx: ctx,
		items: [],
		names: new haxe.ds.StringMap(),
		paths: new haxe.ds.StringMap()
	};

	public function addItem(item:CompletionItemData, name:Null<String>):Void {
		items.push(item);
		if (name != null) names.set(name, item);
	}

	public function getImportStatus(isImport:Bool, path:GlobalTypePath):ImportStatus {
		if (names.exists(path.name)) {
			// TODO: do we have to check if we get the same thing?
			return Shadowed;
		}
		function checkWildcard():Bool {
			return core.ds.ArrayTools.exists(ctx.m.importResolution.extractWildcardPackages(),
				function(w) return CompilationCache.pathEq({pack: w.pack, name: path.name}, path));
		}
		return (isImport || path.pack.length == 0 || checkWildcard()) ? Imported : Unimported;
	}

	public function isQualified(name:String):Bool return !names.exists(name);

	static function pathKey(path:GlobalTypePath):String return path.pack.join(".") + "|" + path.name;

	public function pathExists(path:GlobalTypePath):Bool return paths.exists(pathKey(path));

	public function addPath(path:GlobalTypePath):Void paths.set(pathKey(path), true);
}

class DisplayToplevel {
	/**
		Merges argument and return types from macro and non-macro context, preferring the one that isn't Dynamic.
		WARNING: Merging types from boths contexts like this is dangerous. The resuling type must never be
		persisted on the compilation server, or else the compiler gets COVID.
	**/
	public static function performTypeVoodoo(t:T, tl_:haxe.ds.Vector<{name:String, optional:Bool, type:T}>, tr_:T):T {
		return switch t {
			case TFun(s):
				var tl = s.args, tr = s.ret;
				// port: the merged pairs, then the rest of tl': always as long as tl'
				var acc = new haxe.ds.Vector(tl_.length);
				for (i in 0...tl_.length) {
					var a1_ = tl_[i];
					acc[i] = if (i < tl.length) {
						var a1 = tl[i];
						a1.type == tDynamic ? a1_ : a1;
					} else a1_;
				}
				TFun({args: acc, ret: tr == tDynamic ? tr_ : tr});
			case _:
				TFun({args: tl_, ret: tr_});
		};
	}

	public static function maybeResolveMacroField(ctx:Typer, t:T, c:TClass, cf:TClassField):{t:T, cf:TClassField} {
		try {
			if (!cf.cfKind.match(Method(MethMacro))) throw core.ds.Exit.raise();
			var m:typing.MacroContext.MacroMethod = ctx.g.doLoadMacro(ctx, false, c.clPath, cf.cfName, Globals.nullPos);
			var t = performTypeVoodoo(t, m.args, m.ret);
			var cf2 = cf.clone();
			cf2.cfType = t;
			return {t: t, cf: cf2};
		} catch (_:Dynamic) {
			return {t: t, cf: cf};
		}
	}

	public static var exclude:Array<String> = [];

	public static function exploreClassPaths(com:CommonContext, timer:Array<String>, classPaths:Array<IClassPath>, recursive:Bool,
			fPack:GlobalTypePath->Void, fModule:String->GlobalTypePath->Void):Void {
		var cs:Cache = com.cs;
		Timer.time(com.timerCtx, timer.concat(["class path exploration"]), function(_:Null<Bool>) {
			var checked = new haxe.ds.StringMap<Bool>();
			var tasks = [];
			for (path in classPaths) {
				var path = path.getDirectoryPath();
				if (path != null) tasks.push(new ExploreClassPathTask(com, checked, recursive, fPack, fModule, path, []));
			}
			var task = new ArbitraryTask(["explore"], 50, function() for (task in tasks) task.run());
			cs.addTask(task);
			return null;
		}, null);
	}

	public static function readClassPaths(com:CommonContext, timer:Array<String>):Void {
		exploreClassPaths(com, timer, (com.classPaths : core.ClassPaths).filter(cp -> cp.path != ""), true, function(_) {},
			function(file, path) {
				// Don't parse the display file as that would maybe overwrite the content from stdin with the file contents.
				if (!DisplayPosition.displayPosition.isInFile(com.partScope.fileKeys.get(file))) {
					var r = Display.parseModule_(com, path, Globals.nullPos);
					if (!CompilationCache.pathEq({pack: r.pack, name: ""}, {pack: path.pack, name: ""})) {
						var fileKey = com.partScope.fileKeys.get(file);
						CommonCache.getCache(com).removeFileForReal(fileKey);
					}
				}
			});
	}

	public static function initOrUpdateServer(cs:Cache, com:CommonContext, timerName:Array<String>):Void {
		var cc = CommonCache.getCache(com);
		if (!cc.isInitialized()) {
			cc.setInitialized(true);
			readClassPaths(com, timerName);
		}
		// Force executing all "explore" tasks here because we need their information.
		cs.runTasks(true, function(task) return task.getId()[0] == "explore");
		// Iterate all removed files of the current context. If they aren't part of the context again,
		// re-parse them and remove them from c_removed_files.
		var removedFiles = cc.getRemovedFiles();
		var removedRemovedFiles = [];
		removedFiles.iter(function(fileKey, filePath) {
			removedRemovedFiles.push(fileKey);
			try {
				cc.findFile(fileKey);
			} catch (_:core.ds.NotFound) {
				try typing.TypeloadParse.parseModuleFile(com, filePath, Globals.nullPos)
				catch (_:Dynamic) {}
			}
		});
		for (k in removedRemovedFiles) removedFiles.remove(k);
	}

	/** +1 for each matching package part. 0 = no common part **/
	public static function packSimilarity(pack1:Array<String>, pack2:Array<String>):Int {
		var count = 0;
		while (count < pack1.length && count < pack2.length && pack1[count] == pack2[count]) count++;
		return count;
	}

	/** Returns `true` if `pack1` contains or is `pack2` **/
	public static function packContains(pack1:Array<String>, pack2:Array<String>):Bool {
		var i = 0;
		while (true) {
			if (i >= pack1.length) return true;
			if (i < pack2.length && pack1[i] == pack2[i]) i++;
			else return false;
		}
	}

	public static function isPackVisible(pack:Array<String>):Bool return !core.ds.ArrayTools.exists(pack,
		s -> s.length > 0 && s.charAt(0) == "_");

	static function collect_(ctx:Typer, tk:ToplevelKind, withType:WithTypeValue, sort:Bool):Array<CompletionItemData> {
		var cctx = CollectionContext.create(ctx);
		var curpack = ctx.c.curclass.clPath.pack;
		var packages = new OcamlHashtbl<GlobalTypePath, Bool>(OcamlHash.hashPath, CompilationCache.pathEq, 0);
		function addPackage(path:GlobalTypePath):Void packages.replace(path, true);

		function add(item:CompletionItemData, name:Null<String>):Void cctx.addItem(item, name);
		function addType(mt:ModuleType):Void {
			switch mt {
				case TClassDecl({clKind: KAbstractImpl(_) | KModuleFields(_)}):
				case _:
					var path = tInfos(mt).mtPath;
					var mname = tInfos(mt).mtModule.mPath.name;
					var path:GlobalTypePath = path.name == mname ? path : {pack: path.pack.concat([mname]), name: path.name};
					if (!cctx.pathExists(path)) {
						Display.mergeCoreDoc(ctx, mt);
						var is = cctx.getImportStatus(true, path);
						if (!Meta.has(MetaTag.NoCompletion, tInfos(mt).mtMeta)) {
							add(CompletionItem.makeCiType(CompletionModuleType.ofModuleType(mt), is, null), path.name);
							cctx.addPath(path);
						}
					}
			}
		}

		function processDecls(pack:Array<String>, name:String, decls:haxe.ds.Vector<TypeDecl>):Bool {
			var addedSomething = false;
			function add(item:CompletionItemData, name:Null<String>):Void {
				addedSomething = true;
				cctx.addItem(item, name);
			}
			function run():Void for (decl in decls) {
				try {
					var r = switch decl.definition {
						case EClass(d): {tname: d.name.name, isPrivate: d.flags.has(HPrivate), meta: d.meta};
						case EEnum(d): {tname: d.name.name, isPrivate: d.flags.has(EPrivate), meta: d.meta};
						case ETypedef(d): {tname: d.name.name, isPrivate: d.flags.has(TDPrivate), meta: d.meta};
						case EAbstract(d): {tname: d.name.name, isPrivate: d.flags.has(AbPrivate), meta: d.meta};
						case EStatic(d): {
								tname: d.name.name,
								isPrivate: core.ds.ArrayTools.exists(d.flags, a -> a.access == APrivate),
								meta: d.meta
							};
						case EImport(_) | EUsing(_): throw core.ds.Exit.raise();
					};
					var fp = core.Path.fullDotPath(pack, name, r.tname);
					var path:GlobalTypePath = {pack: fp.pack, name: fp.name};
					if (!cctx.pathExists(path) && !r.isPrivate && !Meta.has(MetaTag.NoCompletion, r.meta)) {
						cctx.addPath(path);
						// If we share a package, the module's main type shadows everything with the same name.
						var shadowingName = (packContains(pack, curpack) && r.tname == name) ? name : null;
						// Also, this means we can access it as if it was imported (assuming it's not shadowed by something else.
						var is = cctx.getImportStatus(shadowingName != null, path);
						add(CompletionItem.makeCiType(CompletionModuleType.ofTypeDecl(pack, name, decl), is, null), shadowingName);
					}
				} catch (_:core.ds.Exit) {}
			}
			if (isPackVisible(pack)) run();
			return addedSomething;
		}

		// Collection starts here

		function tpair(?values:haxe.ds.StringMap<Expr>, t:T):TPair {
			var ct = CompletionType.fromType(Display.getImportStatus.bind(ctx), values, t);
			return {t: t, ct: ct};
		}
		switch tk {
			case TKType | TKOverride:
			case TKExpr(p) | TKPattern(p) | TKField(p):
				// locals
				Timer.time(ctx.com.timerCtx, ["display", "toplevel collect", "locals"], function(_:Null<Bool>) {
					ctx.f.locals.iter(function(_, v) {
						if (!Typecore.isGenLocal(v)) add(CompletionItem.makeCiLocal(v, tpair(Ast.getValueMeta(v.vMeta), v.vType)), v.vName);
					});
					return null;
				}, null);

				function addField(scope:ClassFieldScope, origin:ClassFieldOrigin, cf:TClassField):Void {
					var r = switch origin {
						case Self(TClassDecl(c)):
							var cf = maybeResolveMacroField(ctx, cf.cfType, c, cf).cf;
							{origin: Self(TClassDecl(c)), cf: cf};
						case StaticImport(TClassDecl(c)):
							var cf = maybeResolveMacroField(ctx, cf.cfType, c, cf).cf;
							{origin: StaticImport(TClassDecl(c)), cf: cf};
						case Parent(TClassDecl(c)):
							var cf = maybeResolveMacroField(ctx, cf.cfType, c, cf).cf;
							{origin: Parent(TClassDecl(c)), cf: cf};
						case StaticExtension(TClassDecl(c)):
							var cf = maybeResolveMacroField(ctx, cf.cfType, c, cf).cf;
							{origin: StaticExtension(TClassDecl(c)), cf: cf};
						case _:
							{origin: origin, cf: cf};
					};
					var origin = r.origin, cf = r.cf;
					var isQualified = cctx.isQualified(cf.cfName);
					add(CompletionItem.makeCiClassField(CompletionClassField.make(cf, scope, origin, isQualified),
						tpair(Ast.getValueMeta(cf.cfMeta), cf.cfType)),
						cf.cfName);
				}
				function maybeAddField(scope:ClassFieldScope, origin:ClassFieldOrigin, cf:TClassField):Void {
					if (!Meta.has(MetaTag.NoCompletion, cf.cfMeta)) addField(scope, origin, cf);
				}

				Timer.time(ctx.com.timerCtx, ["display", "toplevel collect", "fields"], function(_:Null<Bool>) {
					// member fields
					if (ctx.e.curfun != FunStatic) {
						var allFields = core.TOther.TClassTools.getAllFields(ctx.c.curclass, extractParamTypes(ctx.c.curclass.clParams));
						core.ds.PMap.iter(function(_, e:{cls:TClass, field:TClassField}) {
							var origin = e.cls == ctx.c.curclass ? Self(TClassDecl(e.cls)) : Parent(TClassDecl(e.cls));
							maybeAddField(CFSMember, origin, e.field);
						}, allFields);
						// TODO: local using?
					}

					// statics
					switch ctx.c.curclass.clKind {
						case KAbstractImpl(a) if (a.aImpl != null):
							var c = a.aImpl;
							var origin = Self(TAbstractDecl(a));
							for (cf in c.clOrderedStatics) {
								if (hasClassFieldFlag(cf, CfImpl)) {
									if (ctx.e.curfun == FunStatic) {} else {
										var cf = Typecore.prepareUsingField(cf);
										maybeAddField(CFSMember, origin, cf);
									}
								} else maybeAddField(CFSStatic, origin, cf);
							}
						case _:
							for (cf in ctx.c.curclass.clOrderedStatics) maybeAddField(CFSStatic, Self(TClassDecl(ctx.c.curclass)), cf);
					}
					return null;
				}, null);

				Timer.time(ctx.com.timerCtx, ["display", "toplevel collect", "enum ctors"], function(_:Null<Bool>) {
					// enum constructors
					function enumCtors(t:ModuleType):Void {
						switch t {
							case TAbstractDecl(a) if (a.aImpl != null && a.aEnum && !cctx.pathExists(a.aPath) && ctx.c.curclass != a.aImpl):
								var c = a.aImpl;
								cctx.addPath(a.aPath);
								for (cf in c.clOrderedStatics) {
									var ccf = CompletionClassField.make(cf, CFSMember, Self(CompletionItem.declOfClass(c)), true);
									if (hasClassFieldFlag(cf, CfEnum)
										&& !Meta.has(MetaTag.NoCompletion,
											cf.cfMeta)) add(CompletionItem.makeCiEnumAbstractField(a, ccf, tpair(cf.cfType)), cf.cfName);
								}
							case TTypeDecl(t):
								switch follow(t.tType) {
									case TEnum(e, _): enumCtors(TEnumDecl(e));
									case _:
								}
							case TEnumDecl(e) if (!cctx.pathExists(e.ePath)):
								cctx.addPath(e.ePath);
								var origin = Self(TEnumDecl(e));
								core.ds.PMap.iter(function(_, ef:TEnumField) {
									var isQualified = cctx.isQualified(ef.efName);
									add(CompletionItem.makeCiEnumField(CompletionEnumField.make(ef, origin, isQualified), tpair(ef.efType)),
										ef.efName);
								}, e.eConstrs);
							case _:
						}
					}
					for (mt in ctx.m.curmod.mTypes) enumCtors(mt);
					for (ti in ctx.m.importResolution.extractTypeImports()) enumCtors(ti.type);

					// enum constructors of expected type
					switch withType {
						case WithType(t, _):
							try enumCtors(moduleTypeOfType(follow(t)))
							catch (_:core.ds.Exit) {}
						case _:
					}
					return null;
				}, null);

				Timer.time(ctx.com.timerCtx, ["display", "toplevel collect", "globals"], function(_:Null<Bool>) {
					// imported globals
					ctx.m.importResolution.extractFieldImports().iter(function(name, fi) {
						var mt = fi.type, s = fi.name;
						try {
							var isQualified = cctx.isQualified(name);
							function classImport(c:TClass):Void {
								var cf = core.ds.PMap.find(s, c.clStatics);
								var cf = if (name == cf.cfName) cf else {
									var cf2 = cf.clone();
									cf2.cfName = name;
									cf2;
								};
								var r = switch c.clKind {
									case KAbstractImpl(a): {
											decl: TAbstractDecl(a),
											make: hasClassFieldFlag(cf,
												CfEnum) ? CompletionItem.makeCiEnumAbstractField.bind(a) : CompletionItem.makeCiClassField
										};
									case _: {decl: TClassDecl(c), make: CompletionItem.makeCiClassField};
								};
								var origin = StaticImport(r.decl);
								if (Typecore.canAccess(ctx, c, cf, true) && !Meta.has(MetaTag.NoCompletion, cf.cfMeta)) {
									add(r.make(CompletionClassField.make(cf, CFSStatic, origin, isQualified),
										tpair(Ast.getValueMeta(cf.cfMeta), cf.cfType)),
										name);
								}
							}
							switch resolveTypedef(mt) {
								case TClassDecl(c):
									classImport(c);
								case TEnumDecl(en):
									var ef = core.ds.PMap.find(s, en.eConstrs);
									var ef = if (name == ef.efName) ef else {
										var ef2 = ef.clone();
										ef2.efName = name;
										ef2;
									};
									var origin = StaticImport(TEnumDecl(en));
									add(CompletionItem.makeCiEnumField(CompletionEnumField.make(ef, origin, isQualified), tpair(ef.efType)),
										s);
								case TAbstractDecl({aImpl: c}) if (c != null):
									classImport(c);
								case _:
									throw core.ds.NotFound.raise();
							}
						} catch (_:core.ds.NotFound) {}
					});
					return null;
				}, null);

				Timer.time(ctx.com.timerCtx, ["display", "toplevel collect", "rest"], function(_:Null<Bool>) {
					// literals
					add(CompletionItem.makeCiLiteral("null", tpair(tDynamic)), "null");
					add(CompletionItem.makeCiLiteral("true", tpair(ctx.com.basic.tbool)), "true");
					add(CompletionItem.makeCiLiteral("false", tpair(ctx.com.basic.tbool)), "false");
					switch ctx.e.curfun {
						case FunMember | FunConstructor | FunMemberClassLocal:
							var t = TInst(ctx.c.curclass, extractParamTypes(ctx.c.curclass.clParams));
							add(CompletionItem.makeCiLiteral("this", tpair(t)), "this");
							if (ctx.c.curclass.clSuper != null) {
								var s = ctx.c.curclass.clSuper;
								add(CompletionItem.makeCiLiteral("super", tpair(TInst(s.cls, s.params))), "super");
							}
						case FunMemberAbstract:
							var t = TInst(ctx.c.curclass, extractParamTypes(ctx.c.curclass.clParams));
							add(CompletionItem.makeCiLiteral("abstract", tpair(t)), "abstract");
						case _:
					}

					// keywords
					var kwds:Array<Keyword> = [
						Function, Var, Final, If, Else, While, Do, For, Break, Return, Continue, Switch, Try, New, Throw, Untyped, Cast,
						Inline
					];
					for (kwd in kwds) add(CompletionItem.makeCiKeyword(kwd), Ast.sKeyword(kwd));

					// builtins
					add(CompletionItem.makeCiLiteral("trace",
						tpair(TFun({args: vector({name: "value", optional: false, type: tDynamic}), ret: ctx.com.basic.tvoid}))),
						"trace");
					return null;
				}, null);
		}

		// type params
		for (tp in ctx.typeParams) add(CompletionItem.makeCiTypeParam(tp.ttpClass, tpair(tp.ttpType)), tp.ttpClass.clPath.name);

		// module types
		for (mt in ctx.m.curmod.mTypes) addType(mt);

		// module imports
		var imports = ctx.m.importResolution.extractTypeImports().map(ti -> ti.type);
		imports.reverse(); // reverse!
		for (mt in imports) addType(mt);

		var cs:Cache = ctx.com.cs;
		function checkPackage(pack:Array<String>):Void {
			if (pack.length == 0) return;
			addPackage({pack: pack.slice(0, pack.length - 1), name: pack[pack.length - 1]});
		}
		Timer.time(ctx.com.timerCtx, ["display", "toplevel collect", "syntax"], function(_:Null<Bool>) {
			// types from files
			// online: iter context files
			initOrUpdateServer(cs, ctx.com, ["display", "toplevel"]);
			var cc = CommonCache.getCache(ctx.com);
			var files = cc.getFiles();
			// Sort files by reverse distance of their package to our current package.
			var files = files.fold(function(file, cfile, acc:Array<{key:String, cfile:CachedFile, i:Int}>) {
				var i = packSimilarity(curpack, cfile.cPackage);
				acc.unshift({key: file, cfile: cfile, i: i});
				return acc;
			}, []);
			haxe.ds.ArraySort.sort(files, (a, b) -> -Reflect.compare(a.i, b.i));
			for (f in files) {
				var cfile = f.cfile;
				var moduleName = CompilationCache.getModuleNameOfCfile(cfile.cFilePath.file, cfile);
				var dotPath = Globals.sTypePath({pack: cfile.cPackage, name: moduleName});
				if (core.ds.ArrayTools.exists(exclude, e -> StringTools.startsWith(dotPath, e + "."))) {} else {
					ctx.com.moduleToFile.add({pack: cfile.cPackage, name: moduleName}, cfile.cFilePath);
					if (processDecls(cfile.cPackage, moduleName, cfile.cDecls)) checkPackage(cfile.cPackage);
				}
			}
			return null;
		}, null);

		Timer.time(ctx.com.timerCtx, ["display", "toplevel collect", "native lib"], function(_:Null<Bool>) {
			for (file in ctx.com.nativeLibs.allLibs) {
				var lib = cs.getNativeLib(file);
				if (lib != null) lib.cNlFiles.iter(function(path, p:Package) {
					if (processDecls(p.pack, path.name, p.declarations)) checkPackage(p.pack);
				});
			}
			return null;
		}, null);

		Timer.time(ctx.com.timerCtx, ["display", "toplevel collect", "packages"], function(_:Null<Bool>) {
			// packages
			packages.iter(function(path, _) {
				var fullPack = path.pack.concat([path.name]);
				if (isPackVisible(fullPack)) add(CompletionItem.makeCiPackage(path, []), path.name);
			});
			return null;
		}, null);

		return Timer.time(ctx.com.timerCtx, ["display", "toplevel sorting"], function(_:Null<Bool>) {
			// sorting
			var l = cctx.items.copy();
			var l = if (sort) Display.sortFields(l, withType, tk) else l;
			return l;
		}, null);
	}

	public static function collect(ctx:Typer, tk:ToplevelKind, withType:WithTypeValue, sort:Bool):Array<CompletionItemData> {
		return Timer.time(ctx.com.timerCtx, ["display", "toplevel collect"], function(sort:Bool) return collect_(ctx, tk, withType, sort),
			sort);
	}

	public static function collectAndRaise<R>(ctx:Typer, tk:ToplevelKind, withType:WithTypeValue, cr:CompletionResultKindValue,
			name:String, pname:Pos, pinsert:Pos):R {
		var p_ = DisplayException.lastCompletionPos;
		var fields = if (p_ != null && pname.pmin == p_.pmin) DisplayException.lastCompletionResult.toArray() else collect(ctx, tk, withType,
			name == "");
		return DisplayException.raiseFields(fields, cr, DisplayTypes.makeSubject(name, pinsert, pname));
	}

	public static function handleUnresolvedIdentifier(ctx:Typer, i:String, p:Pos, onlyTypes:Bool):Void {
		var l = collect(ctx, onlyTypes ? TKType : TKExpr(p), NoValue, false);
		var cl = l.map(function(it) {
			var s = CompletionItem.getName(it);
			var i = core.StringError.levenshtein(i, s);
			return {s: s, it: it, i: i};
		});
		haxe.ds.ArraySort.sort(cl, (a, b) -> Reflect.compare(a.i, b.i));
		// port: StringError.filter_similar
		var similar = [];
		for (e in cl) {
			if (e.i <= Std.int((e.s.length < i.length ? e.s.length : i.length) / 3)) similar.push(e)
			else break;
		}
		var cm = DiagnosticsPrinter.makeUnresolvedIdentifierMessage(i, p, similar.map(e -> {s: e.s, item: e.it, r: e.i}));
		compiler.io.CompilerMessage.addModuleDiagnostic(ctx.com, ctx.m.curmod, cm);
	}
}
