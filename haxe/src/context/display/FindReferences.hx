package context.display;

import core.Globals;
import core.Globals.Pos;
import core.TFunctions.*;
import compiler.CompilationCache;
import context.Common;
import context.Typecore.Typer;
import context.display.Display.ReferencePosition;
import context.display.Statistics;
import core.DisplayTypes;
import core.TType;

class FindReferences {
	public static function findPossibleReferences(tctx:Typer, cs:Cache):Void {
		var r = ReferencePosition.get();
		SyntaxExplorer.exploreUncachedModules(tctx, cs, [{name: r.name, kind: r.kind}]);
	}

	static function findReferences_(com:CommonContext, withDefinition:Bool, posFilters:Array<StatisticsFilter>):Array<Pos> {
		var r = core.Timer.time(com.timerCtx, ["display", "references", "collect"],
			function(withExpressions:Bool) return Statistics.collectStatistics(com, posFilters, withExpressions), true);
		var symbols = r.symbols, relations = r.relations;
		function loop(acc:Array<Pos>, relations:Array<{r:Relation, p:Pos}>):Array<Pos> {
			for (rel in relations) {
				if (rel.r == Referenced && !core.ds.ArrayTools.exists(acc, p -> Statistics.posEq(p, rel.p))) acc.unshift(rel.p);
			}
			return acc;
		}
		var usages = core.Timer.time(com.timerCtx, ["display", "references", "filter"], function(_:Null<Bool>) {
			return symbols.fold(function(p, sym, acc:Array<Pos>) {
				var acc = if (withDefinition) [p].concat(acc) else acc;
				var l = relations.findOpt(p);
				return l == null ? acc : loop(acc, l);
			}, []);
		}, null);
		ReferencePosition.reset();
		return usages;
	}

	// This probably exists somewhere already but I can't find it
	public static function isVarField(cf:TClassField):Bool return switch cf.cfKind {
		case Method(_): false;
		case Var(_): true;
	};

	public static function collectReferencePositions(com:CommonContext,
			ref:{name:String, pos:Pos, kind:Symbol}):Array<{name:String, pos:Pos, kind:Symbol}> {
		var name = ref.name, pos = ref.pos, kind = ref.kind;
		switch [kind, com.display.dmsKind] {
			case [SKField(cf, c), DMUsage(_, findDescendants, _)] if (c != null && findDescendants && isVarField(cf)):
				var d = [];
				d.push(ref);
				switch cf.cfKind {
					case Var(vk):
						var host = typing.FieldAccess.getHost(c, cf);
						function check(r:VarAccess, mode:context.Typecore.AccessMode):Void {
							switch r {
								case AccCall | AccPrivateCall:
									switch typing.FieldAccess.findAccessorForField(host, cf, cf.cfType, mode) {
										case AccessorFound(found):
											var cHost = typing.FieldAccess.getHostClassRaise(found.host);
											var newRef = {
												name: found.field.cfName,
												pos: found.field.cfNamePos,
												kind: SKField(found.field, cHost)
											};
											d.push(newRef);
											for (x in collectReferencePositions(com, newRef)) d.push(x);
										case _:
									}
								case _:
							}
						}
						check(vk.vRead, MGet);
						check(vk.vWrite, MSet(null));
					case _:
				}
				return d;
			case [SKField(cf, c), DMUsage(_, findDescendants, findBase)]
				if (c != null && (findDescendants || findBase) && !hasClassFieldFlag(cf, CfStatic)):
				function collect():Array<{name:String, pos:Pos, kind:Symbol}> {
					var c = {
						var found:Null<TClass> = null;
						for (t in com.types) switch t {
							case TClassDecl(c_) if (CompilationCache.pathEq(c.clPath, c_.clPath)):
								found = c_;
								break;
							case _:
						}
						if (found == null) throw core.ds.Exit.raise();
						found;
					};
					var fieldClassPairs = {
						// check classes hierarchy
						var r = if (findBase) {
							function loop(c:TClass):{cf:TClassField, c:TClass} {
								if (c.clSuper == null) return {cf: c.clFields.find(cf.cfName), c: c};
								try {
									return loop(c.clSuper.cls);
								} catch (_:core.ds.NotFound) {
									return {cf: c.clFields.find(cf.cfName), c: c};
								}
							}
							try loop(c)
							catch (_:core.ds.NotFound) {cf: cf, c: c};
						} else {cf: cf, c: c};
						var cf = r.cf, c = r.c;
						// check interfaces of the found base class
						var loop:TClass->Array<{cf:TClassField, c:TClass}> = null;
						function foldInterface(acc:Array<{cf:TClassField, c:TClass}>,
								i:{cls:TClass, params:TParams}):Array<{cf:TClassField, c:TClass}> {
							try {
								return loop(i.cls).concat(acc);
							} catch (_:core.ds.NotFound) {
								return acc;
							}
						}
						loop = function(c:TClass):Array<{cf:TClassField, c:TClass}> {
							var pairs = [];
							for (i in c.clImplements) pairs = foldInterface(pairs, i);
							return pairs.length == 0 ? [{cf: c.clFields.find(cf.cfName), c: c}] : pairs;
						};
						var pairs = [];
						for (i in c.clImplements) pairs = foldInterface(pairs, i);
						pairs.length == 0 ? [{cf: cf, c: c}] : pairs;
					};
					function fullPos(p:Pos):Pos return Statistics.posEq(p,
						Globals.nullPos) ? Globals.nullPos : {pfile: core.Path.getFullPath(p.pfile), pmin: p.pmin, pmax: p.pmax};
					if (findDescendants) {
						function extends_(childCls:TClass, pair:{cf:TClassField, c:TClass}):Bool return extendsClass(childCls, pair.c);
						var acc = [];
						for (t in com.types) switch t {
							case TClassDecl(childCls) if (core.ds.ArrayTools.exists(fieldClassPairs, extends_.bind(childCls))):
								var cf = childCls.clFields.get(cf.cfName);
								if (cf != null) acc.unshift({name: name, pos: fullPos(cf.cfNamePos), kind: SKField(cf, childCls)});
							case _:
						}
						return acc;
					} else return fieldClassPairs.map(pair -> {
						name: name,
						pos: fullPos(pair.cf.cfNamePos),
						kind: SKField(pair.cf, pair.c)
					});
				}
				return try collect() catch (_:core.ds.Exit) [ref];
			case _:
				return [ref];
		}
	}

