package ml2hx.rt;

// OCaml predefined exception (README).
class DivisionByZeroExn extends Exn {
	public function new() {
		super("Division_by_zero");
	}
	override public function structuralFields():Array<Any> return [];
}
