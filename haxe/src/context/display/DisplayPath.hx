package context.display;

import core.Globals;
import core.Globals.Pos;
import core.Globals.GlobalTypePath;
import core.TFunctions.*;
import core.WithType as WithTypeTools;
import core.display.DisplayPosition;
import context.Common;
import context.Typecore.Typer;
import context.display.ImportHandling.ImportDisplayKind;
import core.Ast;
import core.DisplayTypes;
import core.TType;
import core.display.CompletionItem;

class TypePathHandler {
	public static function unique(l:Array<String>):Array<String> {
		var l = l.copy();
		haxe.ds.ArraySort.sort(l, Display.compareStrings);
		var out = [];
		for (i in 0...l.length) if (i + 1 >= l.length || l[i] != l[i + 1]) out.push(l[i]);
		return out;
	}

	public static function readTypePath(com:CommonContext, p:Array<String>):{packages:Array<String>, classes:Array<String>} {
		var classes:Array<String> = [];
		var packages:Array<String> = [];
		var p = if (p.length > 0) {
			switch com.packageRules.get(p[0]) {
				case Remap(s): [s].concat(p.slice(1));
				case _: p;
			}
		} else p;
			(com.classPaths : core.ClassPaths).iter(function(path) {
				var path = path.path;
				var dir = path + p.join("/");
				var r = try sys.FileSystem.readDirectory(dir) catch (_:Dynamic) [];
				for (f in r) {
					if (try sys.FileSystem.isDirectory(dir + "/" + f) catch (_:Dynamic) false) {
						if (StringTools.fastCodeAt(f, 0) >= "a".code && StringTools.fastCodeAt(f, 0) <= "z".code) {
							if (p.length == 1 && p[0] == ".") {
								var r = readTypePath(com, [f]);
								if (r.packages.length == 0 && r.classes.length == 0) {} else {
									switch com.packageRules.get(f) {
										case Forbidden:
										case Remap(f):
											packages.unshift(f);
										case null:
											packages.unshift(f);
									}
								}
							} else packages.unshift(f);
						}
					} else if (core.Path.fileExtension(f) == "hx" && f != "import.hx") {
						var c = haxe.io.Path.withoutExtension(f);
						if (c.indexOf(".") < 0) {
							if (c.length < 2 || c.substr(c.length - 2, 2) != "__") classes.unshift(c);
						}
					}
				}
			});
		function processLib(modules:Array<GlobalTypePath>) {
			for (m in modules) {
				var path = m.pack, name = m.name;
				if (path.join(".") == p.join(".") && path.length == p.length) classes.unshift(name) else {
					function loop(p1:Array<String>, p2:Array<String>) {
						if (p1.length == 0) {} else if (p2.length == 0) packages.unshift(p1[0]) else if (p1[0] == p2[0]) loop(p1.slice(1), p2.slice(1));
					}
					loop(path, p);
				}
			}
		}
		for (lib in com.nativeLibs.swfLibs) processLib(lib.listModules());
		for (lib in com.nativeLibs.javaLibs) processLib(lib.listModules());
		return {packages: unique(packages), classes: unique(classes)};
	}

	/** raise field completion listing packages and modules in a given package **/
	public static function completeTypePath(com:CommonContext, p:Array<String>):Null<Array<CompletionItemData>> {
		var r = readTypePath(com, p);
		if (r.packages.length == 0 && r.classes.length == 0) return core.Error.abort("No modules found in " + p.join("."), Globals.nullPos);
		var packs = r.packages.map(n -> CompletionItem.makeCiPackage({pack: p, name: n}, []));
		var modules = r.classes.map(n -> CompletionItem.makeCiModule({pack: p, name: n}));
		return packs.concat(modules);
	}

