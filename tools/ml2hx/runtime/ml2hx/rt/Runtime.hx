package ml2hx.rt;


// Primitives the emitter calls: OCaml's structural equality, comparison and
// hashing over the representations of the README, checked accesses, and the
// matching helpers for extensible types.
class Runtime {
	// ---------------------------------------------------------------- ints
	public static function div(a:Int, b:Int):Int {
		if (b == 0) throw DivisionByZero.instance;
		var q = a / b;
		return Std.int(q);
	}
	public static function mod(a:Int, b:Int):Int {
		if (b == 0) throw DivisionByZero.instance;
		return a % b;
	}
	public static inline function compareInt(a:Int, b:Int):Int return a < b ? -1 : a > b ? 1 : 0;
	public static inline function compareBool(a:Bool, b:Bool):Int return (a ? 1 : 0) - (b ? 1 : 0);
	public static function compareString(a:String, b:String):Int return a < b ? -1 : a > b ? 1 : 0;

	// ---------------------------------------------------------------- checked accesses
	public static function stringGet(s:String, i:Int):Int {
		if (i < 0 || i >= s.length) throw new InvalidArgument("index out of bounds");
		return StringTools.fastCodeAt(s, i);
	}
	public static function bytesGet(b:haxe.io.Bytes, i:Int):Int {
		if (i < 0 || i >= b.length) throw new InvalidArgument("index out of bounds");
		return b.get(i);
	}
	public static function bytesSet(b:haxe.io.Bytes, i:Int, c:Int):Unit {
		if (i < 0 || i >= b.length) throw new InvalidArgument("index out of bounds");
		b.set(i, c);
		return Unit.value;
	}
	public static function arrayGet<T>(a:Array<T>, i:Int):T {
		if (i < 0 || i >= a.length) throw new InvalidArgument("index out of bounds");
		return a[i];
	}
	public static function arraySet<T>(a:Array<T>, i:Int, v:T):Unit {
		if (i < 0 || i >= a.length) throw new InvalidArgument("index out of bounds");
		a[i] = v;
		return Unit.value;
	}

	// ---------------------------------------------------------------- extensible types
	public static inline function isInstance<T>(v:Any, c:Class<T>):Bool return Std.isOfType(v, c);
	public static function downcast<T>(v:Any, c:Class<T>):MlOption<T> return Std.isOfType(v, c) ? Some(cast v) : None;

	// ---------------------------------------------------------------- structural operations
	public static inline function equal(a:Dynamic, b:Dynamic):Bool return Poly.equal(a, b);
	public static inline function compare(a:Dynamic, b:Dynamic):Int return Poly.compare(a, b);
	public static inline function hash(v:Dynamic):Int return Poly.hashParam(10, 100, 0, v);
}
