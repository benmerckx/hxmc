package ml2hx.rt;

// OCaml predefined exception (README).
class OutOfMemoryExn extends Exn {
	public function new() {
		super("Out_of_memory");
	}
	override public function structuralFields():Array<Any> return [];
}
