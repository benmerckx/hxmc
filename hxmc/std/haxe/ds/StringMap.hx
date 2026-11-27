// hxmc: haxe/upstream/std/haxe/ds/StringMap.hx as a compact insertion-ordered hash table (as
// in Python and JS): entries are appended to fixed-size arrays, an
// open-addressing index with linear probing finds them (removals shift the
// probe chain back: no tombstones). Iteration follows insertion order.
// IntMap, StringMap and ObjectMap are the same code but for the key type,
// hash and equality, and what the index keeps beside each entry: here the
// key's hash (a string's own is cached in it, but the index's spares the
// loads of keys that collide), also kept by entry for the growth.
//
// Here only, so far: a small table (room for at most SMALL entries) has no
// index; a lookup scans the entries' hashes, which sit next to each other,
// and the arrays are sized for the entries alone, grown by half (1, 2, 3, 5
// and 8 entries; a table of one entry is less than half the size it
// was with an index of 8 slots).

package haxe.ds;

import hxmc.rt.MapSlots;
import hxmc.rt.MapSlots.RefSlots;
import hxmc.rt.MapSlots.MapRace;

/**
	StringMap allows mapping of String keys to arbitrary values.

	See `Map` for documentation details.

	@see https://haxe.org/manual/std-Map.html
**/
class StringMap<T> implements haxe.Constraints.IMap<String, T> {
	// the largest room of a table without an index, and the first room
	static inline var SMALL = 8;
	static inline var FIRST = 1;

	// the entries' hashes (room), then, past SMALL entries, the index (cap =
	// 2 * room slots of two elements: the key's hash and its entry + 1, 0 an
	// empty slot)
	var slots:MapSlots<Int>;
	// the entries' keys and values, interleaved (2 * room)
	var kvs:RefSlots;
	// the removed entries, null until the first removal
	var dead:MapSlots<Bool>;
	var used:Int; // entries appended, the removed ones included
	var live:Int;
	var room:Int; // the entries that fit before the next growth
	var mask:Int; // cap - 1 with an index, else 0
	// a write under way (MapRace: threads using the map together)
	var writing:Bool;

	/**
		Creates a new StringMap.
	**/
	public function new() {} // no arrays: the first set grows the table

	// (the string's FNV-1a hash mixed: its low bits, which pick the slot, alone
	// cluster keys that differ only in their last units)
	inline function hashOf(k:String):Int {
		var h = hxmc.rt.Str.strHash(k) * 0x9E3779B1;
		return h ^ (h >>> 16);
	}

	// (a removed entry's key is null and its hash 1, never the null key's 0:
	// the scan passes it)
	inline function find(k:String, h:Int):Int {
		var slots = this.slots, kvs = this.kvs, mask = this.mask;
		var r = -1;
		if (mask == 0) {
			var n = used;
			// (the arrays read once, their sizes tested once: MapSlots)
			if (n > 0 && (slots == null || kvs == null || n > slots.length || 2 * n > kvs.length)) throw MapRace.TORN;
			var j = 0;
			while (j < n) {
				if (slots.at(j) == h && (kvs.at(2 * j) : String) == k) {
					r = j;
					break;
				}
				j++;
			}
		} else {
			var ix = room;
			if (ix + 2 * mask + 2 > slots.length) throw MapRace.TORN;
			var i = h & mask, left = mask;
			while (true) {
				// (each slot once at most: an index without an empty slot is a race's, MapRace)
				if (--left < -1) throw MapRace.TORN;
				var e = slots.at(ix + 2 * i + 1);
				if (e == 0) break;
				// (an entry the index names: tested, its key and its value)
				if (slots.at(ix + 2 * i) == h) {
					if (e < 0 || e > kvs.length >> 1) throw MapRace.TORN;
					if ((kvs.at(2 * e - 2) : String) != k) {
						i = (i + 1) & mask;
						continue;
					}
					r = e - 1;
					break;
				}
				i = (i + 1) & mask;
			}
		}
		return r;
	}

	/**
		See `Map.get`
	**/
	public function get(k:String):Null<T> {
		if (writing) throw MapRace.READ_WRITE;
		var e = find(k, hashOf(k));
		// (find tested the entry)
		return e < 0 ? null : kvs.at(2 * e + 1);
	}

	/**
		See `Map.exists`
	**/
	public function exists(k:String):Bool {
		if (writing) throw MapRace.READ_WRITE;
		return find(k, hashOf(k)) >= 0;
	}

	// a write begins (another under way: a race, MapRace), and ends
	inline function begin() {
		if (writing) throw MapRace.WRITES;
		writing = true;
	}

	inline function end()
		writing = false;

	/**
		See `Map.set`
	**/
	public function set(k:String, v:T):Void {
		begin();
		var h = hashOf(k);
		var e = find(k, h);
		if (e >= 0)
			kvs.put(2 * e + 1, v); // (find tested the entry)
		else {
			if (used >= room) grow();
			add(k, v, h);
		}
		end();
	}

	// appends an entry (there is room for it) and indexes it
	inline function add(k:String, v:Dynamic, h:Int) {
		var slots = this.slots, kvs = this.kvs, mask = this.mask;
		var n = used++;
		slots[n] = h;
		kvs[2 * n] = k;
		kvs[2 * n + 1] = v;
		live++;
		if (mask != 0) {
			var ix = room;
			if (ix + 2 * mask + 2 > slots.length) throw MapRace.TORN;
			var i = h & mask, left = mask;
			while (slots.at(ix + 2 * i + 1) != 0) {
				i = (i + 1) & mask;
				if (--left < 0) throw MapRace.TORN;
			}
			slots.put(ix + 2 * i, h);
			slots.put(ix + 2 * i + 1, n + 1);
		}
	}

