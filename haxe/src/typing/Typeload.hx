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

package typing;

import core.WithType as WithTypeTools;
import core.WithType.WithTypeValue;
import core.MetaList.StrictMeta as MetaTag;
import core.Globals.Pos;
import core.display.DisplayPosition;
import core.Ast;
import core.Ast.*;
import core.TType;
import core.TType.*;
import core.TFunctions.*;
import core.TOther.*;
import core.TOther;
import core.TPrinting.*;
import core.Globals;
import core.Meta;
import core.WithType;
import core.Error.*;
import core.Error;
import context.Typecore.*;
import context.Typecore;
import context.TyperPass;
import context.Typecore.TyperManager;
import context.Common;
import context.Common.*;
import core.TUnification;
import core.TUnification.*;
import core.Message.WarningCode;
import core.Globals.*;
import core.DisplayTypes;
import core.ds.AtomicLazy;
import core.ds.PMap;
import core.ds.NotFound;
import syntax.Parser;
import context.display.ImportHandling;
import core.display.CompletionItem.ToplevelKind;
import core.display.CompletionItem.CompletionModuleKind;
import core.display.CompletionItem.TKind;
import core.DisplayTypes.CompletionResultKindValue;
import core.DisplayTypes.DisplayExceptionKind;
import core.display.CompletionItem.ClassFieldOrigin;

using Lambda;
using core.ds.ArrayTools;
using core.ds.VectorTools;

import core.Define;
import core.ds.VectorTools.vector;
import haxe.ds.Vector;

// Type instance and type parameter handling.
enum LoadInstanceParamMode {
	ParamNormal;
	ParamSpawnMonos;
	ParamCustom(f:BuildInfo->Null<TParams>->TParams);
}

enum LoadInstanceMode {
	LoadNormal;
	LoadReturn;
	LoadAny; // We don't necessarily know why we're loading, so let's just load anything
}

class Typeload {
	public static var typeFunctionParamsRef:Typer->Func->TypeParamHost->String->TypeParams = function(_:Typer, _:Func, _:TypeParamHost,
			_:String):TypeParams {
		throw "Uninitialized typeFunctionParamsRef";
	};

	public static function checkFieldAccess(ctx:Typer, cff:ClassField):Null<PlacedAccess> {
		var displayed:Null<PlacedAccess> = null,
			acc:Array<PlacedAccess> = [],
			p0 = core.ds.Record.copy(cff.cffPos);
		p0.pmax = p0.pmin;
		inline function checkDisplay(p1:Pos):Void {
			var pmid = core.ds.Record.copy(p0);
			pmid.pmin = p0.pmax;
			pmid.pmax = p1.pmin;
			if (DisplayPosition.displayPosition.enclosedIn(pmid) && acc.length > 0) displayed = acc[0];
		}
		for (entry in cff.cffAccess) {
			var access = entry.access, p1 = entry.pos;
			checkDisplay(p1);
			var prior:Null<PlacedAccess> = null;
			for (a in acc) if (a.access == access) {
				prior = a;
				break;
			}
			if (prior != null) {
				if (p1 != Globals.nullPos && prior.pos != Globals.nullPos) displayErrorExt(ctx.com,
					makeError(Custom("Duplicate access modifier " + Ast.sAccess(access)), p1,
						[makeError(Custom(complMsg("Previously defined here")), prior.pos)]));
				p0 = p1;
				continue;
			}
			switch access {
				case APublic | APrivate:
					for (a in acc) if (a.access == APublic || a.access == APrivate) {
						prior = a;
						break;
					}
					if (prior != null) displayErrorExt(ctx.com,
						makeError(Custom("Conflicting access modifier " + Ast.sAccess(access)), p1,
							[makeError(Custom(complMsg("Conflicts with this")), prior.pos)]));
					else acc.unshift(entry);
				case _:
					acc.unshift(entry);
			}
			p0 = p1;
		}
		// This is a bit dodgy. Ideally we would use the position of the `function` keyword, but we don't have that...
		// Using the name means this is going to complete within the `function` keyword too. Not sure what we
		// can do about it.
		checkDisplay(cff.cffName.pos);
		return displayed;
	}

	public static function findTypeInModule(m:ModuleDef, name:String):ModuleType {
		for (mt in m.mTypes) if (!tPrivate(mt) && tPath(mt).name == name) return mt;
		throw NotFound.raise();
	}

	// raises Type_not_found
	public static function findTypeInModuleRaise(ctx:Typer, m:ModuleDef, name:String, p:Pos):ModuleType {
		for (mt in m.mTypes) {
			if (tPath(mt).name == name) {
				if (ctx.m.curmod != tModule(mt) && tPrivate(mt)) raiseTypingErrorExt(makeError(TypeNotFound(m.mPath, name, PrivateType),
					p));
				return mt;
			}
		}
		return raiseTypingErrorExt(makeError(TypeNotFound(m.mPath, name, NotDefined), p));
	}

	/** since load_type_def and load_instance are used in PASS2, they should not access the structure of a type **/
	public static function findTypeInCurrentModuleContext(ctx:Typer, pack:Array<String>, name:String):ModuleType {
		if (pack.length == 0) {
			// Check the types in our own module
			for (mt in ctx.m.curmod.mTypes) if (tName(mt) == name) return mt;
			var found = ctx.m.importResolution.findTypeImport(name);
			ImportHandling.markImportPosition(ctx, found.pos);
			return found.type;
		}
		for (mt in ctx.m.curmod.mTypes) if (Common.samePath(tPath(mt), {pack: pack, name: name})) return mt;
		throw NotFound.raise();
	}

