package ml2hx.std;

import Array;
import String;
import StdTypes;
import ml2hx.rt.*;
import ml2hx.rt.MlList;
import ml2hx.rt.MlOption;

// a node of Set.Make(Ord).t; the empty set is null
class SetNode<E> implements Block {
	public final l:Null<SetNode<E>>;
	public final v:E;
	public final r:Null<SetNode<E>>;
	public final h:Int;

	public inline function new(l, v, r, h) {
		this.l = l;
		this.v = v;
		this.r = r;
		this.h = h;
	}

	public function blockTag():Int
		return 0;

	public function blockSize():Int
		return 4;

	public function blockField(i:Int):Dynamic
		return switch i {
			case 0: l;
			case 1: v;
			case 2: r;
			case _: Int63.ofInt(h);
		}
}

typedef SetT<E> = Null<SetNode<E>>;

private enum SetEnumeration<E> {
	End;
	More(v:E, t:SetT<E>, e:SetEnumeration<E>);
}

class Set {
	// the functor Set.Make
	public static function Make<E>(ord:Map.MapOrderedType<E>):SetMake<E>
		return new SetMake(ord);
}

// Set.Make(Ord): OCaml 5.2's set.ml
class SetMake<E> {
	final cmp:(E, E) -> Int63;

	public function new(ord:Map.MapOrderedType<E>)
		cmp = ord.compare;

	inline function c(a:E, b:E):Int
		return Int63.compare(cmp(a, b), Int63.zero);

	static inline function height<E>(s:SetT<E>):Int
		return s == null ? 0 : s.h;

	static inline function create<E>(l:SetT<E>, v:E, r:SetT<E>):SetT<E> {
		var hl = height(l), hr = height(r);
		return new SetNode(l, v, r, hl >= hr ? hl + 1 : hr + 1);
	}

	static function bal<E>(l:SetT<E>, v:E, r:SetT<E>):SetT<E> {
		var hl = height(l), hr = height(r);
		if (hl > hr + 2) {
			if (l == null) throw new InvalidArgument("Set.bal");
			if (height(l.l) >= height(l.r)) return create(l.l, l.v, create(l.r, v, r));
			var lr = l.r;
			if (lr == null) throw new InvalidArgument("Set.bal");
			return create(create(l.l, l.v, lr.l), lr.v, create(lr.r, v, r));
		} else if (hr > hl + 2) {
			if (r == null) throw new InvalidArgument("Set.bal");
			if (height(r.r) >= height(r.l)) return create(create(l, v, r.l), r.v, r.r);
			var rl = r.l;
			if (rl == null) throw new InvalidArgument("Set.bal");
			return create(create(l, v, rl.l), rl.v, create(rl.r, r.v, r.r));
		}
		return new SetNode(l, v, r, hl >= hr ? hl + 1 : hr + 1);
	}

	public function add(x:E, t:SetT<E>):SetT<E> {
		if (t == null) return new SetNode(null, x, null, 1);
		var k = c(x, t.v);
		if (k == 0) return t;
		if (k < 0) {
			var ll = add(x, t.l);
			return t.l == ll ? t : bal(ll, t.v, t.r);
		}
		var rr = add(x, t.r);
		return t.r == rr ? t : bal(t.l, t.v, rr);
	}

	public function singleton(x:E):SetT<E>
		return new SetNode(null, x, null, 1);

	static function addMinElement<E>(x:E, t:SetT<E>):SetT<E>
		return t == null ? new SetNode(null, x, null, 1) : bal(addMinElement(x, t.l), t.v, t.r);

	static function addMaxElement<E>(x:E, t:SetT<E>):SetT<E>
		return t == null ? new SetNode(null, x, null, 1) : bal(t.l, t.v, addMaxElement(x, t.r));

	static function join<E>(l:SetT<E>, v:E, r:SetT<E>):SetT<E> {
		if (l == null) return addMinElement(v, r);
		if (r == null) return addMaxElement(v, l);
		if (l.h > r.h + 2) return bal(l.l, l.v, join(l.r, v, r));
		if (r.h > l.h + 2) return bal(join(l, v, r.l), r.v, r.r);
		return create(l, v, r);
	}

	public function minElt(t:SetT<E>):E {
		if (t == null) throw NotFound.instance;
		while (t.l != null) t = t.l;
		return t.v;
	}

	public function minEltOpt(t:SetT<E>):MlOption<E>
		return t == null ? None : Some(minElt(t));