	/** raise field completion listing module sub-types and static fields **/
	public static function completeTypePathInner(ctx:Typer, p:Array<String>, c:String, curPackage:Bool,
			isImport:Bool):Null<Array<CompletionItemData>> {
		try {
			var r = if (p.length > 0
				&& StringTools.fastCodeAt(p[p.length - 1], 0) >= "A".code
				&& StringTools.fastCodeAt(p[p.length - 1], 0) <= "Z".code) {
				{slPack: p.slice(0, p.length - 1), sModule: p[p.length - 1]};
			} else {slPack: p, sModule: c};
			var slPack = r.slPack, sModule = r.sModule;
			// This is a bit wacky: We want to reset the display position so that revisiting the display file
			// does not raise another TypePath exception. However, we still want to have it treated like the
			// display file, so we just set the position to 0 (#6558).
			var old = DisplayPosition.displayPosition.get();
			DisplayPosition.displayPosition.set({pfile: old.pfile, pmin: 0, pmax: 0});
			function lookup(p:Array<String>):ModuleDef {
				try {
					return ctx.g.doLoadModule(ctx, {pack: p, name: sModule}, Globals.nullPos);
				} catch (e:Dynamic) {
					if (curPackage) {
						if (p.length == 0) throw e;
						return lookup(p.slice(0, p.length - 1));
					} else throw e;
				}
			}
			var m = try {
				var m = lookup(slPack);
				DisplayPosition.displayPosition.set(old);
				m;
			} catch (e:Dynamic) {
				DisplayPosition.displayPosition.set(old);
				throw e;
			};
			var statics:Null<TClass> = null;
			var enumStatics:Null<TEnum> = null;
			var publicTypes = m.mTypes.filter(function(t) {
				var tinfos = tInfos(t);
				var isModuleType = tinfos.mtPath.name == c;
				if (isImport && isModuleType) switch t {
					case TClassDecl(c) | TAbstractDecl({aImpl: c}) if (c != null):
						c.clBuild();
						statics = c;
					case TEnumDecl(en):
						enumStatics = en;
					case _:
				}
				return !tinfos.mtPrivate;
			});
			var types = if (c != sModule) [] else publicTypes.map(mt -> CompletionItem.makeCiType(CompletionModuleType.ofModuleType(mt),
				Imported, null));
			function classOrigin(c:TClass):ClassFieldOrigin return switch c.clKind {
				case KAbstractImpl(a): Self(TAbstractDecl(a));
				case _: Self(TClassDecl(c));
			};
			function tpair(t:T):TPair return {t: t, ct: CompletionType.fromType(Display.getImportStatus.bind(ctx), t)};
			function makeFieldDoc(c:TClass, cf:TClassField):CompletionItemData {
				return CompletionItem.makeCiClassField(CompletionClassField.make(cf, CFSStatic, classOrigin(c), true), tpair(cf.cfType));
			}
			var fields = if (statics == null) types else {
				var c = statics;
				types.concat(c.clOrderedStatics.filter(cf -> hasClassFieldFlag(cf, CfPublic)).map(makeFieldDoc.bind(c)));
			};
			var fields = if (enumStatics == null) fields else {
				var en = enumStatics;
				core.ds.PMap.fold(function(ef:TEnumField, acc:Array<CompletionItemData>) {
					return [
						CompletionItem.makeCiEnumField(CompletionEnumField.make(ef, Self(TEnumDecl(en)), true), tpair(ef.efType))
					].concat(acc);
				}, en.eConstrs, fields);
			};
			return fields;
		} catch (_:Dynamic) {
			return core.Error.abort("Could not load module " + Globals.sTypePath({pack: p, name: c}), Globals.nullPos);
		}
	}
}

class DisplayPath {
	public static function resolvePositionByPath<R>(ctx:Typer, path:TypePath, p:Pos):R {
		var mt = ctx.g.doLoadTypeDef(ctx, p, path);
		var p = tInfos(mt).mtPos;
		return DisplayException.sendPositionsRaise(ctx.com, [p]);
	}

