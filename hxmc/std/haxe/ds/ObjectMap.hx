// hxmc: haxe/upstream/std/haxe/ds/ObjectMap.hx as a compact insertion-ordered hash table (as
// in Python and JS): entries are appended to fixed-size arrays, an
// open-addressing index (0 empty, -1 removed, else entry + 1) finds them.
// Iteration follows insertion order. IntMap, StringMap and ObjectMap are the
// same code but for the key type, hash and equality, and where a key's hash
// is kept: here in the key's header (keys compare by address, as cheaply as
// hashes would).

package haxe.ds;

import hxmc.rt.MapSlots;

/**
	ObjectMap allows mapping of object keys to arbitrary values.

	On static targets, the keys are considered to be strong references. Refer
	to `haxe.ds.WeakMap` for a weak reference version.

	See `Map` for documentation details.

	@see https://haxe.org/manual/std-Map.html
**/
class ObjectMap<K:{}, T> implements haxe.Constraints.IMap<K, T> {
	// the index (cap slots)
	var slots:MapSlots<Int>;
	// the entries' keys and values, interleaved (2 * room, room = cap * 3 / 4:
	// the entries that fit before the next growth)
	var kvs:MapSlots<Dynamic>;
	// the removed entries, null until the first removal
	var dead:MapSlots<Bool>;
	var used:Int; // entries appended, the removed ones included
	var live:Int;
	var mask:Int; // cap - 1

	/**
		Creates a new ObjectMap.
	**/
	public function new()
		mask = -1; // no arrays: the first set grows the table

	inline function hashOf(k:K):Int {
		return hxmc.Native.objHash(k);
	}

	inline function find(k:K):Int {
		if (live == 0) return -1;
		var slots = this.slots, mask = this.mask;
		var i = hashOf(k) & mask;
		var r = -1;
		while (true) {
			var e = slots[i];
			if (e == 0) break;
			if (e > 0 && hxmc.Native.refEq(kvs[2 * e - 2], k)) {
				r = e - 1;
				break;
			}
			i = (i + 1) & mask;
		}
		return r;
	}

	/**
		See `Map.get`
	**/
	public function get(k:K):Null<T> {
		var e = find(k);
		return e < 0 ? null : kvs[2 * e + 1];
	}

	/**
		See `Map.exists`
	**/
	public function exists(k:K):Bool
		return find(k) >= 0;

	/**
		See `Map.set`
	**/
	public function set(k:K, v:T):Void {
		var e = find(k);
		if (e >= 0) {
			kvs[2 * e + 1] = v;
			return;
		}
		if ((used + 1) * 4 > (mask + 1) * 3) grow();
		add(k, v);
	}

	// appends an entry (there is room for it) and indexes it
	inline function add(k:Dynamic, v:Dynamic) {
		var slots = this.slots, kvs = this.kvs, mask = this.mask;
		var n = used++;
		kvs[2 * n] = k;
		kvs[2 * n + 1] = v;
		live++;
		var i = hashOf(k) & mask;
		while (slots[i] > 0)
			i = (i + 1) & mask;
		slots[i] = n + 1;
	}

	/**
		See `Map.remove`
	**/
	public function remove(k:K):Bool {
		if (live == 0) return false;
		var slots = this.slots, kvs = this.kvs, mask = this.mask;
		var i = hashOf(k) & mask;
		while (true) {
			var e = slots[i];
			if (e == 0) return false;
			if (e > 0 && hxmc.Native.refEq(kvs[2 * e - 2], k)) {
				slots[i] = -1;
				if (dead == null) dead = new MapSlots<Bool>(((mask + 1) * 3) >> 2);
				dead[e - 1] = true;
				kvs[2 * e - 2] = null;
				kvs[2 * e - 1] = null;
				live--;
				return true;
			}
			i = (i + 1) & mask;
		}
	}

	// rebuild with removed entries dropped and room for twice the live ones
	function grow() {
		var okvs = kvs, od = dead, on = used;
		var cap = 8;
		while (cap * 3 < (live + 1) * 8)
			cap *= 2;
		var room = (cap * 3) >> 2;
		slots = new MapSlots<Int>(cap);
		kvs = new MapSlots<Dynamic>(2 * room);
		dead = null;
		used = 0;
		live = 0;
		mask = cap - 1;
		for (j in 0...on)
			if (od == null || !od[j]) add(okvs[2 * j], okvs[2 * j + 1]);
	}

	/**
		See `Map.keys`

		(java) Implementation detail: Do not `set()` any new value while
		iterating, as it may cause a resize, which will break iteration.
	**/
	public function keys():Iterator<K>
		return new ObjectMapIterator(this, 0);

	/**
		See `Map.iterator`

		(java) Implementation detail: Do not `set()` any new value while
		iterating, as it may cause a resize, which will break iteration.
	**/
	public function iterator():Iterator<T>
		return cast new ObjectMapIterator(this, 1);

	/**
		See `Map.keyValueIterator`
	**/
	@:runtime public inline function keyValueIterator():KeyValueIterator<K, T>
		return new haxe.iterators.MapKeyValueIterator(this);

	/**
		See `Map.copy`
	**/
	public function copy():ObjectMap<K, T> {
		var m = new ObjectMap<K, T>();
		for (j in 0...used)
			if (dead == null || !dead[j]) m.set(kvs[2 * j], kvs[2 * j + 1]);
		return m;
	}

	/**
		See `Map.toString`
	**/
	public function toString():String {
		var b = new StringBuf();
		b.add("[");
		var first = true;
		for (j in 0...used)
			if (dead == null || !dead[j]) {
				if (!first) b.add(", ");
				first = false;
				b.add(Std.string(kvs[2 * j]));
				b.add(" => ");
				b.add(Std.string(kvs[2 * j + 1]));
			}
		b.add("]");
		return b.toString();
	}

	/**
		See `Map.clear`
	**/
	public function clear():Void {
		slots = null;
		kvs = null;
		dead = null;
		used = 0;
		live = 0;
		mask = -1;
	}

	public function size():Int
		return live;
}

@:access(haxe.ds.ObjectMap)
private class ObjectMapIterator<K:{}, T> {
	var m:ObjectMap<K, T>;
	var i:Int;
	var at:Int; // 0 keys, 1 values

	public function new(m, at) {
		this.m = m;
		this.at = at;
		i = 0;
		skip();
	}

	inline function skip() {
		if (m.dead != null)
			while (i < m.used && m.dead[i])
				i++;
	}

	public function hasNext():Bool
		return i < m.used;

	public function next():Dynamic {
		if (i >= m.used) return null; // (past the end)
		var r:Dynamic = m.kvs[2 * i + at];
		i++;
		skip();
		return r;
	}
}
