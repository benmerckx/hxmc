package ml2hx.std;

import Array;
import String;
import StdTypes;
import ml2hx.rt.*;
import ml2hx.rt.MlList;
import ml2hx.rt.MlOption;
import haxe.ds.Vector;

// Stdlib.Hashtbl (OCaml 5.2's hashtbl.ml, not randomized): the same buckets,
// the same insertion at the head of a bucket, the same doubling (in place,
// keeping the order of each bucket) when size > 2 * buckets, so iter, fold
// and to_seq visit the bindings in OCaml's order. Generic tables hash with
// Hashtbl.hash (ml2hx.rt.Poly) and compare keys with compare = 0; the
// functors' instances (Make, MakeSeeded) with their argument's.
class HashtblBucket<K, V> {
	public var key:K;
	public var data:V;
	public var next:Null<HashtblBucket<K, V>>;

	public inline function new(key:K, data:V, next:Null<HashtblBucket<K, V>>) {
		this.key = key;
		this.data = data;
		this.next = next;
	}
}

class HashtblT<K, V> {
	public var size:Int;
	public var data:Vector<Null<HashtblBucket<K, V>>>;
	public final seed:Int;
	// negative during a traversal (OCaml's flip_ongoing_traversal)
	public var initialSize:Int;

	public function new(n:Int, seed:Int) {
		size = 0;
		data = new Vector(n);
		this.seed = seed;
		initialSize = n;
	}
}

typedef HashtblHashedType<K> = {
	function equal(a:K, b:K):Bool;
	function hash(k:K):Int63;
}

typedef HashtblSeededHashedType<K> = {
	function equal(a:K, b:K):Bool;
	function seededHash(seed:Int63, k:K):Int63;
}

class Hashtbl {
	// the functors Hashtbl.Make and Hashtbl.MakeSeeded
	public static function Make<K>(h:HashtblHashedType<K>):HashtblMake<K>
		return new HashtblMake(h);

	public static function MakeSeeded<K>(h:HashtblSeededHashedType<K>):HashtblMakeSeeded<K>
		return new HashtblMakeSeeded(h);

	static inline var MAX_ARRAY_LENGTH = 0x3FFFFFFF;

	public static function powerOf2Above(x:Int, n:Int):Int {
		while (true) {
			if (x >= n) return x;
			if (x * 2 > MAX_ARRAY_LENGTH) return x;
			x *= 2;
		}
	}

	// ---- shared by the generic tables and the functors' (index: the bucket of a key)

	public static function make<K, V>(n:Int63):HashtblT<K, V> {
		var k = n.isInt() ? n.toInt() : (Int63.lt(n, Int63.zero) ? 0 : MAX_ARRAY_LENGTH);
		return new HashtblT(powerOf2Above(16, k), 0);
	}

	public static function clear<K, V>(h:HashtblT<K, V>):Unit {
		if (h.size > 0) {
			h.size = 0;
			for (i in 0...h.data.length) h.data[i] = null;
		}
		return Unit.value;
	}

	public static function reset<K, V>(h:HashtblT<K, V>):Unit {
		var len = h.data.length;
		var init = h.initialSize < 0 ? -h.initialSize : h.initialSize;
		if (len == init) return clear(h);
		h.size = 0;
		h.data = new Vector(init);
		return Unit.value;
	}

	static function copyBucketlist<K, V>(b:Null<HashtblBucket<K, V>>):Null<HashtblBucket<K, V>> {
		if (b == null) return null;
		var r = new HashtblBucket(b.key, b.data, b.next);
		var prec = r;
		var cur = b.next;
		while (cur != null) {
			var c = new HashtblBucket(cur.key, cur.data, cur.next);
			prec.next = c;
			prec = c;
			cur = cur.next;
		}
		return r;
	}

	public static function copy<K, V>(h:HashtblT<K, V>):HashtblT<K, V> {
		var r = new HashtblT<K, V>(h.data.length, h.seed);
		r.size = h.size;
		r.initialSize = h.initialSize;
		for (i in 0...h.data.length) r.data[i] = copyBucketlist(h.data[i]);
		return r;
	}

