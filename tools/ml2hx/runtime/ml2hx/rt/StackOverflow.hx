package ml2hx.rt;

class StackOverflow extends MlException {
	public static final instance = new StackOverflow();

	public function new() super();

	public static inline function raise():StackOverflow
		return instance;

	override public function exnName():String
		return "Stack_overflow";
}
