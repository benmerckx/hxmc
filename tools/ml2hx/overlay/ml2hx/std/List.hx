package ml2hx.std;

import Array;
import String;
import StdTypes;
import Array as HArray;
import ml2hx.rt.*;
import ml2hx.rt.MlList;
import ml2hx.rt.MlOption;

// Stdlib.List (OCaml 5.2's list.ml): the same results, the same order of
// the calls of the function arguments, the same exceptions. Built front to
// back through an array where OCaml conses in tail-modulo-cons style.
class List {
	static inline function build<T>(a:HArray<T>, tail:MlList<T>):MlList<T> {
		var l = tail;
		var i = a.length;
		while (i > 0) l = Cons(a[--i], l);
		return l;
	}

	static inline function z(c:Int63):Int
		return Int63.compare(c, Int63.zero);

	public static function length<T>(l:MlList<T>):Int63 {
		var n = 0;
		while (true) switch l {
			case Nil: return Int63.ofInt(n);
			case Cons(_, t): n++; l = t;
		}
	}

	public static function compareLengths<A, B>(a:MlList<A>, b:MlList<B>):Int63 {
		while (true) switch [a, b] {
			case [Nil, Nil]: return Int63.zero;
			case [Nil, _]: return Int63.minusOne;
			case [_, Nil]: return Int63.one;
			case [Cons(_, x), Cons(_, y)]: a = x; b = y;
		}
	}

	public static function compareLengthWith<T>(l:MlList<T>, n:Int63):Int63 {
		var k = n;
		while (true) switch l {
			case Nil: return Int63.eq(k, Int63.zero) ? Int63.zero : (Int63.gt(k, Int63.zero) ? Int63.minusOne : Int63.one);
			case Cons(_, t):
				if (Int63.le(k, Int63.zero)) return Int63.one;
				k = Int63.pred(k);
				l = t;
		}
	}

	public static inline function cons<T>(a:T, l:MlList<T>):MlList<T>
		return Cons(a, l);

	public static function isEmpty<T>(l:MlList<T>):Bool
		return l == Nil || switch l { case Nil: true; case _: false; };

	public static function hd<T>(l:MlList<T>):T {
		return switch l {
			case Nil: throw new Failure("hd");
			case Cons(a, _): a;
		}
	}

	public static function tl<T>(l:MlList<T>):MlList<T> {
		return switch l {
			case Nil: throw new Failure("tl");
			case Cons(_, t): t;
		}
	}

	public static function nth<T>(l:MlList<T>, n:Int63):T {
		if (Int63.lt(n, Int63.zero)) throw new InvalidArgument("List.nth");
		var k = n;
		while (true) switch l {
			case Nil: throw new Failure("nth");
			case Cons(a, t):
				if (Int63.eq(k, Int63.zero)) return a;
				k = Int63.pred(k);
				l = t;
		}
	}

	public static function nthOpt<T>(l:MlList<T>, n:Int63):MlOption<T> {
		if (Int63.lt(n, Int63.zero)) throw new InvalidArgument("List.nth");
		var k = n;
		while (true) switch l {
			case Nil: return None;
			case Cons(a, t):
				if (Int63.eq(k, Int63.zero)) return Some(a);
				k = Int63.pred(k);
				l = t;
		}
	}

	public static function append<T>(a:MlList<T>, b:MlList<T>):MlList<T> {
		if (b == Nil) return a;
		var items = [];
		while (true) switch a {
			case Nil: break;
			case Cons(x, t): items.push(x); a = t;
		}
		return build(items, b);
	}

	public static function revAppend<T>(a:MlList<T>, b:MlList<T>):MlList<T> {
		while (true) switch a {
			case Nil: return b;
			case Cons(x, t): b = Cons(x, b); a = t;
		}
	}

	public static inline function rev<T>(l:MlList<T>):MlList<T>
		return revAppend(l, Nil);

	public static function init<T>(len:Int63, f:Int63->T):MlList<T> {
		if (Int63.lt(len, Int63.zero)) throw new InvalidArgument("List.init");
		var n = len.toInt();
		var items = [];
		for (i in 0...n) items.push(f(Int63.ofInt(i)));
		return build(items, Nil);
	}