	public static function findReferences(com:CommonContext, withDefinition:Bool):Void {
		var posFilters = [];
		for (r in collectReferencePositions(com, ReferencePosition.get())) {
			if (!Statistics.posEq(r.pos, Globals.nullPos)) posFilters.unshift(SFPos(r.pos));
		}
		var usages = findReferences_(com, withDefinition, posFilters);
		haxe.ds.ArraySort.sort(usages, comparePos);
		DisplayException.sendPositionsRaise(com, usages);
	}

	static function comparePos(p1:Pos, p2:Pos):Int {
		var c = Display.compareStrings(p1.pfile, p2.pfile);
		if (c != 0) return c;
		return Reflect.compare(p1.pmin, p2.pmin);
	}

	static function findImplementations_(com:CommonContext, name:String, pos:Pos, kind:Symbol):Void {
		var r = core.Timer.time(com.timerCtx, ["display", "implementations", "collect"],
			function(withExpressions:Bool) return Statistics.collectStatistics(com, [SFPos(pos)], withExpressions), false);
		var symbols = r.symbols, relations = r.relations;
		function loop(acc:Array<Pos>, relations:Array<{r:Relation, p:Pos}>):Array<Pos> {
			for (rel in relations) switch rel.r {
				case Implemented | Overridden | Extended:
					acc.unshift(rel.p);
				case _:
			}
			return acc;
		}
		var usages = core.Timer.time(com.timerCtx, ["display", "implementations", "filter"], function(_:Null<Bool>) {
			var usages = symbols.fold(function(p, sym, acc:Array<Pos>) {
				var l = relations.findOpt(p);
				return l == null ? acc : loop(acc, l);
			}, []);
			haxe.ds.ArraySort.sort(usages, comparePos);
			return usages;
		}, null);
		ReferencePosition.reset();
		DisplayException.sendPositionsRaise(com, usages);
	}

	public static function findImplementations(com:CommonContext):Void {
		var r = ReferencePosition.get();
		if (!Statistics.posEq(r.pos, Globals.nullPos)) findImplementations_(com, r.name, r.pos, r.kind)
		else DisplayException.sendPositionsRaise(com, []);
	}
}
