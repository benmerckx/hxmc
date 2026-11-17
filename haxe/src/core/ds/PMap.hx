package core.ds;

import haxe.ds.Vector;

// port: OCaml's persistent maps with string keys (extlib's `(string, 'a) PMap.t`,
// `StringMap` of Map.Make(String)), iterated in key order (Key.compareStrings).
// The sorted keys and their values are two Vectors: a lookup is a binary
// search, iterating is a loop. An update copies them once, replacing a value
// copies the values alone (the keys' Vector is shared), and an update that
// changes nothing returns the map itself. Where upstream keeps such a map in a
// mutable field (`c.cl_fields <- PMap.add ...`), the port reassigns the field:
// a record or a type that took the old map keeps it, as upstream's does.
// A map the port mutates in place is a core.ds.OrderedMap.
@:allow(core.ds.OrderedMap)
final class PMap<V> {
	static final emptyMap:PMap<Dynamic> = new PMap(new Vector(0), new Vector(0));

	final ks:Vector<String>;
	final vs:Vector<V>;

	public var size(get, never):Int;

	inline function get_size():Int return ks.length;

	function new(ks:Vector<String>, vs:Vector<V>) {
		this.ks = ks;
		this.vs = vs;
	}

	public static inline function empty<V>():PMap<V> return cast emptyMap;

	public static function singleton<V>(key:String, value:V):PMap<V> {
		var ks = new Vector<String>(1), vs = new Vector<V>(1);
		ks[0] = key;
		vs[0] = value;
		return new PMap(ks, vs);
	}

	// port: the map of successive `add`s of the pairs (the last value of a key
	// wins), sorted once.
	public static function ofArrays<V>(keys:Array<String>, values:Array<V>):PMap<V> {
		var n = keys.length;
		if (n == 0) return empty();
		var order = [for (i in 0...n) i];
		order.sort(function(a, b) {
			var c = Key.compareStrings(keys[a], keys[b]);
			return c != 0 ? c : a - b;
		});
		var m = 0;
		for (j in 0...n)
			if (j == n - 1 || keys[order[j]] != keys[order[j + 1]]) order[m++] = order[j];
		var ks = new Vector<String>(m), vs = new Vector<V>(m);
		for (j in 0...m) {
			ks[j] = keys[order[j]];
			vs[j] = values[order[j]];
		}
		return new PMap(ks, vs);
	}

	// port: keys already sorted and unique, their values at the same indices.
	static function ofSorted<V>(keys:Array<String>, values:Vector<V>):PMap<V> {
		var n = keys.length;
		if (n == 0) return empty();
		var ks = new Vector<String>(n);
		for (i in 0...n) ks[i] = keys[i];
		return new PMap(ks, values);
	}

	// port: the index of the first key not below key.
	function lowerBound(key:String):Int {
		var lo = 0, hi = ks.length;
		while (lo < hi) {
			var mid = (lo + hi) >> 1;
			if (Key.lessStrings(ks[mid], key)) lo = mid + 1;
			else hi = mid;
		}
		return lo;
	}

	inline function indexOf(key:String):Int {
		var i = lowerBound(key);
		return i < ks.length && ks[i] == key ? i : -1;
	}

	public inline function isEmpty():Bool return ks.length == 0;

	// port: the key and the value at index i of the key order (0 <= i < size): loops in
	// either direction without an iterator or a copy.
	public inline function keyAt(i:Int):String return ks[i];

	public inline function valueAt(i:Int):V return vs[i];

	public function exists(key:String):Bool return indexOf(key) >= 0;

	// port: PMap.find, raising Not_found.
	public function find(key:String):V {
		var i = indexOf(key);
		if (i < 0) throw NotFound.raise();
		return vs[i];
	}

	public function get(key:String):Null<V> {
		var i = indexOf(key);
		return i < 0 ? null : vs[i];
	}

	public function add(key:String, value:V):PMap<V> {
		var n = ks.length, i = lowerBound(key);
		if (i < n && ks[i] == key) {
			if (vs[i] == value) return this;
			var nv = vs.copy();
			nv[i] = value;
			return new PMap(ks, nv);
		}
		var nk = new Vector<String>(n + 1), nv = new Vector<V>(n + 1);
		Vector.blit(ks, 0, nk, 0, i);
		Vector.blit(vs, 0, nv, 0, i);
		nk[i] = key;
		nv[i] = value;
		Vector.blit(ks, i, nk, i + 1, n - i);
		Vector.blit(vs, i, nv, i + 1, n - i);
		return new PMap(nk, nv);
	}

