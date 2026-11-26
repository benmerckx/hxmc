// hxmc: haxe/upstream/std/haxe/ds/ObjectMap.hx as a compact insertion-ordered hash table (as
// in Python and JS): entries are appended to fixed-size arrays, an
// open-addressing index with linear probing finds them. Iteration follows
// insertion order. IntMap, StringMap and ObjectMap are the same code but for
// the key type, hash and equality, and where a key's hash is kept.
//
// Here a key's hash is its address (docs/hxmc.md, "Identity maps";
// hxmc.rt.IdHash), kept in the index beside the entry: the collector moves
// objects, so the index remembers the collection count it was built at and is
// brought up to date before the next hash (update): after minor collections
// only the entries whose key was young when added (listed in `young`) are
// indexed again, after a major one every entry. Removals shift the probe
// chain back (no tombstones).

package haxe.ds;

import hxmc.rt.MapSlots;
import hxmc.rt.MapSlots.RefSlots;
import hxmc.rt.MapSlots.MapRace;
import hxmc.rt.IdHash;

/**
	ObjectMap allows mapping of object keys to arbitrary values.

	On static targets, the keys are considered to be strong references. Refer
	to `haxe.ds.WeakMap` for a weak reference version.

	See `Map` for documentation details.

	@see https://haxe.org/manual/std-Map.html
**/
class ObjectMap<K:{}, T> implements haxe.Constraints.IMap<K, T> {
	// the index: element 0 the collection count it is up to date with
	// (IdHash.seen), 1 unused, then cap slots of two elements: the key's
	// hash and its entry + 1 (0: an empty slot)
	var slots:MapSlots<Int>;
	// the entries' keys and values, interleaved (2 * room, room = cap / 2:
	// the entries that fit before the next growth)
	var kvs:RefSlots;
	// the removed entries, null until the first removal
	var dead:MapSlots<Bool>;
	// (entry, hash) pairs: the entries whose key was in the nursery when
	// added since the index was last brought up to date (youngCap pairs)
	var young:MapSlots<Int>;
	var nyoung:Int;
	var youngCap:Int;
	var majors:Int; // the major collections the index is up to date with
	var used:Int; // entries appended, the removed ones included
	var live:Int;
	var mask:Int; // cap - 1
	// a write under way (MapRace: threads using the map together; bringing
	// the index up to date is not one, threads that only read do it)
	var writing:Bool;

	/**
		Creates a new ObjectMap.
	**/
	public function new()
		mask = -1; // no arrays: the first set grows the table

	inline function hashOf(k:Dynamic):Int {
		return IdHash.hash(k);
	}

	// the index brought up to date with the collections since
	inline function sync() {
		var slots = this.slots;
		if (slots == null) throw MapRace.TORN;
		if (IdHash.seen(slots) != IdHash.count() && !update()) throw MapRace.TORN;
	}

	// a write begins (another under way: a race, MapRace), and ends
	inline function begin() {
		if (writing) throw MapRace.WRITES;
		writing = true;
	}

	inline function end()
		writing = false;

	// the entry of k (whose hash is h), or -1; the index is up to date
	inline function find(k:Dynamic, h:Int):Int {
		var slots = this.slots, kvs = this.kvs, mask = this.mask;
		// (the arrays read once, the index's size tested once: MapSlots; an entry the index names, tested)
		if (!fits(slots, mask)) throw MapRace.TORN;
		var i = h & mask;
		var r = -1, left = mask;
		while (true) {
			// (each slot once at most: an index without an empty slot is a race's, MapRace)
			if (--left < -1) throw MapRace.TORN;
			var e = slots.at(3 + 2 * i);
			if (e == 0) break;
			if (slots.at(2 + 2 * i) == h) {
				if (e < 0 || e > kvs.length >> 1) throw MapRace.TORN;
				if (hxmc.Native.refEq(kvs.at(2 * e - 2), k)) {
					r = e - 1;
					break;
				}
			}
			i = (i + 1) & mask;
		}
		return r;
	}

	/**
		See `Map.get`
	**/
	public function get(k:K):Null<T> {
		if (writing) throw MapRace.READ_WRITE;
		if (live == 0) return null;
		sync();
		var e = find(k, hashOf(k));
		// (find tested the entry)
		return e < 0 ? null : kvs.at(2 * e + 1);
	}

