package context.display;

import core.Globals.Pos;
import core.Globals;
import core.Path.UniqueKey;
import core.display.DisplayPosition;
import core.StringError;
import core.Error.*;
import core.ds.PMap;
import core.ds.NotFound;
import context.Resolution;
import context.Resolution.*;
import core.display.CompletionItem.ToplevelKind;
import core.DisplayTypes.CompletionResultKindValue;
import context.Common.*;
import core.Ast;
import context.Typecore.Typer;
import core.TType;
import core.TFunctions.*;
import context.Typecore.*;
import context.TyperPass;

using core.ds.VectorTools;

enum ImportDisplayKind {
	IDKPackage(sl:Array<String>);
	IDKModule(sl:Array<String>, s:String);
	IDKSubType(sl:Array<String>, sm:String, st:String);
	IDKModuleField(sl:Array<String>, sm:String, sf:String);
	IDKSubTypeField(sl:Array<String>, sm:String, st:String, sf:String);
	IDK;
}

// port: ModuleDefDisplay.mImportPositions is keyed by position strings (see key).
class ImportHandling {
	public static function convertImportToSomethingUsable(pt:Pos, path:haxe.ds.Vector<PlacedName>):{kind:ImportDisplayKind, pos:Pos} {
		var pack:Array<String> = [],
			m:Null<String> = null,
			t:Null<String> = null;
		for (part in path) {
			var s = part.name, p = part.pos;
			var isLower = Ast.isLowerIdent(s);
			var isDisplayPos = DisplayPosition.enclosesPosition(pt, p);
			if (m == null && t != null) throw new core.Globals.InternalCompilerError("importHandling.ml: impossible import state",
				""); // impossible, I think
			else if (isLower && m != null && t == null) {
				if (isDisplayPos) return {kind: IDKModuleField(pack.copy(), m, s), pos: p};
				else return {kind: IDK, pos: p}; // assume that we're done
			} else if (m != null && t != null) {
				if (isDisplayPos) return {kind: IDKSubTypeField(pack.copy(), m, t, s), pos: p};
				else return {kind: IDK, pos: p};
			} else if (isLower && m == null && t == null) {
				if (isDisplayPos) return {kind: IDKPackage(pack.concat([s])), pos: p};
				else pack.push(s);
			} else if (!isLower && m != null && t == null) {
				if (isDisplayPos) return {kind: IDKSubType(pack.copy(), m, s), pos: p};
				else t = s;
			} else {
				if (isDisplayPos) return {kind: IDKModule(pack.copy(), s), pos: p};
				else m = s;
			}
		}
		return {kind: IDK, pos: Globals.nullPos};
	}

	// port: injective (the file comes last) and much cheaper than JSON-encoding the position per lookup.
	public static function key(p:Pos):String return p.pmin + ":" + p.pmax + ":" + p.pfile;

	public static function posOfKey(k:String):Pos {
		var i = k.indexOf(":"), j = k.indexOf(":", i + 1);
		return {pfile: k.substr(j + 1), pmin: Std.parseInt(k.substr(0, i)), pmax: Std.parseInt(k.substr(i + 1, j - i - 1))};
	}

	// port: OCaml's `compare` on positions: file, then pmin, then pmax.
	public static function comparePos(a:Pos, b:Pos):Int {
		var c = context.display.Display.compareStrings(a.pfile, b.pfile);
		if (c != 0) return c;
		if (a.pmin != b.pmin) return a.pmin < b.pmin ? -1 : 1;
		if (a.pmax != b.pmax) return a.pmax < b.pmax ? -1 : 1;
		return 0;
	}

	// port: `PMap.iter` over `m_import_positions`: in position order.
	public static function iterImportPositions(positions:Map<String, Bool>, f:String->Pos->Bool->Void):Void {
		var l = [for (k in positions.keys()) {key: k, pos: posOfKey(k)}];
		l.sort((a, b) -> comparePos(a.pos, b.pos));
		for (e in l) f(e.key, e.pos, positions.get(e.key));
	}

