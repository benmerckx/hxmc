package hxmc;

import haxe.Int64;

// hxmc.I64 on the targets other than hxmc: haxe.Int64 with I64's operators
// and toInt, so that a kernel's 64-bit integers (hxmc.unsafe.Int64, a span's
// Int64 elements) compile there too.
abstract I64(Int64) from Int64 to Int64 {
	@:from static inline function ofInt(v:Int):I64
		return Int64.ofInt(v);

	// the low 32 bits
	public inline function toInt():Int
		return Int64.toInt(this);

	@:op(a + b) static inline function add(a:I64, b:I64):I64
		return Int64.add(a, b);

	@:op(a - b) static inline function sub(a:I64, b:I64):I64
		return Int64.sub(a, b);

	@:op(a * b) static inline function mul(a:I64, b:I64):I64
		return Int64.mul(a, b);

	@:op(a / b) static inline function div(a:I64, b:I64):I64
		return Int64.div(a, b);

	@:op(a % b) static inline function mod(a:I64, b:I64):I64
		return Int64.mod(a, b);

	@:op(a << b) static inline function shl(a:I64, b:Int):I64
		return Int64.shl(a, b);

	@:op(a >> b) static inline function shr(a:I64, b:Int):I64
		return Int64.shr(a, b);

	@:op(a >>> b) static inline function ushr(a:I64, b:Int):I64
		return Int64.ushr(a, b);

	@:op(a | b) static inline function or(a:I64, b:I64):I64
		return Int64.or(a, b);

	@:op(a & b) static inline function and(a:I64, b:I64):I64
		return Int64.and(a, b);

	@:op(a ^ b) static inline function xor(a:I64, b:I64):I64
		return Int64.xor(a, b);

	@:op(-a) static inline function neg(a:I64):I64
		return Int64.neg(a);

	@:op(~a) static inline function compl(a:I64):I64
		return Int64.xor(a, Int64.make(-1, -1));

	@:op(a == b) static inline function eq(a:I64, b:I64):Bool
		return Int64.eq(a, b);

	@:op(a != b) static inline function neq(a:I64, b:I64):Bool
		return Int64.neq(a, b);

	@:op(a < b) static inline function lt(a:I64, b:I64):Bool
		return Int64.compare(a, b) < 0;

	@:op(a <= b) static inline function lte(a:I64, b:I64):Bool
		return Int64.compare(a, b) <= 0;

	@:op(a > b) static inline function gt(a:I64, b:I64):Bool
		return Int64.compare(a, b) > 0;

	@:op(a >= b) static inline function gte(a:I64, b:I64):Bool
		return Int64.compare(a, b) >= 0;

	public inline function toString():String
		return Int64.toStr(this);
}
