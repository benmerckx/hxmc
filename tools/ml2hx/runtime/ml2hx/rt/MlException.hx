package ml2hx.rt;

// The base of every OCaml exception: a predefined one (Not_found, Failure...)
// and the converted program's (Stdlib.Exit, Typecore.Error...). `exnName` is
// the constructor's name as Printexc prints it ("Not_found", "Stdlib.Exit");
// the payload is the fields 0... (`exnArg`). Constant exceptions are raised as
// their one `instance` (OCaml allocates nothing for them either).
//
// As an OCaml value (Obj, compare, hash) an exception is laid out as OCaml
// lays it out: a constant one is its extension constructor, a block of tag
// Object_tag (248) holding the name and an id; one with arguments is a block
// of tag 0 holding the constructor, then the arguments.
class MlException extends haxe.Exception implements Block {
	public function new() {
		super("");
	}

	public function exnName():String
		throw new haxe.Exception("MlException.exnName: not overridden");

	public function exnArity():Int
		return 0;

	public function exnArg(i:Int):Dynamic
		throw new haxe.Exception("MlException.exnArg: out of range");

	public function blockTag():Int return exnArity() == 0 ? ExnSlot.OBJECT_TAG : 0;
	public function blockSize():Int return exnArity() == 0 ? 2 : exnArity() + 1;
	public function blockField(i:Int):Dynamic {
		if (exnArity() == 0) return i == 0 ? exnName() : Int63.ofInt(ExnSlot.idOf(exnName()));
		return i == 0 ? ExnSlot.of(exnName()) : exnArg(i - 1);
	}

	// The runtime's printing of an uncaught exception (printexc.c's
	// caml_format_exception): Name, Name(1, "s", _).
	override public function toString():String {
		var b = new StringBuf();
		b.add(exnName());
		var n = exnArity();
		if (n == 0) return b.toString();
		// Match_failure, Assert_failure, Undefined_recursive_module: their tuple
		var args:Array<Dynamic> = [for (i in 0...n) exnArg(i)];
		if (n == 1 && Std.isOfType(args[0], Block) && isSpecial()) {
			var t:Block = args[0];
			args = [for (i in 0...t.blockSize()) t.blockField(i)];
		}
		b.add("(");
		for (i in 0...args.length) {
			if (i > 0) b.add(", ");
			var a:Dynamic = args[i];
			if (Std.isOfType(a, String)) b.add('"' + ByteString.toNative(a) + '"');
			else if (haxe.Int64.isInt64(a)) b.add((a : Int63).toString());
			else b.add("_");
		}
		b.add(")");
		return b.toString();
	}

	function isSpecial():Bool {
		var name = exnName();
		return name == "Match_failure" || name == "Assert_failure" || name == "Undefined_recursive_module";
	}

	override function get_message():String
		return toString();

	// An exception of the target (not an OCaml one) seen by an OCaml handler.
	public static function wrap(e:haxe.Exception):MlException {
		if (Std.isOfType(e, MlException)) return cast e;
		var native:Dynamic = e.native;
		if (Std.isOfType(native, MlException)) return cast native;
		return new NativeException(e);
	}
}

// An extension constructor as a value (Obj.Extension_constructor): a block
// of tag Object_tag holding the name and the id. One per name.
class ExnSlot implements Block {
	public static inline var OBJECT_TAG = 248;
	static var slots = new haxe.ds.StringMap<ExnSlot>();
	static var nextId = 1;

	public final name:String;
	public final id:Int;

	function new(name:String, id:Int) {
		this.name = name;
		this.id = id;
	}

	public static function of(name:String):ExnSlot {
		var s = slots.get(name);
		if (s == null) {
			s = new ExnSlot(name, nextId++);
			slots.set(name, s);
		}
		return s;
	}
	public static function idOf(name:String):Int return of(name).id;

	public function blockTag():Int return OBJECT_TAG;
	public function blockSize():Int return 2;
	public function blockField(i:Int):Dynamic return i == 0 ? name : Int63.ofInt(id);
}

class NativeException extends MlException {
	public final error:haxe.Exception;
	public function new(error:haxe.Exception) {
		super();
		this.error = error;
	}
	override public function exnName():String return "Native(" + error.message + ")";
}
