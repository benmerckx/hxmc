package ml2hx.rt;

class Exit extends MlException {
	public static final instance = new Exit();

	public function new() super();

	public static inline function raise():Exit
		return instance;

	override public function exnName():String
		return "Stdlib.Exit";
}