	public static function flatten<T>(l:MlList<MlList<T>>):MlList<T> {
		var items = [];
		while (true) switch l {
			case Nil: break;
			case Cons(x, t):
				var y = x;
				while (true) switch y {
					case Nil: break;
					case Cons(v, r): items.push(v); y = r;
				}
				l = t;
		}
		return build(items, Nil);
	}

	public static inline function concat<T>(l:MlList<MlList<T>>):MlList<T>
		return flatten(l);

	public static function map<A, B>(f:A->B, l:MlList<A>):MlList<B> {
		switch l {
			case Nil: return Nil;
			case Cons(a, Nil): return Cons(f(a), Nil);
			case _:
		}
		var items = [];
		while (true) switch l {
			case Nil: break;
			case Cons(a, t): items.push(f(a)); l = t;
		}
		return build(items, Nil);
	}

	public static function mapi<A, B>(f:(Int63, A) -> B, l:MlList<A>):MlList<B> {
		var items = [];
		var i = 0;
		while (true) switch l {
			case Nil: break;
			case Cons(a, t): items.push(f(Int63.ofInt(i++), a)); l = t;
		}
		return build(items, Nil);
	}

	public static function revMap<A, B>(f:A->B, l:MlList<A>):MlList<B> {
		var acc = Nil;
		while (true) switch l {
			case Nil: return acc;
			case Cons(a, t): acc = Cons(f(a), acc); l = t;
		}
	}

	public static function iter<A>(f:A->Unit, l:MlList<A>):Unit {
		while (true) switch l {
			case Nil: return Unit.value;
			case Cons(a, t): f(a); l = t;
		}
	}

	public static function iteri<A>(f:(Int63, A) -> Unit, l:MlList<A>):Unit {
		var i = 0;
		while (true) switch l {
			case Nil: return Unit.value;
			case Cons(a, t): f(Int63.ofInt(i++), a); l = t;
		}
	}

	public static function foldLeft<A, B>(f:(A, B) -> A, acc:A, l:MlList<B>):A {
		while (true) switch l {
			case Nil: return acc;
			case Cons(a, t): acc = f(acc, a); l = t;
		}
	}

	public static function foldRight<A, B>(f:(A, B) -> B, l:MlList<A>, acc:B):B {
		var items = toArray(l);
		var i = items.length;
		while (i > 0) acc = f(items[--i], acc);
		return acc;
	}

	public static function map2<A, B, C>(f:(A, B) -> C, a:MlList<A>, b:MlList<B>):MlList<C> {
		var items = [];
		while (true) switch [a, b] {
			case [Nil, Nil]: return build(items, Nil);
			case [Cons(x, Nil), Cons(y, Nil)]:
				items.push(f(x, y));
				return build(items, Nil);
			case [Cons(x1, Cons(x2, xs)), Cons(y1, Cons(y2, ys))]:
				items.push(f(x1, y1));
				items.push(f(x2, y2));
				a = xs;
				b = ys;
			case _: throw new InvalidArgument("List.map2");
		}
	}

	public static function revMap2<A, B, C>(f:(A, B) -> C, a:MlList<A>, b:MlList<B>):MlList<C> {
		var acc = Nil;
		while (true) switch [a, b] {
			case [Nil, Nil]: return acc;
			case [Cons(x, xs), Cons(y, ys)]: acc = Cons(f(x, y), acc); a = xs; b = ys;
			case _: throw new InvalidArgument("List.rev_map2");
		}
	}

	public static function iter2<A, B>(f:(A, B) -> Unit, a:MlList<A>, b:MlList<B>):Unit {
		while (true) switch [a, b] {
			case [Nil, Nil]: return Unit.value;
			case [Cons(x, xs), Cons(y, ys)]: f(x, y); a = xs; b = ys;
			case _: throw new InvalidArgument("List.iter2");
		}
	}

	public static function foldLeft2<A, B, C>(f:(A, B, C) -> A, acc:A, a:MlList<B>, b:MlList<C>):A {
		while (true) switch [a, b] {
			case [Nil, Nil]: return acc;
			case [Cons(x, xs), Cons(y, ys)]: acc = f(acc, x, y); a = xs; b = ys;
			case _: throw new InvalidArgument("List.fold_left2");
		}
	}