	public static inline function length<K, V>(h:HashtblT<K, V>):Int63
		return Int63.ofInt(h.size);

	static inline function ongoingTraversal<K, V>(h:HashtblT<K, V>):Bool
		return h.initialSize < 0;

	static inline function flipOngoingTraversal<K, V>(h:HashtblT<K, V>)
		h.initialSize = -h.initialSize;

	public static function insertAllBuckets<K, V>(indexfun:K->Int, inplace:Bool, odata:Vector<Null<HashtblBucket<K, V>>>, ndata:Vector<Null<HashtblBucket<K, V>>>) {
		var nsize = ndata.length;
		var tails = new Vector<Null<HashtblBucket<K, V>>>(nsize);
		for (i in 0...odata.length) {
			var b = odata[i];
			while (b != null) {
				var next = b.next;
				var cell = inplace ? b : new HashtblBucket(b.key, b.data, null);
				var nidx = indexfun(b.key);
				var tail = tails[nidx];
				if (tail == null) ndata[nidx] = cell else tail.next = cell;
				tails[nidx] = cell;
				b = next;
			}
		}
		if (inplace) for (i in 0...nsize) {
			var tail = tails[i];
			if (tail != null) tail.next = null;
		}
	}

	public static function resize<K, V>(indexfun:(HashtblT<K, V>, K) -> Int, h:HashtblT<K, V>) {
		var odata = h.data;
		var osize = odata.length;
		var nsize = osize * 2;
		if (nsize < MAX_ARRAY_LENGTH) {
			var ndata = new Vector<Null<HashtblBucket<K, V>>>(nsize);
			var inplace = !ongoingTraversal(h);
			h.data = ndata;
			insertAllBuckets(k -> indexfun(h, k), inplace, odata, ndata);
		}
	}

	public static function iter<K, V>(f:(K, V) -> Unit, h:HashtblT<K, V>):Unit {
		var old = ongoingTraversal(h);
		if (!old) flipOngoingTraversal(h);
		try {
			var d = h.data;
			for (i in 0...d.length) {
				var b = d[i];
				while (b != null) {
					var next = b.next;
					f(b.key, b.data);
					b = next;
				}
			}
			if (!old) flipOngoingTraversal(h);
		} catch (e:Dynamic) {
			if (!old) flipOngoingTraversal(h);
			throw e;
		}
		return Unit.value;
	}

	public static function filterMapInplace<K, V>(f:(K, V) -> MlOption<V>, h:HashtblT<K, V>):Unit {
		var d = h.data;
		var old = ongoingTraversal(h);
		if (!old) flipOngoingTraversal(h);
		try {
			for (i in 0...d.length) {
				var prec:Null<HashtblBucket<K, V>> = null;
				var slot = h.data[i];
				while (slot != null) {
					switch f(slot.key, slot.data) {
						case None:
							h.size--;
						case Some(data):
							if (prec == null) h.data[i] = slot else prec.next = slot;
							slot.data = data;
							prec = slot;
					}
					slot = slot.next;
				}
				if (prec == null) h.data[i] = null else prec.next = null;
			}
			if (!old) flipOngoingTraversal(h);
		} catch (e:Dynamic) {
			if (!old) flipOngoingTraversal(h);
			throw e;
		}
		return Unit.value;
	}

	public static function fold<K, V, A>(f:(K, V, A) -> A, h:HashtblT<K, V>, init:A):A {
		var old = ongoingTraversal(h);
		if (!old) flipOngoingTraversal(h);
		try {
			var d = h.data;
			var accu = init;
			for (i in 0...d.length) {
				var b = d[i];
				while (b != null) {
					var next = b.next;
					accu = f(b.key, b.data, accu);
					b = next;
				}
			}
			if (!old) flipOngoingTraversal(h);
			return accu;
		} catch (e:Dynamic) {
			if (!old) flipOngoingTraversal(h);
			throw e;
		}
	}

