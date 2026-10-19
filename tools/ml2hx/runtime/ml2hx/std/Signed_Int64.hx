package ml2hx.std;

import Array;
import String;
import StdTypes;
import haxe.Int64 as I64;
import ml2hx.rt.*;

// integers' Signed.Int64: Stdlib.Int64's operations.
typedef SignedInt64T = I64;

class Signed_Int64 {
	public static final zero = ml2hx.prim.Int64Ops.zero;
	public static final one = ml2hx.prim.Int64Ops.one;
	public static final minusOne = ml2hx.prim.Int64Ops.minusOne;
	public static final maxInt = ml2hx.prim.Int64Ops.maxInt;
	public static final minInt = ml2hx.prim.Int64Ops.minInt;
	public static inline function add(a:I64, b:I64):I64 return ml2hx.prim.Int64Ops.add(a, b);
	public static inline function sub(a:I64, b:I64):I64 return ml2hx.prim.Int64Ops.sub(a, b);
	public static inline function mul(a:I64, b:I64):I64 return ml2hx.prim.Int64Ops.mul(a, b);
	public static inline function div(a:I64, b:I64):I64 return ml2hx.prim.Int64Ops.div(a, b);
	public static inline function rem(a:I64, b:I64):I64 return ml2hx.prim.Int64Ops.rem(a, b);
	public static inline function succ(a:I64):I64 return ml2hx.prim.Int64Ops.succ(a);
	public static inline function pred(a:I64):I64 return ml2hx.prim.Int64Ops.pred(a);
	public static inline function neg(a:I64):I64 return ml2hx.prim.Int64Ops.neg(a);
	public static inline function abs(a:I64):I64 return ml2hx.prim.Int64Ops.abs(a);
	public static inline function logand(a:I64, b:I64):I64 return ml2hx.prim.Int64Ops.logand(a, b);
	public static inline function logor(a:I64, b:I64):I64 return ml2hx.prim.Int64Ops.logor(a, b);
	public static inline function logxor(a:I64, b:I64):I64 return ml2hx.prim.Int64Ops.logxor(a, b);
	public static inline function lognot(a:I64):I64 return ml2hx.prim.Int64Ops.lognot(a);
	public static inline function shiftLeft(a:I64, n:Int63):I64 return ml2hx.prim.Int64Ops.shiftLeft(a, n);
	public static inline function shiftRight(a:I64, n:Int63):I64 return ml2hx.prim.Int64Ops.shiftRight(a, n);
	public static inline function shiftRightLogical(a:I64, n:Int63):I64 return ml2hx.prim.Int64Ops.shiftRightLogical(a, n);
	public static inline function ofInt(n:Int63):I64 return ml2hx.prim.Int64Ops.ofInt(n);
	public static inline function toInt(a:I64):Int63 return ml2hx.prim.Int64Ops.toInt(a);
	public static inline function ofInt64(a:I64):I64 return a;
	public static inline function toInt64(a:I64):I64 return a;
	public static inline function ofString(s:String):I64 return ml2hx.prim.Int64Ops.ofString(s);
	public static inline function toString(a:I64):String return ml2hx.prim.Int64Ops.toString(a);
	public static inline function compare(a:I64, b:I64):Int63 return ml2hx.prim.Int64Ops.compare(a, b);
	public static inline function equal(a:I64, b:I64):Bool return a == b;
	public static inline function max(a:I64, b:I64):I64 return ml2hx.prim.Int64Ops.max(a, b);
	public static inline function min(a:I64, b:I64):I64 return ml2hx.prim.Int64Ops.min(a, b);
}
