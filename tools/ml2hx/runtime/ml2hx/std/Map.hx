package ml2hx.std;

import Array;
import String;
import StdTypes;
import ml2hx.rt.*;
import ml2hx.rt.MlList;
import ml2hx.rt.MlOption;

typedef MapOrderedType<K> = {
	function compare(a:K, b:K):Int63;
}

// a node of Map.Make(Ord).t; the empty map is null
class MapNode<K, V> implements Block {
	public final l:Null<MapNode<K, V>>;
	public final v:K;
	public final d:V;
	public final r:Null<MapNode<K, V>>;
	public final h:Int;

	public inline function new(l, v, d, r, h) {
		this.l = l;
		this.v = v;
		this.d = d;
		this.r = r;
		this.h = h;
	}

	public function blockTag():Int
		return 0;

	public function blockSize():Int
		return 5;

	public function blockField(i:Int):Dynamic
		return switch i {
			case 0: l;
			case 1: v;
			case 2: d;
			case 3: r;
			case _: Int63.ofInt(h);
		}
}

typedef MapT<K, V> = Null<MapNode<K, V>>;

private enum MapEnumeration<K, V> {
	End;
	More(k:K, d:V, t:MapT<K, V>, e:MapEnumeration<K, V>);
}

class Map {
	// the functor Map.Make
	public static function Make<K>(ord:MapOrderedType<K>):MapMake<K>
		return new MapMake(ord);
}

// Map.Make(Ord): OCaml 5.2's map.ml (the same AVL balancing, the same
// order of the calls of the function arguments)
class MapMake<K> {
	final cmp:(K, K) -> Int63;

	public function new(ord:MapOrderedType<K>)
		cmp = ord.compare;

	inline function c(a:K, b:K):Int
		return Int63.compare(cmp(a, b), Int63.zero);

	static inline function height<K, V>(m:MapT<K, V>):Int
		return m == null ? 0 : m.h;

	static inline function create<K, V>(l:MapT<K, V>, x:K, d:V, r:MapT<K, V>):MapT<K, V> {
		var hl = height(l), hr = height(r);
		return new MapNode(l, x, d, r, hl >= hr ? hl + 1 : hr + 1);
	}

	public function singleton<V>(x:K, d:V):MapT<K, V>
		return new MapNode(null, x, d, null, 1);

	static function bal<K, V>(l:MapT<K, V>, x:K, d:V, r:MapT<K, V>):MapT<K, V> {
		var hl = height(l), hr = height(r);
		if (hl > hr + 2) {
			if (l == null) throw new InvalidArgument("Map.bal");
			var ll = l.l, lv = l.v, ld = l.d, lr = l.r;
			if (height(ll) >= height(lr)) return create(ll, lv, ld, create(lr, x, d, r));
			if (lr == null) throw new InvalidArgument("Map.bal");
			return create(create(ll, lv, ld, lr.l), lr.v, lr.d, create(lr.r, x, d, r));
		} else if (hr > hl + 2) {
			if (r == null) throw new InvalidArgument("Map.bal");
			var rl = r.l, rv = r.v, rd = r.d, rr = r.r;
			if (height(rr) >= height(rl)) return create(create(l, x, d, rl), rv, rd, rr);
			if (rl == null) throw new InvalidArgument("Map.bal");
			return create(create(l, x, d, rl.l), rl.v, rl.d, create(rl.r, rv, rd, rr));
		}
		return new MapNode(l, x, d, r, hl >= hr ? hl + 1 : hr + 1);
	}

	public inline function empty<V>():MapT<K, V>
		return null;

	public inline function isEmpty<V>(m:MapT<K, V>):Bool
		return m == null;

	public function add<V>(x:K, data:V, m:MapT<K, V>):MapT<K, V> {
		if (m == null) return new MapNode(null, x, data, null, 1);
		var k = c(x, m.v);
		if (k == 0) return m.d == data ? m : new MapNode(m.l, x, data, m.r, m.h);
		if (k < 0) {
			var ll = add(x, data, m.l);
			return m.l == ll ? m : bal(ll, m.v, m.d, m.r);
		}
		var rr = add(x, data, m.r);
		return m.r == rr ? m : bal(m.l, m.v, m.d, rr);
	}

