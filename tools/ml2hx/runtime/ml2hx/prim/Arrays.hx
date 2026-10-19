package ml2hx.prim;

import ml2hx.rt.*;

// OCaml's array.c: arrays are Haxe arrays (float arrays too).
class Arrays {
	static inline function i(n:Int63):Int return n.toInt();
	static function size(n:Int63):Int {
		if (Int63.lt(n, Int63.zero) || Int63.gt(n, Int63.ofInt(0x7FFFFFF))) throw new InvalidArgument("Array.make");
		return i(n);
	}

	public static function camlMakeVect<T>(n:Int63, v:T):Array<T> {
		var len = size(n);
		var a = [];
		if (len > 0) a[len - 1] = v;
		for (k in 0...len) a[k] = v;
		return a;
	}
	public static inline function camlArrayMake<T>(n:Int63, v:T):Array<T> return camlMakeVect(n, v);
	public static function camlArrayCreateFloat(n:Int63):Array<Float> return camlMakeVect(n, 0.0);
	public static function camlFloatarrayCreate(n:Int63):Array<Float> return camlMakeVect(n, 0.0);
	public static function camlMakeFloatVect(n:Int63):Array<Float> return camlMakeVect(n, 0.0);
	public static function camlFloatarrayMake(n:Int63, v:Float):Array<Float> return camlMakeVect(n, v);
	public static function camlArraySub<T>(a:Array<T>, ofs:Int63, len:Int63):Array<T> return a.slice(i(ofs), i(ofs) + i(len));
	public static function camlFloatarraySub(a:Array<Float>, ofs:Int63, len:Int63):Array<Float> return camlArraySub(a, ofs, len);
	public static function camlArrayAppend<T>(a:Array<T>, b:Array<T>):Array<T> return a.concat(b);
	public static function camlFloatarrayAppend(a:Array<Float>, b:Array<Float>):Array<Float> return a.concat(b);
	public static function camlArrayConcat<T>(l:MlList<Array<T>>):Array<T> {
		var out = [];
		var x = l;
		while (true) switch x {
			case Nil: break;
			case Cons(a, t):
				for (v in a) out.push(v);
				x = t;
		}
		return out;
	}
	public static function camlArrayBlit<T>(src:Array<T>, so:Int63, dst:Array<T>, d:Int63, n:Int63):Unit {
		var s = i(so), o = i(d), len = i(n);
		if (src == dst && s < o) {
			var k = len - 1;
			while (k >= 0) {
				dst[o + k] = src[s + k];
				k--;
			}
		} else for (k in 0...len) dst[o + k] = src[s + k];
		return Unit.value;
	}
	public static function camlFloatarrayBlit(src:Array<Float>, so:Int63, dst:Array<Float>, d:Int63, n:Int63):Unit return camlArrayBlit(src, so, dst, d, n);
	public static function camlArrayFill<T>(a:Array<T>, ofs:Int63, len:Int63, v:T):Unit {
		var o = i(ofs);
		for (k in 0...i(len)) a[o + k] = v;
		return Unit.value;
	}
	public static function camlFloatarrayFill(a:Array<Float>, ofs:Int63, len:Int63, v:Float):Unit return camlArrayFill(a, ofs, len, v);
	public static function camlFloatarrayGet(a:Array<Float>, n:Int63):Float return Runtime.arrayGet(a, i(n));
	public static function camlFloatarraySet(a:Array<Float>, n:Int63, v:Float):Unit return Runtime.arraySet(a, i(n), v);
	public static function camlFloatarrayUnsafeGet(a:Array<Float>, n:Int63):Float return a[i(n)];
	public static function camlFloatarrayUnsafeSet(a:Array<Float>, n:Int63, v:Float):Unit {
		a[i(n)] = v;
		return Unit.value;
	}
}
