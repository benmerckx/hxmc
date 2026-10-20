package core.ds;

import haxe.ds.StringMap;

// port: OCaml PMap with string keys. Updates copy the table; iteration follows
// key order, never hash order.
class PMap {
	public static function empty<V>():StringMap<V> return new StringMap();

	public static function add<V>(key:String, value:V, map:StringMap<V>):StringMap<V> {
		var out = map.copy();
		out.set(key, value);
		return out;
	}

	public static function remove<V>(key:String, map:StringMap<V>):StringMap<V> {
		var out = map.copy();
		out.remove(key);
		return out;
	}

	public static function find<V>(key:String, map:StringMap<V>):V {
		if (!map.exists(key)) throw NotFound.raise();
		return map.get(key);
	}

	public static function findOpt<V>(key:String, map:StringMap<V>):Null<V> return map.get(key);

	public static function mem<V>(key:String, map:StringMap<V>):Bool return map.exists(key);

	public static function exists<V>(key:String, map:StringMap<V>):Bool return map.exists(key);

	public static function isEmpty<V>(map:StringMap<V>):Bool return !map.keys().hasNext();

	public static function keys<V>(map:StringMap<V>):Array<String> {
		var keys = [for (k in map.keys()) k];
		keys.sort(core.ds.Key.compareStrings);
		return keys;
	}

	public static function iter<V>(f:String->V->Void, map:StringMap<V>):Void for (k in keys(map)) f(k, map.get(k));

	public static function fold<V, A>(f:V->A->A, map:StringMap<V>, acc:A):A {
		for (k in keys(map)) acc = f(map.get(k), acc);
		return acc;
	}

	public static function foldi<V, A>(f:String->V->A->A, map:StringMap<V>, acc:A):A {
		for (k in keys(map)) acc = f(k, map.get(k), acc);
		return acc;
	}

	public static function map<V, W>(f:V->W, map:StringMap<V>):StringMap<W> {
		var out = new StringMap<W>();
		for (k in keys(map)) out.set(k, f(map.get(k)));
		return out;
	}
}