	public function find<V>(x:K, m:MapT<K, V>):V {
		while (m != null) {
			var k = c(x, m.v);
			if (k == 0) return m.d;
			m = k < 0 ? m.l : m.r;
		}
		throw NotFound.instance;
	}

	public function findOpt<V>(x:K, m:MapT<K, V>):MlOption<V> {
		while (m != null) {
			var k = c(x, m.v);
			if (k == 0) return Some(m.d);
			m = k < 0 ? m.l : m.r;
		}
		return None;
	}

	public function mem<V>(x:K, m:MapT<K, V>):Bool {
		while (m != null) {
			var k = c(x, m.v);
			if (k == 0) return true;
			m = k < 0 ? m.l : m.r;
		}
		return false;
	}

	public function findFirst<V>(f:K->Bool, m:MapT<K, V>):Tuple2<K, V> {
		while (m != null) {
			if (f(m.v)) {
				var v0 = m.v, d0 = m.d;
				var t = m.l;
				while (t != null) {
					if (f(t.v)) {
						v0 = t.v;
						d0 = t.d;
						t = t.l;
					} else
						t = t.r;
				}
				return new Tuple2(v0, d0);
			}
			m = m.r;
		}
		throw NotFound.instance;
	}

	public function findFirstOpt<V>(f:K->Bool, m:MapT<K, V>):MlOption<Tuple2<K, V>> {
		try
			return Some(findFirst(f, m))
		catch (e:NotFound)
			return None;
	}

	public function findLast<V>(f:K->Bool, m:MapT<K, V>):Tuple2<K, V> {
		while (m != null) {
			if (f(m.v)) {
				var v0 = m.v, d0 = m.d;
				var t = m.r;
				while (t != null) {
					if (f(t.v)) {
						v0 = t.v;
						d0 = t.d;
						t = t.r;
					} else
						t = t.l;
				}
				return new Tuple2(v0, d0);
			}
			m = m.l;
		}
		throw NotFound.instance;
	}

	public function findLastOpt<V>(f:K->Bool, m:MapT<K, V>):MlOption<Tuple2<K, V>> {
		try
			return Some(findLast(f, m))
		catch (e:NotFound)
			return None;
	}

	public function minBinding<V>(m:MapT<K, V>):Tuple2<K, V> {
		if (m == null) throw NotFound.instance;
		while (m.l != null) m = m.l;
		return new Tuple2(m.v, m.d);
	}

	public function minBindingOpt<V>(m:MapT<K, V>):MlOption<Tuple2<K, V>>
		return m == null ? None : Some(minBinding(m));

	public function maxBinding<V>(m:MapT<K, V>):Tuple2<K, V> {
		if (m == null) throw NotFound.instance;
		while (m.r != null) m = m.r;
		return new Tuple2(m.v, m.d);
	}

	public function maxBindingOpt<V>(m:MapT<K, V>):MlOption<Tuple2<K, V>>
		return m == null ? None : Some(maxBinding(m));

	public inline function choose<V>(m:MapT<K, V>):Tuple2<K, V>
		return minBinding(m);

	public inline function chooseOpt<V>(m:MapT<K, V>):MlOption<Tuple2<K, V>>
		return minBindingOpt(m);

	static function removeMinBinding<K, V>(m:MapT<K, V>):MapT<K, V> {
		if (m == null) throw new InvalidArgument("Map.remove_min_elt");
		if (m.l == null) return m.r;
		return bal(removeMinBinding(m.l), m.v, m.d, m.r);
	}

	function merge2<V>(t1:MapT<K, V>, t2:MapT<K, V>):MapT<K, V> {
		if (t1 == null) return t2;
		if (t2 == null) return t1;
		var b = minBinding(t2);
		return bal(t1, b.v0, b.v1, removeMinBinding(t2));
	}

	public function remove<V>(x:K, m:MapT<K, V>):MapT<K, V> {
		if (m == null) return null;
		var k = c(x, m.v);
		if (k == 0) return merge2(m.l, m.r);
		if (k < 0) {
			var ll = remove(x, m.l);
			return m.l == ll ? m : bal(ll, m.v, m.d, m.r);
		}
		var rr = remove(x, m.r);
		return m.r == rr ? m : bal(m.l, m.v, m.d, rr);
	}