	public static function findInWildcardImports<R>(ctx:Typer, mname:String, p:Pos, f:ModuleDef->R):R {
		for (entry in ctx.m.importResolution.extractWildcardPackages()) try {
			var path:core.Globals.GlobalTypePath = {pack: entry.pack, name: mname}, m:ModuleDef;
			try m = ctx.g.doLoadModule(ctx, path, p)
			catch (exc:Dynamic) {
				switch exc {
					case(core.ds.ExceptionTools.typing(_) => Some({errMessage: ModuleNotFound(mpath)})) if (Common.samePath(mpath, path)):
						throw NotFound.raise();
					case _:
						throw exc;
				}
			}
			var result = f(m);
			ImportHandling.markImportPosition(ctx, entry.pos);
			return result;
		} catch (exc:Dynamic) {
			if (!Std.isOfType(exc, NotFound)) throw exc;
		}
		throw NotFound.raise();
	}

	public static function findInModulesStartingFromCurrentPackage<R>(ctx:Typer, mname:String, p:Pos, f:ModuleDef->R):R {
		var pack:Array<String> = ctx.m.curmod.mPath.pack.copy(),
			m:ModuleDef = null;
		while (true) {
			var path:core.Globals.GlobalTypePath = {pack: pack, name: mname};
			try {
				m = ctx.g.doLoadModule(ctx, path, p);
				break;
			} catch (exc:Dynamic) {
				switch exc {
					case(core.ds.ExceptionTools.typing(_) => Some({errMessage: ModuleNotFound(mpath)})) if (Common.samePath(mpath, path)):
						if (pack.length == 0) throw NotFound.raise();
						pack = pack.slice(0, pack.length - 1);
					case _:
						throw exc;
				}
			}
		}
		return f(m);
	}

	public static function findInUnqualifiedModules<R>(ctx:Typer, name:String, p:Pos, f:ModuleDef->R):R {
		try return findInWildcardImports(ctx, name, p, f)
		catch (exc:Dynamic) {
			if (!Std.isOfType(exc, NotFound)) throw exc;
			return findInModulesStartingFromCurrentPackage(ctx, name, p, f);
		}
	}

	public static function loadUnqualifiedTypeDef(ctx:Typer, mname:String, tname:String, p:Pos):ModuleType {
		try return findInUnqualifiedModules(ctx, mname, p, m -> findTypeInModuleRaise(ctx, m, tname, p))
		catch (exc:Dynamic) {
			if (!Std.isOfType(exc, NotFound)) throw exc;
			return raiseErrorMsg(ModuleNotFound({pack: [], name: mname}), p);
		}
	}

	public static function loadModule(ctx:Typer, path:GlobalTypePath, p:Pos):ModuleDef {
		try return ctx.g.doLoadModule(ctx, path, p)
		catch (exc:Dynamic) {
			switch exc {
				case(core.ds.ExceptionTools.typing(_) => Some({errMessage: ModuleNotFound(mpath)}))
					if (Common.samePath(mpath, path) && path.pack.length > 0 && path.pack[0] == "std"):
					return ctx.g.doLoadModule(ctx, {pack: path.pack.slice(1), name: path.name}, p);
				case _:
					throw exc;
			}
		}
	}

	public static function loadQualifiedTypeDef(ctx:Typer, pack:Array<String>, mname:String, tname:String,
			p:Pos):ModuleType return findTypeInModuleRaise(ctx, loadModule(ctx, {
			pack: pack,
			name: mname
		}, p), tname, p);

	public static function loadTypeDefPrime(ctx:Typer, pack:Array<String>, mname:String, tname:String,
			p:Pos):ModuleType return pack.length == 0 ? loadUnqualifiedTypeDef(ctx, mname, tname,
			p) : loadQualifiedTypeDef(ctx, pack, mname, tname, p);

	/*
		load a type or a subtype definition
	*/
	public static function loadTypeDef(ctx:Typer, p:Pos, t:TypePath):ModuleType {
		// port: `t = Parser.magic_type_path` is OCaml structural equality ({[]; ""; []; None})
		if (t.tpackage.length == 0
			&& t.tname == ""
			&& (t.tparams == null || t.tparams.length == 0)
			&& t.tsub == null) context.display.DisplayException.raiseFields(context.display.DisplayToplevel.collect(ctx, TKType, NoValue,
				true), CRTypeHint,
				core.DisplayTypes.DisplayTypes.makeSubject(null, p));
		// The type name is the module name or the module sub-type name
		var name = t.tsub == null ? t.tname : t.tsub;
		try {
			// If there's a sub-type, there's no reason to look in our module or its imports
			if (t.tsub != null) throw NotFound.raise();
			return findTypeInCurrentModuleContext(ctx, t.tpackage, name);
		} catch (exc:Dynamic) {
			if (!Std.isOfType(exc, NotFound)) throw exc;
			return loadTypeDefPrime(ctx, t.tpackage, t.tname, name, p);
		}
	}

	public static function generateArgsMeta(com:CommonContext, cls:Null<TClass>, addMeta:MetadataEntry->Void, args:Vector<FuncArg>):Void {
		var values:Array<ObjectField> = [];
		for (arg in args) if (arg.expr != null) values.unshift({
			key: {name: arg.name.name, pos: arg.name.pos, quote: NoQuotes},
			expr: arg.expr
		});
		if (values.length > 0) addMeta({
			meta: MetaTag.Value,
			exprs: vector({expr: EObjectDecl(haxe.ds.Vector.fromArrayCopy(values)), pos: Globals.nullPos}),
			pos: Globals.nullPos
		});
		if (args.exists(arg -> arg.meta.length > 0)) addMeta({
			meta: MetaTag.HaxeArguments,
			exprs: vector(
				{
					expr: EFunction(FKAnonymous, {
						fParams: vector(),
						fArgs: args,
						fType: null,
						fExpr: null
					}),
					pos: Globals.nullPos
				}
			),
			pos: Globals.nullPos
		});
	}

	public static function isRedefined(ctx:Typer, cf1:TClassField, fields:TypeMap<TClassField>, p:Pos):Bool {
		if (!fields.exists(cf1.cfName)) return false;
		var cf2 = fields.get(cf1.cfName), pc = printContext();
		if (!typeIseq(cf1.cfType,
			cf2.cfType)) raiseTypingErrorExt(makeError(Custom("Cannot redefine field " + cf1.cfName + " with different type"), p, [
				makeError(Custom(complMsg("Second type was " + sType(pc, cf2.cfType))), cf2.cfPos),
				makeError(Custom(complMsg("First type was " + sType(pc, cf1.cfType))), cf1.cfPos)
			]));
		return true;
	}