	public static function foldRight2<A, B, C>(f:(A, B, C) -> C, a:MlList<A>, b:MlList<B>, acc:C):C {
		// the lengths are checked as the recursion descends: before any call
		var xs = [], ys = [];
		while (true) switch [a, b] {
			case [Nil, Nil]: break;
			case [Cons(x, xr), Cons(y, yr)]: xs.push(x); ys.push(y); a = xr; b = yr;
			case _: throw new InvalidArgument("List.fold_right2");
		}
		var i = xs.length;
		while (i > 0) {
			i--;
			acc = f(xs[i], ys[i], acc);
		}
		return acc;
	}

	public static function forAll<A>(p:A->Bool, l:MlList<A>):Bool {
		while (true) switch l {
			case Nil: return true;
			case Cons(a, t): if (!p(a)) return false; l = t;
		}
	}

	public static function exists<A>(p:A->Bool, l:MlList<A>):Bool {
		while (true) switch l {
			case Nil: return false;
			case Cons(a, t): if (p(a)) return true; l = t;
		}
	}

	public static function forAll2<A, B>(p:(A, B) -> Bool, a:MlList<A>, b:MlList<B>):Bool {
		while (true) switch [a, b] {
			case [Nil, Nil]: return true;
			case [Cons(x, xs), Cons(y, ys)]: if (!p(x, y)) return false; a = xs; b = ys;
			case _: throw new InvalidArgument("List.for_all2");
		}
	}

	public static function exists2<A, B>(p:(A, B) -> Bool, a:MlList<A>, b:MlList<B>):Bool {
		while (true) switch [a, b] {
			case [Nil, Nil]: return false;
			case [Cons(x, xs), Cons(y, ys)]: if (p(x, y)) return true; a = xs; b = ys;
			case _: throw new InvalidArgument("List.exists2");
		}
	}

	public static function mem<A>(x:A, l:MlList<A>):Bool {
		while (true) switch l {
			case Nil: return false;
			case Cons(a, t): if (Poly.compare(a, x) == 0) return true; l = t;
		}
	}

	public static function memq<A>(x:A, l:MlList<A>):Bool {
		while (true) switch l {
			case Nil: return false;
			case Cons(a, t): if (Stdlib.opPhysEq(a, x)) return true; l = t;
		}
	}

	public static function assoc<A, B>(x:A, l:MlList<Tuple2<A, B>>):B {
		while (true) switch l {
			case Nil: throw NotFound.instance;
			case Cons(p, t): if (Poly.compare(p.v0, x) == 0) return p.v1; l = t;
		}
	}

	public static function assocOpt<A, B>(x:A, l:MlList<Tuple2<A, B>>):MlOption<B> {
		while (true) switch l {
			case Nil: return None;
			case Cons(p, t): if (Poly.compare(p.v0, x) == 0) return Some(p.v1); l = t;
		}
	}

	public static function assq<A, B>(x:A, l:MlList<Tuple2<A, B>>):B {
		while (true) switch l {
			case Nil: throw NotFound.instance;
			case Cons(p, t): if (Stdlib.opPhysEq(p.v0, x)) return p.v1; l = t;
		}
	}

	public static function assqOpt<A, B>(x:A, l:MlList<Tuple2<A, B>>):MlOption<B> {
		while (true) switch l {
			case Nil: return None;
			case Cons(p, t): if (Stdlib.opPhysEq(p.v0, x)) return Some(p.v1); l = t;
		}
	}

	public static function memAssoc<A, B>(x:A, l:MlList<Tuple2<A, B>>):Bool {
		while (true) switch l {
			case Nil: return false;
			case Cons(p, t): if (Poly.compare(p.v0, x) == 0) return true; l = t;
		}
	}

	public static function memAssq<A, B>(x:A, l:MlList<Tuple2<A, B>>):Bool {
		while (true) switch l {
			case Nil: return false;
			case Cons(p, t): if (Stdlib.opPhysEq(p.v0, x)) return true; l = t;
		}
	}