	public function maxElt(t:SetT<E>):E {
		if (t == null) throw NotFound.instance;
		while (t.r != null) t = t.r;
		return t.v;
	}

	public function maxEltOpt(t:SetT<E>):MlOption<E>
		return t == null ? None : Some(maxElt(t));

	static function removeMinElt<E>(t:SetT<E>):SetT<E> {
		if (t == null) throw new InvalidArgument("Set.remove_min_elt");
		if (t.l == null) return t.r;
		return bal(removeMinElt(t.l), t.v, t.r);
	}

	function merge(t1:SetT<E>, t2:SetT<E>):SetT<E> {
		if (t1 == null) return t2;
		if (t2 == null) return t1;
		return bal(t1, minElt(t2), removeMinElt(t2));
	}

	function concat(t1:SetT<E>, t2:SetT<E>):SetT<E> {
		if (t1 == null) return t2;
		if (t2 == null) return t1;
		return join(t1, minElt(t2), removeMinElt(t2));
	}

	public function split(x:E, t:SetT<E>):Tuple3<SetT<E>, Bool, SetT<E>> {
		if (t == null) return new Tuple3(null, false, null);
		var k = c(x, t.v);
		if (k == 0) return new Tuple3(t.l, true, t.r);
		if (k < 0) {
			var s = split(x, t.l);
			return new Tuple3(s.v0, s.v1, join(s.v2, t.v, t.r));
		}
		var s = split(x, t.r);
		return new Tuple3(join(t.l, t.v, s.v0), s.v1, s.v2);
	}

	public inline function empty():SetT<E>
		return null;

	public inline function isEmpty(t:SetT<E>):Bool
		return t == null;

	public function mem(x:E, t:SetT<E>):Bool {
		while (t != null) {
			var k = c(x, t.v);
			if (k == 0) return true;
			t = k < 0 ? t.l : t.r;
		}
		return false;
	}

	public function remove(x:E, t:SetT<E>):SetT<E> {
		if (t == null) return null;
		var k = c(x, t.v);
		if (k == 0) return merge(t.l, t.r);
		if (k < 0) {
			var ll = remove(x, t.l);
			return t.l == ll ? t : bal(ll, t.v, t.r);
		}
		var rr = remove(x, t.r);
		return t.r == rr ? t : bal(t.l, t.v, rr);
	}

	public function union(s1:SetT<E>, s2:SetT<E>):SetT<E> {
		if (s1 == null) return s2;
		if (s2 == null) return s1;
		if (s1.h >= s2.h) {
			if (s2.h == 1) return add(s2.v, s1);
			var s = split(s1.v, s2);
			var r = union(s1.r, s.v2);
			return join(union(s1.l, s.v0), s1.v, r);
		}
		if (s1.h == 1) return add(s1.v, s2);
		var s = split(s2.v, s1);
		var r = union(s.v2, s2.r);
		return join(union(s.v0, s2.l), s2.v, r);
	}

	public function inter(s1:SetT<E>, s2:SetT<E>):SetT<E> {
		if (s1 == null || s2 == null) return null;
		var s = split(s1.v, s2);
		var r = inter(s1.r, s.v2);
		var l = inter(s1.l, s.v0);
		return s.v1 ? join(l, s1.v, r) : concat(l, r);
	}

	public function diff(s1:SetT<E>, s2:SetT<E>):SetT<E> {
		if (s1 == null) return null;
		if (s2 == null) return s1;
		var s = split(s1.v, s2);
		var r = diff(s1.r, s.v2);
		var l = diff(s1.l, s.v0);
		return s.v1 ? concat(l, r) : join(l, s1.v, r);
	}

	public function disjoint(s1:SetT<E>, s2:SetT<E>):Bool {
		if (s1 == null || s2 == null) return true;
		if (s1 == s2) return false;
		var s = split(s1.v, s2);
		if (s.v1) return false;
		return disjoint(s1.l, s.v0) && disjoint(s1.r, s.v2);
	}

	static function consEnum<E>(s:SetT<E>, e:SetEnumeration<E>):SetEnumeration<E> {
		while (s != null) {
			e = More(s.v, s.r, e);
			s = s.l;
		}
		return e;
	}

	static function snocEnum<E>(s:SetT<E>, e:SetEnumeration<E>):SetEnumeration<E> {
		while (s != null) {
			e = More(s.v, s.l, e);
			s = s.r;
		}
		return e;
	}

