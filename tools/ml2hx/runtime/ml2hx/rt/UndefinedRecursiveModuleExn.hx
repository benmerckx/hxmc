package ml2hx.rt;

// OCaml predefined exception (README).
class UndefinedRecursiveModuleExn extends Exn {
	public final v0:String;
	public final v1:Int;
	public final v2:Int;
	public function new(v0:String, v1:Int, v2:Int) {
		super("Undefined_recursive_module");
		this.v0 = v0;
		this.v1 = v1;
		this.v2 = v2;
	}
	override public function structuralFields():Array<Any> return [v0, v1, v2];
}