	public static function removeAssoc<A, B>(x:A, l:MlList<Tuple2<A, B>>):MlList<Tuple2<A, B>> {
		var items = [];
		while (true) switch l {
			case Nil: return build(items, Nil);
			case Cons(p, t):
				if (Poly.compare(p.v0, x) == 0) return build(items, t);
				items.push(p);
				l = t;
		}
	}

	public static function removeAssq<A, B>(x:A, l:MlList<Tuple2<A, B>>):MlList<Tuple2<A, B>> {
		var items = [];
		while (true) switch l {
			case Nil: return build(items, Nil);
			case Cons(p, t):
				if (Stdlib.opPhysEq(p.v0, x)) return build(items, t);
				items.push(p);
				l = t;
		}
	}

	public static function find<A>(p:A->Bool, l:MlList<A>):A {
		while (true) switch l {
			case Nil: throw NotFound.instance;
			case Cons(a, t): if (p(a)) return a; l = t;
		}
	}

	public static function findOpt<A>(p:A->Bool, l:MlList<A>):MlOption<A> {
		while (true) switch l {
			case Nil: return None;
			case Cons(a, t): if (p(a)) return Some(a); l = t;
		}
	}

	public static function findIndex<A>(p:A->Bool, l:MlList<A>):MlOption<Int63> {
		var i = 0;
		while (true) switch l {
			case Nil: return None;
			case Cons(a, t): if (p(a)) return Some(Int63.ofInt(i)); i++; l = t;
		}
	}

	public static function findMap<A, B>(f:A->MlOption<B>, l:MlList<A>):MlOption<B> {
		while (true) switch l {
			case Nil: return None;
			case Cons(a, t):
				var r = f(a);
				switch r {
					case Some(_): return r;
					case None: l = t;
				}
		}
	}

	public static function findMapi<A, B>(f:(Int63, A) -> MlOption<B>, l:MlList<A>):MlOption<B> {
		var i = 0;
		while (true) switch l {
			case Nil: return None;
			case Cons(a, t):
				var r = f(Int63.ofInt(i++), a);
				switch r {
					case Some(_): return r;
					case None: l = t;
				}
		}
	}

	public static function findAll<A>(p:A->Bool, l:MlList<A>):MlList<A> {
		var items = [];
		while (true) switch l {
			case Nil: return build(items, Nil);
			case Cons(a, t): if (p(a)) items.push(a); l = t;
		}
	}

	public static inline function filter<A>(p:A->Bool, l:MlList<A>):MlList<A>
		return findAll(p, l);

	public static function filteri<A>(p:(Int63, A) -> Bool, l:MlList<A>):MlList<A> {
		var items = [];
		var i = 0;
		while (true) switch l {
			case Nil: return build(items, Nil);
			case Cons(a, t): if (p(Int63.ofInt(i++), a)) items.push(a); l = t;
		}
	}

	public static function filterMap<A, B>(f:A->MlOption<B>, l:MlList<A>):MlList<B> {
		var items = [];
		while (true) switch l {
			case Nil: return build(items, Nil);
			case Cons(a, t):
				switch f(a) {
					case Some(v): items.push(v);
					case None:
				}
				l = t;
		}
	}

	public static function concatMap<A, B>(f:A->MlList<B>, l:MlList<A>):MlList<B> {
		var items = [];
		while (true) switch l {
			case Nil: return build(items, Nil);
			case Cons(a, t):
				var ys = f(a);
				while (true) switch ys {
					case Nil: break;
					case Cons(y, r): items.push(y); ys = r;
				}
				l = t;
		}
	}

	public static function foldLeftMap<A, B, C>(f:(A, B) -> Tuple2<A, C>, acc:A, l:MlList<B>):Tuple2<A, MlList<C>> {
		var items = [];
		while (true) switch l {
			case Nil: return new Tuple2(acc, build(items, Nil));
			case Cons(x, t):
				var r = f(acc, x);
				acc = r.v0;
				items.push(r.v1);
				l = t;
		}
	}