	public function compare(s1:SetT<E>, s2:SetT<E>):Int63 {
		var e1 = consEnum(s1, End), e2 = consEnum(s2, End);
		while (true) switch [e1, e2] {
			case [End, End]: return Int63.zero;
			case [End, _]: return Int63.minusOne;
			case [_, End]: return Int63.one;
			case [More(v1, r1, n1), More(v2, r2, n2)]:
				var k = cmp(v1, v2);
				if (!Int63.eq(k, Int63.zero)) return k;
				e1 = consEnum(r1, n1);
				e2 = consEnum(r2, n2);
		}
	}

	public function equal(s1:SetT<E>, s2:SetT<E>):Bool
		return Int63.eq(compare(s1, s2), Int63.zero);

	public function subset(s1:SetT<E>, s2:SetT<E>):Bool {
		if (s1 == null) return true;
		if (s2 == null) return false;
		var k = c(s1.v, s2.v);
		if (k == 0) return subset(s1.l, s2.l) && subset(s1.r, s2.r);
		if (k < 0) return subset(new SetNode(s1.l, s1.v, null, 0), s2.l) && subset(s1.r, s2);
		return subset(new SetNode(null, s1.v, s1.r, 0), s2.r) && subset(s1.l, s2);
	}

	public function iter(f:E->Unit, t:SetT<E>):Unit {
		while (t != null) {
			iter(f, t.l);
			f(t.v);
			t = t.r;
		}
		return Unit.value;
	}

	public function fold<A>(f:(E, A) -> A, t:SetT<E>, accu:A):A {
		while (t != null) {
			accu = f(t.v, fold(f, t.l, accu));
			t = t.r;
		}
		return accu;
	}

	public function forAll(p:E->Bool, t:SetT<E>):Bool
		return t == null || (p(t.v) && forAll(p, t.l) && forAll(p, t.r));

	public function exists(p:E->Bool, t:SetT<E>):Bool
		return t != null && (p(t.v) || exists(p, t.l) || exists(p, t.r));

	public function filter(p:E->Bool, t:SetT<E>):SetT<E> {
		if (t == null) return null;
		var l = filter(p, t.l);
		var pv = p(t.v);
		var r = filter(p, t.r);
		if (pv) return (t.l == l && t.r == r) ? t : join(l, t.v, r);
		return concat(l, r);
	}

	public function partition(p:E->Bool, t:SetT<E>):Tuple2<SetT<E>, SetT<E>> {
		if (t == null) return new Tuple2(null, null);
		var lp = partition(p, t.l);
		var pv = p(t.v);
		var rp = partition(p, t.r);
		return pv ? new Tuple2(join(lp.v0, t.v, rp.v0), concat(lp.v1, rp.v1)) : new Tuple2(concat(lp.v0, rp.v0), join(lp.v1, t.v, rp.v1));
	}

	public function cardinal(t:SetT<E>):Int63 {
		function count(t:SetT<E>):Int
			return t == null ? 0 : count(t.l) + 1 + count(t.r);
		return Int63.ofInt(count(t));
	}

	public function elements(t:SetT<E>):MlList<E> {
		function aux(accu:MlList<E>, t:SetT<E>):MlList<E> {
			while (t != null) {
				accu = Cons(t.v, aux(accu, t.r));
				t = t.l;
			}
			return accu;
		}
		return aux(Nil, t);
	}

	public inline function toList(t:SetT<E>):MlList<E>
		return elements(t);

	public inline function choose(t:SetT<E>):E
		return minElt(t);

	public inline function chooseOpt(t:SetT<E>):MlOption<E>
		return minEltOpt(t);

	public function find(x:E, t:SetT<E>):E {
		while (t != null) {
			var k = c(x, t.v);
			if (k == 0) return t.v;
			t = k < 0 ? t.l : t.r;
		}
		throw NotFound.instance;
	}

	public function findOpt(x:E, t:SetT<E>):MlOption<E> {
		while (t != null) {
			var k = c(x, t.v);
			if (k == 0) return Some(t.v);
			t = k < 0 ? t.l : t.r;
		}
		return None;
	}

	public function findFirst(f:E->Bool, t:SetT<E>):E {
		while (t != null) {
			if (f(t.v)) {
				var v0 = t.v;
				var s = t.l;
				while (s != null) if (f(s.v)) {
					v0 = s.v;
					s = s.l;
				} else s = s.r;
				return v0;
			}
			t = t.r;
		}
		throw NotFound.instance;
	}