	public static function sortedImportPositions(positions:Map<String, {pos:Pos, used:{value:Bool}}>):Array<{pos:Pos, used:{value:Bool}}> {
		var l = [for (v in positions) v];
		l.sort((a, b) -> comparePos(a.pos, b.pos));
		return l;
	}

	public static function addImportPosition(ctx:Typer, p:Pos, path:haxe.ds.Vector<PlacedName>):Void {
		var positions = ctx.m.curmod.mExtra.mDisplay.mImportPositions, k = key(p);
		if (!positions.exists(k)) positions.set(k, false);
	}

	public static function markImportPosition(ctx:Typer, p:Pos):Void {
		var positions = ctx.m.curmod.mExtra.mDisplay.mImportPositions, k = key(p);
		if (positions.exists(k)) positions.set(k, true);
	}

	public static function commitImport(ctx:Typer, path:haxe.ds.Vector<PlacedName>, mode:ImportMode, p:Pos):Void {
		ctx.m.importStatements.unshift({path: path, mode: mode});
		if (haxe.io.Path.withoutDirectory(p.pfile) != "import.hx") addImportPosition(ctx, p, path);
	}

	public static function initImport(ctx:Typer, path:haxe.ds.Vector<PlacedName>, mode:ImportMode, p:Pos):Void {
		var i = 0;
		while (i < path.length && Ast.isLowerIdent(path[i].name)) i++;
		var pack = path.slice(0, i), rest = path.slice(i);
		if (rest.length == 0) {
			if (mode == IAll) ctx.m.importResolution.add(wildcardPackageResolution(pack.mapToArray(part -> part.name), p));
			// p spans `import |` (to the display position), so we take the pmax here
			else if (path.length == 0) DisplayException.raiseFields(DisplayToplevel.collect(ctx, TKType, NoValue, true), CRImport,
				core.DisplayTypes.DisplayTypes.makeSubject(null, {
					pfile: p.pfile,
					pmin: p.pmax,
					pmax: p.pmax
				}));
			else raiseTypingError("Module name must start with an uppercase letter", path[path.length - 1].pos);
			return;
		}
		var tname = rest[0].name, p2 = rest[0].pos;
		rest = rest.slice(1);
		var p1 = pack.length == 0 ? p2 : pack[0].pos,
			pType = Ast.punion(p1, p2);
		var md = ctx.g.doLoadModule(ctx, {pack: pack.mapToArray(part -> part.name), name: tname}, pType, MDepFromImport),
			types = md.mTypes;
		inline function errorPrivate(p:Pos):Void raiseTypingError("Importing private declarations from a module is not allowed", p);
		inline function checkPrivate(t:ModuleType, p:Pos):Void {
			if (ctx.m.curmod != tModule(t) && tPrivate(t)) errorPrivate(p);
		}
		// TODO: cleaner way to get module fields?
		inline function staticNames():Array<String> {
			if (md.mStatics == null) return [];
			var names = PMap.keys(md.mStatics.clStatics);
			names.reverse();
			return names;
		}
		function failUsefully<R>(name:String, p:Pos):R {
			var lower = name.charAt(0) >= "a" && name.charAt(0) <= "z",
				candidates = lower ? staticNames() : types.map(mt -> tPath(mt).name);
			return raiseTypingError(StringError.stringError(name, candidates,
				"Module "
				+ Globals.sTypePath(md.mPath)
				+ " does not define "
				+ (lower ? "field" : "type")
				+ " "
				+ name),
				p);
		}
		function findType(name:String):ModuleType {
			for (mt in types) if (tPath(mt).name == name) return mt;
			throw NotFound.raise();
		}
		inline function getType(name:String):ModuleType {
			var t = try findType(name) catch (_:NotFound) failUsefully(name, pType);
			checkPrivate(t, pType);
			return t;
		}
		inline function checkAlias(mt:ModuleType, name:String, pname:Pos):Void {
			if (!(name.charAt(0) >= "A" && name.charAt(0) <= "Z")) raiseTypingError("Type aliases must start with an uppercase letter",
				pname);
			// Imports from import.hx should not match display position from current file
			if (ctx.m.isDisplayFile
				&& DisplayPosition.displayPosition.enclosedIn(pname)
				&& UniqueKey.create(pname.pfile) == UniqueKey.lazyKey(ctx.m.curmod.mExtra.mFile)) DisplayEmitter.displayAlias(ctx, name,
					typeOfModuleType(mt), pname);
		}
		inline function addStaticInit(t:ModuleType, name:Null<String>, s:String):ResolvedImport return switch resolveTypedef(t) {
			case TClassDecl(c):
				c.clBuild();
				staticFieldResolution(c, PMap.find(s, c.clStatics), name, p);
			case TAbstractDecl(a) if (a.aImpl != null):
				var c = a.aImpl;
				c.clBuild();
				staticAbstractFieldResolution(a, c, PMap.find(s, c.clStatics), name, p);
			case TEnumDecl(en): enumConstructorResolution(en, PMap.find(s, en.eConstrs), name, p);
			case _: throw NotFound.raise();
		};
		inline function addLazyResolution(f:Void->Null<ResolvedImport>):Void ctx.m.importResolution.add(lazyResolution(f));
		switch mode {
			case INormal | IAsName(_):
				var name:Null<PlacedName> = switch mode {
					case IAsName(n): n;
					case _: null;
				};
				var alias = name == null ? null : name.name;
				if (rest.length == 0) {
					if (name == null) {
						var rev = types.copy();
						rev.reverse();
						for (mt in rev) if (!tPrivate(mt)) ctx.m.importResolution.add(moduleTypeResolution(mt, null, p));
						if (md.mStatics != null) ctx.m.importResolution.add(classStaticsResolution(md.mStatics, p));
					} else {
						var mt = getType(tname);
						checkAlias(mt, name.name, name.pos);
						ctx.m.importResolution.add(moduleTypeResolution(mt, name.name, p));
					}
				} else if (rest.length == 1) {
					var subName = rest[0].name,
						pu = Ast.punion(p1, rest[0].pos);
					try {
						var sub = findType(subName);
						checkPrivate(sub, pu);
						if (name != null) checkAlias(sub, name.name, name.pos);
						ctx.m.importResolution.add(moduleTypeResolution(sub, alias, p));
					} catch (_:NotFound) {
						// this might be a static property, wait later to check
						function findMainTypeStatic():Null<ResolvedImport> {
							try {
								var main = findType(tname);
								// port: HashLink 2.0 JIT: an early exit through two nested try blocks restores only the
								// innermost trap, leaving a dangling handler; the result is returned from the outer try only.
								var resolved = try addStaticInit(main, alias, subName) catch (_:NotFound) {
									var info = switch resolveTypedef(main) {
										case TClassDecl(c): {
												parent: "Class<" + Globals.sTypePath(c.clPath) + ">",
												kind: "field",
												names: PMap.keys(c.clStatics)
											};
										case TAbstractDecl(a) if (a.aImpl != null): {
												parent: "Abstract<" + Globals.sTypePath(md.mPath) + ">",
												kind: "field",
												names: PMap.keys(a.aImpl.clStatics)
											};
										case TEnumDecl(e): {
												parent: "Enum<" + Globals.sTypePath(md.mPath) + ">",
												kind: "field",
												names: PMap.keys(e.eConstrs)
											};
										case _: {
												parent: "Module " + Globals.sTypePath(md.mPath),
												kind: "field or subtype",
												names: staticNames()
											};
									};
									// port: PMap.foldi builds source candidate lists in reverse key order.
									switch resolveTypedef(main) {
										case TClassDecl(_) | TEnumDecl(_): info.names.reverse();
										case TAbstractDecl(a) if (a.aImpl != null): info.names.reverse();
										case _:
									}
									displayError(ctx.com,
										StringError.stringError(subName, info.names, info.parent + " has no " + info.kind + " " + subName),
										p);
									return null;
								}
								return resolved;
							} catch (_:NotFound) return failUsefully(subName, p);
						}
						addLazyResolution(function() {
							if (md.mStatics != null) {
								var c = md.mStatics;
								try {
									c.clBuild();
									for (cf in c.clOrderedStatics) if (cf.cfName == subName) {
										if (!hasClassFieldFlag(cf, CfPublic)) errorPrivate(p);
										return staticFieldResolution(c, cf, alias, p);
									}
									throw NotFound.raise();
								} catch (_:NotFound) return findMainTypeStatic();
							}
							return findMainTypeStatic();
						});
					}
				} else {
					if (rest.length > 2) raiseTypingError("Unexpected " + rest[2].name, rest[2].pos);
					var sub = getType(rest[0].name),
						fname = rest[1].name,
						p3 = rest[1].pos;
					addLazyResolution(function() {
						try return addStaticInit(sub, alias, fname)
						catch (_:NotFound) {
							displayError(ctx.com, Globals.sTypePath(tPath(sub)) + " has no field " + fname, Ast.punion(p, p3));
							return null;
						}
					});
				}
			case IAll:
				var t = if (rest.length == 0) getType(tname) else if (rest.length == 1) getType(rest[0].name) else
					raiseTypingError("Unexpected "
					+ rest[1].name, rest[1].pos);
				addLazyResolution(function() return switch resolveTypedef(t) {
					case TClassDecl(c): classStaticsResolution(c, p);
					case TAbstractDecl(a) if (a.aImpl != null): classStaticsResolution(a.aImpl, p);
					case TEnumDecl(en): enumStaticsResolution(en, p);
					case _: raiseTypingError("No statics to import from this type", p);
				});
		}
	}