	public static function partition<A>(p:A->Bool, l:MlList<A>):Tuple2<MlList<A>, MlList<A>> {
		var yes = [], no = [];
		while (true) switch l {
			case Nil: return new Tuple2(build(yes, Nil), build(no, Nil));
			case Cons(x, t): if (p(x)) yes.push(x) else no.push(x); l = t;
		}
	}

	public static function split<A, B>(l:MlList<Tuple2<A, B>>):Tuple2<MlList<A>, MlList<B>> {
		var xs = [], ys = [];
		while (true) switch l {
			case Nil: return new Tuple2(build(xs, Nil), build(ys, Nil));
			case Cons(p, t): xs.push(p.v0); ys.push(p.v1); l = t;
		}
	}

	public static function combine<A, B>(a:MlList<A>, b:MlList<B>):MlList<Tuple2<A, B>> {
		var items = [];
		while (true) switch [a, b] {
			case [Nil, Nil]: return build(items, Nil);
			case [Cons(x, xs), Cons(y, ys)]: items.push(new Tuple2(x, y)); a = xs; b = ys;
			case _: throw new InvalidArgument("List.combine");
		}
	}

	public static function merge<A>(cmp:(A, A) -> Int63, a:MlList<A>, b:MlList<A>):MlList<A> {
		var items = [];
		while (true) switch [a, b] {
			case [Nil, _]: return build(items, b);
			case [_, Nil]: return build(items, a);
			case [Cons(h1, t1), Cons(h2, t2)]:
				if (z(cmp(h1, h2)) <= 0) {
					items.push(h1);
					a = t1;
				} else {
					items.push(h2);
					b = t2;
				}
		}
	}

	// stable_sort, exactly OCaml's merge sort (the same comparisons in the same order)
	public static function stableSort<A>(cmp:(A, A) -> Int63, l:MlList<A>):MlList<A> {
		inline function le(x:A, y:A):Bool
			return z(cmp(x, y)) <= 0;
		inline function gt(x:A, y:A):Bool
			return z(cmp(x, y)) > 0;
		function revMerge(l1:MlList<A>, l2:MlList<A>, accu:MlList<A>):MlList<A> {
			while (true) switch [l1, l2] {
				case [Nil, _]: return revAppend(l2, accu);
				case [_, Nil]: return revAppend(l1, accu);
				case [Cons(h1, t1), Cons(h2, t2)]:
					if (le(h1, h2)) {
						accu = Cons(h1, accu);
						l1 = t1;
					} else {
						accu = Cons(h2, accu);
						l2 = t2;
					}
			}
		}
		function revMergeRev(l1:MlList<A>, l2:MlList<A>, accu:MlList<A>):MlList<A> {
			while (true) switch [l1, l2] {
				case [Nil, _]: return revAppend(l2, accu);
				case [_, Nil]: return revAppend(l1, accu);
				case [Cons(h1, t1), Cons(h2, t2)]:
					if (gt(h1, h2)) {
						accu = Cons(h1, accu);
						l1 = t1;
					} else {
						accu = Cons(h2, accu);
						l2 = t2;
					}
			}
		}
		var rest:MlList<A> = Nil;
		var sort:(Int, MlList<A>) -> MlList<A> = null;
		var revSort:(Int, MlList<A>) -> MlList<A> = null;
		sort = function(n:Int, l:MlList<A>):MlList<A> {
			if (n == 2) switch l {
				case Cons(x1, Cons(x2, tl)):
					rest = tl;
					return le(x1, x2) ? Cons(x1, Cons(x2, Nil)) : Cons(x2, Cons(x1, Nil));
				case _:
			}
			if (n == 3) switch l {
				case Cons(x1, Cons(x2, Cons(x3, tl))):
					rest = tl;
					return if (le(x1, x2)) {
						if (le(x2, x3)) Cons(x1, Cons(x2, Cons(x3, Nil))) else if (le(x1, x3)) Cons(x1, Cons(x3, Cons(x2, Nil))) else
							Cons(x3, Cons(x1, Cons(x2, Nil)));
					} else if (le(x1, x3)) Cons(x2, Cons(x1, Cons(x3, Nil))) else if (le(x2, x3)) Cons(x2, Cons(x3, Cons(x1, Nil))) else
						Cons(x3, Cons(x2, Cons(x1, Nil)));
				case _:
			}
			var n1 = n >> 1;
			var n2 = n - n1;
			var s1 = revSort(n1, l);
			var s2 = revSort(n2, rest);
			return revMergeRev(s1, s2, Nil);
		}
		revSort = function(n:Int, l:MlList<A>):MlList<A> {
			if (n == 2) switch l {
				case Cons(x1, Cons(x2, tl)):
					rest = tl;
					return gt(x1, x2) ? Cons(x1, Cons(x2, Nil)) : Cons(x2, Cons(x1, Nil));
				case _:
			}
			if (n == 3) switch l {
				case Cons(x1, Cons(x2, Cons(x3, tl))):
					rest = tl;
					return if (gt(x1, x2)) {
						if (gt(x2, x3)) Cons(x1, Cons(x2, Cons(x3, Nil))) else if (gt(x1, x3)) Cons(x1, Cons(x3, Cons(x2, Nil))) else
							Cons(x3, Cons(x1, Cons(x2, Nil)));
					} else if (gt(x1, x3)) Cons(x2, Cons(x1, Cons(x3, Nil))) else if (gt(x2, x3)) Cons(x2, Cons(x3, Cons(x1, Nil))) else
						Cons(x3, Cons(x2, Cons(x1, Nil)));
				case _:
			}
			var n1 = n >> 1;
			var n2 = n - n1;
			var s1 = sort(n1, l);
			var s2 = sort(n2, rest);
			return revMerge(s1, s2, Nil);
		}
		var len = length(l).toInt();
		if (len < 2) return l;
		return sort(len, l);
	}

