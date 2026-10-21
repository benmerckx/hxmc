package typing;

import core.Globals.Platform;
import core.ds.AtomicLazy;
import core.TFunctions.TypeExit;
import context.Typecore.Typer as TyperContext;
import context.Common.CommonContext;
import context.Common.LocalWrapperApi;
import context.TyperPass.TyperPassTools;
import context.Resolution;
import optimization.Inline;
import core.Globals.Pos;
import core.TType;
import core.TType.*;
import core.TFunctions.*;
import core.TOther.*;
import core.TOther;
import core.Globals;
import core.Error.*;
import core.Error;
import context.Typecore.*;
import context.Typecore;
import context.TyperPass;
import context.Typecore.TyperManager;
import context.Common;
import core.Define;
import typing.Typer.*;
import context.Resolution.*;
import core.ds.VectorTools.vector;

class TyperEntry {
	public static function loadStdTypes(ctx:TyperContext):Void {
		var stdTypes:ModuleDef;
		try stdTypes = TypeloadModule.loadModule(ctx, {pack: [], name: "StdTypes"}, Globals.nullPos)
		catch (e:Dynamic) {
			switch e {
				case(core.ds.ExceptionTools.typing(_) => Some({errMessage: ModuleNotFound({pack: [], name: "StdTypes"})})):
					stdTypes = raiseStdNotFound();
				case _:
					throw e;
			}
		}
		var types:Array<ModuleType> = stdTypes.mTypes.copy();
		types.reverse();
		for (t in types) {
			ctx.m.importResolution.add(Resolution.moduleTypeResolution(t, null, Globals.nullPos));
			switch t {
				case TAbstractDecl(a):
					switch a.aPath.name {
						case "Void":
							var t = TAbstract(a, vector());
							core.TUnification.unify(t, ctx.t.tvoid);
							ctx.t.tvoid = t;
						case "Float":
							var t = TAbstract(a, vector());
							core.TUnification.unify(t, ctx.t.tfloat);
							ctx.t.tfloat = t;
						case "Int":
							var t = TAbstract(a, vector());
							core.TUnification.unify(t, ctx.t.tint);
							ctx.t.tint = t;
						case "Bool":
							var t = TAbstract(a, vector());
							core.TUnification.unify(t, ctx.t.tbool);
							ctx.t.tbool = t;
						case "Dynamic": ctx.g.tDynamicDef = TAbstract(a, extractParamTypes(a.aParams));
						case "Null":
							ctx.t.tnull = function(t:T):T {
								try {
									return !isNull(t, true) && !isExplicitNull(t) ? TAbstract(a, vector(t)) : t;
								} catch (err:TypeExit) {
									// don't force lazy evaluation
									var r = new TLazy(lazyAvailable(tDynamic));
									r.value = lazyWait(function() {
										var t1 = !isNull(t) ? TAbstract(a, vector(t)) : t;
										r.value = lazyAvailable(t1);
										return t1;
									});
									return TLazy(r);
								}
							};
						case _:
					}
				case TTypeDecl(td):
					if (td.tPath.name == "Iterator") ctx.t.titerator = t -> TType(td, vector(t));
				case TEnumDecl(_) | TClassDecl(_):
			}
		}
	}

	public static function loadString(ctx:TyperContext):Void {
		var m = TypeloadModule.loadModule(ctx, {pack: [], name: "String"}, Globals.nullPos);
		for (mt in m.mTypes) switch mt {
			case TClassDecl(c = {clPath: {pack: [], name: "String"}}):
				var t = TInst(c, vector());
				core.TUnification.unify(t, ctx.t.tstring);
				ctx.t.tstring = t;
			case _:
		}
	}

	public static function loadStd(ctx:TyperContext):Void {
		var m = TypeloadModule.loadModule(ctx, {pack: [], name: "Std"}, Globals.nullPos);
		for (mt in m.mTypes) switch mt {
			case TClassDecl(c = {clPath: {pack: [], name: "Std"}}):
				ctx.com.std = c;
			case _:
		}
	}

	public static function loadAny(ctx:TyperContext):Void {
		var m = TypeloadModule.loadModule(ctx, {pack: [], name: "Any"}, Globals.nullPos);
		for (mt in m.mTypes) switch mt {
			case TAbstractDecl(a) if (a.aPath.name == "Any"):
				var t = TAbstract(a, vector());
				core.TUnification.unify(t, ctx.t.tany);
				ctx.t.tany = t;
			case _:
		}
	}

	public static function loadArray(ctx:TyperContext):Void {
		var m = TypeloadModule.loadModule(ctx, {pack: [], name: "Array"}, Globals.nullPos);
		for (mt in m.mTypes) switch mt {
			case TClassDecl(c = {clPath: {pack: [], name: "Array"}}):
				ctx.t.tarray = t -> TInst(c, vector(t));
				return;
			case _:
		}
		throw "Could not locate Array";
	}