	public static function makeExtensionType(ctx:Typer, tl:Array<{type:T, pos:Pos}>):T {
		var fields:TypeMap<TClassField> = PMap.empty();
		for (pair in tl) switch follow(pair.type) {
			case TAnon(a):
				PMap.iter(function(_:String, cf:TClassField) {
					if (!isRedefined(ctx, cf, fields, pair.pos)) fields = PMap.add(cf.cfName, cf, fields);
				}, a.aFields);
			case _:
				displayError(ctx.com, "Can only extend structures", pair.pos);
				fields = PMap.empty();
		}
		return mkAnon(Extend(tl.mapToVector(pair -> pair.type)), fields);
	}

	public static function checkParamConstraints(ctx:Typer, t:T, map:T->T, ttp:TypedTypeParam, p:Pos):Void {
		for (ti in getConstraints(ttp)) {
			var mapped = map(ti);
			try unifyRaise(t, mapped, p)
			catch (exc:Dynamic) {
				switch exc {
					case(core.ds.ExceptionTools.typing(_) => Some(err)):
						switch err.errMessage {
							case Unify(l):
								inline function fail():Void {
									if (!ctx.f.isUntyped) {
										var copy = core.ds.Record.copy(err);
										copy.errMessage = Unify([ConstraintFailure(Globals.sTypePath(ttp.ttpClass.clPath))].concat(l));
										displayErrorExt(ctx.com, copy);
									}
								}
								switch follow(t) {
									case TInst({clKind: KExpr(e)}, _):
										var local = TyperManager.cloneForTypeParameterExpression(ctx),
											e = typeExpr(local, e, WithTypeTools.withType(mapped));
										try unifyRaise(e.etype, mapped, p) catch (exc:Dynamic) {
											switch exc {
												case(core.ds.ExceptionTools.typing(_) => Some({errMessage: Unify(_)})): fail();
												case _: throw exc;
											}
										}
									case _: fail();
								}
							case _: throw exc;
						}
					case _:
						throw exc;
				}
			}
		}
	}

	public static function maybeBuildInstance(ctx:Typer, t0:T, getParams:LoadInstanceParamMode, p:Pos):T {
		function loop(t:T):T return switch t {
			case TInst(c, tl) if (c.clKind == KGeneric):
				var info = ctx.g.getBuildInfo(ctx, TClassDecl(c), p);
				var params = switch getParams {
					case ParamNormal | ParamSpawnMonos: tl;
					case ParamCustom(f): f(info, tl);
				};
				maybeBuildInstance(ctx, info.buildApply(params), getParams, p);
			case TType(td, tl): loop(applyTypedef(td, tl));
			case TMono(m) if (m.tmType != null): loop(m.tmType);
			case _: t0;
		};
		return loop(t0);
	}

	public static function loadParams(ctx:Typer, info:BuildInfo, params:Vector<TypeParamOrConst>, p:Pos):TParams {
		var rest = info.buildKind == BuildGenericBuild && info.buildParams.length == 1 && info.buildParams[0].ttpName == "Rest",
			javaRest = ctx.com.platform == Jvm && info.buildExtern;
		rest = rest || javaRest;
		function loadParam(param:TypeParamOrConst, ttp:Null<TypedTypeParam>):{type:T, pos:Pos}
			return switch param {
				case TPExpr(e):
					var name = switch e.expr {
						case EConst(String(s, _)): "S" + s;
						case EConst(Int(value, suffix)): "I" + Ast.sConstant(Int(value, suffix));
						case EConst(Float(value, suffix)): "F" + Ast.sConstant(Float(value, suffix));
						case EDisplay(_):
							typeExpr(ctx, e, WithTypeTools.value);
							"Expr";
						case _: "Expr";
					};
					var c = mkClass(ctx.m.curmod, {pack: [], name: name}, p, e.pos);
					c.clKind = KExpr(e);
					{type: TInst(c, vector()), pos: e.pos};
				case TPType({type: CTPath({path: {tpackage: ["$"], tname: "_hx_default"}}), pos: p}):
					if (ttp != null && ttp.ttpDefault != null) {type: ttp.ttpDefault, pos: p}; else if (ttp != null)
						raiseTypingError("Invalid default, type parameter "
						+ ttp.ttpName + " has no default value",
						p); else if (rest) raiseTypingError("Cannot use default with rest type parameters",
						p); else raiseTypingError("Too many type parameters for " + Globals.sTypePath(info.buildPath), p);
				case TPType(t): {type: loadComplexType(ctx, true, LoadNormal, t), pos: t.pos};
			};
		var checks = [];
		// port: the given and expected parameters walked from ii and ei on (upstream: their tails), the
		// types collected in order (upstream: `t :: loop ...`) and made a Vector once at the end
		var inputs = params, expected = info.buildParams, acc:Array<T> = [];
		function loop(ii:Int, ei:Int, isRest:Bool):Void {
			while (true) {
				if (ii < inputs.length && ei < expected.length) {
					var ttp = expected[ei],
						name = ttp.ttpName,
						loaded = loadParam(inputs[ii], ttp),
						t = loaded.type;
					var expression = switch t {
						case TInst({clKind: KExpr(_)}, _): true;
						case _: false;
					}, expects = name == "Const" || Meta.has(MetaTag.Const, ttp.ttpClass.clMeta), accepts = name == "Rest";
					if (expression) {
						if (!expects && !accepts) raiseTypingError("Constant value unexpected here", p);
					} else if (expects) raiseTypingError("Type parameter is expected to be a constant value", p);
					isRest = isRest || (name == "Rest" && info.buildKind == BuildGenericBuild);
					var generic = switch info.buildKind {
						case BuildGeneric(_): true;
						case _: false;
					};
					if (ttp.ttpConstraints != null || generic) checks.push({type: t, param: ttp, pos: loaded.pos});
					acc.push(t);
					ii++;
					ei++;
					continue;
				}
				if (ii == inputs.length && ei == expected.length) return;
				if (ii == inputs.length) {
					if (expected.length - ei == 1 && expected[ei].ttpName == "Rest" && info.buildKind == BuildGenericBuild) return;
					var ttp = expected[ei], t:T;
					if (javaRest) t = tDynamic;
					else if (ttp.ttpDefault != null) t = ttp.ttpDefault;
					else if (ignoreError(ctx.com)) t = ttp.ttpType;
					else t = raiseTypingError("Not enough type parameters for " + Globals.sTypePath(info.buildPath), p);
					acc.push(t);
					ei++;
					continue;
				}
				var loaded = loadParam(inputs[ii], null);
				if (isRest) {
					acc.push(loaded.type);
					ii++;
					ei = expected.length;
					continue;
				}
				if (ignoreError(ctx.com)) return;
				raiseTypingError("Too many type parameters for " + Globals.sTypePath(info.buildPath), loaded.pos);
				return;
			}
		}
		loop(0, 0, false);
		var result:TParams = VectorTools.ofArray(acc);
		if (!rest) {
			function map(t:T):T return maybeBuildInstance(ctx, applyParams(info.buildParams, result, t), ParamNormal, p);
			delay(ctx.g, PCheckConstraint, function() {
				for (check in checks) checkParamConstraints(ctx, check.type, map, check.param, check.pos);
			});
		}
		return result;
	}

