package macros;

import core.TType.ModuleType;
import macros.MacroApi.CompilerApi;
import macros.eval.EvalContext.Context;
import macros.eval.EvalValue.Value;

// port: the seam in front of the macro engine. Upstream's `Interp` is
// `InterpImpl (= Eval | Hlmacro) + MacroApiImpl`, a choice made when the
// compiler is built; here MacroContext calls the engine through this
// interface, so a host can install another one at run time (hxmc's
// HaxeMain: Mir macros, hxmc/src/hxmc/interp/MirMacros.hx). Every engine keeps Eval's
// context and values: MacroApi stays a single implementation, and errors
// and positions travel as Eval's do (exceptions, `api.pos`). Eval is the
// default and the only engine of the port's own builds.
interface IMacroEngine {
	// the macro context's interpreter (EvalMain.create)
	function create(com:context.Common.CommonContext, api:CompilerApi, isMacro:Bool, args:Array<String>):Context;
	// once the macro context is created (EvalMain.init)
	function init(ctx:Context):Void;
	// the types of the macro context, after its filters (EvalMain.addTypes)
	function addTypes(ctx:Context, types:Array<ModuleType>, ready:ModuleType->Void):Void;
	// calls the static function `f` of the class at `path` with encoded arguments (EvalMain.callPath)
	function callPath(ctx:Context, path:Array<String>, f:String, vl:Array<Value>, api:CompilerApi):haxe.ds.Option<Value>;
	// a cached context reused by the next compilation (EvalMain.doReuse)
	function doReuse(ctx:Context, api:CompilerApi, args:Array<String>):Void;
	// a compilation error was reported (EvalMain.setError)
	function setError(ctx:Context, b:Bool):Void;
	// the API macro code calls from now on (`mint.curapi <- api`)
	function setApi(ctx:Context, api:CompilerApi):Void;
}

// port: Eval through the seam: each method is the EvalMain function upstream calls.
class EvalEngine implements IMacroEngine {
	public function new() {}

	public function create(com:context.Common.CommonContext, api:CompilerApi, isMacro:Bool, args:Array<String>):Context
		return macros.eval.EvalMain.create(com, api, isMacro, args);

	public function init(ctx:Context):Void
		macros.eval.EvalMain.init(ctx);

	public function addTypes(ctx:Context, types:Array<ModuleType>, ready:ModuleType->Void):Void
		macros.eval.EvalMain.addTypes(ctx, types, ready);

	public function callPath(ctx:Context, path:Array<String>, f:String, vl:Array<Value>, api:CompilerApi):haxe.ds.Option<Value>
		return macros.eval.EvalMain.callPath(ctx, path, f, vl, api);

	public function doReuse(ctx:Context, api:CompilerApi, args:Array<String>):Void
		macros.eval.EvalMain.doReuse(ctx, api, args);

	public function setError(ctx:Context, b:Bool):Void
		macros.eval.EvalMain.setError(ctx, b);

	public function setApi(ctx:Context, api:CompilerApi):Void
		ctx.curapi = api;
}

class MacroEngine {
	// port: the engine MacroContext uses for the macro context (not for
	// --interp, which is Eval's own run of a program)
	public static var engine:IMacroEngine = new EvalEngine();
}