	public function remove(key:String):PMap<V> {
		var i = indexOf(key);
		if (i < 0) return this;
		var n = ks.length - 1;
		if (n == 0) return empty();
		var nk = new Vector<String>(n), nv = new Vector<V>(n);
		Vector.blit(ks, 0, nk, 0, i);
		Vector.blit(vs, 0, nv, 0, i);
		Vector.blit(ks, i + 1, nk, i, n - i);
		Vector.blit(vs, i + 1, nv, i, n - i);
		return new PMap(nk, nv);
	}

	public function iter(f:String->V->Void):Void
		for (i in 0...ks.length) f(ks[i], vs[i]);

	public function fold<A>(f:V->A->A, acc:A):A {
		for (i in 0...ks.length) acc = f(vs[i], acc);
		return acc;
	}

	public function foldi<A>(f:String->V->A->A, acc:A):A {
		for (i in 0...ks.length) acc = f(ks[i], vs[i], acc);
		return acc;
	}

	// port: the map of f's results, sharing the keys. f runs in key order: extlib's
	// PMap.map visits its tree in post-order, which depends on the tree's history of
	// insertions, which no other layout keeps.
	public function map<W>(f:V->W):PMap<W> {
		var n = ks.length;
		if (n == 0) return empty();
		var nv = new Vector<W>(n);
		for (i in 0...n) nv[i] = f(vs[i]);
		return new PMap(ks, nv);
	}

	// port: the bindings f maps to a value, to that value (null drops one); f runs in key order.
	public function filterMap<W>(f:V->Null<W>):PMap<W> {
		var n = ks.length, keys = [], values = [];
		for (i in 0...n) {
			var w = f(vs[i]);
			if (w != null) {
				keys.push(ks[i]);
				values.push(w);
			}
		}
		return ofSorted(keys, Vector.fromArrayCopy(values));
	}

	// port: f of the values, in key order (f runs in that order).
	public function mapToArray<W>(f:V->W):Array<W> {
		var n = vs.length, out:Array<W> = [];
		out.resize(n);
		for (i in 0...n) out[i] = f(vs[i]);
		return out;
	}

	// port: the list `PMap.fold (fun v acc -> f v :: acc) m []` builds: f runs in key
	// order, its results are in reverse.
	public function foldCons<W>(f:V->W):Array<W> {
		var n = vs.length, out:Array<W> = [];
		out.resize(n);
		for (i in 0...n) out[n - 1 - i] = f(vs[i]);
		return out;
	}

	// port: map with the keys, in key order as map.
	public function mapi<W>(f:String->V->W):PMap<W> {
		var n = ks.length;
		if (n == 0) return empty();
		var nv = new Vector<W>(n);
		for (i in 0...n) nv[i] = f(ks[i], vs[i]);
		return new PMap(ks, nv);
	}

	// port: the keys in order, a new Array.
	public function keyArray():Array<String> {
		var out:Array<String> = [];
		out.resize(ks.length);
		for (i in 0...ks.length) out[i] = ks[i];
		return out;
	}

	// port: the values in key order, a new Array.
	public function valueArray():Array<V> {
		var out:Array<V> = [];
		out.resize(vs.length);
		for (i in 0...vs.length) out[i] = vs[i];
		return out;
	}

	public inline function keys():PMapKeyIterator return new PMapKeyIterator(ks);

	public inline function iterator():PMapValueIterator<V> return new PMapValueIterator(vs);

	public inline function keyValueIterator():PMapKeyValueIterator<V> return new PMapKeyValueIterator(ks, vs);
}

class PMapKeyIterator {
	final ks:Vector<String>;
	var i = 0;

	public inline function new(ks:Vector<String>) this.ks = ks;

	public inline function hasNext():Bool return i < ks.length;

	public inline function next():String return ks[i++];
}

class PMapValueIterator<V> {
	final vs:Vector<V>;
	var i = 0;

	public inline function new(vs:Vector<V>) this.vs = vs;

	public inline function hasNext():Bool return i < vs.length;

	public inline function next():V return vs[i++];
}

class PMapKeyValueIterator<V> {
	final ks:Vector<String>;
	final vs:Vector<V>;
	var i = 0;

	public inline function new(ks:Vector<String>, vs:Vector<V>) {
		this.ks = ks;
		this.vs = vs;
	}

	public inline function hasNext():Bool return i < ks.length;

	public inline function next():{key:String, value:V} {
		var j = i++;
		return {key: ks[j], value: vs[j]};
	}
}
