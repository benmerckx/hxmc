package ml2hx.rt;

class EndOfFile extends MlException {
	public static final instance = new EndOfFile();

	public function new() super();

	public static inline function raise():EndOfFile
		return instance;

	override public function exnName():String
		return "End_of_file";
}
