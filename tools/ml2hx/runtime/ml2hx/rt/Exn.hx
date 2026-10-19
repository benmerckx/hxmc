package ml2hx.rt;

// OCaml's exn. Exceptions declared in OCaml are subclasses with their
// payload as fields v0, v1, ... (README).
class Exn extends haxe.Exception implements Structural {
	public function new(name:String) super(name);
	// The OCaml name, qualified as Printexc prints it (Not_found, Foo.Error).
	public inline function name():String return message;
	public function structuralFields():Array<Any> return [];
	// Exceptions that are not OCaml exceptions (native errors of the
	// target) seen by an OCaml handler.
	public static function wrap(e:haxe.Exception):Exn {
		if (Std.isOfType(e, Exn)) return cast e;
		var native:Any = e.native;
		if (Std.isOfType(native, Exn)) return cast native;
		return new NativeExn(e);
	}
}

class NativeExn extends Exn {
	public final error:haxe.Exception;
	public function new(error:haxe.Exception) {
		super("Native");
		this.error = error;
	}
	override function toString() return error.toString();
}
