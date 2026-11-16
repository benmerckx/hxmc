package core.ds;

import haxe.ds.StringMap;

// port: a mutable map with string keys, iterated in key order (Key.compareStrings),
// for the port's own maps that upstream keeps in a PMap ref or a Hashtbl sorted
// before output and that nothing else holds: a StringMap and its keys sorted
// when first iterated, dropped when a key is added or removed. A map shared the
// way upstream's persistent maps are is a core.ds.PMap.
final class OrderedMap<V> {
	final map = new StringMap<V>();
	var sorted:Null<Array<String>>;

	public inline function new() {}

	public inline function exists(key:String):Bool return map.exists(key);

	public inline function get(key:String):Null<V> return map.get(key);

	public function find(key:String):V {
		if (!map.exists(key)) throw NotFound.raise();
		return map.get(key);
	}

	public function set(key:String, value:V):Void {
		if (sorted != null && !map.exists(key)) sorted = null;
		map.set(key, value);
	}

	public function remove(key:String):Bool {
		if (!map.remove(key)) return false;
		sorted = null;
		return true;
	}

	// port: the keys in order; the Array is shared until the next change of keys.
	public function sortedKeys():Array<String> {
		var s = sorted;
		if (s == null) {
			s = [for (k in map.keys()) k];
			s.sort(Key.compareStrings);
			sorted = s;
		}
		return s;
	}

	public inline function keys():Iterator<String> return sortedKeys().iterator();

	public function iter(f:String->V->Void):Void
		for (k in sortedKeys()) f(k, map.get(k));

	public function fold<A>(f:V->A->A, acc:A):A {
		for (k in sortedKeys()) acc = f(map.get(k), acc);
		return acc;
	}

	public function foldi<A>(f:String->V->A->A, acc:A):A {
		for (k in sortedKeys()) acc = f(k, map.get(k), acc);
		return acc;
	}

	// port: the values in key order.
	public inline function iterator():OrderedMapValueIterator<V> return new OrderedMapValueIterator(map, sortedKeys());

	// port: the persistent map of the same bindings, for a map built here and then kept.
	public function toPMap():PMap<V> {
		var ks = sortedKeys(), vs = new haxe.ds.Vector<V>(ks.length);
		for (i in 0...ks.length) vs[i] = map.get(ks[i]);
		return PMap.ofSorted(ks, vs);
	}
}

class OrderedMapValueIterator<V> {
	final map:StringMap<V>;
	final keys:Array<String>;
	var i = 0;

	public inline function new(map:StringMap<V>, keys:Array<String>) {
		this.map = map;
		this.keys = keys;
	}

	public inline function hasNext():Bool return i < keys.length;

	public inline function next():V return map.get(keys[i++]);
}
