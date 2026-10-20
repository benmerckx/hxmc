// hxmc: haxe/upstream/std/haxe/ds/IntMap.hx as a compact insertion-ordered hash table (as
// in Python and JS): entries are appended to fixed-size arrays, an
// open-addressing index with linear probing finds them (removals shift the
// probe chain back: no tombstones). Iteration follows insertion order.
// IntMap, StringMap and ObjectMap are the same code but for the key type,
// hash and equality, and what the index keeps beside each entry: here the
// key, compared without another load (its hash is computed again).

package haxe.ds;

import hxmc.rt.MapSlots;
import hxmc.rt.MapSlots.RefSlots;

/**
	IntMap allows mapping of Int keys to arbitrary values.

	See `Map` for documentation details.

	@see https://haxe.org/manual/std-Map.html
**/
class IntMap<T> implements haxe.Constraints.IMap<Int, T> {
	// the index (cap slots of two elements: the key and its entry + 1, 0 an
	// empty slot), then the entries' keys (room = cap / 2: the entries
	// that fit before the next growth)
	var slots:MapSlots<Int>;
	// the entries' values (room)
	var vs:RefSlots;
	// the removed entries, null until the first removal
	var dead:MapSlots<Bool>;
	var used:Int; // entries appended, the removed ones included
	var live:Int;
	var mask:Int; // cap - 1

	/**
		Creates a new IntMap.
	**/
	public function new()
		mask = -1; // no arrays: the first set grows the table

	inline function hashOf(k:Int):Int {
		var h = k * 0x9E3779B1;
		return h ^ (h >>> 16);
	}

	inline function find(k:Int):Int {
		if (live == 0) return -1;
		var slots = this.slots, mask = this.mask;
		var i = hashOf(k) & mask;
		var r = -1;
		while (true) {
			var e = slots[2 * i + 1];
			if (e == 0) break;
			if (slots[2 * i] == k) {
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
	public function get(k:Int):Null<T> {
		var e = find(k);
		return e < 0 ? null : vs[e];
	}

	/**
		See `Map.exists`
	**/
	public function exists(k:Int):Bool
		return find(k) >= 0;

	/**
		See `Map.set`
	**/
	public function set(k:Int, v:T):Void {
		var e = find(k);
		if (e >= 0) {
			vs[e] = v;
			return;
		}
		if (used >= (mask + 1) >> 1) grow();
		add(k, v);
	}

	// appends an entry (there is room for it) and indexes it
	inline function add(k:Int, v:Dynamic) {
		var slots = this.slots, mask = this.mask;
		var n = used++;
		slots[2 * (mask + 1) + n] = k;
		vs[n] = v;
		live++;
		var i = hashOf(k) & mask;
		while (slots[2 * i + 1] != 0)
			i = (i + 1) & mask;
		slots[2 * i] = k;
		slots[2 * i + 1] = n + 1;
	}

	// empties slot i, moving back the slots after it whose probe chain
	// passes through it (backward-shift deletion)
	function unindex(i:Int) {
		var slots = this.slots, mask = this.mask;
		var j = i;
		while (true) {
			j = (j + 1) & mask;
			var e = slots[2 * j + 1];
			if (e == 0) break;
			var home = hashOf(slots[2 * j]) & mask;
			// (j stays where it is when its home is cyclically in (i, j])
			if (i <= j ? (i < home && home <= j) : (i < home || home <= j)) continue;
			slots[2 * i] = slots[2 * j];
			slots[2 * i + 1] = e;
			i = j;
		}
		slots[2 * i + 1] = 0;
	}

	/**
		See `Map.remove`
	**/
	public function remove(k:Int):Bool {
		if (live == 0) return false;
		var slots = this.slots, mask = this.mask;
		var i = hashOf(k) & mask;
		while (true) {
			var e = slots[2 * i + 1];
			if (e == 0) return false;
			if (slots[2 * i] == k) {
				unindex(i);
				if (dead == null) dead = new MapSlots<Bool>((mask + 1) >> 1);
				dead[e - 1] = true;
				vs[e - 1] = null;
				live--;
				return true;
			}
			i = (i + 1) & mask;
		}
	}

	// rebuild with removed entries dropped and room for twice the live ones
	// (a table that only grows doubles: at 1/2 full, to 1/4; a rebuild after
	// removals moves at most one entry per removal)
	function grow() {
		var os = slots, ovs = vs, od = dead, on = used, ocap = mask + 1;
		var cap = 8;
		while (cap < live * 4)
			cap *= 2;
		var room = cap >> 1;
		slots = new MapSlots<Int>(2 * cap + room);
		vs = new RefSlots(room);
		dead = null;
		used = 0;
		live = 0;
		mask = cap - 1;
		for (j in 0...on)
			if (od == null || !od[j]) add(os[2 * ocap + j], ovs[j]);
	}

	/**
		See `Map.keys`

		(java) Implementation detail: Do not `set()` any new value while
		iterating, as it may cause a resize, which will break iteration.
	**/
	public function keys():Iterator<Int>
		return new IntMapIterator(this, true);

	/**
		See `Map.iterator`

		(java) Implementation detail: Do not `set()` any new value while
		iterating, as it may cause a resize, which will break iteration.
	**/
	public function iterator():Iterator<T>
		return cast new IntMapIterator(this, false);

	/**
		See `Map.keyValueIterator`
	**/
	@:runtime public inline function keyValueIterator():KeyValueIterator<Int, T>
		return new haxe.iterators.MapKeyValueIterator(this);

	/**
		See `Map.copy`
	**/
	public function copy():IntMap<T> {
		var m = new IntMap<T>();
		for (j in 0...used)
			if (dead == null || !dead[j]) m.set(slots[2 * (mask + 1) + j], vs[j]);
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
				b.add(Std.string(slots[2 * (mask + 1) + j]));
				b.add(" => ");
				b.add(Std.string(vs[j]));
			}
		b.add("]");
		return b.toString();
	}

	/**
		See `Map.clear`
	**/
	public function clear():Void {
		slots = null;
		vs = null;
		dead = null;
		used = 0;
		live = 0;
		mask = -1;
	}

	public function size():Int
		return live;
}

@:access(haxe.ds.IntMap)
private class IntMapIterator<T> {
	var m:IntMap<T>;
	var i:Int;
	var keys:Bool;

	public function new(m, keys) {
		this.m = m;
		this.keys = keys;
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
		var r:Dynamic = keys ? m.slots[2 * (m.mask + 1) + i] : m.vs[i];
		i++;
		skip();
		return r;
	}
}