	public function update<V>(x:K, f:MlOption<V>->MlOption<V>, m:MapT<K, V>):MapT<K, V> {
		if (m == null) return switch f(None) {
			case None: null;
			case Some(data): new MapNode(null, x, data, null, 1);
		}
		var k = c(x, m.v);
		if (k == 0) return switch f(Some(m.d)) {
			case None: merge2(m.l, m.r);
			case Some(data): m.d == data ? m : new MapNode(m.l, x, data, m.r, m.h);
		}
		if (k < 0) {
			var ll = update(x, f, m.l);
			return m.l == ll ? m : bal(ll, m.v, m.d, m.r);
		}
		var rr = update(x, f, m.r);
		return m.r == rr ? m : bal(m.l, m.v, m.d, rr);
	}

	public function addToList<V>(x:K, data:V, m:MapT<K, MlList<V>>):MapT<K, MlList<V>>
		return update(x, o -> switch o {
			case None: Some(Cons(data, Nil));
			case Some(l): Some(Cons(data, l));
		}, m);

	public function iter<V>(f:(K, V) -> Unit, m:MapT<K, V>):Unit {
		while (m != null) {
			iter(f, m.l);
			f(m.v, m.d);
			m = m.r;
		}
		return Unit.value;
	}

	public function map<V, W>(f:V->W, m:MapT<K, V>):MapT<K, W> {
		if (m == null) return null;
		var l = map(f, m.l);
		var d = f(m.d);
		var r = map(f, m.r);
		return new MapNode(l, m.v, d, r, m.h);
	}

	public function mapi<V, W>(f:(K, V) -> W, m:MapT<K, V>):MapT<K, W> {
		if (m == null) return null;
		var l = mapi(f, m.l);
		var d = f(m.v, m.d);
		var r = mapi(f, m.r);
		return new MapNode(l, m.v, d, r, m.h);
	}

	public function fold<V, A>(f:(K, V, A) -> A, m:MapT<K, V>, accu:A):A {
		while (m != null) {
			accu = f(m.v, m.d, fold(f, m.l, accu));
			m = m.r;
		}
		return accu;
	}

	public function forAll<V>(p:(K, V) -> Bool, m:MapT<K, V>):Bool {
		if (m == null) return true;
		return p(m.v, m.d) && forAll(p, m.l) && forAll(p, m.r);
	}

	public function exists<V>(p:(K, V) -> Bool, m:MapT<K, V>):Bool {
		if (m == null) return false;
		return p(m.v, m.d) || exists(p, m.l) || exists(p, m.r);
	}

	static function addMinBinding<K, V>(k:K, x:V, m:MapT<K, V>):MapT<K, V> {
		if (m == null) return new MapNode(null, k, x, null, 1);
		return bal(addMinBinding(k, x, m.l), m.v, m.d, m.r);
	}

	static function addMaxBinding<K, V>(k:K, x:V, m:MapT<K, V>):MapT<K, V> {
		if (m == null) return new MapNode(null, k, x, null, 1);
		return bal(m.l, m.v, m.d, addMaxBinding(k, x, m.r));
	}

	static function join<K, V>(l:MapT<K, V>, v:K, d:V, r:MapT<K, V>):MapT<K, V> {
		if (l == null) return addMinBinding(v, d, r);
		if (r == null) return addMaxBinding(v, d, l);
		if (l.h > r.h + 2) return bal(l.l, l.v, l.d, join(l.r, v, d, r));
		if (r.h > l.h + 2) return bal(join(l, v, d, r.l), r.v, r.d, r.r);
		return create(l, v, d, r);
	}

	function concat<V>(t1:MapT<K, V>, t2:MapT<K, V>):MapT<K, V> {
		if (t1 == null) return t2;
		if (t2 == null) return t1;
		var b = minBinding(t2);
		return join(t1, b.v0, b.v1, removeMinBinding(t2));
	}

	function concatOrJoin<V>(t1:MapT<K, V>, v:K, d:MlOption<V>, t2:MapT<K, V>):MapT<K, V>
		return switch d {
			case Some(d): join(t1, v, d, t2);
			case None: concat(t1, t2);
		}

