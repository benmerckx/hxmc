package ml2hx.rt;

// The base of every OCaml exception: a predefined one (Not_found, Failure...),
// the library's (Stdlib.Exit, Stream.Failure...) and the converted program's.
// `exnName` is the constructor's name as Printexc prints it ("Not_found",
// "Stdlib.Exit", "Typecore.Error"); the payload is the fields 0... (`exnArg`).
// Constant exceptions are raised as their one `instance` (OCaml allocates
// nothing for them either).
class MlException extends haxe.Exception {
	public function new() {
		super("");
	}

	public function exnName():String
		throw new haxe.Exception("MlException.exnName: not overridden");

	public function exnArity():Int
		return 0;

	public function exnArg(i:Int):Dynamic
		throw new haxe.Exception("MlException.exnArg: out of range");

	// Printexc.to_string's default printer
	override public function toString():String
		return ml2hx.std.Printexc.toString(this);

	override function get_message():String
		return toString();
}
