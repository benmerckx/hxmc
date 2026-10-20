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
// chain back (no tombstones). WasmGC has no addresses: there the hash is the
// one the engine's object keeps (hxmc.Native.objHash), which never changes.

package haxe.ds;

import hxmc.rt.MapSlots;
import hxmc.rt.MapSlots.RefSlots;
#if !hxmc.wasm_gc
import hxmc.rt.IdHash;
#end

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

	/**
		Creates a new ObjectMap.
	**/
	public function new()
		mask = -1; // no arrays: the first set grows the table

	inline function hashOf(k:Dynamic):Int {
		#if hxmc.wasm_gc
		return hxmc.Native.objHash(k);
		#else
		return IdHash.hash(k);
		#end
	}

	// the index brought up to date with the collections since (none on WasmGC)
	inline function sync() {
		#if !hxmc.wasm_gc
		if (IdHash.seen(slots) != IdHash.count()) update();
		#end
	}

	// the entry of k (whose hash is h), or -1; the index is up to date
	inline function find(k:Dynamic, h:Int):Int {
		var slots = this.slots, kvs = this.kvs, mask = this.mask;
		var i = h & mask;
		var r = -1;
		while (true) {
			var e = slots[3 + 2 * i];
			if (e == 0) break;
			if (slots[2 + 2 * i] == h && hxmc.Native.refEq(kvs[2 * e - 2], k)) {
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
		if (live == 0) return null;
		sync();
		var e = find(k, hashOf(k));
		return e < 0 ? null : kvs[2 * e + 1];
	}

	/**
		See `Map.exists`
	**/
	public function exists(k:K):Bool {
		if (live == 0) return false;
		sync();
		return find(k, hashOf(k)) >= 0;
	}

	/**
		See `Map.set`
	**/
	public function set(k:K, v:T):Void {
		if (live > 0) {
			sync();
			var e = find(k, hashOf(k));
			if (e >= 0) {
				kvs[2 * e + 1] = v;
				return;
			}
		}
		// the allocations first: a collection they run moves keys, so the
		// hash is taken after them
		if (used >= (mask + 1) >> 1) grow();
		#if !hxmc.wasm_gc
		if (nyoung == youngCap && IdHash.young(k)) growYoung();
		sync();
		#end
		add(k, v);
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
		#if !hxmc.wasm_gc
		if (IdHash.young(k)) {
			young[2 * nyoung] = n;
			young[2 * nyoung + 1] = h;
			nyoung++;
		}
		#end
	}

	inline function index(h:Int, e:Int) {
		var slots = this.slots, mask = this.mask;
		var i = h & mask;
		while (slots[3 + 2 * i] != 0)
			i = (i + 1) & mask;
		slots[2 + 2 * i] = h;
		slots[3 + 2 * i] = e + 1;
	}

	// empties slot i, moving back the slots after it whose probe chain
	// passes through it (backward-shift deletion: no tombstones)
	@:hxmc.noGc function unindex(i:Int) {
		var slots = this.slots, mask = this.mask;
		var j = i;
		while (true) {
			j = (j + 1) & mask;
			var e = slots[3 + 2 * j];
			if (e == 0) break;
			var home = slots[2 + 2 * j] & mask;
			// (j stays where it is when its home is cyclically in (i, j])
			if (i <= j ? (i < home && home <= j) : (i < home || home <= j)) continue;
			slots[2 + 2 * i] = slots[2 + 2 * j];
			slots[3 + 2 * i] = e;
			i = j;
		}
		slots[3 + 2 * i] = 0;
	}

	/**
		See `Map.remove`
	**/
	public function remove(k:K):Bool {
		if (live == 0) return false;
		if (dead == null) dead = new MapSlots<Bool>((mask + 1) >> 1); // (before the hash)
		sync();
		var slots = this.slots, kvs = this.kvs, mask = this.mask;
		var h = hashOf(k);
		var i = h & mask;
		while (true) {
			var e = slots[3 + 2 * i];
			if (e == 0) return false;
			if (slots[2 + 2 * i] == h && hxmc.Native.refEq(kvs[2 * e - 2], k)) {
				unindex(i);
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
		#if !hxmc.wasm_gc
		majors = IdHash.majors();
		IdHash.setSeen(s, IdHash.count());
		#end
	}

	#if !hxmc.wasm_gc
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
	// by threads that only read it); no allocation
	@:hxmc.noGc function update() {
		IdHash.lock();
		var n = IdHash.count();
		if (IdHash.seen(slots) != n) {
			var m = IdHash.majors();
			if (m != majors || 2 * nyoung > live) {
				// every key moved (or most of them): index them all again
				var slots = this.slots;
				for (i in 0...mask + 1)
					slots[3 + 2 * i] = 0;
				for (e in 0...used)
					if (dead == null || !dead[e]) index(hashOf(kvs[2 * e]), e);
			} else {
				// minor collections: the keys young when added moved, the others did not
				var slots = this.slots, mask = this.mask, young = this.young;
				for (j in 0...nyoung) {
					var e = young[2 * j];
					if (dead != null && dead[e]) continue;
					// (its slot, in the probe chain of the hash it was added with)
					var i = young[2 * j + 1] & mask;
					while (slots[3 + 2 * i] != e + 1)
						i = (i + 1) & mask;
					unindex(i);
					index(hashOf(kvs[2 * e]), e);
				}
			}
			// (the nursery is empty after a collection: no key is young)
			nyoung = 0;
			if (youngCap > 1024) {
				young = null;
				youngCap = 0;
			}
			majors = m;
			IdHash.setSeen(slots, n);
		}
		IdHash.unlock();
	}
	#end

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
		young = null;
		nyoung = 0;
		youngCap = 0;
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
