package core.ds;

// port: an OCaml persistent `IntMap` (Map.Make(Int)) with O(log n) add and remove that share
// structure with the map they extend, as a little-endian Patricia trie. The mutable
// haxe.ds.IntMap copies everything, and PersistentMap copies its entries on each `add`.
// Only what the sites that use it need is here; the order of `exists` is not the key order.
enum PersistentIntMapNode<V> {
	Empty;
	Leaf(key:Int, value:V);
	Branch(prefix:Int, bit:Int, left:PersistentIntMapNode<V>, right:PersistentIntMapNode<V>);
}

abstract PersistentIntMap<V>(PersistentIntMapNode<V>) {
	public inline function new(node:PersistentIntMapNode<V>) this = node;

	public static inline function empty<V>():PersistentIntMap<V> return new PersistentIntMap(Empty);

	static inline function lowestBit(x:Int):Int return x & -x;

	static inline function matchPrefix(k:Int, p:Int, m:Int):Bool return (k & (m - 1)) == p;

	static function join<V>(p0:Int, t0:PersistentIntMapNode<V>, p1:Int, t1:PersistentIntMapNode<V>):PersistentIntMapNode<V> {
		var m = lowestBit(p0 ^ p1);
		var p = p0 & (m - 1);
		return (p0 & m) == 0 ? Branch(p, m, t0, t1) : Branch(p, m, t1, t0);
	}

	static function branch<V>(p:Int, m:Int, l:PersistentIntMapNode<V>, r:PersistentIntMapNode<V>):PersistentIntMapNode<V> return switch [l, r] {
		case [Empty, _]: r;
		case [_, Empty]: l;
		case _: Branch(p, m, l, r);
	};

	static function addNode<V>(k:Int, v:V, t:PersistentIntMapNode<V>):PersistentIntMapNode<V> return switch t {
		case Empty: Leaf(k, v);
		case Leaf(j, _):
			if (j == k) Leaf(k, v) else join(k, Leaf(k, v), j, t);
		case Branch(p, m, l, r):
			if (matchPrefix(k, p, m)) {
				if ((k & m) == 0) Branch(p, m, addNode(k, v, l), r) else Branch(p, m, l, addNode(k, v, r));
			} else join(k, Leaf(k, v), p, t);
	};

	static function removeNode<V>(k:Int, t:PersistentIntMapNode<V>):PersistentIntMapNode<V> return switch t {
		case Empty: Empty;
		case Leaf(j, _): j == k ? Empty : t;
		case Branch(p, m, l, r):
			if (matchPrefix(k, p, m)) {
				if ((k & m) == 0) branch(p, m, removeNode(k, l), r) else branch(p, m, l, removeNode(k, r));
			} else t;
	};

	static function existsNode<V>(f:Int->V->Bool, t:PersistentIntMapNode<V>):Bool return switch t {
		case Empty: false;
		case Leaf(k, v): f(k, v);
		case Branch(_, _, l, r): existsNode(f, l) || existsNode(f, r);
	};

	public function add(k:Int, v:V):PersistentIntMap<V> return new PersistentIntMap(addNode(k, v, this));

	public function remove(k:Int):PersistentIntMap<V> return new PersistentIntMap(removeNode(k, this));

	public function mem(k:Int):Bool {
		var t = this;
		while (true) switch t {
			case Empty: return false;
			case Leaf(j, _): return j == k;
			case Branch(p, m, l, r):
				if (!matchPrefix(k, p, m)) return false;
				t = (k & m) == 0 ? l : r;
		}
	}

	public function exists(f:Int->V->Bool):Bool return existsNode(f, this);
}
