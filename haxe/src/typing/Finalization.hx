package typing;

import core.MetaList.StrictMeta as MetaTag;
import core.Globals.Pos;
import core.Globals.GlobalTypePath;
import core.Message.WarningCode;
import core.Texpr;
import core.ds.NotFound;
import context.Common.CommonContext;
import context.Common.ModuleLut;
import core.TType;
import core.Globals;
import core.Globals.*;
import core.TFunctions.*;
import core.TOther.*;
import core.TOther;
import core.TOther.ExtType;
import core.TOther.TClassTools;
import core.TPrinting.*;
import core.Texpr.Builder;
import core.Error.*;
import core.Error;
import core.Meta;
import context.Typecore.*;
import context.Typecore;
import context.Common;
import context.TyperPass;
import typing.TyperBase.*;
import optimization.Dce;

enum FinalizationState {
	Generating;
	Done;
	NotYet;
}

class Finalization {
	// ----------------------------------------------------------------------
	// FINALIZATION

	public static function maybeLoadMain(tctx:Typer):Null<ModuleDef> {
		return tctx.com.main.mainPath == null ? null : Typeload.loadModule(tctx, tctx.com.main.mainPath, nullPos);
	}

	public static function maybeAddEntrypoint(com:CommonContext):Void {
		var main:Null<TExpr> = com.main.mainExpr;
		if (main == null) return;
		var types:Array<ModuleType> = com.types;
		var et:Null<ModuleType> = null;
		for (t in types) {
			var p = tPath(t);
			if (p.pack.join(".") == "haxe" && p.name == "EntryPoint") {
				et = t;
				break;
			}
		}
		if (et == null) return;
		var ec = switch et {
			case TClassDecl(c): c;
			case _: throw "Invalid EntryPoint type";
		};
		var ef = ec.clStatics.get("run");
		if (ef == null) return;
		var typeExpr = Builder.makeTypeexpr(et, nullPos);
		var e = mk(TCall(mk(TField(typeExpr, FStatic(ec, ef)), ef.cfType, nullPos), []), com.basic.tvoid, nullPos);
		com.main.mainExpr = mk(TBlock([main, e]), com.basic.tvoid, main.epos);
	}

	public static function getMain(ctx:Typer, mainModule:Null<ModuleDef>, types:Array<ModuleType>):{expr:Null<TExpr>, path:Null<String>} {
		if (mainModule == null) return {expr: null, path: null};
		var path = mainModule.mPath;
		var p = nullPos;
		var c:TClass = null;
		var f:TClassField = null;
		if (mainModule.mStatics != null) {
			c = mainModule.mStatics;
			p = c.clNamePos;
			f = c.clStatics.get("main");
		}
		if (f == null) {
			try {
				var t = Typeload.findTypeInModuleRaise(ctx, mainModule, path.name, nullPos);
				switch t {
					case TEnumDecl(_) | TTypeDecl(_) | TAbstractDecl(_):
						raiseTypingError("Invalid -main : " + sTypePath(path) + " is not a class", nullPos);
					case TClassDecl(cls):
						c = cls;
						p = c.clNamePos;
						f = c.clStatics.get("main");
				}
				if (f == null) throw NotFound.raise();
			} catch (error:NotFound) {
				raiseTypingError("Invalid -main : " + sTypePath(path) + " does not have static function main", p);
			}
		}
		var ft = fieldType(f);
		var r = switch follow(ft) {
			case TFun(s) if (s.args.length == 0): s.ret;
			case _: raiseTypingError("Invalid -main : " + sTypePath(path) + " has invalid main function", c.clPos);
		};
		if (!ExtType.isVoid(follow(r))) raiseTypingError("Return type of main function should be Void (found "
			+ sType(printContext(), r)
			+ ")", f.cfNamePos);
		if (!Meta.has(MetaTag.Keep, f.cfMeta)) f.cfMeta.unshift(Dce.mkKeepMeta(f.cfPos));
		var emain = typeModuleType(ctx, TClassDecl(c), nullPos);
		return {
			expr: mk(TCall(mk(TField(emain, FStatic(c, f)), ft, nullPos), []), r, nullPos),
			path: core.Path.UniqueKey.lazyPath(mainModule.mExtra.mFile)
		};
	}

	public static function finalize(ctx:Typer):Void {
		flushPass(ctx.g, PFinal, {name: "final", args: []});
		var callbacks:Array<Array<ModuleType>->Void> = ctx.com.callbacks.getAfterTyping();
		if (callbacks.length == 0) return;
		var handledTypes:Array<ModuleType> = [];
		while (true) {
			var allTypes:Array<ModuleType> = ctx.com.moduleLut.fold(function(_, m:ModuleDef,
					acc:Array<ModuleType>) return m.mTypes.concat(acc), []);
			var newTypes = allTypes.filter(function(mt) {
				// port: OCaml List.memq uses physical identity, including the variant wrapper.
				for (handled in handledTypes) if (mt == handled) return false;
				return true;
			});
			if (newTypes.length == 0) return;
			for (f in callbacks) f(newTypes);
			flushPass(ctx.g, PFinal, {name: "final", args: []});
			handledTypes = allTypes;
		}
	}

	// port: hxmc's persistent module cache (hxmc/src/hxmc/ModuleCache.hx) gives here, for the fields of a
	// ... module it restored (their expressions as the filters left them), what the walk below saw of them
	// ... when the module was typed (cf null: the class's init); always null in the compiler itself.
	public static var sortExprHook:Null<(c:TClass, cf:Null<TClassField>, e:TExpr) -> TExpr> = null;