	// build an instance from a full type
	public static function loadInstancePrime(ctx:Typer, ptp:PlacedTypePath, getParams:LoadInstanceParamMode, mode:LoadInstanceMode):T {
		var t = ptp.path;
		try {
			if (t.tpackage.length != 0 || t.tsub != null) throw NotFound.raise();
			var pt = lookupParam(t.tname, ctx.typeParams);
			if (t.tparams.length != 0) raiseTypingError("Class type parameter " + t.tname + " can't have parameters", ptp.posFull);
			return pt;
		} catch (exc:Dynamic) {
			if (!Std.isOfType(exc, NotFound)) throw exc;
		}
		var mt = loadTypeDef(ctx, ptp.posPath, t),
			info = ctx.g.getBuildInfo(ctx, mt, ptp.posFull);
		if (info.buildPath.pack.length == 0 && info.buildPath.name == "Dynamic") return switch t.tparams {
			case []: tDynamic;
			case [TPType(t)]: TDynamic(loadComplexType(ctx, true, LoadNormal, t));
			case _: raiseTypingError("Too many parameters for Dynamic", ptp.posFull);
		};
		if (info.buildParams.length == 0) {
			if (t.tparams.length > 0) {
				var pos = switch t.tparams[0] {
					case TPType(t): t.pos;
					case TPExpr(e): e.pos;
				};
				displayError(ctx.com, "Too many type parameters for " + Globals.sTypePath(info.buildPath), pos);
			}
			return info.buildApply(vector());
		}
		// TODO: this is currently duplicated, but it seems suspcious anyway...
		var rest = info.buildKind == BuildGenericBuild && info.buildParams.length == 1 && info.buildParams[0].ttpName == "Rest";
		var tl = if (t.tparams.length == 0 && !rest) switch getParams {
			case ParamNormal: loadParams(ctx, info, t.tparams, ptp.posFull);
			case ParamSpawnMonos: Monomorph.spawnConstrainedMonos(t -> t, info.buildParams);
			case ParamCustom(f): f(info, null);
		} else loadParams(ctx, info, t.tparams, ptp.posFull);
		return maybeBuildInstance(ctx, info.buildApply(tl), getParams, ptp.posFull);
	}

	public static function loadInstance(ctx:Typer, ptp:PlacedTypePath, getParams:LoadInstanceParamMode, mode:LoadInstanceMode,
			allowDisplay:Bool = false):T {
		try {
			var t = loadInstancePrime(ctx, ptp, getParams, mode);
			if (allowDisplay) context.display.DisplayEmitter.checkDisplayType(ctx, t, ptp);
			return t;
		} catch (exc:Dynamic) {
			switch exc {
				case(core.ds.ExceptionTools.typing(_) => Some({errMessage: ModuleNotFound(path)}))
					if (ctx.e.macroDepth <= 0
						&& ctx.com.display.dmsKind == DMDefault
						&& DisplayPosition.displayPosition.enclosedIn(ptp.posPath)):
					var s = Globals.sTypePath(path);
					return context.display.DisplayToplevel.collectAndRaise(ctx, TKType, NoValue, CRTypeHint, s, ptp.posFull, ptp.posPath);
				case _:
					throw exc;
			}
		}
	}

	static function structCompletion<R>(e:Dynamic, intersection:Bool):R {
		if (Std.isOfType(e, context.display.DisplayException)) switch (e : context.display.DisplayException).kind {
			case DisplayFields(r) if (r.fkind.match(CRTypeHint)):
				var l = r.fitems.filter(item -> switch item.ciKind {
					case ITType({kind: Struct}, _): true;
					case _: false;
				});
				return context.display.DisplayException.raiseFields(l, CRStructExtension(intersection), r.fsubject);
			case _:
		}
		throw e;
	}

