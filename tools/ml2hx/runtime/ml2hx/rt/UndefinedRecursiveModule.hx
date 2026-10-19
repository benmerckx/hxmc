package ml2hx.rt;

// Undefined_recursive_module of (string * int * int): one argument, a tuple (as OCaml lays it out).
class UndefinedRecursiveModule extends MlException {
	public final v0:Tuple3<String, Int63, Int63>;

	public function new(v0:Tuple3<String, Int63, Int63>) {
		super();
		this.v0 = v0;
	}

	public static inline function at(file:String, line:Int63, col:Int63):UndefinedRecursiveModule
		return new UndefinedRecursiveModule(new Tuple3(file, line, col));

	override public function exnArity():Int
		return 1;

	override public function exnArg(i:Int):Dynamic
		return i == 0 ? v0 : super.exnArg(i);

	override public function exnName():String
		return "Undefined_recursive_module";
}