	public static function sortTypes(com:CommonContext, modules:ModuleLut):{types:Array<ModuleType>, modules:Array<ModuleDef>} {
		inline function sortExpr(c:TClass, cf:Null<TClassField>, e:TExpr):TExpr return sortExprHook == null ? e : sortExprHook(c, cf, e);
		var types:Array<ModuleType> = [];
		var states:Map<String, FinalizationState> = [];
		var statics:Map<String, Bool> = [];
		// port: cached path keys (pack#name) rather than joining a fresh string per comparison.
		inline function key(p:GlobalTypePath):String return p.hashKey();
		inline function staticKey(c:TClass, name:String):String return key(c.clPath) + ":" + name;
		var loop:ModuleType->Void = null;
		var walkExpr:GlobalTypePath->TExpr->Void = null;
		inline function loopClass(p:GlobalTypePath, c:TClass):Void {
			if (key(c.clPath) != key(p)) loop(TClassDecl(c));
		}
		inline function loopEnum(p:GlobalTypePath, e:TEnum):Void {
			if (key(e.ePath) != key(p)) loop(TEnumDecl(e));
		}
		inline function loopAbstract(p:GlobalTypePath, a:TAbstract):Void {
			if (key(a.aPath) != key(p)) loop(TAbstractDecl(a));
		}
		inline function walkStaticField(p:GlobalTypePath, c:TClass, cf:TClassField):Void {
			if (cf.cfExpr != null && !statics.exists(staticKey(c, cf.cfName))) {
				statics.set(staticKey(c, cf.cfName), true);
				walkExpr(p, sortExpr(c, cf, cf.cfExpr));
			}
		}
		walkExpr = function(p, e) {
			switch e.eexpr {
				case TTypeExpr(t):
					switch t {
						case TClassDecl(c): loopClass(p, c);
						case TEnumDecl(e): loopEnum(p, e);
						case TAbstractDecl(a): loopAbstract(p, a);
						case TTypeDecl(_): throw "Typedef in static initialization";
					}
				case TNew(c, _, _):
					Texpr.iter(e1 -> walkExpr(p, e1),
						e); // port: not iterWith: a typed closure passed to its generic parameter is wrapped per call
					loopClass(p, c);
					function walkConstructor(c:TClass):Void {
						var k = staticKey(c, "new");
						if (statics.exists(k)) return;
						statics.set(k, true);
						if (c.clConstructor != null && c.clConstructor.cfExpr != null) walkExpr(p, sortExpr(c, c.clConstructor, c.clConstructor.cfExpr));
						if (c.clSuper != null) walkConstructor(c.clSuper.cls);
					}
					walkConstructor(c);
				case TField(e1, FStatic(c, cf)):
					walkExpr(p, e1);
					walkStaticField(p, c, cf);
				case _:
					Texpr.iter(e1 -> walkExpr(p, e1),
						e); // port: not iterWith: a typed closure passed to its generic parameter is wrapped per call
			}
		};
		inline function walkClass(p:GlobalTypePath, c:TClass):Void {
			if (c.clSuper != null) loopClass(p, c.clSuper.cls);
			for (parent in c.clImplements) loopClass(p, parent.cls);
			var init = TClassTools.getClInit(c);
			if (init != null) walkExpr(p, sortExpr(c, null, init));
			// port: upstream PMap.iter is key-ordered, not insertion/hash order.
			var names = [for (name in c.clStatics.keys()) name];
			names.sort(core.ds.Key.compareStrings);
			for (name in names) {
				var f = c.clStatics.get(name);
				if (f.cfExpr != null) switch f.cfExpr.eexpr {
					case TFunction(_):
					case _:
						walkExpr(p, sortExpr(c, f, f.cfExpr));
				}
			}
		}
		loop = function(t) {
			var p = tPath(t), k = key(p);
			var state = states.exists(k) ? states.get(k) : NotYet;
			switch state {
				case Done:
				case Generating:
					Common.moduleWarning(com, tModule(t), WStaticInitOrder, [],
						"Warning : maybe loop in static generation of " + sTypePath(p), tInfos(t).mtPos);
				case NotYet:
					states.set(k, Generating);
					switch t {
						case TClassDecl(c): walkClass(p, c);
						case _:
					}
					states.set(k, Done);
					types.push(t); // port: upstream conses here and reverses the list at the end
			}
		};
		var sortedModules:Array<ModuleDef> = modules.fold(function(_, m, acc:Array<ModuleDef>) {
			acc.unshift(m);
			return acc;
		}, []);
		sortedModules.sort(function(m1, m2) {
			// port: OCaml compares the package list first, then the module name.
			var p1 = m1.mPath.pack, p2 = m2.mPath.pack;
			for (i in 0...Std.int(Math.min(p1.length, p2.length))) {
				var comparison = core.ds.Key.compareStrings(p1[i], p2[i]);
				if (comparison != 0) return comparison;
			}
			return p1.length != p2.length ? p1.length - p2.length : core.ds.Key.compareStrings(m1.mPath.name, m2.mPath.name);
		});
		for (m in sortedModules) for (t in m.mTypes) loop(t);
		return {types: types, modules: sortedModules};
	}

	public static function generate(ctx:Typer,
			mainPath:Null<ModuleDef>):{main:{expr:Null<TExpr>, path:Null<String>}, types:Array<ModuleType>, modules:Array<ModuleDef>} {
		var sorted = sortTypes(ctx.com, ctx.com.moduleLut);
		return {main: getMain(ctx, mainPath, sorted.types), types: sorted.types, modules: sorted.modules};
	}
}
