package hxmc.unsafe;

// C's uint16_t: an Int holding the value of a 16-bit unsigned integer (docs/interop.md,
// "C interop"). Arithmetic is Int's; converting an Int back wraps, as C's
// conversion does. In memory (Ptr<UInt16>, @:hxmc.struct fields) and in calls
// of C functions it takes 2 bytes.
abstract UInt16(Int) to Int {
	inline function new(v:Int)
		this = v;

	@:from public static inline function ofInt(v:Int):UInt16
		return new UInt16(v & 0xFFFF);

	// Int's operators (the result is an Int)
	@:op(A + B) @:commutative static inline function add(a:UInt16, b:Int):Int
		return (a : Int) + b;

	@:op(A - B) static inline function sub(a:UInt16, b:Int):Int
		return (a : Int) - b;

	@:op(A - B) static inline function subFrom(a:Int, b:UInt16):Int
		return a - (b : Int);

	@:op(A * B) @:commutative static inline function mul(a:UInt16, b:Int):Int
		return (a : Int) * b;

	@:op(A / B) static inline function div(a:UInt16, b:Int):Float
		return (a : Int) / b;

	@:op(A % B) static inline function mod(a:UInt16, b:Int):Int
		return (a : Int) % b;

	@:op(A & B) @:commutative static inline function and(a:UInt16, b:Int):Int
		return (a : Int) & b;

	@:op(A | B) @:commutative static inline function or(a:UInt16, b:Int):Int
		return (a : Int) | b;

	@:op(A ^ B) @:commutative static inline function xor(a:UInt16, b:Int):Int
		return (a : Int) ^ b;

	@:op(A << B) static inline function shl(a:UInt16, b:Int):Int
		return (a : Int) << b;

	@:op(A >> B) static inline function shr(a:UInt16, b:Int):Int
		return (a : Int) >> b;

	@:op(A >>> B) static inline function ushr(a:UInt16, b:Int):Int
		return (a : Int) >>> b;

	@:op(-A) static inline function neg(a:UInt16):Int
		return -(a : Int);

	@:op(~A) static inline function not(a:UInt16):Int
		return ~(a : Int);

	@:op(A == B) @:commutative static inline function eq(a:UInt16, b:Int):Bool
		return (a : Int) == b;

	@:op(A != B) @:commutative static inline function ne(a:UInt16, b:Int):Bool
		return (a : Int) != b;

	@:op(A < B) static inline function lt(a:UInt16, b:Int):Bool
		return (a : Int) < b;

	@:op(A <= B) static inline function le(a:UInt16, b:Int):Bool
		return (a : Int) <= b;

	@:op(A > B) static inline function gt(a:UInt16, b:Int):Bool
		return (a : Int) > b;

	@:op(A >= B) static inline function ge(a:UInt16, b:Int):Bool
		return (a : Int) >= b;

	@:op(A < B) static inline function lt2(a:Int, b:UInt16):Bool
		return a < (b : Int);

	@:op(A <= B) static inline function le2(a:Int, b:UInt16):Bool
		return a <= (b : Int);

	@:op(A > B) static inline function gt2(a:Int, b:UInt16):Bool
		return a > (b : Int);

	@:op(A >= B) static inline function ge2(a:Int, b:UInt16):Bool
		return a >= (b : Int);

	public inline function toString():String
		return Std.string((this : Int));
}
