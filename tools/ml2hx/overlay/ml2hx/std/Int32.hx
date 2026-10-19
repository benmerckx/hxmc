package ml2hx.std;

import Array;
import String;
import StdTypes;
import haxe.Int64;
import ml2hx.rt.*;

// Stdlib.Int32: 32-bit wrapping integers (haxe.Int32).
class Int32 {
	public static final zero:haxe.Int32 = 0;
	public static final one:haxe.Int32 = 1;
	public static final minusOne:haxe.Int32 = -1;
	public static final maxInt:haxe.Int32 = 0x7FFFFFFF;
	public static final minInt:haxe.Int32 = 0x80000000;

	public static inline function neg(a:haxe.Int32):haxe.Int32 return -a;
	public static inline function add(a:haxe.Int32, b:haxe.Int32):haxe.Int32 return a + b;
	public static inline function sub(a:haxe.Int32, b:haxe.Int32):haxe.Int32 return a - b;
	public static inline function mul(a:haxe.Int32, b:haxe.Int32):haxe.Int32 return a * b;
	public static function div(a:haxe.Int32, b:haxe.Int32):haxe.Int32 {
		if (b == 0) throw DivisionByZero.instance;
		if (b == -1) return -a;
		return Int64.toInt(Int64.div(Int64.ofInt(a), Int64.ofInt(b)));
	}
	public static function rem(a:haxe.Int32, b:haxe.Int32):haxe.Int32 {
		if (b == 0) throw DivisionByZero.instance;
		if (b == -1) return 0;
		return Int64.toInt(Int64.mod(Int64.ofInt(a), Int64.ofInt(b)));
	}
	static inline function unsigned(a:haxe.Int32):Int64 return Int64.make(0, a);
	public static function unsignedDiv(a:haxe.Int32, b:haxe.Int32):haxe.Int32 {
		if (b == 0) throw DivisionByZero.instance;
		return Int64.toInt(Int64.div(unsigned(a), unsigned(b)));
	}
	public static function unsignedRem(a:haxe.Int32, b:haxe.Int32):haxe.Int32 {
		if (b == 0) throw DivisionByZero.instance;
		return Int64.toInt(Int64.mod(unsigned(a), unsigned(b)));
	}
	public static inline function succ(a:haxe.Int32):haxe.Int32 return a + 1;
	public static inline function pred(a:haxe.Int32):haxe.Int32 return a - 1;
	public static inline function abs(a:haxe.Int32):haxe.Int32 return a < 0 ? -a : a;
	public static inline function logand(a:haxe.Int32, b:haxe.Int32):haxe.Int32 return a & b;
	public static inline function logor(a:haxe.Int32, b:haxe.Int32):haxe.Int32 return a | b;
	public static inline function logxor(a:haxe.Int32, b:haxe.Int32):haxe.Int32 return a ^ b;
	public static inline function lognot(a:haxe.Int32):haxe.Int32 return ~a;
	public static inline function shiftLeft(a:haxe.Int32, n:Int63):haxe.Int32 return a << (n.toInt() & 31);
	public static inline function shiftRight(a:haxe.Int32, n:Int63):haxe.Int32 return a >> (n.toInt() & 31);
	public static inline function shiftRightLogical(a:haxe.Int32, n:Int63):haxe.Int32 return a >>> (n.toInt() & 31);
	public static inline function ofInt(n:Int63):haxe.Int32 return n.toInt();
	public static inline function toInt(a:haxe.Int32):Int63 return Int63.ofInt(a);
	public static function unsignedToInt(a:haxe.Int32):MlOption<Int63> return Some(Int63.ofInt64(unsigned(a)));
	public static function ofFloat(f:Float):haxe.Int32 return Int64.toInt(Float64.toInt64(f));
	public static inline function toFloat(a:haxe.Int32):Float return (a : Int);
	public static function ofString(s:String):haxe.Int32 return Int64.toInt(Stdlib.parseIntnat(s, 32, "Int32.of_string"));
	public static function ofStringOpt(s:String):MlOption<haxe.Int32> {
		return try Some(ofString(s)) catch (e:Failure) None;
	}
	public static inline function toString(a:haxe.Int32):String return Std.string((a : Int));
	public static inline function bitsOfFloat(f:Float):haxe.Int32 return haxe.io.FPHelper.floatToI32(f);
	public static inline function floatOfBits(a:haxe.Int32):Float return haxe.io.FPHelper.i32ToFloat(a);
	public static inline function compare(a:haxe.Int32, b:haxe.Int32):Int63 return Int63.ofInt(a < b ? -1 : a > b ? 1 : 0);
	public static function unsignedCompare(a:haxe.Int32, b:haxe.Int32):Int63 return compare(a - 0x80000000, b - 0x80000000);
	public static inline function equal(a:haxe.Int32, b:haxe.Int32):Bool return a == b;
	public static inline function min(a:haxe.Int32, b:haxe.Int32):haxe.Int32 return a <= b ? a : b;
	public static inline function max(a:haxe.Int32, b:haxe.Int32):haxe.Int32 return a >= b ? a : b;
}
