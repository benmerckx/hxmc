package hxmc.unsafe;

// C's int16_t: an Int holding the value of a 16-bit signed integer (docs/interop.md,
// "C interop"). Arithmetic is Int's; converting an Int back wraps, as C's
// conversion does. In memory (Ptr<Int16>, @:hxmc.struct fields) and in calls
// of C functions it takes 2 bytes.
abstract Int16(Int) to Int {
	inline function new(v:Int)
		this = v;

	@:from public static inline function ofInt(v:Int):Int16
		return new Int16((v << 16) >> 16);

	// Int's operators (the result is an Int)
	@:op(A + B) @:commutative static inline function add(a:Int16, b:Int):Int
		return (a : Int) + b;

	@:op(A - B) static inline function sub(a:Int16, b:Int):Int
		return (a : Int) - b;

	@:op(A - B) static inline function subFrom(a:Int, b:Int16):Int
		return a - (b : Int);

	@:op(A * B) @:commutative static inline function mul(a:Int16, b:Int):Int
		return (a : Int) * b;

	@:op(A / B) static inline function div(a:Int16, b:Int):Float
		return (a : Int) / b;

	@:op(A % B) static inline function mod(a:Int16, b:Int):Int
		return (a : Int) % b;

	@:op(A & B) @:commutative static inline function and(a:Int16, b:Int):Int
		return (a : Int) & b;

	@:op(A | B) @:commutative static inline function or(a:Int16, b:Int):Int
		return (a : Int) | b;

	@:op(A ^ B) @:commutative static inline function xor(a:Int16, b:Int):Int
		return (a : Int) ^ b;

	@:op(A << B) static inline function shl(a:Int16, b:Int):Int
		return (a : Int) << b;

	@:op(A >> B) static inline function shr(a:Int16, b:Int):Int
		return (a : Int) >> b;

	@:op(A >>> B) static inline function ushr(a:Int16, b:Int):Int
		return (a : Int) >>> b;

	@:op(-A) static inline function neg(a:Int16):Int
		return -(a : Int);

	@:op(~A) static inline function not(a:Int16):Int
		return ~(a : Int);

	@:op(A == B) @:commutative static inline function eq(a:Int16, b:Int):Bool
		return (a : Int) == b;

	@:op(A != B) @:commutative static inline function ne(a:Int16, b:Int):Bool
		return (a : Int) != b;

	@:op(A < B) static inline function lt(a:Int16, b:Int):Bool
		return (a : Int) < b;

	@:op(A <= B) static inline function le(a:Int16, b:Int):Bool
		return (a : Int) <= b;

	@:op(A > B) static inline function gt(a:Int16, b:Int):Bool
		return (a : Int) > b;

	@:op(A >= B) static inline function ge(a:Int16, b:Int):Bool
		return (a : Int) >= b;

	@:op(A < B) static inline function lt2(a:Int, b:Int16):Bool
		return a < (b : Int);

	@:op(A <= B) static inline function le2(a:Int, b:Int16):Bool
		return a <= (b : Int);

	@:op(A > B) static inline function gt2(a:Int, b:Int16):Bool
		return a > (b : Int);

	@:op(A >= B) static inline function ge2(a:Int, b:Int16):Bool
		return a >= (b : Int);

	public inline function toString():String
		return Std.string((this : Int));
}