	public function findLast(f:E->Bool, t:SetT<E>):E {
		while (t != null) {
			if (f(t.v)) {
				var v0 = t.v;
				var s = t.r;
				while (s != null) if (f(s.v)) {
					v0 = s.v;
					s = s.r;
				} else s = s.l;
				return v0;
			}
			t = t.l;
		}
		throw NotFound.instance;
	}

	function tryJoin(l:SetT<E>, v:E, r:SetT<E>):SetT<E> {
		if ((l == null || c(maxElt(l), v) < 0) && (r == null || c(v, minElt(r)) < 0)) return join(l, v, r);
		return union(l, add(v, r));
	}

	public function map(f:E->E, t:SetT<E>):SetT<E> {
		if (t == null) return null;
		var l = map(f, t.l);
		var v = f(t.v);
		var r = map(f, t.r);
		if (t.l == l && t.v == v && t.r == r) return t;
		return tryJoin(l, v, r);
	}

	public function filterMap(f:E->MlOption<E>, t:SetT<E>):SetT<E> {
		if (t == null) return null;
		var l = filterMap(f, t.l);
		var v = f(t.v);
		var r = filterMap(f, t.r);
		return switch v {
			case Some(v): (t.l == l && t.v == v && t.r == r) ? t : tryJoin(l, v, r);
			case None: if (l == null) r else if (r == null) l else tryJoin(l, minElt(r), removeMinElt(r));
		}
	}

	function ofSortedList(l:MlList<E>):SetT<E> {
		var rest = l;
		function sub(n:Int):SetT<E> {
			switch n {
				case 0:
					return null;
				case 1:
					switch rest {
						case Cons(x0, t):
							rest = t;
							return new SetNode(null, x0, null, 1);
						case _:
					}
				case 2:
					switch rest {
						case Cons(x0, Cons(x1, t)):
							rest = t;
							return new SetNode(new SetNode(null, x0, null, 1), x1, null, 2);
						case _:
					}
				case 3:
					switch rest {
						case Cons(x0, Cons(x1, Cons(x2, t))):
							rest = t;
							return new SetNode(new SetNode(null, x0, null, 1), x1, new SetNode(null, x2, null, 1), 2);
						case _:
					}
				case _:
			}
			var nl = Std.int(n / 2);
			var left = sub(nl);
			switch rest {
				case Cons(mid, t):
					rest = t;
					var right = sub(n - nl - 1);
					return create(left, mid, right);
				case Nil:
					throw new haxe.Exception("Set.of_sorted_list: assertion");
			}
		}
		return sub(List.length(l).toInt());
	}

	public function ofList(l:MlList<E>):SetT<E> {
		switch l {
			case Nil: return null;
			case Cons(x0, Nil): return singleton(x0);
			case Cons(x0, Cons(x1, Nil)): return add(x1, singleton(x0));
			case Cons(x0, Cons(x1, Cons(x2, Nil))): return add(x2, add(x1, singleton(x0)));
			case Cons(x0, Cons(x1, Cons(x2, Cons(x3, Nil)))): return add(x3, add(x2, add(x1, singleton(x0))));
			case Cons(x0, Cons(x1, Cons(x2, Cons(x3, Cons(x4, Nil))))): return add(x4, add(x3, add(x2, add(x1, singleton(x0)))));
			case _: return ofSortedList(List.sortUniq(cmp, l));
		}
	}

	public function addSeq(s:Seq.SeqT<E>, t:SetT<E>):SetT<E>
		return Seq.foldLeft((t, x) -> add(x, t), t, s);

	public function ofSeq(s:Seq.SeqT<E>):SetT<E>
		return addSeq(s, null);

	static function seqOfEnum<E>(e:SetEnumeration<E>):Seq.SeqT<E>
		return _ -> switch e {
			case End: Seq.SeqNode.Nil;
			case More(x, t, rest): Seq.SeqNode.Cons(x, seqOfEnum(consEnum(t, rest)));
		}

	static function revSeqOfEnum<E>(e:SetEnumeration<E>):Seq.SeqT<E>
		return _ -> switch e {
			case End: Seq.SeqNode.Nil;
			case More(x, t, rest): Seq.SeqNode.Cons(x, revSeqOfEnum(snocEnum(t, rest)));
		}

	public function toSeq(t:SetT<E>):Seq.SeqT<E>
		return seqOfEnum(consEnum(t, End));

	public function toRevSeq(t:SetT<E>):Seq.SeqT<E>
		return revSeqOfEnum(snocEnum(t, End));
}
