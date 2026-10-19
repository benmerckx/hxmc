package ml2hx.rt;

// OCaml predefined exception (README).
class NotFoundExn extends Exn {
	public function new() {
		super("Not_found");
	}
	override public function structuralFields():Array<Any> return [];
}
