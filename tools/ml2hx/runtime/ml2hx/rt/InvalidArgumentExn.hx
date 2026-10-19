package ml2hx.rt;

// OCaml predefined exception (README).
class InvalidArgumentExn extends Exn {
	public final v0:String;
	public function new(v0:String) {
		super("Invalid_argument");
		this.v0 = v0;
	}
	override public function structuralFields():Array<Any> return [v0];
}
