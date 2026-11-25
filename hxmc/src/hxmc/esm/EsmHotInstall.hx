package hxmc.esm;

import core.Globals;
import core.Globals.GlobalTypePath;
import core.Ast.MetadataEntry;
import core.TFunctions.*;
import core.TType;
import core.TType.TClass;
import core.TType.TClassField;
import generators.Genjs.JsCtx;

// -D esm.hot: filter hooks, DCE off, defines hygiene.
class EsmHotInstall {
	static var installed = false;

	public static function install():Void {
		if (installed) return;
		installed = true;
		generators.EsmHotEmit.tryEmitClassStatic = tryEmitClassStatic;
		generators.EsmHotEmit.tryEmitClosure = tryEmitClosure;
		generators.EsmHotEmit.beforeRename = function(com) {
			if (!core.Define.rawDefined(com.defines, "esm.hot")) return;
			HotLowering.runEarly(com);
		};
		generators.EsmHotEmit.afterRename = function(com) {
			if (!core.Define.rawDefined(com.defines, "esm.hot")) return;
			HotLowering.runLate(com);
		};
		generators.EsmHotEmit.prepareFieldCells = function(ctx, c, f) {
			if (!core.Define.rawDefined(ctx.com.defines, "esm.hot")) return;
			HotLowering.prepareFieldCells(ctx.com, c, f);
		};
		var prev = compiler.Compiler.beforeTypingHook;
		compiler.Compiler.beforeTypingHook = function(com, actx) {
			if (prev != null) prev(com, actx);
			registerHotMetas(com);
			com.callbacks.addAfterFilters(function() {
				if (!core.Define.rawDefined(com.defines, "esm.hot")) return;
				HotIds.run(com);
			});
			if (!core.Define.rawDefined(com.defines, "esm.hot")) return;
			if (!core.Define.rawDefined(com.defines, "esm"))
				core.Define.rawDefineValue(com.defines, "esm", "");
			if (!core.Define.rawDefined(com.defines, "hxmc.no-module-cache"))
				core.Define.rawDefineValue(com.defines, "hxmc.no-module-cache", "");
			if (!core.Define.rawDefined(com.defines, "dce") || core.Define.rawDefinedValue(com.defines, "dce") != "no")
				core.Define.rawDefineValue(com.defines, "dce", "no");
			// Keep @:esm.hot.* on locals as TMeta through filters (typeMeta preserve).
			if (!core.Define.rawDefined(com.defines, "retain_untyped_meta"))
				core.Define.rawDefineValue(com.defines, "retain_untyped_meta", "");
		};
	}

	static function tryEmitClosure(ctx:JsCtx, m:MetadataEntry, f:TFunc, pos:Pos):Bool {
		if (!core.Define.rawDefined(ctx.com.defines, "esm.hot")) return false;
		if (!hxmc.esm.EsmHotMeta.isClosureMeta(m)) return false;
		var id = hxmc.esm.EsmHotMeta.closureIdFromEntry(m);
		if (id == null) return false;
		var capHash = hxmc.esm.EsmHotMeta.closureCapHashFromEntry(m);
		var caps = closureCapsForEmit(f, hxmc.esm.EsmHotMeta.closureCapturesFromEntry(m));
		var capHash2 = caps.length == 0 ? "" : (capHash != null ? capHash : "");
		var impl = closureImplForEmit(f, caps);
		hxmc.genesm.GenesmHot.emitHotClosure(ctx, id, capHash2, caps, impl, pos);
		return true;
	}

	// Drop capture names that are parameters of any nested function in the closure impl.
	// Drop spurious $env wrapper when there are no real captures (false param capture).
	static function closureImplForEmit(f:TFunc, caps:Array<String>):TFunc {
		if (caps.length > 0) return f;
		var inner = unwrapReturnedLambda(f);
		return inner != null ? inner : f;
	}

	static function unwrapReturnedLambda(f:TFunc):Null<TFunc> {
		function fromExpr(e:TExpr):Null<TFunc> switch e.eexpr {
			case TReturn({eexpr: TFunction(inner)}): return inner;
			case TBlock(el):
				for (x in el) {
					var r = fromExpr(x);
					if (r != null) return r;
				}
				return null;
			default:
				return null;
		}
		if (f.tfArgs.length == 1 && f.tfArgs[0].variable.vName == "$env") return fromExpr(f.tfExpr);
		return fromExpr(f.tfExpr);
	}

	static function closureCapsForEmit(f:TFunc, metaCaps:Array<String>):Array<String> {
		if (metaCaps.length == 0) return metaCaps;
		var paramNames = new Map<String, Bool>();
		var localNames = new Map<String, Bool>();
		function collectAllParams(tf:TFunc):Void {
			for (a in tf.tfArgs) paramNames.set(a.variable.vName, true);
			HotExprMap.mapTransform(function(e:TExpr):TExpr {
				switch e.eexpr {
					case TFunction(inner):
						for (a in inner.tfArgs) paramNames.set(a.variable.vName, true);
					default:
				}
				return e;
			}, tf.tfExpr);
		}
		function collectDeclaredLocals(expr:TExpr):Void {
			HotExprMap.mapTransform(function(e:TExpr):TExpr {
				switch e.eexpr {
					case TVar(v, _):
						localNames.set(v.vName, true);
					case TFunction(inner):
						for (a in inner.tfArgs) localNames.set(a.variable.vName, true);
					default:
				}
				return e;
			}, expr);
		}
		collectAllParams(f);
		collectDeclaredLocals(f.tfExpr);
		return [for (n in metaCaps) if (!paramNames.exists(n) && !localNames.exists(n)) n];
	}

	static function registerHotMetas(com:context.Common.CommonContext):Void {
		var um:core.Meta.UserMeta = {doc: null, flags: [], source: null};
		for (leaf in ["cell", "scope", "keyed", "function"]) {
			core.Meta.registerUserMeta(com.userMetas, ":esm.hot." + leaf, um);
			core.Meta.registerUserMeta(com.userMetas, "esm.hot." + leaf, um);
		}
	}

	static function tryEmitClassStatic(ctx:JsCtx, c:TClass, _clPath:GlobalTypePath, f:TClassField):Bool {
		if (!core.Define.rawDefined(ctx.com.defines, "esm.hot")) return false;
		if (f.cfExpr == null) return false;
		return switch f.cfExpr.eexpr {
			case TFunction(_):
				hxmc.genesm.GenesmHot.emitClassStatic(ctx, c, f);
				true;
			default:
				false;
		};
	}
}
