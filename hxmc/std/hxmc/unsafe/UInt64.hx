package hxmc.unsafe;

import hxmc.I64;

// C's uint64_t (and size_t): the 64 bits of an I64 read as unsigned
// (docs/plans/lowlevel.md, "C interop"). Arithmetic is I64's (wrapping, the same
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
}