	/**
		See `Map.exists`
	**/
	public function exists(k:K):Bool {
		if (writing) throw MapRace.READ_WRITE;
		if (live == 0) return false;
		sync();
		return find(k, hashOf(k)) >= 0;
	}

	/**
		See `Map.set`
	**/
	public function set(k:K, v:T):Void {
		begin();
		var e = -1;
		if (live > 0) {
			sync();
			e = find(k, hashOf(k));
		}
		if (e >= 0)
			kvs.put(2 * e + 1, v); // (find tested the entry)
		else {
			// the allocations first: a collection they run moves keys, so the
			// hash is taken after them
			if (used >= (mask + 1) >> 1) grow();
			if (nyoung == youngCap && IdHash.young(k)) growYoung();
			sync();
			add(k, v);
		}
		end();
	}

	// appends an entry (there is room for it, and in `young`) and indexes it;
	// the index is up to date
	inline function add(k:Dynamic, v:Dynamic) {
		var kvs = this.kvs;
		var n = used++;
		kvs[2 * n] = k;
		kvs[2 * n + 1] = v;
		live++;
		var h = hashOf(k);
		index(h, n);
		if (IdHash.young(k)) {
			young[2 * nyoung] = n;
			young[2 * nyoung + 1] = h;
			nyoung++;
		}
	}

	inline function index(h:Int, e:Int) {
		var slots = this.slots, mask = this.mask;
		if (!fits(slots, mask) || !indexIn(slots, mask, h, e)) throw MapRace.TORN;
	}

	// (without a GC point) the index's slot for entry e, whose hash is h, in
	// an index of `slots` and `mask` whose size the caller has tested; false
	// where the index has no empty slot (a race's: MapRace)
	@:hxmc.unsafe static inline function indexIn(slots:MapSlots<Int>, mask:Int, h:Int, e:Int):Bool {
		var i = h & mask, left = mask;
		while (slots.at(3 + 2 * i) != 0 && left >= 0) {
			i = (i + 1) & mask;
			left--;
		}
		if (left < 0) return false;
		slots.put(2 + 2 * i, h);
		slots.put(3 + 2 * i, e + 1);
		return true;
	}

	// (without a GC point) whether `slots` holds an index of mask + 1 slots:
	// not where a write under way on another thread grew the table between
	// the reads of the two (MapRace)
	@:hxmc.unsafe static inline function fits(slots:MapSlots<Int>, mask:Int):Bool
		return slots != null && mask >= 0 && slots.length >= 4 + 2 * mask;

	// empties slot i, moving back the slots after it whose probe chain
	// passes through it (backward-shift deletion: no tombstones); false where
	// the index is not of the size it should be (MapRace)
	@:hxmc.unsafe static function unindex(slots:MapSlots<Int>, mask:Int, i:Int):Bool {
		if (!fits(slots, mask) || i < 0 || i > mask) return false;
		var j = i, left = mask;
		while (true) {
			j = (j + 1) & mask;
			if (--left < 0) return false;
			var e = slots.at(3 + 2 * j);
			if (e == 0) break;
			var home = slots.at(2 + 2 * j) & mask;
			// (j stays where it is when its home is cyclically in (i, j])
			if (i <= j ? (i < home && home <= j) : (i < home || home <= j)) continue;
			slots.put(2 + 2 * i, slots.at(2 + 2 * j));
			slots.put(3 + 2 * i, e);
			i = j;
		}
		slots.put(3 + 2 * i, 0);
		return true;
	}

	/**
		See `Map.remove`
	**/
	public function remove(k:K):Bool {
		if (live == 0) {
			if (writing) throw MapRace.READ_WRITE;
			return false;
		}
		begin();
		var r = removeEntry(k);
		end();
		return r;
	}

