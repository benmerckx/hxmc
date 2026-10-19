package ml2hx.std;

import String;
import StdTypes;
import Array as A;
import ml2hx.rt.*;
import ml2hx.rt.MlList;
import ml2hx.rt.MlOption;

// Stdlib.Array over Haxe arrays (OCaml 5.2's array.ml; sort is its heap
// sort and stable_sort its merge sort, comparison for comparison)
class Array {
	static inline function oob():Dynamic
		throw new InvalidArgument("index out of bounds");

	public static inline function length<T>(a:A<T>):Int63
		return Int63.ofInt(a.length);

	public static function get<T>(a:A<T>, i:Int63):T {
		var k = i.toInt();
		if (!i.isInt() || k < 0 || k >= a.length) oob();
		return a[k];
	}

	public static function set<T>(a:A<T>, i:Int63, v:T):Unit {
		var k = i.toInt();
		if (!i.isInt() || k < 0 || k >= a.length) oob();
		a[k] = v;
		return Unit.value;
	}

	public static inline function unsafeGet<T>(a:A<T>, i:Int63):T
		return a[i.toInt()];

	public static inline function unsafeSet<T>(a:A<T>, i:Int63, v:T):Unit {
		a[i.toInt()] = v;
		return Unit.value;
	}

	public static function make<T>(n:Int63, v:T):A<T> {
		if (Int63.lt(n, Int63.zero)) throw new InvalidArgument("Array.make");
		var k = n.toInt();
		var a = [];
		a.resize(k);
		for (i in 0...k) a[i] = v;
		return a;
	}

	public static inline function create<T>(n:Int63, v:T):A<T>
		return make(n, v);

	public static function init<T>(n:Int63, f:Int63->T):A<T> {
		if (Int63.lt(n, Int63.zero)) throw new InvalidArgument("Array.init");
		var k = n.toInt();
		var a = [];
		for (i in 0...k) a.push(f(Int63.ofInt(i)));
		return a;
	}

	public static function makeMatrix<T>(x:Int63, y:Int63, v:T):A<A<T>> {
		var r = make(x, (null : A<T>));
		for (i in 0...r.length) r[i] = make(y, v);
		return r;
	}

	public static function append<T>(a:A<T>, b:A<T>):A<T>
		return a.concat(b);

	public static function concat<T>(l:MlList<A<T>>):A<T> {
		var r = [];
		while (true) switch l {
			case Nil: return r;
			case Cons(a, t):
				for (x in a) r.push(x);
				l = t;
		}
	}

	public static function sub<T>(a:A<T>, ofs:Int63, len:Int63):A<T> {
		var o = ofs.toInt(), n = len.toInt();
		if (Int63.lt(ofs, Int63.zero) || Int63.lt(len, Int63.zero) || o > a.length - n) throw new InvalidArgument("Array.sub");
		return a.slice(o, o + n);
	}

	public static inline function copy<T>(a:A<T>):A<T>
		return a.copy();

	public static function fill<T>(a:A<T>, ofs:Int63, len:Int63, v:T):Unit {
		var o = ofs.toInt(), n = len.toInt();
		if (Int63.lt(ofs, Int63.zero) || Int63.lt(len, Int63.zero) || o > a.length - n) throw new InvalidArgument("Array.fill");
		for (i in o...o + n) a[i] = v;
		return Unit.value;
	}

	public static function blit<T>(src:A<T>, srcOfs:Int63, dst:A<T>, dstOfs:Int63, len:Int63):Unit {
		var s = srcOfs.toInt(), d = dstOfs.toInt(), n = len.toInt();
		if (Int63.lt(len, Int63.zero) || Int63.lt(srcOfs, Int63.zero) || s > src.length - n || Int63.lt(dstOfs, Int63.zero) || d > dst.length - n)
			throw new InvalidArgument("Array.blit");
		if (src == dst && s < d) {
			var i = n;
			while (i > 0) {
				i--;
				dst[d + i] = src[s + i];
			}
		} else
			for (i in 0...n) dst[d + i] = src[s + i];
		return Unit.value;
	}

	public static function toList<T>(a:A<T>):MlList<T>
		return List.ofArray(a);