	public static inline function sort<A>(cmp:(A, A) -> Int63, l:MlList<A>):MlList<A>
		return stableSort(cmp, l);

	public static inline function fastSort<A>(cmp:(A, A) -> Int63, l:MlList<A>):MlList<A>
		return stableSort(cmp, l);

	// sort_uniq through the stable sort, keeping the first of equal runs (OCaml
	// keeps the first of each pair compared equal: the same elements)
	public static function sortUniq<A>(cmp:(A, A) -> Int63, l:MlList<A>):MlList<A> {
		var s = toArray(stableSort(cmp, l));
		var items = [];
		for (x in s) if (items.length == 0 || z(cmp(items[items.length - 1], x)) != 0) items.push(x);
		return build(items, Nil);
	}

	public static function equal<A>(eq:(A, A) -> Bool, a:MlList<A>, b:MlList<A>):Bool {
		while (true) switch [a, b] {
			case [Nil, Nil]: return true;
			case [Cons(x, xs), Cons(y, ys)]: if (!eq(x, y)) return false; a = xs; b = ys;
			case _: return false;
		}
	}

	public static function compare<A>(cmp:(A, A) -> Int63, a:MlList<A>, b:MlList<A>):Int63 {
		while (true) switch [a, b] {
			case [Nil, Nil]: return Int63.zero;
			case [Nil, _]: return Int63.minusOne;
			case [_, Nil]: return Int63.one;
			case [Cons(x, xs), Cons(y, ys)]:
				var c = cmp(x, y);
				if (z(c) != 0) return c;
				a = xs;
				b = ys;
		}
	}

	public static function toSeq<A>(l:MlList<A>):Seq.SeqT<A> {
		return function(_:Unit):Seq.SeqNode<A> {
			return switch l {
				case Nil: Seq.SeqNode.Nil;
				case Cons(x, t): Seq.SeqNode.Cons(x, toSeq(t));
			}
		}
	}

	public static function ofSeq<A>(s:Seq.SeqT<A>):MlList<A> {
		var items = [];
		while (true) switch s(Unit.value) {
			case Seq.SeqNode.Nil: return build(items, Nil);
			case Seq.SeqNode.Cons(x, next): items.push(x); s = next;
		}
	}

	// ---- for the runtime

	public static function toArray<A>(l:MlList<A>):HArray<A> {
		var a = [];
		while (true) switch l {
			case Nil: return a;
			case Cons(x, t): a.push(x); l = t;
		}
	}

	public static inline function ofArray<A>(a:HArray<A>):MlList<A>
		return build(a, Nil);
}