	/*
		build an instance from a complex type
	*/
	public static function loadComplexTypePrime(ctx:Typer, allowDisplay:Bool, mode:LoadInstanceMode, hint:TypeHint):T {
		var p = hint.pos;
		return switch hint.type {
			case CTParent(t): loadComplexType(ctx, allowDisplay, mode, t);
			case CTPath({path: {tpackage: ["$"], tname: "_hx_mono"}}): spawnMonomorph(ctx, p);
			case CTPath({path: {tpackage: ["$"], tname: "_hx_default"}}): raiseTypingError("Invalid type : default", p);
			case CTPath(ptp): loadInstance(ctx, ptp, ParamNormal, mode, allowDisplay);
			case CTOptional(_): raiseTypingError("Optional type not allowed here", p);
			case CTNamed(_): raiseTypingError("Named type not allowed here", p);
			case CTIntersection(tl):
				var loaded:Array<{type:T, pos:Pos}> = tl.mapToArray(function(t) {
					try return {
						type: loadComplexType(ctx, allowDisplay, LoadNormal, t),
						pos: t.pos
					} catch (e:Dynamic) return structCompletion(e, true);
				});
				var tr = Monomorph.create(), t = TMono(tr), r = makeLazy(ctx.g, t, function() {
					var ta = makeExtensionType(ctx, loaded);
					Monomorph.bind(tr, ta);
					return ta;
				}, "constraint");
				TLazy(r);
			case CTExtend(tl, fields):
				var ta = loadComplexType(ctx, allowDisplay, LoadNormal, {type: CTAnonymous(fields), pos: p});
				var a = switch ta {
					case TAnon(a): a;
					case _: throw "Invalid anonymous extension";
				};
				function extension(pair:{type:T, pos:Pos}):T return switch follow(pair.type) {
					case TInst({clKind: KTypeParameter(_)}, _): raiseTypingError("Cannot structurally extend type parameters", pair.pos);
					case TMono(_): raiseTypingError("Loop found in cascading signatures definitions. Please change order/import", pair.pos);
					case TAnon(a2):
						PMap.iter(function(_:String, cf:TClassField) {
							isRedefined(ctx, cf, a2.aFields, pair.pos);
						}, a.aFields);
						var fields = a2.aFields;
						PMap.iter(function(name:String, cf:TClassField) {
							fields = PMap.add(name, cf, fields);
						}, a.aFields);
						mkAnon(Extend(vector(pair.type)), fields);
					case _: raiseTypingError("Can only extend structures", pair.pos);
				};
				inline function merge(pair:{type:T, pos:Pos}):Void switch follow(pair.type) {
					case TAnon(a2):
						PMap.iter(function(name:String, cf:TClassField) {
							if (!isRedefined(ctx, cf, a.aFields, pair.pos)) a.aFields = PMap.add(name, cf, a.aFields);
						}, a2.aFields);
					case _:
						raiseTypingError("Can only extend structures", pair.pos);
				}
				var instances:Array<{type:T, pos:Pos}> = tl.mapToArray(function(ptp) {
					try return {
						type: loadInstance(ctx, ptp, ParamNormal, LoadNormal, allowDisplay),
						pos: ptp.posFull
					} catch (e:Dynamic) return structCompletion(e, false);
				});
				var tr = Monomorph.create(), t = TMono(tr), r = makeLazy(ctx.g, t, function() {
					var result:T;
					if (instances.length == 1) result = extension(instances[0]);
					else {
						for (instance in instances) merge(instance);
						a.aStatus = Extend(instances.mapToVector(pair -> pair.type));
						result = ta;
					}
					Monomorph.bind(tr, result);
					return t;
				}, "constraint");
				TLazy(r);
			case CTAnonymous(list):
				var displayed:Null<TClassField> = null,
					fields:TypeMap<TClassField> = PMap.empty();
				for (f in list) {
					var name = f.cffName.name, pf = f.cffName.pos, p = f.cffPos;
					if (fields.exists(name)) raiseTypingError("Duplicate field declaration : " + name, pf);
					inline function optionalType(mode:LoadInstanceMode, t:Null<TypeHint>):T {
						if (t == null) return raiseTypingError("Explicit type required for field " + name, p);
						return loadComplexType(ctx, allowDisplay, mode, t);
					}
					if (name == "new") warning(ctx, WDeprecated,
						"Structures with new are deprecated, use haxe.Constraints.Constructible instead", p);
					inline function noExpr(e:Null<Expr>):Void {
						if (e != null) raiseTypingError("Expression not allowed here", e.pos);
					}
					var pub = true, dyn = false, params:TypeParams = vector(), isFinal = false;
					checkFieldAccess(ctx, f); // TODO: do we want to do anything with this?
					for (access in f.cffAccess) switch access.access {
						case APublic:
						case APrivate:
							if (haxe.io.Path.withoutDirectory(access.pos.pfile) != "NativeIterable.hx") // Terrible workaround for #7436
								warning(ctx, WDeprecated,
								"private structure fields are deprecated", access.pos);
							pub = false;
						case ADynamic if (switch f.cffKind {
								case FFun(_): true;
								case _: false;
							}): dyn = true;
						case AFinal: isFinal = true;
						case a: raiseTypingError("Invalid access " + Ast.sAccess(a), p);
					}
					var t:T, kind:FieldKind;
					switch f.cffKind {
						case FVar(type, e) if (isFinal):
							noExpr(e);
							if (type == null) raiseTypingError("Type required for structure property", p);
							t = loadComplexType(ctx, allowDisplay, LoadNormal, type);
							kind = Var({vRead: AccNormal, vWrite: AccNever});
						case FVar({type: CTPath({path: {tpackage: [], tname: "Void"}})}, _) |
							FProp(_, _, {type: CTPath({path: {tpackage: [], tname: "Void"}})}, _):
							t = raiseTypingError("Fields of type Void are not allowed in structures", p);
							kind = Var({vRead: AccNormal, vWrite: AccNormal});
						case FVar(type, e):
							noExpr(e);
							t = optionalType(LoadNormal, type);
							kind = Var({vRead: AccNormal, vWrite: AccNormal});
						case FFun(fd):
							params = typeFunctionParamsRef(ctx, fd, TPHAnonField, name);
							noExpr(fd.fExpr);
							var old = ctx.typeParams;
							ctx.typeParams = params.concat(old);
							var args = fd.fArgs.map(function(arg) {
								noExpr(arg.expr);
								return {name: arg.name.name, optional: arg.optional, type: optionalType(LoadNormal, arg.type)};
							});
							var ret = optionalType(LoadReturn, fd.fType);
							t = Meta.has(MetaTag.Coroutine,
								f.cffMeta) ? ctx.t.tcoro.tcoro.force()({args: args, ret: ret}) : TFun({args: args, ret: ret});
							ctx.typeParams = old;
							kind = Method(dyn ? MethDynamic : MethNormal);
						case FProp(i1, i2, type, e):
							noExpr(e);
							function property(part:PlacedName, get:Bool):VarAccess return switch part.name {
								case "null": AccNo;
								case "never": AccNever;
								case "default": AccNormal;
								case "dynamic": AccCall;
								case "get" if (get): AccCall;
								case "set" if (!get): AccCall;
								case "private get" if (get): AccPrivateCall;
								case "private set" if (!get): AccPrivateCall;
								case x if ((get && x == "get_" + name) || (!get && x == "set_" + name)): AccCall;
								case _: raiseTypingError("Custom property access is no longer supported in Haxe 3", f.cffPos);
							};
							if (type == null) raiseTypingError("Type required for structure property", p);
							t = loadComplexType(ctx, allowDisplay, LoadNormal, type);
							kind = Var({vRead: property(i1, true), vWrite: property(i2, false)});
					}
					if (Meta.has(MetaTag.Optional, f.cffMeta)) t = ctx.t.tnull(t);
					var cf = mkField(name, t, p, f.cffName.pos, pub);
					cf.cfKind = kind;
					cf.cfParams = params;
					cf.cfDoc = f.cffDoc;
					cf.cfMeta = f.cffMeta.copy();
					if (isFinal) addClassFieldFlag(cf, CfFinal);
					initMetaOverloads(ctx, null, cf);
					if (ctx.m.isDisplayFile) {
						context.display.DisplayEmitter.checkDisplayMetadata(ctx, cf.cfMeta);
						if (DisplayPosition.displayPosition.enclosedIn(cf.cfNamePos)) displayed = cf;
					}
					fields = PMap.add(name, cf, fields);
				}
				var a = ({aFields: fields, aStatus: Closed} : core.TType.TAnon);
				if (displayed != null) {
					var cf = displayed;
					delay(ctx.g, PBuildClass,
						function() context.display.DisplayEmitter.displayField(ctx, AnonymousStructure(a), CFSMember, cf, cf.cfNamePos));
				}
				TAnon(a);
			case CTFunction(args, ret):
				var voidArg = args.length == 1 && switch args[0].type {
					case CTPath({path: {tpackage: [], tparams: [], tname: "Void"}}): true;
					case _: false;
				};
				if (voidArg) TFun({args: vector(), ret: loadComplexType(ctx, allowDisplay, LoadReturn, ret)}); else {
					var typed = args.map(function(t) {
						var opt = false, name = "";
						switch t.type {
							case CTOptional(inner) | CTParent({type: CTOptional(inner)}):
								t = inner;
								opt = true;
							case _:
						}
						switch t.type {
							case CTNamed(n, inner):
								name = n.name;
								t = inner;
							case _:
						}
						return {name: name, optional: opt, type: loadComplexType(ctx, allowDisplay, LoadNormal, t)};
					});
					TFun({args: typed, ret: loadComplexType(ctx, allowDisplay, LoadReturn, ret)});
				}
		};
	}