	public static function ofList<T>(l:MlList<T>):A<T>
		return List.toArray(l);

	public static function iter<T>(f:T->Unit, a:A<T>):Unit {
		for (i in 0...a.length) f(a[i]);
		return Unit.value;
	}

	public static function iteri<T>(f:(Int63, T) -> Unit, a:A<T>):Unit {
		for (i in 0...a.length) f(Int63.ofInt(i), a[i]);
		return Unit.value;
	}

	public static function map<T, U>(f:T->U, a:A<T>):A<U> {
		var r = [];
		for (i in 0...a.length) r.push(f(a[i]));
		return r;
	}

	public static function mapi<T, U>(f:(Int63, T) -> U, a:A<T>):A<U> {
		var r = [];
		for (i in 0...a.length) r.push(f(Int63.ofInt(i), a[i]));
		return r;
	}

	public static function foldLeft<Acc, T>(f:(Acc, T) -> Acc, acc:Acc, a:A<T>):Acc {
		for (i in 0...a.length) acc = f(acc, a[i]);
		return acc;
	}

	public static function foldRight<T, Acc>(f:(T, Acc) -> Acc, a:A<T>, acc:Acc):Acc {
		var i = a.length;
		while (i > 0) acc = f(a[--i], acc);
		return acc;
	}

	public static function iter2<T, U>(f:(T, U) -> Unit, a:A<T>, b:A<U>):Unit {
		if (a.length != b.length) throw new InvalidArgument("Array.iter2: arrays must have the same length");
		for (i in 0...a.length) f(a[i], b[i]);
		return Unit.value;
	}

	public static function map2<T, U, V>(f:(T, U) -> V, a:A<T>, b:A<U>):A<V> {
		if (a.length != b.length) throw new InvalidArgument("Array.map2: arrays must have the same length");
		return [for (i in 0...a.length) f(a[i], b[i])];
	}

	public static function forAll<T>(p:T->Bool, a:A<T>):Bool {
		for (x in a) if (!p(x)) return false;
		return true;
	}

	public static function exists<T>(p:T->Bool, a:A<T>):Bool {
		for (x in a) if (p(x)) return true;
		return false;
	}

	public static function mem<T>(x:T, a:A<T>):Bool {
		for (y in a) if (Poly.compare(y, x) == 0) return true;
		return false;
	}

	public static function memq<T>(x:T, a:A<T>):Bool {
		for (y in a) if (Stdlib.opPhysEq(y, x)) return true;
		return false;
	}

	public static function findOpt<T>(p:T->Bool, a:A<T>):MlOption<T> {
		for (x in a) if (p(x)) return Some(x);
		return None;
	}

	public static function findMap<T, U>(f:T->MlOption<U>, a:A<T>):MlOption<U> {
		for (x in a) {
			var r = f(x);
			switch r {
				case Some(_): return r;
				case None:
			}
		}
		return None;
	}

	public static function toSeq<T>(a:A<T>):Seq.SeqT<T> {
		function aux(i:Int):Seq.SeqT<T>
			return _ -> i < a.length ? Seq.SeqNode.Cons(a[i], aux(i + 1)) : Seq.SeqNode.Nil;
		return aux(0);
	}

	public static function ofSeq<T>(s:Seq.SeqT<T>):A<T> {
		var r = [];
		while (true) switch s(Unit.value) {
			case Seq.SeqNode.Nil: return r;
			case Seq.SeqNode.Cons(x, next): r.push(x); s = next;
		}
	}

	static inline function z(c:Int63):Int
		return Int63.compare(c, Int63.zero);