	public static function toSeq<K, V>(h:HashtblT<K, V>):Seq.SeqT<Tuple2<K, V>> {
		var d = h.data;
		function aux(i:Int, b:Null<HashtblBucket<K, V>>):Seq.SeqT<Tuple2<K, V>> {
			return function(_:Unit):Seq.SeqNode<Tuple2<K, V>> {
				while (b == null) {
					if (i == d.length) return Seq.SeqNode.Nil;
					b = d[i++];
				}
				return Seq.SeqNode.Cons(new Tuple2(b.key, b.data), aux(i, b.next));
			}
		}
		return aux(0, null);
	}

	public static function toSeqKeys<K, V>(h:HashtblT<K, V>):Seq.SeqT<K>
		return Seq.map((p:Tuple2<K, V>) -> p.v0, toSeq(h));

	public static function toSeqValues<K, V>(h:HashtblT<K, V>):Seq.SeqT<V>
		return Seq.map((p:Tuple2<K, V>) -> p.v1, toSeq(h));

	public static function stats<K, V>(h:HashtblT<K, V>):HashtblStatistics {
		var mbl = 0;
		for (i in 0...h.data.length) {
			var n = 0, b = h.data[i];
			while (b != null) {
				n++;
				b = b.next;
			}
			if (n > mbl) mbl = n;
		}
		var histo = [for (_ in 0...mbl + 1) Int63.zero];
		for (i in 0...h.data.length) {
			var n = 0, b = h.data[i];
			while (b != null) {
				n++;
				b = b.next;
			}
			histo[n] = Int63.succ(histo[n]);
		}
		return new HashtblStatistics(Int63.ofInt(h.size), Int63.ofInt(h.data.length), Int63.ofInt(mbl), histo);
	}

	// ---- the generic tables

	static inline function keyIndex<K, V>(h:HashtblT<K, V>, key:K):Int
		return Poly.hashParam(10, 100, h.seed, key) & (h.data.length - 1);

	static inline function same<K>(a:K, b:K):Bool
		return Poly.compare(a, b) == 0;

	public static function create<K, V>(n:Int63, ?random:Bool):HashtblT<K, V>
		return make(n);

	public static function add<K, V>(h:HashtblT<K, V>, key:K, data:V):Unit {
		var i = keyIndex(h, key);
		h.data[i] = new HashtblBucket(key, data, h.data[i]);
		h.size++;
		if (h.size > h.data.length << 1) resize(keyIndex, h);
		return Unit.value;
	}

	public static function remove<K, V>(h:HashtblT<K, V>, key:K):Unit {
		var i = keyIndex(h, key);
		var prec:Null<HashtblBucket<K, V>> = null;
		var c = h.data[i];
		while (c != null) {
			if (same(c.key, key)) {
				h.size--;
				if (prec == null) h.data[i] = c.next else prec.next = c.next;
				return Unit.value;
			}
			prec = c;
			c = c.next;
		}
		return Unit.value;
	}

	public static function find<K, V>(h:HashtblT<K, V>, key:K):V {
		var b = h.data[keyIndex(h, key)];
		while (b != null) {
			if (same(key, b.key)) return b.data;
			b = b.next;
		}
		throw NotFound.instance;
	}

	public static function findOpt<K, V>(h:HashtblT<K, V>, key:K):MlOption<V> {
		var b = h.data[keyIndex(h, key)];
		while (b != null) {
			if (same(key, b.key)) return Some(b.data);
			b = b.next;
		}
		return None;
	}

	public static function findAll<K, V>(h:HashtblT<K, V>, key:K):MlList<V> {
		var items = [];
		var b = h.data[keyIndex(h, key)];
		while (b != null) {
			if (same(b.key, key)) items.push(b.data);
			b = b.next;
		}
		return List.ofArray(items);
	}

	public static function replace<K, V>(h:HashtblT<K, V>, key:K, data:V):Unit {
		var i = keyIndex(h, key);
		var l = h.data[i];
		var b = l;
		while (b != null) {
			if (same(b.key, key)) {
				b.key = key;
				b.data = data;
				return Unit.value;
			}
			b = b.next;
		}
		h.data[i] = new HashtblBucket(key, data, l);
		h.size++;
		if (h.size > h.data.length << 1) resize(keyIndex, h);
		return Unit.value;
	}