	function removeEntry(k:K):Bool {
		if (dead == null) dead = new MapSlots<Bool>((mask + 1) >> 1); // (before the hash)
		sync();
		var slots = this.slots, kvs = this.kvs, mask = this.mask;
		var h = hashOf(k);
		var i = h & mask, left = mask;
		while (true) {
			if (--left < -1) throw MapRace.TORN;
			var e = slots[3 + 2 * i];
			if (e == 0) return false;
			if (slots[2 + 2 * i] == h && hxmc.Native.refEq(kvs[2 * e - 2], k)) {
				if (!unindex(slots, mask, i)) throw MapRace.TORN;
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
	// (a table that only grows doubles: at 1/2 full, to 1/4; a rebuild after
	// removals moves at most one entry per removal);
	// the index is up to date, or there is no live entry
	function grow() {
		var okvs = kvs, od = dead, on = used;
		var cap = 8;
		while (cap < live * 4)
			cap *= 2;
		var room = cap >> 1;
		var s = new MapSlots<Int>(2 + 2 * cap);
		kvs = new RefSlots(2 * room);
		// (a collection may have run during these allocations: the hashes are
		// taken after them; the keys young now were young before, so `young`
		// has room for them)
		slots = s;
		dead = null;
		used = 0;
		live = 0;
		nyoung = 0;
		mask = cap - 1;
		for (j in 0...on)
			if (od == null || !od[j]) add(okvs[2 * j], okvs[2 * j + 1]);
		majors = IdHash.majors();
		IdHash.setSeen(s, IdHash.count());
	}

	function growYoung() {
		var cap = youngCap == 0 ? 8 : 2 * youngCap;
		var y = new MapSlots<Int>(2 * cap);
		for (j in 0...2 * nyoung)
			y[j] = young[j];
		young = y;
		youngCap = cap;
	}

	// the index brought up to date with the collections since it last was
	// (the first thread to find it out of date does it: a map may be shared
	// by threads that only read it); no allocation. It reads the table once:
	// false where its arrays and counts are not of one size (a write under way
	// on another thread: MapRace; the caller throws, the lock released)
	@:hxmc.unsafe function update():Bool {
		IdHash.lock();
		var ok = true;
		var n = IdHash.count();
		var slots = this.slots, kvs = this.kvs, dead = this.dead, young = this.young;
		var mask = this.mask, used = this.used, nyoung = this.nyoung;
		if (slots == null)
			ok = false;
		else if (IdHash.seen(slots) != n) {
			if (!fits(slots, mask) || kvs == null || kvs.length < 2 * used || (dead != null && dead.length < used)
				|| (nyoung > 0 && (young == null || young.length < 2 * nyoung)))
				ok = false;
			else {
				var m = IdHash.majors();
				if (m != majors || 2 * nyoung > live) {
					// every key moved (or most of them): index them all again
					for (i in 0...mask + 1)
						slots.put(3 + 2 * i, 0);
					for (e in 0...used)
						if ((dead == null || !dead.at(e)) && !indexIn(slots, mask, hashOf(kvs.at(2 * e)), e)) {
							ok = false;
							break;
						}
				} else {
					// minor collections: the keys young when added moved, the others did not
					for (j in 0...nyoung) {
						var e = young.at(2 * j);
						if (e < 0 || e >= used) {
							ok = false;
							break;
						}
						if (dead != null && dead.at(e)) continue;
						// (its slot, in the probe chain of the hash it was added with: each slot once at most)
						var i = young.at(2 * j + 1) & mask, probes = 0;
						while (slots.at(3 + 2 * i) != e + 1 && probes <= mask) {
							i = (i + 1) & mask;
							probes++;
						}
						if (probes > mask || !unindex(slots, mask, i)) {
							ok = false;
							break;
						}
						if (!indexIn(slots, mask, hashOf(kvs.at(2 * e)), e)) {
							ok = false;
							break;
						}
					}
				}
				if (ok) {
					// (the nursery is empty after a collection: no key is young)
					this.nyoung = 0;
					if (youngCap > 1024) {
						this.young = null;
						youngCap = 0;
					}
					majors = m;
					IdHash.setSeen(slots, n);
				}
			}
		}
		IdHash.unlock();
		return ok;
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
		if (writing) throw MapRace.READ_WRITE;
		var m = new ObjectMap<K, T>();
		for (j in 0...used)
			if (dead == null || !dead[j]) m.set(kvs[2 * j], kvs[2 * j + 1]);
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
		young = null;
		nyoung = 0;
		youngCap = 0;
		used = 0;
		live = 0;
		mask = -1;
		end();
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
		if (m.writing) throw MapRace.READ_WRITE;
		if (i >= m.used) return null; // (past the end)
		var r:Dynamic = m.kvs[2 * i + at];
		i++;
		skip();
		return r;
	}
}
