package hxmc.unsafe;

// C's int8_t: an Int holding the value of an 8-bit signed integer (docs/interop.md,
// "C interop"). Arithmetic is Int's; converting an Int back wraps, as C's
// conversion does. In memory (Ptr<Int8>, @:hxmc.struct fields) and in calls
// of C functions it takes 1 byte.
abstract Int8(Int) to Int {
	inline function new(v:Int)
		this = v;

	@:from public static inline function ofInt(v:Int):Int8
		return new Int8((v << 24) >> 24);

	// Int's operators (the result is an Int)
	@:op(A + B) @:commutative static inline function add(a:Int8, b:Int):Int
		return (a : Int) + b;

	@:op(A - B) static inline function sub(a:Int8, b:Int):Int
		return (a : Int) - b;

	@:op(A - B) static inline function subFrom(a:Int, b:Int8):Int
		return a - (b : Int);

	@:op(A * B) @:commutative static inline function mul(a:Int8, b:Int):Int
		return (a : Int) * b;

	@:op(A / B) static inline function div(a:Int8, b:Int):Float
		return (a : Int) / b;

	@:op(A % B) static inline function mod(a:Int8, b:Int):Int
		return (a : Int) % b;

	@:op(A & B) @:commutative static inline function and(a:Int8, b:Int):Int
		return (a : Int) & b;

	@:op(A | B) @:commutative static inline function or(a:Int8, b:Int):Int
		return (a : Int) | b;

	@:op(A ^ B) @:commutative static inline function xor(a:Int8, b:Int):Int
		return (a : Int) ^ b;

	@:op(A << B) static inline function shl(a:Int8, b:Int):Int
		return (a : Int) << b;

	@:op(A >> B) static inline function shr(a:Int8, b:Int):Int
		return (a : Int) >> b;

	@:op(A >>> B) static inline function ushr(a:Int8, b:Int):Int
		return (a : Int) >>> b;

	@:op(-A) static inline function neg(a:Int8):Int
		return -(a : Int);

	@:op(~A) static inline function not(a:Int8):Int
		return ~(a : Int);

	@:op(A == B) @:commutative static inline function eq(a:Int8, b:Int):Bool
		return (a : Int) == b;

	@:op(A != B) @:commutative static inline function ne(a:Int8, b:Int):Bool
		return (a : Int) != b;

	@:op(A < B) static inline function lt(a:Int8, b:Int):Bool
		return (a : Int) < b;

	@:op(A <= B) static inline function le(a:Int8, b:Int):Bool
		return (a : Int) <= b;

	@:op(A > B) static inline function gt(a:Int8, b:Int):Bool
		return (a : Int) > b;

	@:op(A >= B) static inline function ge(a:Int8, b:Int):Bool
		return (a : Int) >= b;

	@:op(A < B) static inline function lt2(a:Int, b:Int8):Bool
		return a < (b : Int);

	@:op(A <= B) static inline function le2(a:Int, b:Int8):Bool
		return a <= (b : Int);

	@:op(A > B) static inline function gt2(a:Int, b:Int8):Bool
		return a > (b : Int);

	@:op(A >= B) static inline function ge2(a:Int, b:Int8):Bool
		return a >= (b : Int);

	public inline function toString():String
		return Std.string((this : Int));
}