	public static function mem<K, V>(h:HashtblT<K, V>, key:K):Bool {
		var b = h.data[keyIndex(h, key)];
		while (b != null) {
			if (same(b.key, key)) return true;
			b = b.next;
		}
		return false;
	}

	public static function addSeq<K, V>(h:HashtblT<K, V>, s:Seq.SeqT<Tuple2<K, V>>):Unit
		return Seq.iter((p:Tuple2<K, V>) -> add(h, p.v0, p.v1), s);

	public static function replaceSeq<K, V>(h:HashtblT<K, V>, s:Seq.SeqT<Tuple2<K, V>>):Unit
		return Seq.iter((p:Tuple2<K, V>) -> replace(h, p.v0, p.v1), s);

	public static function ofSeq<K, V>(s:Seq.SeqT<Tuple2<K, V>>):HashtblT<K, V> {
		var h = make(Int63.ofInt(16));
		replaceSeq(h, s);
		return h;
	}

	public static inline function hash<K>(k:K):Int63
		return Int63.ofInt(Poly.hash(k));

	public static inline function seededHash<K>(seed:Int63, k:K):Int63
		return Int63.ofInt(Poly.hashParam(10, 100, seed.toInt(), k));

	public static inline function hashParam<K>(meaningful:Int63, total:Int63, k:K):Int63
		return Int63.ofInt(Poly.hashParam(meaningful.toInt(), total.toInt(), 0, k));

	public static inline function seededHashParam<K>(meaningful:Int63, total:Int63, seed:Int63, k:K):Int63
		return Int63.ofInt(Poly.hashParam(meaningful.toInt(), total.toInt(), seed.toInt(), k));
}

class HashtblStatistics implements Block {
	public final numBindings:Int63;
	public final numBuckets:Int63;
	public final maxBucketLength:Int63;
	public final bucketHistogram:Array<Int63>;

	public function new(numBindings, numBuckets, maxBucketLength, bucketHistogram) {
		this.numBindings = numBindings;
		this.numBuckets = numBuckets;
		this.maxBucketLength = maxBucketLength;
		this.bucketHistogram = bucketHistogram;
	}

	public function blockTag():Int
		return 0;

	public function blockSize():Int
		return 4;

	public function blockField(i:Int):Dynamic
		return switch i {
			case 0: numBindings;
			case 1: numBuckets;
			case 2: maxBucketLength;
			case _: bucketHistogram;
		}
}

// Hashtbl.MakeSeeded(H): the functor's instance. Hashtbl.Make(H) is
// `new MakeSeeded(Make.seeded(h))` (its hash ignores the seed), or `new Make(h)`.
class HashtblMakeSeeded<K> {
	final equal:(K, K) -> Bool;
	final seededHash:(Int63, K) -> Int63;

	public function new(h:HashtblSeededHashedType<K>) {
		equal = h.equal;
		seededHash = h.seededHash;
	}

	inline function keyIndex<V>(h:HashtblT<K, V>, key:K):Int
		return seededHash(Int63.ofInt(h.seed), key).toInt() & (h.data.length - 1);

	public function create<V>(n:Int63, ?random:Bool):HashtblT<K, V>
		return Hashtbl.make(n);

	public inline function clear<V>(h:HashtblT<K, V>):Unit
		return Hashtbl.clear(h);

	public inline function reset<V>(h:HashtblT<K, V>):Unit
		return Hashtbl.reset(h);

	public inline function copy<V>(h:HashtblT<K, V>):HashtblT<K, V>
		return Hashtbl.copy(h);

	public inline function length<V>(h:HashtblT<K, V>):Int63
		return Hashtbl.length(h);

	public inline function iter<V>(f:(K, V) -> Unit, h:HashtblT<K, V>):Unit
		return Hashtbl.iter(f, h);

	public inline function filterMapInplace<V>(f:(K, V) -> MlOption<V>, h:HashtblT<K, V>):Unit
		return Hashtbl.filterMapInplace(f, h);