	public function split<V>(x:K, m:MapT<K, V>):Tuple3<MapT<K, V>, MlOption<V>, MapT<K, V>> {
		if (m == null) return new Tuple3(null, None, null);
		var k = c(x, m.v);
		if (k == 0) return new Tuple3(m.l, Some(m.d), m.r);
		if (k < 0) {
			var s = split(x, m.l);
			return new Tuple3(s.v0, s.v1, join(s.v2, m.v, m.d, m.r));
		}
		var s = split(x, m.r);
		return new Tuple3(join(m.l, m.v, m.d, s.v0), s.v1, s.v2);
	}

	public function merge<A, B, C>(f:(K, MlOption<A>, MlOption<B>) -> MlOption<C>, s1:MapT<K, A>, s2:MapT<K, B>):MapT<K, C> {
		if (s1 == null && s2 == null) return null;
		if (s1 != null && s1.h >= height(s2)) {
			// OCaml evaluates the arguments right to left
			var s = split(s1.v, s2);
			var r = merge(f, s1.r, s.v2);
			var d = f(s1.v, Some(s1.d), s.v1);
			return concatOrJoin(merge(f, s1.l, s.v0), s1.v, d, r);
		}
		var s = split(s2.v, s1);
		var r = merge(f, s.v2, s2.r);
		var d = f(s2.v, s.v1, Some(s2.d));
		return concatOrJoin(merge(f, s.v0, s2.l), s2.v, d, r);
	}

	public function union<V>(f:(K, V, V) -> MlOption<V>, s1:MapT<K, V>, s2:MapT<K, V>):MapT<K, V> {
		if (s1 == null) return s2;
		if (s2 == null) return s1;
		if (s1.h >= s2.h) {
			var s = split(s1.v, s2);
			var l = union(f, s1.l, s.v0);
			var r = union(f, s1.r, s.v2);
			return switch s.v1 {
				case None: join(l, s1.v, s1.d, r);
				case Some(d2): concatOrJoin(l, s1.v, f(s1.v, s1.d, d2), r);
			}
		}
		var s = split(s2.v, s1);
		var l = union(f, s.v0, s2.l);
		var r = union(f, s.v2, s2.r);
		return switch s.v1 {
			case None: join(l, s2.v, s2.d, r);
			case Some(d1): concatOrJoin(l, s2.v, f(s2.v, d1, s2.d), r);
		}
	}

	public function filter<V>(p:(K, V) -> Bool, m:MapT<K, V>):MapT<K, V> {
		if (m == null) return null;
		var l = filter(p, m.l);
		var pvd = p(m.v, m.d);
		var r = filter(p, m.r);
		if (pvd) return (m.l == l && m.r == r) ? m : join(l, m.v, m.d, r);
		return concat(l, r);
	}

	public function filterMap<V, W>(f:(K, V) -> MlOption<W>, m:MapT<K, V>):MapT<K, W> {
		if (m == null) return null;
		var l = filterMap(f, m.l);
		var fvd = f(m.v, m.d);
		var r = filterMap(f, m.r);
		return switch fvd {
			case Some(d): join(l, m.v, d, r);
			case None: concat(l, r);
		}
	}

	public function partition<V>(p:(K, V) -> Bool, m:MapT<K, V>):Tuple2<MapT<K, V>, MapT<K, V>> {
		if (m == null) return new Tuple2(null, null);
		var lp = partition(p, m.l);
		var pvd = p(m.v, m.d);
		var rp = partition(p, m.r);
		return pvd ? new Tuple2(join(lp.v0, m.v, m.d, rp.v0), concat(lp.v1, rp.v1)) : new Tuple2(concat(lp.v0, rp.v0), join(lp.v1, m.v, m.d, rp.v1));
	}

	static function consEnum<K, V>(m:MapT<K, V>, e:MapEnumeration<K, V>):MapEnumeration<K, V> {
		while (m != null) {
			e = More(m.v, m.d, m.r, e);
			m = m.l;
		}
		return e;
	}

	static function snocEnum<K, V>(m:MapT<K, V>, e:MapEnumeration<K, V>):MapEnumeration<K, V> {
		while (m != null) {
			e = More(m.v, m.d, m.l, e);
			m = m.r;
		}
		return e;
	}

