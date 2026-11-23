package generators;

import core.Globals;
import core.Globals.*;
import core.Ast;
import core.TType;
import core.TFunctions.*;
import core.Message;
import core.Define;
import core.Meta;
import core.ds.NotFound;
import context.Common;

typedef ContextMain = {
	var mainPath:Null<GlobalTypePath>;
	var mainFile:Null<String>;
	var mainExpr:Null<TExpr>;
}

typedef WarningFunction = (w:WarningCode, options:Array<Array<WarningOption>>, msg:String, p:Pos, ?depth:Int) -> Void;
typedef ErrorFunction = String->Pos->Void;

@:structInit class Gctx {
	public final platform:Platform;
	public final defines:DefineContext;
	public final classPaths:core.ClassPaths;
	public final runCommand:String->Int;
	public final runCommandArgs:String->Array<String>->Int;
	public final warning:WarningFunction;
	public final error:ErrorFunction;
	public final io:compiler.io.CompilerIo.CompilerIoData;
	public final basic:BasicTypes;
	public final debug:Bool;
	public final file:String;
	public final version:CompilerVersion;
	public final features:Map<String, Bool>;
	public final modules:Array<ModuleDef>;
	public final main:ContextMain;
	public final types:Array<ModuleType>;
	public final resources:core.ds.OcamlHashtbl<String, haxe.io.Bytes>;
	public final nativeLibs:Array<context.NativeLibraries.NativeLibraryBase>;
	public final includeFiles:Array<context.Common.IncludeFile>;
	public final std:TClass; /* TODO: I would prefer to not have this here, have to check default_cast */
	public final timerCtx:core.Timer.TimerContext;
	public final pool:context.Parallel.ManagedPoolData;

	public static function defined(com:Gctx, s:String):Bool return Define.defined(com.defines, s);

	public static function definedValue(com:Gctx, v:String):String return Define.definedValue(com.defines, v);

	public static function defineValue(com:Gctx, k:String, v:String):Void Define.defineValue(com.defines, k, v);

	public static function definedValueSafe(com:Gctx, v:String, ?def:String):String
		return def != null ? Define.definedValueSafe(com.defines, v, def) : Define.definedValueSafe(com.defines, v);

	public static function rawDefined(gctx:Gctx, v:String):Bool return Define.rawDefined(gctx.defines, v);

	public static function findFile(ctx:Gctx, f:String):String return ctx.classPaths.findFile(f).file;

	public static function addFeature(gctx:Gctx, f:String):Void gctx.features.set(f, true);

	public static function hasDce(gctx:Gctx):Bool {
		try return Define.definedValue(gctx.defines, Define.Dce) != "no"
		catch (_:NotFound) return false;
	}

	public static function isDirectlyUsed(gctx:Gctx, meta:Metadata):Bool return !hasDce(gctx) || Meta.has(Meta.DirectlyUsed, meta);

	public static function hasFeature(gctx:Gctx, f:String):Bool {
		if (gctx.features.exists(f)) return gctx.features.get(f);
		if (gctx.types.length == 0) return !hasDce(gctx);
		var parts = f.split(".");
		parts.reverse();
		return switch parts {
			case []: throw new core.ds.Failure("");
			case [cl]: hasFeature(gctx, cl + ".*");
			case _:
				var field = parts[0], cl = parts[1], pack = parts.slice(2);
				pack.reverse();
				var r = try {
					var path:GlobalTypePath = {pack: pack, name: cl};
					var found:Null<ModuleType> = null;
					for (t in gctx.types) if (Common.samePath(tPath(t), path) && !Meta.has(Meta.RealPath, tInfos(t).mtMeta)) {
						found = t;
						break;
					}
					if (found == null) throw NotFound.raise();
					switch found {
						case t if (field == "*"):
							!hasDce(gctx) || switch t {
								case TClassDecl(c): hasClassFlag(c, CUsed);
								case TAbstractDecl(a): Meta.has(Meta.ValueUsed, a.aMeta);
								case TEnumDecl(e): hasEnumFlag(e, EnUsed);
								case _: Meta.has(Meta.Used, tInfos(t).mtMeta);
							};
						case TClassDecl(c) if (hasClassFlag(c, CExtern) && (gctx.platform != Js || cl != "Array" && cl != "Math")):
							!hasDce(gctx) || {
								var cf = c.clStatics.get(field);
								if (cf == null) cf = c.clFields.get(field);
								if (cf == null) throw NotFound.raise();
								hasClassFieldFlag(cf, CfUsed);
							};
						case TClassDecl(c):
							c.clStatics.exists(field) || c.clFields.exists(field);
						case _:
							false;
					}
				} catch (_:NotFound) false;
				gctx.features.set(f, r);
				r;
		}
	}

	public static function getEntryPoint(gctx:Gctx):Null<{name:String, cls:TClass, expr:TExpr}> {
		var path = gctx.main.mainPath;
		if (path == null) return null;
		var m:ModuleDef = null;
		for (candidate in gctx.modules) if (Common.samePath(candidate.mPath, path)) {
			m = candidate;
			break;
		}
		if (m == null) throw NotFound.raise();
		var c = m.mStatics;
		if (c == null || !c.clStatics.exists("main")) {
			c = null;
			for (t in m.mTypes) switch t {
				case TClassDecl(cls) if (Common.samePath(cls.clPath, path)):
					c = cls;
					break;
				case _:
			}
		}
		var e = gctx.main.mainExpr; /* must be present at this point */
		return {name: path.name, cls: c, expr: e};
	}

	public static function getEsVersion(defines:DefineContext):Int {
		try {
			var v = Std.parseInt(Define.definedValue(defines, Define.JsEs));
			return v == null ? 0 : v;
		} catch (_:Dynamic) return 0;
	}

	public static function mapSourceHeader(defines:DefineContext, f:String->Void):Void {
		switch Define.definedValueSafe(defines, Define.SourceHeader) {
			case "":
			case s: f(s);
		}
	}
}
