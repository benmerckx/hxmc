package hxmc.unsafe;

import hxmc.I64;

// C's uint64_t (and size_t): the 64 bits of an I64 read as unsigned
// (docs/interop.md, "C interop"). Arithmetic is I64's (wrapping, the same
// bits); comparisons and division are unsigned.
abstract UInt64(I64) from I64 to I64 {
	// the low 32 bits
	public inline function toInt():Int
		return (this : I64).toInt();

	@:from static inline function ofInt(v:Int):UInt64
		return (v : I64); // (sign-extended, as C converts)

	@:op(a < b) static inline function lt(a:UInt64, b:UInt64):Bool
		return Mem.ult(a, b);

	@:op(a > b) static inline function gt(a:UInt64, b:UInt64):Bool
		return Mem.ult(b, a);

	@:op(a <= b) static inline function le(a:UInt64, b:UInt64):Bool
		return !Mem.ult(b, a);

	@:op(a >= b) static inline function ge(a:UInt64, b:UInt64):Bool
		return !Mem.ult(a, b);

	// (b not 0: a division by 0 traps, as I64's)
	@:op(a / b) static inline function div(a:UInt64, b:UInt64):UInt64
		return Mem.udiv(a, b);

	@:op(a % b) static inline function mod(a:UInt64, b:UInt64):UInt64
		return Mem.urem(a, b);
}
