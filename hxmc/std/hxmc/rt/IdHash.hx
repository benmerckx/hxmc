package hxmc.rt;

#if !hxmc.wasm_gc
import hxmc.I64;
import hxmc.unsafe.Atomic;
import hxmc.unsafe.Mem;

// haxe.ds.ObjectMap's hash of a key: its address (docs/hxmc.md, "Identity
// maps"), which the collector changes when it moves the object. Every
// collection counts (Gc's hxmc_gc_count; hxmc_gc_majors the major ones,
// which move every object): a map remembers the count its index was built at
// and brings it up to date before it hashes again: after minor collections
// it indexes again only the keys that were young when they were added (only
// the nursery's objects moved), after a major one all of them. Nothing here
// allocates or reaches a GC point, so a hash stays valid until the map's
// next allocation.
@:allow(haxe.ds)
class IdHash {
	// the collections so far, and the major ones
	static inline function count():Int
		return Mem.getI32(Mem.sym("hxmc_gc_count"), 0);

	static inline function majors():Int
		return Mem.getI32(Mem.sym("hxmc_gc_majors"), 0);

	// the address's bits mixed (Fibonacci hashing: the high half of the
	// product by 2^64 / phi); objects are 8-byte aligned
	static inline function hash(k:Dynamic):Int
		return ((Mem.addr(k).toI64() * (((0x9E3779B9 : I64) << 32) | ((0x7F4A7C15 : I64) & 0xFFFFFFFF))) >>> 32).toInt();

	// in the nursery: the object moves at the next collection
	static inline function young(k:Dynamic):Bool {
		var p = Mem.addr(k);
		return !p.ult(Mem.getPtr(Mem.sym("rt_young_start"), 0)) && p.ult(Mem.getPtr(Mem.sym("rt_young_end"), 0));
	}

	// the collection count an index (an Int NativeArray: element 0) was built
	// at: read with acquire semantics, as other threads may share a map they
	// only read, the first of which to see it out of date brings it up to
	// date (under the lock below) and stores the count last
	static inline function seen(slots:Dynamic):Int
		return Atomic.load32(Mem.addr(slots).add(8));

	static inline function setSeen(slots:Dynamic, n:Int)
		Atomic.store32(Mem.addr(slots).add(8), n);

	#if (hxmc.target == "wasm32-wasi")
	static inline function lock() {}

	static inline function unlock() {}
	#else
	// one lock for every map's update (rare: once per collection for a map
	// used after it); only with several threads
	// (kept: only named by its symbol, which --dce full does not see; corpus case ObjectMapDce)
	@:keep @:hxmc.export("hxmc_idhash_lock") static var lockWord:Int;

	@:hxmc.noGc static function lock() {
		if (Threads.mt == 0) return;
		while (Atomic.cas32(Mem.sym("hxmc_idhash_lock"), 0, 1) != 0)
			Os.yield();
	}

	@:hxmc.noGc static function unlock() {
		if (Threads.mt == 0) return;
		Atomic.store32(Mem.sym("hxmc_idhash_lock"), 0);
	}
	#end
}
#end
