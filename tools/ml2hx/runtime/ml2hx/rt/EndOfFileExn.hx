package ml2hx.rt;

// OCaml predefined exception (README).
class EndOfFileExn extends Exn {
	public function new() {
		super("End_of_file");
	}
	override public function structuralFields():Array<Any> return [];
}