	// empties slot i, moving back the slots after it whose probe chain
	// passes through it (backward-shift deletion)
	function unindex(i:Int) {
		var slots = this.slots, mask = this.mask, ix = room;
		if (i < 0 || i > mask || ix + 2 * mask + 2 > slots.length) throw MapRace.TORN;
		var j = i, left = mask;
		while (true) {
			j = (j + 1) & mask;
			if (--left < 0) throw MapRace.TORN;
			var e = slots.at(ix + 2 * j + 1);
			if (e == 0) break;
			var home = slots.at(ix + 2 * j) & mask;
			// (j stays where it is when its home is cyclically in (i, j])
			if (i <= j ? (i < home && home <= j) : (i < home || home <= j)) continue;
			slots.put(ix + 2 * i, slots.at(ix + 2 * j));
			slots.put(ix + 2 * i + 1, e);
			i = j;
		}
		slots.put(ix + 2 * i + 1, 0);
	}

	/**
		See `Map.remove`
	**/
	public function remove(k:String):Bool {
		if (live == 0) {
			if (writing) throw MapRace.READ_WRITE;
			return false;
		}
		begin();
		var r = removeEntry(k);
		end();
		return r;
	}

	function removeEntry(k:String):Bool {
		var h = hashOf(k);
		var e = -1;
		if (mask == 0) {
			e = find(k, h);
			if (e < 0) return false;
		} else {
			var slots = this.slots, mask = this.mask, ix = room;
			var i = h & mask, left = mask;
			while (true) {
				if (--left < -1) throw MapRace.TORN;
				var f = slots[ix + 2 * i + 1];
				if (f == 0) return false;
				if (slots[ix + 2 * i] == h && (kvs[2 * f - 2] : String) == k) {
					unindex(i);
					e = f - 1;
					break;
				}
				i = (i + 1) & mask;
			}
		}
		if (dead == null) dead = new MapSlots<Bool>(room);
		dead[e] = true;
		slots[e] = 1;
		kvs[2 * e] = null;
		kvs[2 * e + 1] = null;
		live--;
		return true;
	}

	// rebuild with removed entries dropped and room for half again the live
	// ones in a small table, twice in an indexed one (a rebuild after removals
	// moves at most one entry per removal)
	function grow() {
		var r = live + ((live + 1) >> 1);
		if (r < FIRST) r = FIRST;
		if (r > SMALL) {
			r = 2 * SMALL;
			while (r < live * 2)
				r *= 2;
		}
		rebuild(r);
	}

	/**
		hxmc: room for `n` entries without growing (a capacity hint, as Go's
		`make(map[K]V, n)`): the table is rebuilt once if it is smaller.
	**/
	public function reserve(n:Int) {
		var r = n < FIRST ? FIRST : n;
		if (r > SMALL) {
			r = 2 * SMALL;
			while (r < n)
				r *= 2;
		}
		if (r > room && r > used) {
			begin();
			rebuild(r);
			end();
		}
	}

	// the table with room for r entries (and an index of 2 * r slots past
	// SMALL), the live entries added again
	function rebuild(r:Int) {
		var os = slots, okvs = kvs, od = dead, on = used;
		if (r <= SMALL) {
			slots = new MapSlots<Int>(r);
			mask = 0;
		} else {
			slots = new MapSlots<Int>(5 * r);
			mask = 2 * r - 1;
		}
		kvs = new RefSlots(2 * r);
		room = r;
		dead = null;
		used = 0;
		live = 0;
		for (j in 0...on)
			if (od == null || !od[j]) add(okvs[2 * j], okvs[2 * j + 1], os[j]);
	}

	/**
		See `Map.keys`

		(java) Implementation detail: Do not `set()` any new value while
		iterating, as it may cause a resize, which will break iteration.
	**/
	public function keys():Iterator<String>
		return new StringMapIterator(this, 0);

	/**
		See `Map.iterator`

		(java) Implementation detail: Do not `set()` any new value while
		iterating, as it may cause a resize, which will break iteration.
	**/
	public function iterator():Iterator<T>
		return cast new StringMapIterator(this, 1);

	/**
		See `Map.keyValueIterator`
	**/
	@:runtime public inline function keyValueIterator():KeyValueIterator<String, T>
		return new haxe.iterators.MapKeyValueIterator(this);

	/**
		See `Map.copy`
	**/
	public function copy():StringMap<T> {
		// (sized once; the keys are unique and their hashes kept: appended, not looked up)
		if (writing) throw MapRace.READ_WRITE;
		var m = new StringMap<T>();
		if (live == 0) return m;
		m.reserve(live);
		for (j in 0...used)
			if (dead == null || !dead[j]) m.add(kvs[2 * j], kvs[2 * j + 1], slots[j]);
		return m;
	}

	/**
		See `Map.toString`
	**/
	public function toString():String {
		if (writing) throw MapRace.READ_WRITE;
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
		begin();
		slots = null;
		kvs = null;
		dead = null;
		used = 0;
		live = 0;
		room = 0;
		mask = 0;
		end();
	}

	public function size():Int
		return live;
}

@:access(haxe.ds.StringMap)
private class StringMapIterator<T> {
	var m:StringMap<T>;
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
		if (m.writing) throw MapRace.READ_WRITE;
		if (i >= m.used) return null; // (past the end)
		var r:Dynamic = m.kvs[2 * i + at];
		i++;
		skip();
		return r;
	}
}
