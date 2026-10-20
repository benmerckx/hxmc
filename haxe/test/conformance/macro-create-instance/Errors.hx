import haxe.macro.Context;
import haxe.macro.Expr;

// A typing error of the macro API (Context.typeof of an ill-typed
// expression) caught by macro code as a haxe.macro.Error: its message,
// position and class. (Native macros: a bundle cannot hold haxe.macro.Error
// yet, which extends the compiler's haxe.Exception, hxmc.macro.Loader: this
// class runs on Eval.)
class Errors {
	public static macro function typeError(e:Expr):Expr {
		return try {
			Context.typeof(e);
			macro "typed";
		} catch (err:haxe.macro.Expr.Error) {
			var p = Context.getPosInfos(err.pos);
			var s = err.message + " @" + p.min + "-" + p.max + " " + Std.isOfType(err, haxe.Exception);
			macro $v{s};
		}
	}
}