	public function compare<V>(cmpd:(V, V) -> Int63, m1:MapT<K, V>, m2:MapT<K, V>):Int63 {
		var e1 = consEnum(m1, End), e2 = consEnum(m2, End);
		while (true) switch [e1, e2] {
			case [End, End]: return Int63.zero;
			case [End, _]: return Int63.minusOne;
			case [_, End]: return Int63.one;
			case [More(v1, d1, r1, n1), More(v2, d2, r2, n2)]:
				var k = cmp(v1, v2);
				if (!Int63.eq(k, Int63.zero)) return k;
				var k = cmpd(d1, d2);
				if (!Int63.eq(k, Int63.zero)) return k;
				e1 = consEnum(r1, n1);
				e2 = consEnum(r2, n2);
		}
	}

	public function equal<V>(eq:(V, V) -> Bool, m1:MapT<K, V>, m2:MapT<K, V>):Bool {
		var e1 = consEnum(m1, End), e2 = consEnum(m2, End);
		while (true) switch [e1, e2] {
			case [End, End]: return true;
			case [End, _] | [_, End]: return false;
			case [More(v1, d1, r1, n1), More(v2, d2, r2, n2)]:
				if (!(c(v1, v2) == 0 && eq(d1, d2))) return false;
				e1 = consEnum(r1, n1);
				e2 = consEnum(r2, n2);
		}
	}

	public function cardinal<V>(m:MapT<K, V>):Int63 {
		function count(m:MapT<K, V>):Int
			return m == null ? 0 : count(m.l) + 1 + count(m.r);
		return Int63.ofInt(count(m));
	}

	public function bindings<V>(m:MapT<K, V>):MlList<Tuple2<K, V>> {
		function aux(accu:MlList<Tuple2<K, V>>, m:MapT<K, V>):MlList<Tuple2<K, V>> {
			while (m != null) {
				accu = Cons(new Tuple2(m.v, m.d), aux(accu, m.r));
				m = m.l;
			}
			return accu;
		}
		return aux(Nil, m);
	}

	public inline function toList<V>(m:MapT<K, V>):MlList<Tuple2<K, V>>
		return bindings(m);

	public function ofList<V>(bs:MlList<Tuple2<K, V>>):MapT<K, V>
		return List.foldLeft((m, p:Tuple2<K, V>) -> add(p.v0, p.v1, m), null, bs);

	public function addSeq<V>(s:Seq.SeqT<Tuple2<K, V>>, m:MapT<K, V>):MapT<K, V>
		return Seq.foldLeft((m, p:Tuple2<K, V>) -> add(p.v0, p.v1, m), m, s);

	public function ofSeq<V>(s:Seq.SeqT<Tuple2<K, V>>):MapT<K, V>
		return addSeq(s, null);

	static function seqOfEnum<K, V>(e:MapEnumeration<K, V>):Seq.SeqT<Tuple2<K, V>>
		return _ -> switch e {
			case End: Seq.SeqNode.Nil;
			case More(k, v, t, rest): Seq.SeqNode.Cons(new Tuple2(k, v), seqOfEnum(consEnum(t, rest)));
		}

	static function revSeqOfEnum<K, V>(e:MapEnumeration<K, V>):Seq.SeqT<Tuple2<K, V>>
		return _ -> switch e {
			case End: Seq.SeqNode.Nil;
			case More(k, v, t, rest): Seq.SeqNode.Cons(new Tuple2(k, v), revSeqOfEnum(snocEnum(t, rest)));
		}

	public function toSeq<V>(m:MapT<K, V>):Seq.SeqT<Tuple2<K, V>>
		return seqOfEnum(consEnum(m, End));

	public function toRevSeq<V>(m:MapT<K, V>):Seq.SeqT<Tuple2<K, V>>
		return revSeqOfEnum(snocEnum(m, End));

	public function toSeqFrom<V>(low:K, m:MapT<K, V>):Seq.SeqT<Tuple2<K, V>> {
		var e = End;
		while (m != null) {
			var k = c(m.v, low);
			if (k == 0) {
				e = More(m.v, m.d, m.r, e);
				break;
			} else if (k < 0)
				m = m.r;
			else {
				e = More(m.v, m.d, m.r, e);
				m = m.l;
			}
		}
		return seqOfEnum(e);
	}
}
