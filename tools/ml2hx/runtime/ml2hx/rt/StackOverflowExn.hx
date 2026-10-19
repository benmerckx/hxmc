package ml2hx.rt;

// OCaml predefined exception (README).
class StackOverflowExn extends Exn {
	public function new() {
		super("Stack_overflow");
	}
	override public function structuralFields():Array<Any> return [];
}