	public static function loadComplexType(ctx:Typer, allowDisplay:Bool, mode:LoadInstanceMode, hint:TypeHint):T {
		try return loadComplexTypePrime(ctx, allowDisplay, mode, hint)
		catch (exc:Dynamic) {
			switch exc {
				case(core.ds.ExceptionTools.typing(_) => Some(err)):
					switch err.errMessage {
						case ModuleNotFound(_) | TypeNotFound(_, _, _):
							if (context.display.Diagnostics.errorInDiagnosticsRun(ctx.com, err.errPos)) {
								switch err.errMessage {
									case ModuleNotFound({pack: [], name: name}):
										delay(ctx.g, PForce,
											function() context.display.DisplayToplevel.handleUnresolvedIdentifier(ctx, name, err.errPos, true));
									case _:
										Common.displayErrorExt(ctx.com, err);
								}
								return tDynamic;
							} else if (Common.canRecoverInDisplay(ctx.com)
								&& !(ctx.m.isDisplayFile && DisplayPosition.displayPosition.enclosedIn(err.errPos))) {
								Common.displayErrorExt(ctx.com, err);
								return tDynamic;
							} else
								throw exc;
						case _: throw exc;
					}
				case _:
					throw exc;
			}
		}
	}

	public static function initMetaOverloads(ctx:Typer, co:Null<TClass>, cf:TClassField):Void {
		var overloads:Array<TClassField> = [],
			baseMeta = cf.cfMeta.filter(m -> m.meta != MetaTag.Overload && m.meta != MetaTag.Value),
			kept:Metadata = [];
		for (m in cf.cfMeta) switch m {
			case {meta: MetaTag.Overload, exprs: [{expr: EFunction(kind, f), pos: p}]}:
				switch kind {
					case FKNamed(_): raiseTypingError("Function name must not be part of @:overload", p);
					case _:
				}
				switch f.fExpr {
					case {expr: EBlock([])}:
					case _: raiseTypingError("Overload must only declare an empty method body {}", p);
				}
				switch cf.cfKind {
					case Method(MethInline): raiseTypingError("Cannot @:overload inline function", p);
					case _:
				}
				var old = ctx.typeParams;
				if (cf.cfParams.length > 0) ctx.typeParams = ctx.typeParams.filter(ttp -> ttp.ttpHost != TPHMethod);
				var params = typeFunctionParamsRef(ctx, f, TPHMethod, cf.cfName);
				ctx.typeParams = params.concat(ctx.typeParams);
				inline function optionalType(mode:LoadInstanceMode, t:Null<TypeHint>):T {
					if (t == null) return raiseTypingError("Explicit type required", p);
					return loadComplexType(ctx, true, mode, t);
				}
				var args = f.fArgs.map(function(arg) {
					var t = optionalType(LoadNormal, arg.type);
					if (arg.optional) t = ctx.t.tnull(t);
					return {name: arg.name.name, optional: arg.optional || arg.expr != null, type: t};
				});
				var overloadField = core.ds.Record.copy(cf);
				overloadField.cfType = TFun({args: args, ret: optionalType(LoadReturn, f.fType)});
				overloadField.cfParams = params;
				overloadField.cfMeta = baseMeta.copy();
				generateArgsMeta(ctx.com, co, m -> overloadField.cfMeta.unshift(m), f.fArgs);
				overloads.unshift(overloadField);
				ctx.typeParams = old;
			case {meta: MetaTag.Overload, exprs: []} if (ctx.com.config.pfOverload):
				addClassFieldFlag(cf, CfOverload);
				switch follow(cf.cfType) {
					case TFun({args: args, ret: _}): for (arg in args) switch arg.type {
							case TMono(t) if (t.tmType == null): raiseTypingError("Explicit type required for overload functions\n... For function argument '"
									+ arg.name
									+ "'", cf.cfPos);
							case _:
						}
					case _: // could be a variable
				}
				kept.push(m);
			case {meta: MetaTag.Overload, exprs: [], pos: p}:
				raiseTypingError("This platform does not support this kind of overload declaration. Try @:overload(function()... {}) instead",
					p);
			case {meta: MetaTag.Overload, pos: p}:
				raiseTypingError("Invalid @:overload metadata format", p);
			case _:
				kept.push(m);
		}
		cf.cfMeta = kept;
		overloads.reverse();
		cf.cfOverloads = overloads;
	}