	public inline function fold<V, A>(f:(K, V, A) -> A, h:HashtblT<K, V>, init:A):A
		return Hashtbl.fold(f, h, init);

	public inline function stats<V>(h:HashtblT<K, V>):HashtblStatistics
		return Hashtbl.stats(h);

	public inline function toSeq<V>(h:HashtblT<K, V>):Seq.SeqT<Tuple2<K, V>>
		return Hashtbl.toSeq(h);

	public inline function toSeqKeys<V>(h:HashtblT<K, V>):Seq.SeqT<K>
		return Hashtbl.toSeqKeys(h);

	public inline function toSeqValues<V>(h:HashtblT<K, V>):Seq.SeqT<V>
		return Hashtbl.toSeqValues(h);

	public function add<V>(h:HashtblT<K, V>, key:K, data:V):Unit {
		var i = keyIndex(h, key);
		h.data[i] = new HashtblBucket(key, data, h.data[i]);
		h.size++;
		if (h.size > h.data.length << 1) Hashtbl.resize(keyIndex, h);
		return Unit.value;
	}

	public function remove<V>(h:HashtblT<K, V>, key:K):Unit {
		var i = keyIndex(h, key);
		var prec:Null<HashtblBucket<K, V>> = null;
		var c = h.data[i];
		while (c != null) {
			if (equal(c.key, key)) {
				h.size--;
				if (prec == null) h.data[i] = c.next else prec.next = c.next;
				return Unit.value;
			}
			prec = c;
			c = c.next;
		}
		return Unit.value;
	}

	public function find<V>(h:HashtblT<K, V>, key:K):V {
		var b = h.data[keyIndex(h, key)];
		while (b != null) {
			if (equal(key, b.key)) return b.data;
			b = b.next;
		}
		throw NotFound.instance;
	}

	public function findOpt<V>(h:HashtblT<K, V>, key:K):MlOption<V> {
		var b = h.data[keyIndex(h, key)];
		while (b != null) {
			if (equal(key, b.key)) return Some(b.data);
			b = b.next;
		}
		return None;
	}

	public function findAll<V>(h:HashtblT<K, V>, key:K):MlList<V> {
		var items = [];
		var b = h.data[keyIndex(h, key)];
		while (b != null) {
			if (equal(b.key, key)) items.push(b.data);
			b = b.next;
		}
		return List.ofArray(items);
	}

	public function replace<V>(h:HashtblT<K, V>, key:K, data:V):Unit {
		var i = keyIndex(h, key);
		var l = h.data[i];
		var b = l;
		while (b != null) {
			if (equal(b.key, key)) {
				b.key = key;
				b.data = data;
				return Unit.value;
			}
			b = b.next;
		}
		h.data[i] = new HashtblBucket(key, data, l);
		h.size++;
		if (h.size > h.data.length << 1) Hashtbl.resize(keyIndex, h);
		return Unit.value;
	}

	public function mem<V>(h:HashtblT<K, V>, key:K):Bool {
		var b = h.data[keyIndex(h, key)];
		while (b != null) {
			if (equal(b.key, key)) return true;
			b = b.next;
		}
		return false;
	}

	public function addSeq<V>(h:HashtblT<K, V>, s:Seq.SeqT<Tuple2<K, V>>):Unit
		return Seq.iter((p:Tuple2<K, V>) -> add(h, p.v0, p.v1), s);

	public function replaceSeq<V>(h:HashtblT<K, V>, s:Seq.SeqT<Tuple2<K, V>>):Unit
		return Seq.iter((p:Tuple2<K, V>) -> replace(h, p.v0, p.v1), s);

	public function ofSeq<V>(s:Seq.SeqT<Tuple2<K, V>>):HashtblT<K, V> {
		var h = Hashtbl.make(Int63.ofInt(16));
		replaceSeq(h, s);
		return h;
	}
}

// Hashtbl.Make(H)
class HashtblMake<K> extends HashtblMakeSeeded<K> {
	public function new(h:HashtblHashedType<K>) {
		var hash = h.hash;
		super({equal: h.equal, seededHash: (_, k) -> hash(k)});
	}
}
