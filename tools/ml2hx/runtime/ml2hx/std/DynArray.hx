package ml2hx.std;

import Array as HArray;
import String;
import StdTypes;
import ml2hx.rt.*;
import ml2hx.rt.MlList;

// Extlib's DynArray (dynArray.ml): a growable array. The resizer policy
// only affects capacity, which is not observable here (a Haxe Array grows).
class DynArrayT<T> {
	public var arr:HArray<T>;
	public function new(arr:HArray<T>) this.arr = arr;
}

class DynArrayInvalidArg extends MlException {
	public final v0:Int63;
	public final v1:String;
	public final v2:String;
	public function new(v0:Int63, v1:String, v2:String) {
		super();
		this.v0 = v0;
		this.v1 = v1;
		this.v2 = v2;
	}
	override public function exnName():String return "DynArray.Invalid_arg";
	override public function exnArity():Int return 3;
	override public function exnArg(i:Int):Dynamic return switch i { case 0: v0; case 1: v1; case 2: v2; case _: super.exnArg(i); };
}

class DynArray {
	static inline function invalid(i:Int, f:String, p:String):Dynamic throw new DynArrayInvalidArg(Int63.ofInt(i), f, p);

	public static function create<T>(_:Unit):DynArrayT<T> return new DynArrayT<T>([]);
	public static function make<T>(_:Int63):DynArrayT<T> return new DynArrayT<T>([]);
	public static function init<T>(n:Int63, f:Int63->T):DynArrayT<T> {
		var len = n.toInt();
		if (len < 0) invalid(len, "init", "len");
		var a = [];
		for (i in 0...len) a.push(f(Int63.ofInt(i)));
		return new DynArrayT(a);
	}
	public static inline function empty<T>(d:DynArrayT<T>):Bool return d.arr.length == 0;
	public static inline function length<T>(d:DynArrayT<T>):Int63 return Int63.ofInt(d.arr.length);
	public static function get<T>(d:DynArrayT<T>, i:Int63):T {
		var k = i.toInt();
		if (Int63.lt(i, Int63.zero) || k >= d.arr.length) invalid(k, "get", "index");
		return d.arr[k];
	}
	public static inline function unsafeGet<T>(d:DynArrayT<T>, i:Int63):T return d.arr[i.toInt()];
	public static function last<T>(d:DynArrayT<T>):T {
		if (d.arr.length == 0) invalid(0, "last", "<array len is 0>");
		return d.arr[d.arr.length - 1];
	}
	public static function set<T>(d:DynArrayT<T>, i:Int63, v:T):Unit {
		var k = i.toInt();
		if (Int63.lt(i, Int63.zero) || k >= d.arr.length) invalid(k, "set", "index");
		d.arr[k] = v;
		return Unit.value;
	}
	public static inline function unsafeSet<T>(d:DynArrayT<T>, i:Int63, v:T):Unit {
		d.arr[i.toInt()] = v;
		return Unit.value;
	}
	public static function insert<T>(d:DynArrayT<T>, i:Int63, v:T):Unit {
		var k = i.toInt();
		if (Int63.lt(i, Int63.zero) || k > d.arr.length) invalid(k, "insert", "index");
		d.arr.insert(k, v);
		return Unit.value;
	}
	public static inline function add<T>(d:DynArrayT<T>, v:T):Unit {
		d.arr.push(v);
		return Unit.value;
	}
	public static function delete<T>(d:DynArrayT<T>, i:Int63):Unit {
		var k = i.toInt();
		if (Int63.lt(i, Int63.zero) || k >= d.arr.length) invalid(k, "delete", "index");
		d.arr.splice(k, 1);
		return Unit.value;
	}
	public static function deleteRange<T>(d:DynArrayT<T>, i:Int63, n:Int63):Unit {
		var k = i.toInt(), len = n.toInt();
		if (len < 0) invalid(len, "delete_range", "len");
		if (k < 0 || k + len > d.arr.length) invalid(k, "delete_range", "index");
		d.arr.splice(k, len);
		return Unit.value;
	}
	public static function deleteLast<T>(d:DynArrayT<T>):Unit {
		if (d.arr.length <= 0) invalid(0, "delete_last", "<array len is 0>");
		d.arr.pop();
		return Unit.value;
	}
	public static function clear<T>(d:DynArrayT<T>):Unit {
		d.arr = [];
		return Unit.value;
	}
	public static function blit<T>(src:DynArrayT<T>, srcIdx:Int63, dst:DynArrayT<T>, dstIdx:Int63, len:Int63):Unit {
		var s = srcIdx.toInt(), t = dstIdx.toInt(), n = len.toInt();
		if (n < 0) invalid(n, "blit", "len");
		if (s < 0 || s + n > src.arr.length) invalid(s, "blit", "source index");
		if (t < 0 || t > dst.arr.length) invalid(t, "blit", "dest index");
		var copy = src.arr.slice(s, s + n);
		for (i in 0...n) {
			if (t + i < dst.arr.length) dst.arr[t + i] = copy[i]; else dst.arr.push(copy[i]);
		}
		return Unit.value;
	}
	public static function append<T>(src:DynArrayT<T>, dst:DynArrayT<T>):Unit {
		for (x in src.arr.copy()) dst.arr.push(x);
		return Unit.value;
	}
	public static function toList<T>(d:DynArrayT<T>):MlList<T> {
		var l:MlList<T> = Nil, i = d.arr.length;
		while (i > 0) l = Cons(d.arr[--i], l);
		return l;
	}
	public static inline function toArray<T>(d:DynArrayT<T>):HArray<T> return d.arr.copy();
	public static function ofList<T>(l:MlList<T>):DynArrayT<T> {
		var a = [];
		while (true) switch l {
			case Nil: break;
			case Cons(h, t): a.push(h); l = t;
		}
		return new DynArrayT(a);
	}
	public static inline function ofArray<T>(a:HArray<T>):DynArrayT<T> return new DynArrayT(a.copy());
	public static inline function copy<T>(d:DynArrayT<T>):DynArrayT<T> return new DynArrayT(d.arr.copy());
	public static function sub<T>(d:DynArrayT<T>, start:Int63, len:Int63):DynArrayT<T> {
		var s = start.toInt(), n = len.toInt();
		if (n < 0) invalid(n, "sub", "len");
		if (s < 0 || s + n > d.arr.length) invalid(s, "sub", "start");
		return new DynArrayT(d.arr.slice(s, s + n));
	}
	public static function iter<T>(f:T->Unit, d:DynArrayT<T>):Unit {
		var i = 0;
		while (i < d.arr.length) f(d.arr[i++]);
		return Unit.value;
	}
	public static function iteri<T>(f:(Int63, T) -> Unit, d:DynArrayT<T>):Unit {
		var i = 0;
		while (i < d.arr.length) { f(Int63.ofInt(i), d.arr[i]); i++; }
		return Unit.value;
	}
	public static function filter<T>(f:T->Bool, d:DynArrayT<T>):Unit {
		d.arr = [for (x in d.arr) if (f(x)) x];
		return Unit.value;
	}
	public static function indexOf<T>(f:T->Bool, d:DynArrayT<T>):Int63 {
		for (i in 0...d.arr.length) if (f(d.arr[i])) return Int63.ofInt(i);
		throw NotFound.instance;
	}
	public static function map<T, U>(f:T->U, d:DynArrayT<T>):DynArrayT<U> return new DynArrayT([for (x in d.arr) f(x)]);
	public static function mapi<T, U>(f:(Int63, T) -> U, d:DynArrayT<T>):DynArrayT<U> return new DynArrayT([for (i in 0...d.arr.length) f(Int63.ofInt(i), d.arr[i])]);
	public static function foldLeft<A, T>(f:(A, T) -> A, x:A, d:DynArrayT<T>):A {
		var i = 0;
		while (i < d.arr.length) x = f(x, d.arr[i++]);
		return x;
	}
	public static function foldRight<T, A>(f:(T, A) -> A, d:DynArrayT<T>, x:A):A {
		var i = d.arr.length;
		while (i > 0) x = f(d.arr[--i], x);
		return x;
	}
}