	public static function tIterator(ctx:Typer, p:Pos):{type:T, parameter:T}
		return switch loadQualifiedTypeDef(ctx, [], "StdTypes", "Iterator", p) {
			case TTypeDecl(t):
				addDependency(ctx.m.curmod, t.tModule, MDepFromTyping);
				var pt = spawnMonomorph(ctx, p);
				{type: applyTypedef(t, vector(pt)), parameter: pt};
			case _: throw "Iterator is not a typedef";
		};

	/*
		load either a type t or Null<Unknown> if not defined
	*/
	public static function loadTypeHint(ctx:Typer, pcur:Pos, mode:LoadInstanceMode, t:Null<TypeHint>, opt:Bool = false):T {
		var type = t == null ? spawnMonomorph(ctx, pcur) : loadComplexType(ctx, true, mode, t);
		return opt ? ctx.t.tnull(type) : type;
	}

	// ----------------------------------------------------------------------
	// PASS 1 & 2 : Module and Class Structure
	public static function typeTypeParam(ctx:Typer, host:TypeParamHost, path:GlobalTypePath, tp:TypeParam):TypedTypeParam {
		var name = tp.tpName.name,
			c = mkClass(ctx.m.curmod, {pack: path.pack.concat([path.name]), name: name}, tp.tpName.pos, tp.tpName.pos);
		c.clParams = typeTypeParams(ctx, host, c.clPath, tp.tpParams);
		c.clMeta = tp.tpMeta;
		var ttp = mkTypeParam(c, host, null, null);
		if (ctx.m.isDisplayFile
			&& DisplayPosition.displayPosition.enclosedIn(tp.tpName.pos)) context.display.DisplayEmitter.displayType(ctx, ttp.ttpType,
				tp.tpName.pos);
		return ttp;
	}

	public static function typeTypeParams(ctx:Typer, host:TypeParamHost, path:GlobalTypePath, tpl:Vector<TypeParam>):TypeParams {
		var names:Array<String> = [], pairs = [];
		for (tp in tpl) {
			if (names.contains(tp.tpName.name)) displayError(ctx.com, "Duplicate type parameter name: " + tp.tpName.name, tp.tpName.pos);
			names.unshift(tp.tpName.name);
			pairs.push({syntax: tp, param: typeTypeParam(ctx, host, path, tp)});
		}
		var params = pairs.mapToVector(pair -> pair.param),
			local = TyperManager.cloneForTypeParams(ctx, params.concat(ctx.typeParams));
		for (pair in pairs) {
			var tp = pair.syntax, ttp = pair.param;
			if (tp.tpDefault != null) {
				var ct = tp.tpDefault,
					r = makeLazy(local.g, ttp.ttpType, function() {
						var t = loadComplexType(local, true, LoadNormal, ct);
						switch host {
							case TPHType:
							case TPHConstructor | TPHMethod | TPHEnumConstructor | TPHAnonField | TPHLocal | TPHUnbound:
								displayError(local.com, "Default type parameters are only supported on types", ct.pos);
						}
						checkParamConstraints(local, t, t -> t, ttp, ct.pos);
						return t;
					}, "default");
				ttp.ttpDefault = TLazy(r);
			}
			if (tp.tpConstraints != null) {
				var th = tp.tpConstraints,
					constraints = AtomicLazy.fromFun(function() {
						function load(th:TypeHint):TParams return switch th.type {
							case CTIntersection(tl): tl.map(t -> loadComplexType(local, true, LoadNormal, t));
							case CTParent(ct): load(ct);
							case _: vector(loadComplexType(local, true, LoadNormal, th));
						};
						var constr = load(th);
						// check against direct recursion
						function check(t:T):Void switch follow(t) {
							case TInst(c2, _) if (ttp.ttpClass == c2):
								raiseTypingError("Recursive constraint parameter is not allowed", th.pos);
							case TInst({clKind: KTypeParameter(param)}, _):
								delay(local.g, PConnectField, function() {
									for (t in getConstraints(param)) check(t);
								});
							case _:
						}
						for (t in constr) check(t);
						return constr;
					});
				delay(local.g, PConnectField, function() {
					constraints.force();
				});
				ttp.ttpConstraints = constraints;
			}
		}
		return params;
	}

