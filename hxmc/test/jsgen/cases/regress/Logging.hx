package regress;

// (a static that reaches a later module's class through an interface, an override and `super`: hex.log's
// LogManager.getLogger)
interface ICtx {
	function getLogger():regress.zz.Lg;
}

class Ctx implements ICtx {
	public function new() {}

	public function getLogger():regress.zz.Lg return newInstance("logger");

	function newInstance(n:String):regress.zz.Lg return new regress.zz.Lg(n);
}

class GCtx extends Ctx {
	override function newInstance(n:String):regress.zz.Lg return super.newInstance(n + "!");
}

class Mgr {
	static var ctx:ICtx = new GCtx();

	public static function getLogger() return ctx.getLogger();
}

class Metrics {
	public static var logger = Mgr.getLogger();
}