	public static function handleUsing(ctx:Typer, path:haxe.ds.Vector<PlacedName>,
			p:Pos):{types:Array<ModuleType>, filterClasses:Array<ModuleType>->Array<{cls:TClass, pos:Pos}>} {
		var parts = path.rev();
		var t:TypePath;
		if (parts.length >= 2) {
			var s1 = parts[0].name,
				s2 = parts[1].name,
				pack = parts.slice(2).mapToArray(part -> part.name);
			pack.reverse();
			if (Ast.isLowerIdent(s2)) {
				pack.push(s2);
				t = Ast.mkTypePath(pack, s1);
			} else t = Ast.mkTypePath(pack, s2, null, s1);
		} else if (parts.length == 1) t = Ast.mkTypePath([], parts[0].name);
		else return DisplayException.raiseFields(DisplayToplevel.collect(ctx, TKType, NoValue, true), CRUsing,
			core.DisplayTypes.DisplayTypes.makeSubject(null, {
				pfile: p.pfile,
				pmin: p.pmax,
				pmax: p.pmax
			}));
		var types:Array<ModuleType>;
		if (t.tsub == null) {
			var md = ctx.g.doLoadModule(ctx, {pack: t.tpackage, name: t.tname}, p, MDepFromImport);
			types = md.mTypes.filter(mt -> !tPrivate(mt));
			if (md.mStatics != null) types.unshift(TClassDecl(md.mStatics));
		} else types = [ctx.g.doLoadTypeDef(ctx, p, t)];
		function filterClasses(types:Array<ModuleType>):Array<{cls:TClass, pos:Pos}> {
			var result:Array<{cls:TClass, pos:Pos}> = [];
			for (td in types) switch resolveTypedef(td) {
				case TClassDecl(c):
					result.unshift({cls: c, pos: p});
				case TAbstractDecl(a) if (a.aImpl != null):
					result.unshift({cls: a.aImpl, pos: p});
				case _:
			}
			return result;
		}
		return {types: types, filterClasses: filterClasses};
	}

	public static function initUsing(ctx:Typer, path:haxe.ds.Vector<PlacedName>, p:Pos):Void {
		var result = handleUsing(ctx, path, p), types = result.types.copy();
		types.reverse();
		// do the import first
		for (mt in types) ctx.m.importResolution.add(Resolution.moduleTypeResolution(mt, null, p));
		// delay the using since we need to resolve typedefs
		delayLate(ctx.g, PConnectField, () -> ctx.m.moduleUsing = result.filterClasses(result.types).concat(ctx.m.moduleUsing));
	}
}