	public static function loadCoreClass(ctx:Typer, c:TClass):TClass {
		var ctx2 = ctx.g.coreApi;
		if (ctx2 == null) {
			var com2 = Common.clone(ctx.com, ctx.com.isMacroContext);
			enterStage(com2, CInitMacrosDone);
			com2.defines.values = PMap.empty();
			Common.define(com2, Define.CoreApi);
			Common.define(com2, Define.Sys);
			allowPackage(com2, "sys");
			Define.rawDefineValue(com2.defines, "target.threaded", "true"); // hack because we check this in sys.thread classes
			if (ctx.com.isMacroContext) Common.define(com2, Define.Macro);
			com2.classPaths.lockContext(ctx.com.customExt, platformNameMacro(ctx.com), true);
			com2.classPaths.modify(function(cp:core.ClassPath.IClassPath) return switch cp.scope {
				case core.ClassPath.ClassPathScope.Std: [cp.clone()];
				case _: [];
			}, ctx.com.classPaths.asList());
			if (com2.display.dmsCheckCoreApi) {
				var copy = core.ds.Record.copy(com2.display);
				copy.dmsCheckCoreApi = false;
				com2.display = copy;
			}
			context.CommonCache.lockSignature(com2, "load_core_class");
			context.CommonCache.getCache(ctx.com).addChild(context.CommonCache.getCacheSign(com2));
			ctx2 = createContextRef(com2, ctx.g.macros);
			ctx.g.coreApi = ctx2;
		}
		var path = switch c.clKind {
			case KAbstractImpl(a): a.aPath;
			case _: c.clPath;
		};
		var t = loadTypeDefPrime(ctx2, c.clModule.mPath.pack, c.clModule.mPath.name, path.name, Globals.nullPos);
		flushPass(ctx2.g, PFinal, {name: "core_final", path: c.clPath.pack.concat([c.clPath.name])});
		return switch t {
			case TClassDecl(ccore): ccore;
			case TAbstractDecl(a) if (a.aImpl != null): a.aImpl;
			case _: throw "Invalid core class";
		};
	}

	public static function initCoreApi(ctx:Typer, c:TClass):Void {
		var ccore = loadCoreClass(ctx, c),
			cp:TypeParams = ccore.clParams,
			params:TypeParams = c.clParams;
		if (cp.length != params.length) raiseTypingError("Class must have the same number of type parameters as core type", c.clPos);
		for (i in 0...cp.length) {
			var a:TParams = getConstraints(cp[i]),
				b:TParams = getConstraints(params[i]);
			if (a.length != b.length) raiseTypingError("Type parameters must have the same number of constraints as core type", c.clPos);
			try for (j in 0...a.length) typeEq(EqCoreType, b[j], a[j])
			catch (exc:Unify_error) displayErrorExt(ctx.com,
				makeError(Custom("Type parameter " + params[i].ttpName + " has different constraint than in core type"), c.clPos,
					[makeError(Custom(complMsg(errorMsg(Unify(exc.errors)))), c.clPos)]));
		}
		if (c.clDoc == null) c.clDoc = ccore.clDoc;
		inline function compare(f:TClassField, f2:TClassField):Void {
			var p = f2.cfExpr == null ? c.clPos : f2.cfExpr.epos;
			try typeEq(EqCoreType, applyParams(ccore.clParams, extractParamTypes(c.clParams), f.cfType), f2.cfType)
			catch (exc:Unify_error) displayErrorExt(ctx.com,
				makeError(Custom("Field " + f.cfName + " has different type than in core type"), p,
					[makeError(Custom(complMsg(errorMsg(Unify(exc.errors)))), p)]));
			if (hasClassFieldFlag(f2,
				CfPublic) != hasClassFieldFlag(f,
					CfPublic)) raiseTypingError("Field " + f.cfName + " has different visibility than core type", p);
			if (f2.cfDoc == null) f2.cfDoc = f.cfDoc;
			if (!fieldKindEq(f2.cfKind, f.cfKind)) switch [f2.cfKind, f.cfKind] {
				// allow to add 'inline'
				// allow to disable 'inline'
				case [Method(MethInline), Method(MethNormal)] | [Method(MethNormal), Method(MethInline)]:
				case _:
					raiseTypingError("Field " + f.cfName + " has different property access than core type", p);
			}
			switch [followWithCoro(f.cfType), followWithCoro(f2.cfType)] {
				case [Coro(_), NotCoro(_)]:
					raiseTypingError("Method should be coroutine", p);
				case [NotCoro(_), Coro(_)]:
					raiseTypingError("Method should not be coroutine", p);
				case [NotCoro(TFun({args: pl1, ret: _})), NotCoro(TFun({args: pl2, ret: _}))] |
					[Coro({args: pl1, ret: _}), Coro({args: pl2, ret: _})]:
					if (pl1.length != pl2.length) raiseTypingError("Argument count mismatch", p);
					for (i in 0...pl1.length) if (pl1[i].name != pl2[i].name) raiseTypingError("Method parameter name '"
						+ pl2[i].name + "' should be '" + pl1[i].name + "'", p);
				case _:
			}
		}
		inline function checkFields(expected:TypeMap<TClassField>, actual:TypeMap<TClassField>):Void {
			PMap.iter(function(name:String, f:TClassField) {
				if (hasClassFieldFlag(f, CfPublic)) {
					var f2 = actual.get(f.cfName);
					if (f2 == null) raiseTypingError("Missing field " + name + " required by core type", c.clPos);
					compare(f, f2);
				}
			}, expected);
			PMap.iter(function(name:String, f:TClassField) {
				var p = f.cfExpr == null ? c.clPos : f.cfExpr.epos;
				if (hasClassFieldFlag(f, CfPublic) && !Meta.has(MetaTag.Hack, f.cfMeta) && !expected.exists(f.cfName)
					&& !hasClassFieldFlag(f, CfOverride)) raiseTypingError("Public field " + name + " is not part of core type", p);
			}, actual);
		}
		checkFields(ccore.clFields, c.clFields);
		checkFields(ccore.clStatics, c.clStatics);
		var a = ccore.clConstructor, b = c.clConstructor;
		if (a == null && b == null) return;
		if (a != null && !hasClassFieldFlag(a, CfPublic)) return;
		if (a != null && b != null) {
			compare(a, b);
			return;
		}
		if (a == null && b != null && !hasClassFieldFlag(b, CfPublic)) return;
		raiseTypingError("Constructor differs from core type", c.clPos);
	}
}
