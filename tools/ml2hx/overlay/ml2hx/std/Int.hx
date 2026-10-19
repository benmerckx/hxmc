package ml2hx.std;

import String;
import StdTypes;
import ml2hx.rt.*;

// Stdlib.Int over Int63.
class Int {
	public static final zero:Int63 = Int63.zero;
	public static final one:Int63 = Int63.one;
	public static final minusOne:Int63 = Int63.minusOne;
	public static final maxInt:Int63 = Int63.maxInt;
	public static final minInt:Int63 = Int63.minInt;
	public static inline function neg(a:Int63):Int63 return Int63.neg(a);
	public static inline function add(a:Int63, b:Int63):Int63 return Int63.add(a, b);
	public static inline function sub(a:Int63, b:Int63):Int63 return Int63.sub(a, b);
	public static inline function mul(a:Int63, b:Int63):Int63 return Int63.mul(a, b);
	public static inline function div(a:Int63, b:Int63):Int63 return Int63.div(a, b);
	public static inline function rem(a:Int63, b:Int63):Int63 return Int63.mod(a, b);
	public static inline function succ(a:Int63):Int63 return Int63.succ(a);
	public static inline function pred(a:Int63):Int63 return Int63.pred(a);
	public static inline function abs(a:Int63):Int63 return Int63.abs(a);
	public static inline function logand(a:Int63, b:Int63):Int63 return Int63.logand(a, b);
	public static inline function logor(a:Int63, b:Int63):Int63 return Int63.logor(a, b);
	public static inline function logxor(a:Int63, b:Int63):Int63 return Int63.logxor(a, b);
	public static inline function lognot(a:Int63):Int63 return Int63.lognot(a);
	public static inline function shiftLeft(a:Int63, n:Int63):Int63 return Int63.shiftLeft(a, n);
	public static inline function shiftRight(a:Int63, n:Int63):Int63 return Int63.shiftRight(a, n);
	public static inline function shiftRightLogical(a:Int63, n:Int63):Int63 return Int63.shiftRightLogical(a, n);
	public static inline function equal(a:Int63, b:Int63):Bool return Int63.eq(a, b);
	public static inline function compare(a:Int63, b:Int63):Int63 return Int63.ofInt(Int63.compare(a, b));
	public static inline function min(a:Int63, b:Int63):Int63 return Int63.min(a, b);
	public static inline function max(a:Int63, b:Int63):Int63 return Int63.max(a, b);
	public static inline function toFloat(a:Int63):Float return Int63.toFloat(a);
	public static inline function ofFloat(f:Float):Int63 return Int63.ofFloat(f);
	public static inline function toString(a:Int63):String return a.toString();
	public static function hash(a:Int63):Int63 return Int63.ofInt(Poly.hashParam(10, 100, 0, a));
	public static function seededHash(seed:Int63, a:Int63):Int63 return Int63.ofInt(Poly.hashParam(10, 100, seed.toInt(), a));
}
