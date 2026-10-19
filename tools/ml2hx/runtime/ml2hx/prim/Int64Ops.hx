package ml2hx.prim;

import haxe.Int64;
import ml2hx.rt.*;

// Int64 operations with OCaml's semantics, for the runtime's own modules
// (the integers package's stand-ins).
class Int64Ops {
	public static final zero:Int64 = Int64.ofInt(0);
	public static final one:Int64 = Int64.ofInt(1);
	public static final minusOne:Int64 = Int64.ofInt(-1);
	public static final maxInt:Int64 = Int64.make(0x7FFFFFFF, 0xFFFFFFFF);
	public static final minInt:Int64 = Int64.make(0x80000000, 0);
	public static inline function add(a:Int64, b:Int64):Int64 return a + b;
	public static inline function sub(a:Int64, b:Int64):Int64 return a - b;
	public static inline function mul(a:Int64, b:Int64):Int64 return a * b;
	public static inline function div(a:Int64, b:Int64):Int64 return Builtin.int64Div(a, b);
	public static inline function rem(a:Int64, b:Int64):Int64 return Builtin.int64Mod(a, b);
	public static inline function succ(a:Int64):Int64 return a + 1;
	public static inline function pred(a:Int64):Int64 return a - 1;
	public static inline function neg(a:Int64):Int64 return -a;
	public static inline function abs(a:Int64):Int64 return a < 0 ? -a : a;
	public static inline function logand(a:Int64, b:Int64):Int64 return a & b;
	public static inline function logor(a:Int64, b:Int64):Int64 return a | b;
	public static inline function logxor(a:Int64, b:Int64):Int64 return a ^ b;
	public static inline function lognot(a:Int64):Int64 return ~a;
	public static inline function shiftLeft(a:Int64, n:Int63):Int64 return Builtin.int64Lsl(a, n);
	public static inline function shiftRight(a:Int64, n:Int63):Int64 return Builtin.int64Asr(a, n);
	public static inline function shiftRightLogical(a:Int64, n:Int63):Int64 return Builtin.int64Lsr(a, n);
	public static inline function ofInt(n:Int63):Int64 return n.toInt64();
	public static inline function toInt(a:Int64):Int63 return Int63.ofInt64(a);
	public static function ofString(s:String):Int64 return Ints.parse(s, 64, "Int64.of_string");
	public static function toString(a:Int64):String return Int64.toStr(a);
	public static function compare(a:Int64, b:Int64):Int63 return Int63.ofInt(Int64.compare(a, b) < 0 ? -1 : Int64.compare(a, b) > 0 ? 1 : 0);
	public static inline function max(a:Int64, b:Int64):Int64 return Int64.compare(a, b) >= 0 ? a : b;
	public static inline function min(a:Int64, b:Int64):Int64 return Int64.compare(a, b) <= 0 ? a : b;
	public static function unsignedCompare(a:Int64, b:Int64):Int63 {
		var c = Int64.ucompare(a, b);
		return Int63.ofInt(c < 0 ? -1 : c > 0 ? 1 : 0);
	}
	// Int64.unsigned_div and unsigned_rem
	public static function unsignedDiv(n:Int64, d:Int64):Int64 {
		if (d < 0) return Int64.ucompare(n, d) < 0 ? zero : one;
		var q = Builtin.int64Div(n >>> 1, d) << 1;
		var r = n - q * d;
		return Int64.ucompare(r, d) >= 0 ? q + 1 : q;
	}
	public static function unsignedRem(n:Int64, d:Int64):Int64 return n - unsignedDiv(n, d) * d;
}
