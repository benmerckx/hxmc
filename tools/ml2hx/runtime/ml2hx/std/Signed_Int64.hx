package ml2hx.std;

import Array;
import String;
import StdTypes;
import haxe.Int64 as I64;
import ml2hx.rt.*;

// integers' Signed.Int64: Stdlib.Int64's operations.
typedef SignedInt64T = I64;

class Signed_Int64 {
	public static final zero = Int64.zero;
	public static final one = Int64.one;
	public static final minusOne = Int64.minusOne;
	public static final maxInt = Int64.maxInt;
	public static final minInt = Int64.minInt;
	public static inline function add(a:I64, b:I64):I64 return Int64.add(a, b);
	public static inline function sub(a:I64, b:I64):I64 return Int64.sub(a, b);
	public static inline function mul(a:I64, b:I64):I64 return Int64.mul(a, b);
	public static inline function div(a:I64, b:I64):I64 return Int64.div(a, b);
	public static inline function rem(a:I64, b:I64):I64 return Int64.rem(a, b);
	public static inline function succ(a:I64):I64 return Int64.succ(a);
	public static inline function pred(a:I64):I64 return Int64.pred(a);
	public static inline function neg(a:I64):I64 return Int64.neg(a);
	public static inline function abs(a:I64):I64 return Int64.abs(a);
	public static inline function logand(a:I64, b:I64):I64 return Int64.logand(a, b);
	public static inline function logor(a:I64, b:I64):I64 return Int64.logor(a, b);
	public static inline function logxor(a:I64, b:I64):I64 return Int64.logxor(a, b);
	public static inline function lognot(a:I64):I64 return Int64.lognot(a);
	public static inline function shiftLeft(a:I64, n:Int63):I64 return Int64.shiftLeft(a, n);
	public static inline function shiftRight(a:I64, n:Int63):I64 return Int64.shiftRight(a, n);
	public static inline function shiftRightLogical(a:I64, n:Int63):I64 return Int64.shiftRightLogical(a, n);
	public static inline function ofInt(n:Int63):I64 return Int64.ofInt(n);
	public static inline function toInt(a:I64):Int63 return Int64.toInt(a);
	public static inline function ofInt64(a:I64):I64 return a;
	public static inline function toInt64(a:I64):I64 return a;
	public static inline function ofString(s:String):I64 return Int64.ofString(s);
	public static inline function toString(a:I64):String return Int64.toString(a);
	public static inline function compare(a:I64, b:I64):Int63 return Int64.compare(a, b);
	public static inline function equal(a:I64, b:I64):Bool return a == b;
	public static inline function max(a:I64, b:I64):I64 return Int64.max(a, b);
	public static inline function min(a:I64, b:I64):I64 return Int64.min(a, b);
}
