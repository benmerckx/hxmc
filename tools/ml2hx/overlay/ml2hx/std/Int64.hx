package ml2hx.std;

import Array;
import String;
import StdTypes;
import haxe.Int64 as I64;
import ml2hx.rt.*;

// Stdlib.Int64: 64-bit wrapping integers (haxe.Int64).
class Int64 {
	public static final zero:I64 = I64.ofInt(0);
	public static final one:I64 = I64.ofInt(1);
	public static final minusOne:I64 = I64.ofInt(-1);
	public static final maxInt:I64 = I64.make(0x7FFFFFFF, 0xFFFFFFFF);
	public static final minInt:I64 = I64.make(0x80000000, 0);

	public static inline function neg(a:I64):I64 return -a;
	public static inline function add(a:I64, b:I64):I64 return a + b;
	public static inline function sub(a:I64, b:I64):I64 return a - b;
	public static inline function mul(a:I64, b:I64):I64 return a * b;
	public static function div(a:I64, b:I64):I64 {
		if (b == 0) throw DivisionByZero.instance;
		if (b == -1) return -a;
		return I64.div(a, b);
	}
	public static function rem(a:I64, b:I64):I64 {
		if (b == 0) throw DivisionByZero.instance;
		if (b == -1) return 0;
		return I64.mod(a, b);
	}
	// unsigned division by halves (Hacker's Delight 9-3)
	public static function unsignedDiv(n:I64, d:I64):I64 {
		if (d == 0) throw DivisionByZero.instance;
		if (d < 0) return unsignedCompareRaw(n, d) < 0 ? 0 : 1;
		var q = I64.shl(I64.div(I64.ushr(n, 1), d), 1);
		var r = n - q * d;
		return unsignedCompareRaw(r, d) >= 0 ? q + 1 : q;
	}
	public static function unsignedRem(n:I64, d:I64):I64 return n - unsignedDiv(n, d) * d;
	public static inline function succ(a:I64):I64 return a + 1;
	public static inline function pred(a:I64):I64 return a - 1;
	public static inline function abs(a:I64):I64 return a < 0 ? -a : a;
	public static inline function logand(a:I64, b:I64):I64 return a & b;
	public static inline function logor(a:I64, b:I64):I64 return a | b;
	public static inline function logxor(a:I64, b:I64):I64 return a ^ b;
	public static inline function lognot(a:I64):I64 return ~a;
	public static inline function shiftLeft(a:I64, n:Int63):I64 return I64.shl(a, n.toInt() & 63);
	public static inline function shiftRight(a:I64, n:Int63):I64 return I64.shr(a, n.toInt() & 63);
	public static inline function shiftRightLogical(a:I64, n:Int63):I64 return I64.ushr(a, n.toInt() & 63);
	public static inline function ofInt(n:Int63):I64 return n.toInt64();
	public static inline function toInt(a:I64):Int63 return Int63.ofInt64(a);
	public static function unsignedToInt(a:I64):MlOption<Int63> return (a < 0 || a > Int63.maxInt.toInt64()) ? None : Some(Int63.ofInt64(a));
	public static inline function ofInt32(a:haxe.Int32):I64 return I64.ofInt(a);
	public static inline function toInt32(a:I64):haxe.Int32 return a.low;
	public static inline function ofNativeint(a:Int):I64 return I64.ofInt(a);
	public static inline function toNativeint(a:I64):Int return a.low;
	public static inline function ofFloat(f:Float):I64 return Float64.toInt64(f);
	public static inline function toFloat(a:I64):Float return Float64.ofInt64(a);
	public static function ofString(s:String):I64 return Stdlib.parseIntnat(s, 64, "Int64.of_string");
	public static function ofStringOpt(s:String):MlOption<I64> {
		return try Some(ofString(s)) catch (e:Failure) None;
	}
	public static inline function toString(a:I64):String return I64.toStr(a);
	public static inline function bitsOfFloat(f:Float):I64 return haxe.io.FPHelper.doubleToI64(f);
	public static inline function floatOfBits(a:I64):Float return haxe.io.FPHelper.i64ToDouble(a.low, a.high);
	public static inline function compare(a:I64, b:I64):Int63 return Int63.ofInt(I64.compare(a, b));
	static inline function unsignedCompareRaw(a:I64, b:I64):Int return I64.compare(a ^ minInt, b ^ minInt);
	public static function unsignedCompare(a:I64, b:I64):Int63 return Int63.ofInt(unsignedCompareRaw(a, b));
	public static inline function equal(a:I64, b:I64):Bool return a == b;
	public static inline function min(a:I64, b:I64):I64 return a <= b ? a : b;
	public static inline function max(a:I64, b:I64):I64 return a >= b ? a : b;
}
