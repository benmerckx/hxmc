package ml2hx.rt;

// OCaml's native 64-bit runtime has signed, wrapping 63-bit machine integers.
// Keep these distinct from Haxe's 32-bit Int, including on JavaScript hosts.
// The value is kept sign-extended from bit 62 in an Int64 (on hxmc a native
// int64_t): every operation that can leave the 63-bit range renormalizes.
abstract Int63(haxe.Int64) {
	inline function new(v:haxe.Int64) this = (v << 1) >> 1;
	inline function raw():haxe.Int64 return this;
	// an Int64 already in range (no renormalization)
	static inline function trusted(v:haxe.Int64):Int63 return cast v;

	public static var zero(get, never):Int63;
	public static var one(get, never):Int63;
	public static var minusOne(get, never):Int63;
	public static var maxInt(get, never):Int63;
	public static var minInt(get, never):Int63;
	static inline function get_zero():Int63 return trusted(haxe.Int64.ofInt(0));
	static inline function get_one():Int63 return trusted(haxe.Int64.ofInt(1));
	static inline function get_minusOne():Int63 return trusted(haxe.Int64.ofInt(-1));
	static inline function get_maxInt():Int63 return trusted(haxe.Int64.make(0x3FFFFFFF, 0xFFFFFFFF));
	static inline function get_minInt():Int63 return trusted(haxe.Int64.make(0xC0000000, 0));

	public static inline function ofInt(v:Int):Int63 return trusted(haxe.Int64.ofInt(v));
	public static function parse(v:String):Int63 return new Int63(haxe.Int64.parseString(v));
	public static inline function ofInt64(v:haxe.Int64):Int63 return new Int63(v);
	public inline function toInt64():haxe.Int64 return this;
	// the low 32 bits (OCaml's Int32.of_int)
	public inline function toInt():Int return haxe.Int64.toInt(this);
	public inline function toString():String return haxe.Int64.toStr(this);
	// whether the value fits a Haxe Int
	public inline function isInt():Bool return haxe.Int64.ofInt(haxe.Int64.toInt(this)) == this;

	public static inline function add(a:Int63, b:Int63):Int63 return new Int63(a.raw() + b.raw());
	public static inline function sub(a:Int63, b:Int63):Int63 return new Int63(a.raw() - b.raw());
	public static inline function mul(a:Int63, b:Int63):Int63 return new Int63(a.raw() * b.raw());
	public static function div(a:Int63, b:Int63):Int63 {
		if (b.raw() == 0) throw DivisionByZero.instance;
		return new Int63(a.raw() / b.raw());
	}
	public static function mod(a:Int63, b:Int63):Int63 {
		if (b.raw() == 0) throw DivisionByZero.instance;
		return new Int63(a.raw() % b.raw());
	}
	public static inline function neg(a:Int63):Int63 return new Int63(-a.raw());
	public static inline function succ(a:Int63):Int63 return new Int63(a.raw() + 1);
	public static inline function pred(a:Int63):Int63 return new Int63(a.raw() - 1);
	public static inline function abs(a:Int63):Int63 return a.raw() < 0 ? neg(a) : a;
	public static inline function eq(a:Int63, b:Int63):Bool return a.raw() == b.raw();
	public static inline function compare(a:Int63, b:Int63):Int return haxe.Int64.compare(a.raw(), b.raw());
	public static inline function lt(a:Int63, b:Int63):Bool return a.raw() < b.raw();
	public static inline function le(a:Int63, b:Int63):Bool return a.raw() <= b.raw();
	public static inline function gt(a:Int63, b:Int63):Bool return a.raw() > b.raw();
	public static inline function ge(a:Int63, b:Int63):Bool return a.raw() >= b.raw();
	public static inline function min(a:Int63, b:Int63):Int63 return a.raw() <= b.raw() ? a : b;
	public static inline function max(a:Int63, b:Int63):Int63 return a.raw() >= b.raw() ? a : b;

	public static inline function logand(a:Int63, b:Int63):Int63 return trusted(a.raw() & b.raw());
	public static inline function logor(a:Int63, b:Int63):Int63 return trusted(a.raw() | b.raw());
	public static inline function logxor(a:Int63, b:Int63):Int63 return trusted(a.raw() ^ b.raw());
	public static inline function lognot(a:Int63):Int63 return trusted(~a.raw());
	// lsl, asr, lsr: counts outside [0, 62] are unspecified in OCaml (taken modulo 64 here)
	public static inline function shiftLeft(a:Int63, n:Int63):Int63 return new Int63(a.raw() << n.toInt());
	public static inline function shiftRight(a:Int63, n:Int63):Int63 return trusted(a.raw() >> n.toInt());
	public static inline function shiftRightLogical(a:Int63, n:Int63):Int63 {
		var k = n.toInt();
		return k == 0 ? a : trusted((a.raw() & haxe.Int64.make(0x7FFFFFFF, 0xFFFFFFFF)) >>> k);
	}

	public static inline function toFloat(a:Int63):Float return Float64.ofInt64(a.raw());
	// truncation toward zero; out of range or nan is unspecified in OCaml (0 here)
	public static inline function ofFloat(f:Float):Int63 return new Int63(Float64.toInt64(f));

	// A key for matching integer literals in Haxe patterns (literals are
	// within 32 bits; values outside map to Int's minimum, never a literal).
	public static inline function patternKey(a:Int63):Int return a.isInt() ? a.toInt() : 0x80000000;
}
