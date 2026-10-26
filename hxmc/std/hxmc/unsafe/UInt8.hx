package hxmc.unsafe;

// C's uint8_t: an Int holding the value of an 8-bit unsigned integer (docs/interop.md,
// "C interop"). Arithmetic is Int's; converting an Int back wraps, as C's
// conversion does. In memory (Ptr<UInt8>, @:hxmc.struct fields) and in calls
// of C functions it takes 1 byte.
abstract UInt8(Int) to Int {
	inline function new(v:Int)
		this = v;

	@:from public static inline function ofInt(v:Int):UInt8
		return new UInt8(v & 0xFF);

	// Int's operators (the result is an Int)
	@:op(A + B) @:commutative static inline function add(a:UInt8, b:Int):Int
		return (a : Int) + b;

	@:op(A - B) static inline function sub(a:UInt8, b:Int):Int
		return (a : Int) - b;

	@:op(A - B) static inline function subFrom(a:Int, b:UInt8):Int
		return a - (b : Int);

	@:op(A * B) @:commutative static inline function mul(a:UInt8, b:Int):Int
		return (a : Int) * b;

	@:op(A / B) static inline function div(a:UInt8, b:Int):Float
		return (a : Int) / b;

	@:op(A % B) static inline function mod(a:UInt8, b:Int):Int
		return (a : Int) % b;

	@:op(A & B) @:commutative static inline function and(a:UInt8, b:Int):Int
		return (a : Int) & b;

	@:op(A | B) @:commutative static inline function or(a:UInt8, b:Int):Int
		return (a : Int) | b;

	@:op(A ^ B) @:commutative static inline function xor(a:UInt8, b:Int):Int
		return (a : Int) ^ b;

	@:op(A << B) static inline function shl(a:UInt8, b:Int):Int
		return (a : Int) << b;

	@:op(A >> B) static inline function shr(a:UInt8, b:Int):Int
		return (a : Int) >> b;

	@:op(A >>> B) static inline function ushr(a:UInt8, b:Int):Int
		return (a : Int) >>> b;

	@:op(-A) static inline function neg(a:UInt8):Int
		return -(a : Int);

	@:op(~A) static inline function not(a:UInt8):Int
		return ~(a : Int);

	@:op(A == B) @:commutative static inline function eq(a:UInt8, b:Int):Bool
		return (a : Int) == b;

	@:op(A != B) @:commutative static inline function ne(a:UInt8, b:Int):Bool
		return (a : Int) != b;

	@:op(A < B) static inline function lt(a:UInt8, b:Int):Bool
		return (a : Int) < b;

	@:op(A <= B) static inline function le(a:UInt8, b:Int):Bool
		return (a : Int) <= b;

	@:op(A > B) static inline function gt(a:UInt8, b:Int):Bool
		return (a : Int) > b;

	@:op(A >= B) static inline function ge(a:UInt8, b:Int):Bool
		return (a : Int) >= b;

	@:op(A < B) static inline function lt2(a:Int, b:UInt8):Bool
		return a < (b : Int);

	@:op(A <= B) static inline function le2(a:Int, b:UInt8):Bool
		return a <= (b : Int);

	@:op(A > B) static inline function gt2(a:Int, b:UInt8):Bool
		return a > (b : Int);

	@:op(A >= B) static inline function ge2(a:Int, b:UInt8):Bool
		return a >= (b : Int);

	public inline function toString():String
		return Std.string((this : Int));
}
