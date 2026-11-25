package hxmc.genesm;

import core.Globals;
import core.TType;
import core.TFunctions.*;
import generators.Genjs;
import generators.Genjs.JsCtx;
import hxmc.esm.HotIds;
import hxmc.esm.HotManifest;
using StringTools;

// Genesm dev backend when -D esm.hot: $h registry, tier-1 bodies, tier-2 class/enum.
class GenesmHot {
	public static function generate(com:generators.Gctx):Void {
		HotManifest.reset();
		if (core.Define.rawDefined(com.defines, "esm.hot"))
			hxmc.esm.HotLowering.runLateGctx(com);
		Genesm.hotRegistry = true;
		try {
			Genesm.generate(com);
			HotManifest.finishGenerate(com);
		} catch (e:Dynamic) {
			Genesm.hotRegistry = false;
			throw e;
		}
		Genesm.hotRegistry = false;
	}

	public static function registerType(ctx:JsCtx, t:ModuleType):Void {
		switch t {
			case TClassDecl(c) if (!hasClassFlag(c, CExtern)):
				if (hasClassFlag(c, CInterface)) return;
				registerClassType(ctx, c);
			case TEnumDecl(e) if (!hasEnumFlag(e, EnExtern)):
				registerEnumType(ctx, e);
			default:
		}
	}

	static function registerClassType(ctx:JsCtx, c:TClass):Void {
		var id = Globals.sTypePath(c.clPath);
		var unit = HotIds.units.get(id);
		if (unit == null) return;
		var p = Genjs.sPath(ctx, Genjs.getGeneratedClassPath(c));
		var reg = p + " = " + Genesm.reg() + ".publishClass(" + jsQuote(id) + "," + jsQuote(unit.layoutHash ?? "") + ","
			+ jsQuote(unit.superId ?? "") + "," + jsQuote(unit.policy) + "," + p + ")";
		HotManifest.recordTypeEmit(id, reg);
		Genjs.newline(ctx);
		Genjs.print(ctx, reg + ";\n");
	}

	static function registerEnumType(ctx:JsCtx, e:TEnum):Void {
		var id = Globals.sTypePath(e.ePath);
		var unit = HotIds.units.get(id);
		if (unit == null) return;
		var p = Genjs.sPath(ctx, e.ePath);
		var reg = Genesm.reg() + '.publishEnum(' + jsQuote(id) + "," + jsQuote(unit.enumTableHash ?? "") + ","
			+ jsQuote(unit.policy) + "," + p + ")";
		HotManifest.recordTypeEmit(id, reg);
		Genjs.newline(ctx);
		Genjs.print(ctx, reg + ";\n");
	}

	static function jsQuote(s:String):String return '"' + jsEscape(s) + '"';

	public static function emitClassStatic(ctx:JsCtx, c:TClass, f:TClassField):Void emitSwappable(ctx, c, f);

	public static function emitSwappableStatic(ctx:JsCtx, s:{c:TClass, f:TClassField, e:TExpr}):Void
		emitSwappable(ctx, s.c, s.f);

	public static function emitHotClosure(ctx:JsCtx, id:String, capHash:String, caps:Array<String>, f:TFunc, pos:Pos):Void {
		var params = new Map<String, Bool>();
		for (a in f.tfArgs) params.set(a.variable.vName, true);
		caps = [for (n in caps) if (!params.exists(n)) n];
		var capHash2 = caps.length == 0 ? "" : capHash;
		var e:TExpr = {eexpr: TFunction(f), etype: null, epos: pos};
		var implJs = emitFnJs(ctx, e);
		var emitHash = HotManifest.recordEmit(id, implJs);
		if (caps.length == 0) {
			Genjs.print(ctx, "(");
			Genjs.print(ctx, Genesm.reg() + '.registerClosure("' + jsEscape(id) + '","' + jsEscape(capHash2) + '","' + jsEscape(emitHash) + '",');
			Genjs.print(ctx, implJs);
			Genjs.print(ctx, "), " + Genesm.reg() + '.makeClosure("' + jsEscape(id) + '",null))');
			return;
		}
		Genjs.print(ctx, "(function(");
		concatIdents(ctx, caps);
		Genjs.spr(ctx, "){");
		Genjs.print(ctx, "var $env = {");
		concatEnvPairs(ctx, caps);
		Genjs.spr(ctx, "};");
		emitClosureRegister(ctx, id, capHash2, emitHash, implJs);
		Genjs.print(ctx, "return " + Genesm.reg() + '.makeClosure("' + jsEscape(id) + '",' + String.fromCharCode(36) + "env);");
		Genjs.spr(ctx, "})(");
		concatIdents(ctx, caps);
		Genjs.spr(ctx, ")");
	}

	static function emitClosureRegister(ctx:JsCtx, id:String, capHash:String, emitHash:String, implJs:String):Void {
		Genjs.print(ctx, Genesm.reg() + '.registerClosure("' + jsEscape(id) + '","' + jsEscape(capHash) + '","' + jsEscape(emitHash) + '",');
		Genjs.print(ctx, implJs);
		Genjs.spr(ctx, ");");
	}

	static function concatIdents(ctx:JsCtx, caps:Array<String>):Void {
		for (i in 0...caps.length) {
			if (i > 0) Genjs.spr(ctx, ",");
			Genjs.spr(ctx, Genjs.ident(caps[i]));
		}
	}

	static function concatEnvPairs(ctx:JsCtx, caps:Array<String>):Void {
		for (i in 0...caps.length) {
			if (i > 0) Genjs.spr(ctx, ",");
			var n = Genjs.ident(caps[i]);
			Genjs.print(ctx, n + ":" + n);
		}
	}

	static function emitSwappable(ctx:JsCtx, c:TClass, f:TClassField):Void {
		if (f.cfExpr != null)
			hxmc.esm.HotLowering.prepareFieldCells(ctx.com, c, f);
		var e = f.cfExpr;
		if (e == null) return;
		var uid = HotIds.unitId(c, f.cfName);
		var clPath = Genjs.getGeneratedClassPath(c);
		var p = Genjs.sPath(ctx, clPath);
		var field = Genjs.staticField(ctx, c, f);
		var fnJs = emitFnJs(ctx, e);
		var t = StringTools.ltrim(fnJs);
		if (!StringTools.startsWith(t, "function"))
			fnJs = "function(){ return " + fnJs + "; }";
		var emitHash = HotManifest.recordEmit(uid, fnJs);
		Genjs.processExpose(f.cfMeta, () -> (Genjs.dotPath(clPath)) + "." + f.cfName, s -> Genjs.print(ctx, "$hx_exports" + Genjs.pathToBrackets(s) + " = "));
		Genjs.print(ctx, Genesm.reg() + '.registerFunction("' + jsEscape(uid) + '","' + jsEscape(emitHash) + '",');
		Genjs.print(ctx, fnJs);
		Genjs.spr(ctx, ");");
		Genjs.newline(ctx);
		Genjs.print(ctx, p + field + ' = function() { return ' + Genesm.reg() + '.invoke("' + jsEscape(uid) + '",arguments); }');
		Genjs.newline(ctx);
	}

	static function emitFnJs(ctx:JsCtx, e:TExpr):String {
		var snap = Genjs.allocCtx(ctx.com, ctx.esVersion);
		snap.typeAccessor = ctx.typeAccessor;
		snap.noFlush = true;
		Genjs.genValue(snap, e);
		return snap.buf.contents();
	}

	static function jsEscape(s:String):String return StringTools.replace(s, "\\", "\\\\").split('"').join('\\"');
}