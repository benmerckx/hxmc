package ml2hx.rt;

class OutOfMemory extends MlException {
	public static final instance = new OutOfMemory();

	public function new() super();

	public static inline function raise():OutOfMemory
		return instance;

	override public function exnName():String
		return "Out_of_memory";
}
