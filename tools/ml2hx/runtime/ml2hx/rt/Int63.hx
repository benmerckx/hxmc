package ml2hx.rt;

// OCaml's native 64-bit runtime has signed, wrapping 63-bit machine integers.
// Keep these distinct from Haxe's 32-bit Int, including on JavaScript hosts.
abstract Int63(haxe.Int64) {
	inline function new(v:haxe.Int64) this = (v << 1) >> 1;
	inline function raw():haxe.Int64 return this;
	public static inline function ofInt(v:Int):Int63 return new Int63(haxe.Int64.ofInt(v));
	public static function parse(v:String):Int63 return new Int63(haxe.Int64.parseString(v));
	public inline function toInt():Int return haxe.Int64.toInt(this);
	public inline function toString():String return haxe.Int64.toStr(this);
	public static inline function add(a:Int63, b:Int63):Int63 return new Int63(a.raw() + b.raw());
	public static inline function sub(a:Int63, b:Int63):Int63 return new Int63(a.raw() - b.raw());
	public static inline function mul(a:Int63, b:Int63):Int63 return new Int63(a.raw() * b.raw());
	public static function div(a:Int63, b:Int63):Int63 {
		if (eq(b, ofInt(0))) throw new haxe.Exception("Division_by_zero");
		return new Int63(a.raw() / b.raw());
	}
	public static function mod(a:Int63, b:Int63):Int63 {
		if (eq(b, ofInt(0))) throw new haxe.Exception("Division_by_zero");
		return new Int63(a.raw() % b.raw());
	}
	public static inline function neg(a:Int63):Int63 return new Int63(-a.raw());
	public static inline function eq(a:Int63, b:Int63):Bool return a.raw() == b.raw();
	public static inline function compare(a:Int63, b:Int63):Int return haxe.Int64.compare(a.raw(), b.raw());
}
