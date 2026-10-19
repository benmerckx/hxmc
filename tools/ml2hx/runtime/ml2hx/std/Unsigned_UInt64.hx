package ml2hx.std;

import Array;
import String;
import StdTypes;
import haxe.Int64 as I64;
import ml2hx.rt.*;

// integers' Unsigned.UInt64: the bits of a 64-bit unsigned integer in an Int64.
typedef UnsignedUInt64T = I64;

class Unsigned_UInt64 {
	static inline function norm(a:I64):I64 return a;
	public static final zero:I64 = I64.ofInt(0);
	public static final one:I64 = I64.ofInt(1);
	public static final maxInt:I64 = I64.make(0xFFFFFFFF, 0xFFFFFFFF);
	public static inline function add(a:I64, b:I64):I64 return norm(a + b);
	public static inline function sub(a:I64, b:I64):I64 return norm(a - b);
	public static inline function mul(a:I64, b:I64):I64 return norm(a * b);
	public static inline function div(a:I64, b:I64):I64 return ml2hx.prim.Int64Ops.unsignedDiv(a, b);
	public static inline function rem(a:I64, b:I64):I64 return ml2hx.prim.Int64Ops.unsignedRem(a, b);
	public static inline function succ(a:I64):I64 return norm(a + 1);
	public static inline function pred(a:I64):I64 return norm(a - 1);
	public static inline function logand(a:I64, b:I64):I64 return a & b;
	public static inline function logor(a:I64, b:I64):I64 return a | b;
	public static inline function logxor(a:I64, b:I64):I64 return a ^ b;
	public static inline function lognot(a:I64):I64 return norm(~a);
	public static inline function shiftLeft(a:I64, n:Int63):I64 return norm(I64.shl(a, n.toInt()));
	public static inline function shiftRight(a:I64, n:Int63):I64 return I64.ushr(a, n.toInt());
	public static inline function ofInt(n:Int63):I64 return norm(n.toInt64());
	public static inline function toInt(a:I64):Int63 return Int63.ofInt64(a);
	public static inline function ofInt64(a:I64):I64 return norm(a);
	public static inline function toInt64(a:I64):I64 return a;
	public static inline function toUint32(a:I64):I64 return I64.make(0, a.low);
	public static inline function ofUint32(a:I64):I64 return a;
	public static inline function toInt32(a:I64):haxe.Int32 return a.low;
	public static inline function compare(a:I64, b:I64):Int63 return ml2hx.prim.Int64Ops.unsignedCompare(a, b);
	public static inline function equal(a:I64, b:I64):Bool return a == b;
	public static inline function max(a:I64, b:I64):I64 return ml2hx.prim.Int64Ops.unsignedCompare(a, b).toInt() >= 0 ? a : b;
	public static inline function min(a:I64, b:I64):I64 return ml2hx.prim.Int64Ops.unsignedCompare(a, b).toInt() <= 0 ? a : b;
	public static function toString(a:I64):String {
		if (I64.compare(a, 0) >= 0) return I64.toStr(a);
		var q = ml2hx.prim.Int64Ops.unsignedDiv(a, 10), r = a - q * 10;
		return I64.toStr(q) + I64.toStr(r);
	}
	public static function ofString(s:String):I64 return norm(ml2hx.prim.Ints.parse(s, 64, "Unsigned.of_string"));
}