	public static function loadUnit(ctx:TyperContext):Void {
		var m = TypeloadModule.loadModule(ctx, {pack: ["haxe"], name: "Unit"}, Globals.nullPos);
		for (mt in m.mTypes) switch mt {
			case TEnumDecl(en) if (en.ePath.name == "Unit"):
				ctx.t.tunit = TEnum(en, vector());
				// ctx.m.importResolution.add(moduleTypeResolution(mt, null, nullPos));
			case _:
		}
	}

	public static function loadEnumTools(ctx:TyperContext):Void {
		var m = TypeloadModule.loadModule(ctx, {pack: ["haxe"], name: "EnumTools"}, Globals.nullPos);
		switch m.mTypes {
			case [TClassDecl(c1), TClassDecl(c2)]:
				ctx.g.globalUsing = [{cls: c1, pos: c1.clPos}, {cls: c2, pos: c2.clPos}].concat(ctx.g.globalUsing);
			case [TClassDecl(c1)]:
				var m = TypeloadModule.loadModule(ctx, {pack: ["haxe"], name: "EnumValueTools"}, Globals.nullPos);
				switch m.mTypes {
					case [TClassDecl(c2)]: ctx.g.globalUsing = [
							{cls: c1, pos: c1.clPos},
							{
								cls: c2,
								pos: c2.clPos
							}
						].concat(ctx.g.globalUsing);
					case _: throw "Invalid EnumValueTools module";
				}
			case _:
				throw "Invalid EnumTools module";
		}
	}

	public static function loadLocalWrapper(ctx:TyperContext):LocalWrapperApi {
		// optimized version for Java - use native arrays
		if (ctx.com.platform == Jvm) {
			var m = TypeloadModule.loadModule(ctx, {pack: ["jvm"], name: "NativeArray"}, Globals.nullPos);
			for (md in m.mTypes) switch md {
				case TClassDecl(cl = {clPath: {pack: ["jvm"], name: "NativeArray"}}):
					return new CaptureLocalWrapper(ctx.t, cl);
				case _:
			}
			throw core.ds.NotFound.raise();
		}
		// default implementation - use haxe array
		return new CaptureLocalWrapper(ctx.t, null);
	}

	public static function loadCoro(ctx:TyperContext):Void {
		ctx.t.tcoro.tcoro = AtomicLazy.fromFun(function() {
			var m = TypeloadModule.loadModule(ctx, {pack: ["haxe", "coro"], name: "Coroutine"}, Globals.nullPos);
			for (mt in m.mTypes) switch mt {
				case TAbstractDecl(a = {aPath: {pack: ["haxe", "coro"], name: "Coroutine"}}):
					return function(signature:TSignature):T return TAbstract(a, vector(TFun(signature)));
				case _:
			}
			throw "Could not locate abstract Coroutine<T> (was it redefined?)";
		});
		ctx.t.tcoro.continuation = AtomicLazy.fromFun(function() {
			var m = TypeloadModule.loadModule(ctx, {pack: ["haxe", "coro"], name: "IContinuation"}, Globals.nullPos);
			for (mt in m.mTypes) switch mt {
				case TClassDecl(cl = {clPath: {pack: ["haxe", "coro"], name: "IContinuation"}}):
					return TInst(cl, vector(ctx.t.tany));
				case _:
			}
			throw "Could not locate class IContinuation<T> (was it redefined?)";
		});
		ctx.t.tcoro.suspensionResultClass = AtomicLazy.fromFun(function() {
			var m = TypeloadModule.loadModule(ctx, {pack: ["haxe", "coro"], name: "SuspensionResult"}, Globals.nullPos);
			for (mt in m.mTypes) switch mt {
				case TClassDecl(cl = {clPath: {pack: ["haxe", "coro"], name: "SuspensionResult"}}):
					return cl;
				case _:
			}
			throw "Could not locate class SuspensionResult<T> (was it redefined?)";
		});
		ctx.t.tcoro.tasyncIterator = AtomicLazy.fromFun(function() {
			var m = TypeloadModule.loadModule(ctx, {pack: ["haxe", "coro"], name: "AsyncIterator"}, Globals.nullPos);
			for (mt in m.mTypes) switch mt {
				case TTypeDecl(td = {tPath: {pack: ["haxe", "coro"], name: "AsyncIterator"}}):
					return function(t:T):T return TType(td, vector(t));
				case _:
			}
			throw "Could not locate typedef AsyncIterator<T> (was it redefined?)";
		});
		var m = TypeloadModule.loadModule(ctx, {pack: ["haxe"], name: "Exception"}, Globals.nullPos);
		for (mt in m.mTypes) switch mt {
			case TClassDecl(cl = {clPath: {pack: ["haxe"], name: "Exception"}}):
				ctx.t.texception = TInst(cl, vector());
			case _:
		}
	}

