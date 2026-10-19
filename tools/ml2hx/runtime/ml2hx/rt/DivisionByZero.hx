package ml2hx.rt;

class DivisionByZero extends MlException {
	public static final instance = new DivisionByZero();

	public function new() super();

	public static inline function raise():DivisionByZero
		return instance;

	override public function exnName():String
		return "Division_by_zero";
}