	public static function handlePathDisplay(ctx:Typer, path:haxe.ds.Vector<PlacedName>, p:Pos):Void {
		function classField(c:TClass, name:String):Void {
			c.clBuild();
			var cf = core.ds.PMap.find(name, c.clStatics);
			var origin = switch c.clKind {
				case KAbstractImpl(a): Self(TAbstractDecl(a));
				case _: Self(TClassDecl(c));
			};
			DisplayEmitter.displayField(ctx, origin, CFSStatic, cf, p);
		}
		var r = ImportHandling.convertImportToSomethingUsable(DisplayPosition.displayPosition.get(), path);
		switch [r.kind, ctx.com.display.dmsKind] {
			case [IDKPackage([s]), DMDefault]:
				var p = r.pos;
				DisplayToplevel.collectAndRaise(ctx, TKType, WithTypeTools.noValue, CRImport, s, p, p);
			case [IDKPackage(sl), DMDefault]:
				var p = r.pos;
				var sl = if (sl.length > 0) sl.slice(0,
					sl.length - 1) else throw new core.Globals.InternalCompilerError("displayPath.ml: empty package", "");
				throw new syntax.Parser.TypePathCompletion(sl, null, true, p);
			case [IDKPackage(_), _]:
				// ?
			case [IDKModule(sl, s), DMDefinition | DMTypeDefinition]:
				// We assume that we want to go to the module file, not a specific type
				// which might not even exist anyway.
				var mt = ctx.g.doLoadModule(ctx, {pack: sl, name: s}, p);
				var p = Globals.filePos(core.Path.UniqueKey.lazyPath(mt.mExtra.mFile));
				DisplayException.sendPositionsRaise(ctx.com, [p]);
			case [IDKModule(sl, s), DMHover]:
				var m = ctx.g.doLoadModule(ctx, {pack: sl, name: s}, p);
				var mt = core.ds.ArrayTools.find(m.mTypes, mt -> tInfos(mt).mtPath.name == s);
				if (mt != null) DisplayEmitter.displayModuleType(ctx, mt, p);
			case [IDKSubType(sl, sm, st), DMHover]:
				var p = r.pos;
				// TODO: remove code duplication once load_type_def change is in
				var m = ctx.g.doLoadModule(ctx, {pack: sl, name: sm}, p);
				var mt = core.ds.ArrayTools.find(m.mTypes, mt -> tInfos(mt).mtPath.name == st);
				if (mt != null) DisplayEmitter.displayModuleType(ctx, mt, p);
			case [IDKModule([], s), DMDefault]:
				var p = r.pos;
				DisplayToplevel.collectAndRaise(ctx, TKType, WithTypeTools.noValue, CRImport, s, p, p);
			case [IDKModule(sl, s), _]:
				throw new syntax.Parser.TypePathCompletion(sl, null, true, r.pos);
			case [IDKSubType(sl, sm, st), DMDefinition | DMTypeDefinition]:
				resolvePositionByPath(ctx, Ast.mkTypePath(sl, sm, null, st), r.pos);
			case [IDKSubType(sl, sm, st), _]:
				throw new syntax.Parser.TypePathCompletion(sl, {name: sm, isSub: false}, true, r.pos);
			case [IDKSubTypeField(sl, sm, st, sf), DMDefault]:
				throw new syntax.Parser.TypePathCompletion(sl.concat([sm]), {name: st, isSub: false}, true, r.pos);
			case [IDKModuleField(sl, sm, sf), DMDefault]:
				throw new syntax.Parser.TypePathCompletion(sl.concat([sm]), {name: sm, isSub: false}, true, r.pos);
			case [IDKSubTypeField(sl, sm, st, sf), _]:
				var p = r.pos;
				var m = ctx.g.doLoadModule(ctx, {pack: sl, name: sm}, p);
				for (t in m.mTypes) switch t {
					case TClassDecl(c) if (c.clPath.name == st): classField(c, sf);
					case TAbstractDecl({aImpl: c, aPath: {name: st_}}) if (c != null && st_ == st): classField(c, sf);
					case _:
				}
			case [IDKModuleField(sl, sm, sf), _]:
				var st = sm;
				var p = r.pos;
				var m = ctx.g.doLoadModule(ctx, {pack: sl, name: sm}, p);
				for (t in m.mTypes) switch t {
					case TClassDecl(c) if (c.clPath.name == st): classField(c, sf);
					case TAbstractDecl({aImpl: c, aPath: {name: st_}}) if (c != null && st_ == st): classField(c, sf);
					case _:
				}
			case [IDK, _]:
		}
	}
}