	// port: hxmc's persistent module cache (hxmc/src/hxmc/ModuleCache.hx) keeps each context's typer here, to
	// ... type a module from its source where the server expects it cached; always null in the compiler itself.
	public static var createdHook:Null<TyperContext->Void> = null;

	public static function create(com:CommonContext, macros:Null<{finalize:Void->Void, typer:TyperContext}>):TyperContext {
		typing.Typer.initialize();
		var ctx:TyperContext = {
			com: com,
			t: com.basic,
			g: null,
			m: {
				curmod: nullModule,
				importResolution: new ResolutionList(["import", "typer"]),
				ownResolution: null,
				enumWithType: null,
				moduleUsing: [],
				importStatements: [],
				isDisplayFile: false
			},
			c: {curclass: nullClass, tthis: tDynamic, getBuildInfos: function() return null},
			f: TyperManager.createCtxF(nullField),
			e: TyperManager.createCtxE(FunStatic, FunFunction),
			pass: PBuildModule,
			allowInline: true,
			allowTransform: true,
			typeParams: vector(),
			memoryMarker: memoryMarker
		};
		ctx.g = {
			coreApi: null,
			macros: macros,
			moduleCheckPolicies: [],
			delayed: {
				var a = new haxe.ds.Vector<TyperPassTasks>(TyperPassTools.allTyperPassesLength);
				for (i in 0...a.length)
					a[i] = new TyperPassTasks([], []);
				a;
			},
			delayedMinIndex: 0,
			debugDelayed: [],
			retainMeta: Common.defined(com, Define.RetainUntypedMeta),
			globalUsing: [],
			complete: false,
			typeHints: [],
			loadOnlyCachedModules: false,
			returnPartialType: false,
			buildCount: 0,
			tDynamicDef: tDynamic,
			continuationApi: null,
			doMacro: MacroContext.typeMacro,
			doLoadMacro: MacroContext.loadMacroPrime,
			doLoadModule: TypeloadModule.loadModule,
			doLoadTypeDef: Typeload.loadTypeDef,
			getBuildInfo: InstanceBuilder.getBuildInfo,
			doFormatString: formatString,
			doLoadCoreClass: Typeload.loadCoreClass,
			delayedDisplay: null,
			callArgContext: null,
			rootTyper: ctx
		};
		if (createdHook != null) createdHook(ctx);
		loadStdTypes(ctx);
		loadString(ctx);
		loadStd(ctx);
		loadAny(ctx);
		loadUnit(ctx);
		loadArray(ctx);
		loadEnumTools(ctx);
		loadCoro(ctx);
		ctx.com.localWrapper = loadLocalWrapper(ctx);
		ctx.g.complete = true;
		return ctx;
	}

	public static function initHooks():Void {
		createContextRef = create;
	}

	static function __init__():Void initHooks();
}

// port: one class for both OCaml objects of load_local_wrapper; a null nativeClass is the default implementation.
private class CaptureLocalWrapper implements LocalWrapperApi {
	final basic:BasicTypes;
	final nativeClass:Null<TClass>;

	public function new(basic:BasicTypes, nativeClass:Null<TClass>) {
		this.basic = basic;
		this.nativeClass = nativeClass;
	}

	public function capturedType(t:T):T return nativeClass == null ? basic.tarray(t) : TInst(nativeClass, vector(t));

	public function mkRef(v:TVar, value:Null<TExpr>, p:Pos):TExpr {
		if (nativeClass == null) return mk(TArrayDecl(value == null ? vector() : vector(value)), v.vType, p);
		if (value == null) {
			var element = switch v.vType {
				case TInst(_, [t]): t;
				case _: throw "Invalid native local wrapper type";
			};
			return mk(TNew(nativeClass, vector(element), vector(mk(TConst(TInt(1)), basic.tint, p))), v.vType, p);
		}
		var e = Inline.mkUntypedCall("__array__", p, vector(value));
		e.etype = v.vType;
		return e;
	}

	public function mkRefAccess(e:TExpr, v:TVar):TExpr {
		var array = core.ds.Record.withFields(e, {etype: v.vType});
		return mk(TArray(array, mk(TConst(TInt(0)), basic.tint, e.epos)), e.etype, e.epos);
	}

	public function mkInit(av:TVar, v:TVar, p:Pos):TExpr {
		var local = mk(TLocal(v), v.vType, p);
		var array = nativeClass == null ? mk(TArrayDecl(vector(local)), av.vType, p) : Inline.mkUntypedCall("__array__", p, vector(local));
		array.etype = av.vType;
		return mk(TVar(av, array), basic.tvoid, p);
	}
}