	public static function sort<T>(cmp:(T, T) -> Int63, a:A<T>):Unit {
		inline function get(i:Int):T
			return a[i];
		inline function set(i:Int, v:T)
			a[i] = v;
		// maxson: -1 - i for OCaml's Bottom i
		function maxson(l:Int, i:Int):Int {
			var i31 = i + i + i + 1;
			var x = i31;
			if (i31 + 2 < l) {
				if (z(cmp(get(i31), get(i31 + 1))) < 0) x = i31 + 1;
				if (z(cmp(get(x), get(i31 + 2))) < 0) x = i31 + 2;
				return x;
			}
			if (i31 + 1 < l && z(cmp(get(i31), get(i31 + 1))) < 0) return i31 + 1;
			if (i31 < l) return i31;
			return -1 - i;
		}
		function trickle(l:Int, i:Int, e:T) {
			while (true) {
				var j = maxson(l, i);
				if (j < 0) {
					set(-1 - j, e);
					return;
				}
				if (z(cmp(get(j), e)) > 0) {
					set(i, get(j));
					i = j;
				} else {
					set(i, e);
					return;
				}
			}
		}
		function bubble(l:Int, i:Int):Int {
			while (true) {
				var j = maxson(l, i);
				if (j < 0) return -1 - j;
				set(i, get(j));
				i = j;
			}
		}
		function trickleup(i:Int, e:T) {
			while (true) {
				var father = Std.int((i - 1) / 3);
				if (i == father) throw new AssertFailure("array.ml", Int63.ofInt(0), Int63.ofInt(0));
				if (z(cmp(get(father), e)) < 0) {
					set(i, get(father));
					if (father > 0) i = father else {
						set(0, e);
						return;
					}
				} else {
					set(i, e);
					return;
				}
			}
		}
		var l = a.length;
		var i = Std.int((l + 1) / 3) - 1;
		while (i >= 0) {
			trickle(l, i, get(i));
			i--;
		}
		var i = l - 1;
		while (i >= 2) {
			var e = get(i);
			set(i, get(0));
			trickleup(bubble(i, 0), e);
			i--;
		}
		if (l > 1) {
			var e = get(1);
			set(1, get(0));
			set(0, e);
		}
		return Unit.value;
	}

	public static function stableSort<T>(cmp:(T, T) -> Int63, a:A<T>):Unit {
		var cutoff = 5;
		function merge(src1ofs:Int, src1len:Int, src2:A<T>, src2ofs:Int, src2len:Int, dst:A<T>, dstofs:Int) {
			var src1r = src1ofs + src1len, src2r = src2ofs + src2len;
			var i1 = src1ofs, s1 = a[src1ofs], i2 = src2ofs, s2 = src2[src2ofs], d = dstofs;
			while (true) {
				if (z(cmp(s1, s2)) <= 0) {
					dst[d] = s1;
					i1++;
					if (i1 < src1r) {
						s1 = a[i1];
						d++;
					} else {
						for (k in 0...src2r - i2) dst[d + 1 + k] = src2[i2 + k];
						return;
					}
				} else {
					dst[d] = s2;
					i2++;
					if (i2 < src2r) {
						s2 = src2[i2];
						d++;
					} else {
						for (k in 0...src1r - i1) dst[d + 1 + k] = a[i1 + k];
						return;
					}
				}
			}
		}
		function isortto(srcofs:Int, dst:A<T>, dstofs:Int, len:Int) {
			for (i in 0...len) {
				var e = a[srcofs + i];
				var j = dstofs + i - 1;
				while (j >= dstofs && z(cmp(dst[j], e)) > 0) {
					dst[j + 1] = dst[j];
					j--;
				}
				dst[j + 1] = e;
			}
		}
		var sortto:(Int, A<T>, Int, Int) -> Void = null;
		sortto = function(srcofs:Int, dst:A<T>, dstofs:Int, len:Int) {
			if (len <= cutoff) isortto(srcofs, dst, dstofs, len) else {
				var l1 = Std.int(len / 2);
				var l2 = len - l1;
				sortto(srcofs + l1, dst, dstofs + l1, l2);
				sortto(srcofs, a, srcofs + l2, l1);
				merge(srcofs + l2, l1, dst, dstofs + l1, l2, dst, dstofs);
			}
		}
		var l = a.length;
		if (l <= cutoff) isortto(0, a, 0, l) else {
			var l1 = Std.int(l / 2);
			var l2 = l - l1;
			var t = [for (_ in 0...l2) a[0]];
			sortto(l1, t, 0, l2);
			sortto(0, a, l2, l1);
			merge(l2, l1, t, 0, l2, a, 0);
		}
		return Unit.value;
	}

	public static inline function fastSort<T>(cmp:(T, T) -> Int63, a:A<T>):Unit
		return stableSort(cmp, a);
}
