package ml2hx.rt;

class NotFound extends MlException {
	public static final instance = new NotFound();

	public function new() super();

	public static inline function raise():NotFound
		return instance;

	override public function exnName():String
		return "Not_found";
}
