package coro;

import core.TType;
import core.TFunctions.NotFound;
import core.ds.AtomicLazy;
import core.ds.PMap;
import core.Globals;
import core.Globals.*;
import coro.ContTypes;
import core.ds.VectorTools.vector;

class CoroInit {
	public static function loadModuleClass(ctx:context.Typecore.Typer, path:GlobalTypePath):TClass {
		var m = ctx.g.doLoadModule(ctx, path, nullPos);
		for (mt in (m.mTypes : Array<ModuleType>)) switch mt {
			case TClassDecl(c) if (core.ds.Key.compare(c.clPath, path) == 0):
				return c;
			case _:
		}
		throw NotFound.raise();
	}

	public static function loadModuleAbstract(ctx:context.Typecore.Typer, path:GlobalTypePath):TAbstract {
		var m = ctx.g.doLoadModule(ctx, path, nullPos);
		for (mt in (m.mTypes : Array<ModuleType>)) switch mt {
			case TAbstractDecl(a) if (core.ds.Key.compare(a.aPath, path) == 0):
				return a;
			case _:
		}
		throw NotFound.raise();
	}

	public static function makeContinuationApi(ctx:context.Typecore.Typer):ContinuationApi {
		var base = loadModuleClass(ctx, {pack: ["haxe", "coro"], name: "BaseContinuation"});
		var state = TAbstract(loadModuleAbstract(ctx, {pack: ["haxe", "coro"], name: "SuspensionState"}), vector());
		var result = (ctx.t.tcoro.suspensionResultClass).force();
		var api = ContTypes.createContinuationApi(base, state, result, (ctx.t.tcoro.continuation).force(),
			PMap.find("suspended", result.clStatics), PMap.find("state", result.clFields), PMap.find("result", result.clFields),
			PMap.find("error", result.clFields), PMap.find("completion", base.clFields), PMap.find("context", base.clFields),
			PMap.find("gotoLabel", base.clFields));
		ctx.g.continuationApi = api;
		return api;
	}
}
