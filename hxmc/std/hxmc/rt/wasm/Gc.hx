package hxmc.rt.wasm;

import hxmc.I64;
import hxmc.rt.Types.*;
import hxmc.rt.GcCore.*;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Ptr;
import hxmc.rt.Tagged;

// The collector and allocator of WebAssembly programs: the native Gc.hx's
// generational copying collector with one thread, in Haxe over linear
// memory (docs/hxmc.md, "WebAssembly"). Same objects, nursery, promotion
// and depth-first copying as the native Gc.hx (whose comments explain them); the
// differences: memory comes from Heap (it grows, it is never given back),
// the old space is a list of chunks rather than a contiguous semispace (a
// major collection copies into chunks taken as it goes, then the from-space's
// chunks are kept for reuse: no semispaces that outgrow the holes their
// predecessors left, which a 4 GB memory cannot afford; or, when the free
// memory does not hold the copy and memory past RT_GROW_MB would be needed
// for it, compacts the chunks where they are, compactOld, so that memory
// does not grow for it), large objects
// (over LARGE) have a region each, which a major collection keeps where it
// is when the object is reached (promoted in place, not copied), memory a
// collection copies into is taken before it starts (reserveFor: a host may
// refuse memory.grow, and a collection cannot stop halfway), no thread
// handshake (one thread, thread-locals are globals), no native handles (no C
// resources), and finalisers are registered but never run. Every function
// here is @:hxmc.unsafe: it runs while objects move, with raw addresses.
@:hxmc.wasm
class Gc {
	static inline var MINOR_MAX = 32 << 20;
	static inline var MINOR_MIN = 4 << 20;
	static inline var LOW_PROMOTION_AFTER = 8;
	static inline var MIN_OLD = 16 << 20;
	static inline var MIN_ROOM = 8 << 20; // the least room a major collection leaves for promotions
	static var tight:Bool; // memory could not grow for a collection's worst case: smaller limits from then on
	static inline var STACK_MB = 4; // the shadow stack's default (RT_STACK_MB)
	static inline var CHUNK = 1 << 20;
	static inline var LARGE = 128 << 10; // larger objects get a region of their own
	static inline var GRAN_SHIFT = 16; // chunks and regions start at multiples of 64 KB
	static inline var GRAN = 1 << GRAN_SHIFT;
	static inline var MAX_LARGE = 0x7FFF0000 - GRAN; // the largest object (its region's size an Int)

	static var nurseryCap:Int; // the nursery's region (from youngStart): its largest size so far
	static var youngStart:Ptr;
	static var youngEnd:Ptr;
	static var youngDirty:Ptr; // the nursery above this holds zeros (never used yet)
	static var zchunk:Int; // RT_ZCHUNK_KB
	static var minorSize:Int;
	static var minorFixed:Bool;
	// the old space: chunks of CHUNK bytes and the regions of large objects,
	// listed as (start, used end, size), the size's low bit set for a large
	// object's region (LARGE_FLAG: its object at its start, alone)
	static inline var LARGE_FLAG = 1;
	static var chunks:Ptr;
	static var nchunks:Int;
	static var chunksCap:Int;
	static var fromChunks:Ptr; // a major collection's from-space: the list before it
	static var nfrom:Int;
	static var fromCap:Int;
	static var cur:Int; // the chunk allocated in (-1: none)
	static var oldPtr:Ptr; // its allocation pointer
	static var oldEnd:Ptr; // its end
	static var oldBytes:I64; // the size of the old space's chunks and regions
	static var oldLimit:I64; // a major collection rather than growing past it
	static var growth:Int; // the next limit, in percent of what a major collection left live (RT_OLD_GROWTH)
	static var pool:Ptr; // free chunks, linked through their first word
	static var poolBytes:I64;
	// a byte per 64 KB of memory: G_OLD in the old space's chunks (the
	// from-space during a major collection), G_LARGE in its large objects'
	// regions (the same), G_TO in a major collection's to-space, 0 elsewhere
	static var gran:Ptr;
	static inline var G_OLD = 1;
	static inline var G_TO = 2;
	static inline var G_LARGE = 3;
	// a major collection compacts the old space where it is (compactOld),
	// rather than copying what is live into new chunks (RT_COMPACT=0), when
	// the free memory does not hold the copy and memory does not grow for it
	// (growFloor); RT_COMPACT=2: at every major collection (forceCompact)
	static var compacting:Bool;
	static var forceCompact:Bool;
	// RT_GROW_MB (256): while memory, grown for a major collection's copy,
	// stays within it (and within RT_MAX_MB's budget), a major collection
	// grows memory and copies rather than compacting. Speed against
	// footprint: a compaction costs about 1.7 copies, but memory never
	// shrinks, so a copying collection's memory is up to twice what is live;
	// below the floor that is cheap, above it compaction keeps memory near
	// what is live (and a host that refuses memory.grow gets a compaction)
	static var growFloor:I64;
	// RT_MAX_MB: what memory should not grow past (0: no such budget). The old
	// space's limit after a major collection leaves room in it for the memory
	// taken until then (startup's, the nursery's) and for a collection (a
	// nursery promoted whole, the marks and the compaction's table), so
	// collections come sooner as what is live nears it; past it memory still
	// grows as a collection or an allocation needs (a soft budget)
	static var budget:I64;
	static var fixedBytes:I64; // memory taken at startup but the nursery's (the stacks, the tables)
	// the memory the running collection copies into, taken before it started
	// (reserveFor), and what it has left of it
	static var resPtr:Ptr;
	static var resEnd:Ptr;
	// the nursery's chunks larger than LARGE taken since the last collection
	// (where an object that gets a region of its own when promoted may be):
	// the most their objects' regions take (reserveFor)
	static var bigRegions:I64;
	static var gcOverflow:Bool; // the copy's stack could not grow: an object copied is not on it (rescan)
	static var inPlace:I64; // RT_STATS: the bytes of the large objects the last major collection kept in place
	static var newState:Int; // what chunks taken now are
	static var copies:Int; // objects copied (a collection's forwarding copied one just now)
	static var copiedBytes:I64;
	static var stackBase:Ptr; // the shadow stack
	static var nglobals:Int;
	static var major:Bool; // which forwarding (minor or major) runs
	static var stats:Bool;
	static var minors:Int;
	// every collection, and the major ones (both move objects: hxmc.rt.IdHash)
	@:hxmc.export("hxmc_gc_majors") static var majors:Int;
	@:hxmc.export("hxmc_gc_count") static var collections:Int;
	// the remembered set: slots, and objects scanned whole
	static var rem:Ptr;
	static var remLen:Int;
	static var remCap:Int;
	static var robjs:Ptr;
	static var robjsLen:Int;
	static var robjsCap:Int;
	static var robjsRecent:Ptr; // 256 entries
	// the depth-first copy's stack: (object, next slot) pairs
	static var gcStack:Ptr;
	static var gcTop:Int;
	static var gcCap:Int;
	// nursery growth (the native Gc.adaptNursery)
	static var lowFor:Int; // collections in a row that promoted little
	static var growthOff:Bool; // memory cannot grow so far
	// hxmc.GcStats and RT_STATS, as the native Gc.hx's (always kept: a few
	// additions and two clock reads per collection): bytes allocated in the
	// nursery up to the last collection and straight in the old space (large
	// objects), what minor collections promoted, the collections' pauses
	static var allocBytes:I64;
	static var largeBytes:I64;
	static var promotedBytes:I64;
	static var youngBytes:I64; // (of the minor collections only, as promotedBytes)
	static var lastPause:Float;
	static var totalPause:Float;
	static var maxPause:Float;
	static var minorSecs:Float;
	static var majorSecs:Float;
	// the last RECORDS collections (hxmc.GcStats.records, as the native Gc.hx's)
	public static inline var RECORDS = 64;
	static var records:Ptr;
	static var nrecords:Int;

	// (the header: read through GcCore, as the native Gc.hx reads it)
	static inline function inYoung(p:Ptr):Bool
		return !p.ult(youngStart) && p.ult(youngEnd);

	// p's granule's state; 0 (none) for a word above the 4 GB the table
	// covers: the tagged word of a scalar (hxmc.rt.Tagged), which a reference
	// slot holds as the value of a type parameter
	static inline function granOf(p:Ptr):Int
		return (p.toI64() >>> 32) == (0 : I64) ? Mem.getU8(gran, (p.toI64() >>> GRAN_SHIFT).toInt()) : 0;

	static inline function isOld(p:Ptr):Bool
		return granOf(p) != 0;

	// a list's entry: its size, and whether it is a large object's region
	static inline function entrySize(l:Ptr, i:Int):Int
		return Mem.getI64(l, 24 * i + 16).toInt() & ~LARGE_FLAG;

	static inline function entryLarge(l:Ptr, i:Int):Bool
		return (Mem.getI64(l, 24 * i + 16).toInt() & LARGE_FLAG) != 0;

	// ---- startup

	@:hxmc.export("rt_init") @:hxmc.unsafe static function init(ng:Int, argc:Int, argv:Ptr):Void {
		Heap.malloc(0); // (the heap's tables)
		Wasi.init();
		var m = Wasi.envInt("RT_MINOR_KB", -1);
		minorFixed = m >= 0;
		minorSize = (m >= 0 ? m : 4096) << 10;
		// (16 KB at least: an allocation of up to 4 KB is always made in the
		// nursery, as generated code assumes, hxmc/rt/Gc.hx)
		if (minorSize < 16384) minorSize = 16384;
		if (minorSize > MINOR_MAX) minorSize = MINOR_MAX;
		stats = Wasi.envInt("RT_STATS", -1) >= 0;
		verifying = Wasi.envInt("RT_VERIFY", -1) >= 0;
		// (the nursery's region as large as the nursery: resizeNursery grows it)
		var before = Heap.freshFrom();
		placeNursery(Heap.region(minorSize), minorSize, before);
		zchunk = Wasi.envInt("RT_ZCHUNK_KB", 32) << 10;
		if (zchunk < 4096) zchunk = 4096;
		emptyChunk();
		var om = Wasi.envInt("RT_OLD_MB", 32);
		oldLimit = (om : I64) << 20;
		growth = Wasi.envInt("RT_OLD_GROWTH", 200);
		var rc = Wasi.envInt("RT_COMPACT", 1);
		compacting = rc != 0;
		forceCompact = rc == 2;
		// (at most 2 GB: a copy beside the old space still fits in 4 GB)
		var gm = Wasi.envInt("RT_GROW_MB", 256);
		if (gm < 0) gm = 0;
		if (gm > 2048) gm = 2048;
		growFloor = (gm : I64) << 20;
		budget = (Wasi.envInt("RT_MAX_MB", 0) : I64) << 20;
		Heap.budget = budget;
		gran = Heap.regionZero(1 << (32 - GRAN_SHIFT));
		chunksCap = 256;
		chunks = Heap.malloc(24 * chunksCap);
		fromCap = 256;
		fromChunks = Heap.malloc(24 * fromCap);
		cur = -1;
		newState = 1;
		// the shadow stack: RT_STACK_MB (4 MB), its end checked where a frame
		// first goes deeper (MirWriter.raiseHw: rt_stack_overflow); a browser's
		// wasm stack (about 1 MB) runs out well before (node's wasi.mjs sets it
		// from --stack-size: as large as node's stack)
		var smb = Wasi.envInt("RT_STACK_MB", STACK_MB);
		if (smb < 1) smb = 1;
		if (smb > 1024) smb = 1024;
		stackMb = smb;
		stackBase = Heap.regionZero(smb << 20);
		Mem.setPtr(Mem.sym("rt_sp_limit"), 0, stackBase.add(smb << 20));
		Mem.tlsSet("rt_sp", stackBase);
		Mem.tlsSet("rt_sp_hw", stackBase);
		// the stack of frame slots (WasmGen: Mem.stack, a try function's locals
		// kept in memory), as large as the shadow stack: the linker's, 64 KB
		// right above the data, runs only this; _start moves the stack pointer to
		// this one's top, and each frame compares it with rt_cstack_lo (no
		// guard page: overflowing it wrote over the statics and the method
		// tables). CSTACK_RESERVE below that end is rt_cstack_overflow's.
		cstackBase = Heap.region((smb << 20) + CSTACK_RESERVE);
		nglobals = ng;
		Mem.setPtr(Mem.sym("rt_globals"), 0, Heap.calloc(ng + 1, 8));
		remCap = 4096;
		rem = Heap.malloc(8 * remCap);
		robjsCap = 256;
		robjs = Heap.malloc(8 * robjsCap);
		robjsRecent = Heap.calloc(256, 8);
		// (RT_VERIFY: a stack that never grows, so the rescan of an overflow runs:
		// 256 entries, as a compaction marks through it and rescans the heap on
		// each overflow, DeepGc's list and tree overflowing 16 entries constantly)
		gcCap = verifying ? 256 : 4096;
		gcStack = Heap.malloc(16 * gcCap);
		hxmc.rt.Boxes.init();
		fixedBytes = Heap.memoryBytes() - nurseryCap;
		// the type objects (rt_type_objs: two words each, DataGen)
		var nt = Mem.getI32(Mem.sym("rt_ntypes"), 0);
		var to = Mem.sym("rt_type_objs");
		for (t in 0...nt) {
			Mem.setI64(to, 16 * t, Types.recordHdr(T_TYPEOBJ, 1));
			Mem.setI64(to, 16 * t + 8, t);
		}
	}

	@:hxmc.unsafe static function setYoungEnd(e:Ptr) {
		youngEnd = e;
		Mem.setPtr(Mem.sym("rt_young_end"), 0, e);
	}

	// the nursery in the region r of cap bytes (empty: at startup, or right
	// after a minor collection); what the region holds below `before`
	// (Heap.freshFrom() before it was taken) may not be zeros
	@:hxmc.unsafe static function placeNursery(r:Ptr, cap:Int, before:Ptr) {
		nurseryCap = cap;
		youngStart = r;
		Mem.setPtr(Mem.sym("rt_young_start"), 0, r);
		setYoungEnd(r.add(minorSize));
		youngDirty = !r.ult(before) ? r : r.add(cap).ult(before) ? r.add(cap) : before;
		if (verifying) Wasm.memset(r, POISON, minorSize);
	}

	static var stackMb:Int;
	static var cstackBase:Ptr;
	static inline var CSTACK_RESERVE = 64 << 10;

	@:hxmc.export("rt_stack_overflow") @:hxmc.unsafe static function stackOverflow():Void {
		Wasi.writeLit(2, "stack overflow: the shadow stack's ");
		Wasi.writeInt(2, stackMb);
		Wasi.writeLit(2, " MB are full (RT_STACK_MB sets its size)\n");
		Wasi.exit(2);
	}

	// the stack of frame slots (_start, DataGen): its end and its top
	@:hxmc.export("rt_cstack_lo") @:hxmc.unsafe static function cstackLo():Ptr
		return cstackBase.add(CSTACK_RESERVE);

	@:hxmc.export("rt_cstack_top") @:hxmc.unsafe static function cstackTop():Ptr
		return cstackBase.add((stackMb << 20) + CSTACK_RESERVE);

	// a frame would go below rt_cstack_lo (WasmGen's prologue). Without a
	// frame itself: the reserve below the end becomes the stack for the message
	@:hxmc.export("rt_cstack_overflow") @:hxmc.unsafe static function cstackOverflow():Void {
		Mem.tlsSet("rt_cstack_lo", cstackBase);
		Wasi.writeLit(2, "stack overflow: the frame stack's ");
		Wasi.writeInt(2, stackMb);
		Wasi.writeLit(2, " MB are full (RT_STACK_MB sets its size)\n");
		Wasi.exit(2);
	}

	// ---- allocation
	// As in the native Gc.hx: allocations bump rt_young_ptr through a chunk of the nursery
	// zeroed when it is taken (32 KB, RT_ZCHUNK_KB: in cache right before its
	// allocations), so no allocation zeroes its own slots. Those whose every
	// slot is written before it is read (Mem.allocRaw) compare the chunk's end
	// rt_young_rlimit; those that rely on the zeros compare rt_young_limit,
	// the same but with RT_VERIFY=1: the free nursery then holds a pattern
	// instead of zeros, the chunk is the whole free nursery, and
	// rt_young_limit is null, so those take the slow path, which zeroes them.

	@:hxmc.unsafe static function emptyChunk() {
		Mem.tlsSet("rt_young_ptr", youngStart);
		Mem.tlsSet("rt_young_rlimit", youngStart);
		Mem.tlsSet("rt_young_limit", youngStart);
	}

	// the next chunk, from the allocation pointer, with room for bytes
	// (false: none); raw: its first bytes are not zeroed (allocSlow: an object
	// without references that its allocation writes whole)
	@:hxmc.unsafe static function nextChunk(bytes:Int, raw:Bool):Bool {
		var p = Mem.tlsGet("rt_young_ptr");
		var avail = youngEnd.diff(p);
		if (avail < (bytes : I64)) return false;
		var take:I64 = verifying ? avail : (bytes > zchunk ? bytes : zchunk);
		if (take > avail) take = avail;
		var e = p.add(take.toInt());
		if (take > (LARGE : I64)) {
			// (objects over LARGE in it: a region each when promoted, rounded
			// up to GRAN, less than GRAN more than each one's bytes)
			bigRegions += take + (take / LARGE) * GRAN;
		}
		if (!verifying) {
			// (up to the old chunk's end the nursery is zeroed already)
			var z = Mem.tlsGet("rt_young_rlimit");
			if (z.ult(p)) z = p;
			if (raw && z.ult(p.add(bytes))) z = p.add(bytes);
			var ze = e.ult(youngDirty) ? e : youngDirty;
			if (z.ult(ze)) Wasm.memset(z, 0, ze.diff(z).toInt());
		}
		Mem.tlsSet("rt_young_rlimit", e);
		Mem.tlsSet("rt_young_limit", verifying ? Ptr.nil() : e);
		return true;
	}

	// (as the native GcPaths.allocSlow: a record's slots from its bytes)
	@:hxmc.export("hxmc_alloc_slow") @:hxmc.collects static function allocSlowParts(lo:Int, tindex:Int, bytes:Int):Ptr
		return allocSlow(Types.isRecord(tindex & 0xFFFF) ? Types.recordHdr(tindex & 0xFFFF, (bytes >> 3) - 1) : Types.arrayHdr(tindex, lo), bytes);

	// (raw: an allocation that writes every slot before it reads one, of an
	// object without references, Types.K_RAW: not zeroed, as no scan reads
	// its slots; MemLower.allocDyn, as the native GcPaths.allocSlowRaw)
	@:hxmc.export("hxmc_alloc_slow_raw") @:hxmc.collects static function allocSlowRawParts(lo:Int, tindex:Int, bytes:Int):Ptr {
		var header = Types.isRecord(tindex & 0xFFFF) ? Types.recordHdr(tindex & 0xFFFF, (bytes >> 3) - 1) : Types.arrayHdr(tindex, lo);
		return allocAny(header, bytes, Types.kindOfWord(tindex) == Types.K_RAW);
	}

	@:hxmc.export("rt_alloc_slow") @:hxmc.collects static function allocSlow(header:I64, bytes:Int):Ptr
		return allocAny(header, bytes, false);

	@:hxmc.collects static function allocAny(header:I64, bytes:Int, raw:Bool):Ptr {
		var p:Ptr;
		if (bytes > minorSize >> 2 && youngEnd.diff(Mem.tlsGet("rt_young_ptr")) < (bytes : I64)) {
			// large objects go straight to the old space (unless the free nursery
			// has room: they may die young)
			if (oldBytes + bytes > oldLimit) collectFor(true, bytes);
			p = oldAlloc(bytes);
			if (p.isNull()) {
				collectFor(true, bytes);
				p = oldAlloc(bytes);
				if (p.isNull()) Heap.outOfMemory();
			}
			largeBytes += bytes;
		} else {
			if (Mem.tlsGet("rt_young_rlimit").diff(Mem.tlsGet("rt_young_ptr")) < (bytes : I64) && !nextChunk(bytes, raw)) {
				collectFor(false, 0);
				nextChunk(bytes, raw);
			}
			p = Mem.tlsGet("rt_young_ptr");
			Mem.tlsSet("rt_young_ptr", p.add(bytes));
			Mem.setI64(p, 0, header);
			// (zeroed with its chunk, but for the pattern of RT_VERIFY, which a raw one keeps)
			if (verifying && !raw) Wasm.memset(p.add(8), 0, bytes - 8);
			return p.add(8);
		}
		Mem.setI64(p, 0, header);
		if (!raw) Wasm.memset(p.add(8), 0, bytes - 8);
		return p.add(8);
	}

	// ---- the old space

	// `bytes` in the old space (null: memory cannot grow so far); an object
	// over LARGE always in a region of its own
	@:hxmc.unsafe static function oldAlloc(bytes:Int):Ptr {
		var p = oldPtr;
		if (bytes <= LARGE && oldEnd.diff(p) >= (bytes : I64)) {
			oldPtr = p.add(bytes);
			return p;
		}
		return oldAllocSlow(bytes);
	}

	@:hxmc.unsafe static function oldAllocSlow(bytes:Int):Ptr {
		if (bytes > LARGE) {
			// (an object of nearly 2 GB, the longest NArray, rounds to more than
			// an Int: and memory could not hold it next to the rest anyway)
			if (bytes > MAX_LARGE) {
				Heap.refuse(bytes);
				return Ptr.nil();
			}
			var size = (bytes + (GRAN - 1)) & ~(GRAN - 1);
			var r = take(size);
			if (!r.isNull()) addChunk(r, r.add(bytes), size, true);
			return r;
		}
		var c = pool;
		if (!c.isNull()) {
			pool = Mem.getPtr(c, 0);
			poolBytes -= CHUNK;
		} else {
			c = take(CHUNK);
			if (c.isNull()) return c;
		}
		syncCur();
		cur = nchunks;
		addChunk(c, c, CHUNK, false);
		oldPtr = c.add(bytes);
		oldEnd = c.add(CHUNK);
		return c;
	}

	// size bytes (a multiple of GRAN) for the old space: from the regions
	// freed, else from what the running collection reserved, else from
	// memory grown (null: it cannot grow so far)
	@:hxmc.unsafe static function take(size:Int):Ptr {
		var f = Heap.freeAligned(size, GRAN);
		if (!f.isNull()) return f;
		// (a large object's region: the free chunks given back first, merged
		// where they are neighbours, rather than memory grown for it; the
		// chunks taken after come from the freed regions as well)
		if (size > CHUNK && !pool.isNull()) {
			while (!pool.isNull()) {
				var c = pool;
				pool = Mem.getPtr(c, 0);
				Heap.release(c, CHUNK);
			}
			poolBytes = 0;
			f = Heap.freeAligned(size, GRAN);
			if (!f.isNull()) return f;
		}
		if (resEnd.diff(resPtr) >= (size : I64)) {
			var r = resPtr;
			resPtr = r.add(size);
			return r;
		}
		return Heap.tryRegionAligned(size, GRAN);
	}

	// (a collection's list has room for every entry it adds: reserveFor)
	@:hxmc.unsafe static function addChunk(start:Ptr, end:Ptr, size:Int, large:Bool) {
		if (nchunks == chunksCap) {
			chunksCap *= 2;
			chunks = Heap.realloc(chunks, 24 * chunksCap);
		}
		Mem.setPtr(chunks, 24 * nchunks, start);
		Mem.setPtr(chunks, 24 * nchunks + 8, end);
		Mem.setI64(chunks, 24 * nchunks + 16, large ? size | LARGE_FLAG : size);
		nchunks++;
		oldBytes += size;
		mark(start, size, large && newState == G_OLD ? G_LARGE : newState);
	}

	@:hxmc.unsafe static function mark(start:Ptr, size:Int, state:Int) {
		var g = (start.toI64() >>> GRAN_SHIFT).toInt();
		for (i in 0...(size >> GRAN_SHIFT))
			Mem.setI8(gran, g + i, state);
	}

	// the current chunk's used end into the list
	@:hxmc.unsafe static function syncCur() {
		if (cur >= 0) Mem.setPtr(chunks, 24 * cur + 8, oldPtr);
	}

	// ---- the write barrier

	@:hxmc.export("hxmc_barrier_slow") @:hxmc.unsafe static function barrierSlow(obj:Ptr, slot:Ptr, v:Ptr, prev:Ptr):Void {
		if (inYoung(v) && !inYoung(prev)) remember(slot);
	}

	@:hxmc.export("rt_write_barrier") @:hxmc.unsafe static function writeBarrier(obj:Ptr, slot:Ptr, v:Ptr):Void
		remember(slot);

	@:hxmc.unsafe static function remember(slot:Ptr) {
		if (remLen == remCap) {
			remCap *= 2;
			rem = Heap.realloc(rem, 8 * remCap);
		}
		Mem.setPtr(rem, 8 * remLen, slot);
		remLen++;
	}

	@:hxmc.unsafe static function rememberObj(o:Ptr) {
		var h = (o.toI64() >> 4).toInt() & 255;
		if (Mem.getPtr(robjsRecent, 8 * h) == o) return;
		Mem.setPtr(robjsRecent, 8 * h, o);
		if (robjsLen == robjsCap) {
			robjsCap *= 2;
			robjs = Heap.realloc(robjs, 8 * robjsCap);
		}
		Mem.setPtr(robjs, 8 * robjsLen, o);
		robjsLen++;
	}

	@:hxmc.export("rt_barrier_range") @:hxmc.unsafe static function barrierRange(obj:Ptr, from:Ptr, n:Int):Void {
		if (inYoung(obj)) return;
		if (n > 16) {
			rememberObj(obj);
			return;
		}
		for (i in 0...n)
			if (inYoung(Mem.getPtr(from, 8 * i))) remember(from.add(8 * i));
	}

	// ---- collection

	@:hxmc.unsafe static function copyTo(dst:Ptr, obj:Ptr):Ptr {
		var words = nslotsOf(obj) + 1;
		var s = obj.add(-8);
		if (words <= 8) {
			for (i in 0...words)
				Mem.setI64(dst, 8 * i, Mem.getI64(s, 8 * i));
		} else
			Wasm.memcpy(dst, s, 8 * words);
		return dst.add(8);
	}

	@:hxmc.unsafe static function forwardTo(p:Ptr, n:Ptr)
		setFwd(p, n);

	// (a major collection: an object of the from-space's chunks is copied, a
	// large one stays where it is, its region joining the to-space)
	@:hxmc.unsafe static function fwd(p:Ptr):Ptr {
		if (!inYoung(p)) {
			if (!major) return p;
			var g = granOf(p);
			if (g != G_OLD) {
				if (g == G_LARGE) promote(p);
				return p;
			}
		}
		if (isFwdAt(p)) return fwdAddr(p);
		var bytes = objBytes(p);
		var d = oldAlloc(bytes);
		if (d.isNull()) Heap.outOfMemory();
		var n = copyTo(d, p);
		copies++;
		copiedBytes += bytes;
		forwardTo(p, n);
		return n;
	}

	// a large object of the from-space, reached: its region (the object at
	// its start) joins the to-space as it is, G_TO from now on, so it is
	// promoted once; scanned as a copy is (copies)
	@:hxmc.unsafe static function promote(p:Ptr) {
		var r = p.add(-8);
		var bytes = objBytes(p);
		var size = (bytes + (GRAN - 1)) & ~(GRAN - 1);
		addChunk(r, r.add(bytes), size, true);
		inPlace += size;
		copies++;
	}

	// false: the stack cannot grow (memory cannot grow so far; RT_VERIFY: it
	// never does): the object is left off, and the copy rescans (gcOverflow)
	@:hxmc.unsafe static function push(o:Ptr):Bool {
		if (gcTop == gcCap) {
			var s = verifying ? Ptr.nil() : Heap.tryRealloc(gcStack, 32 * gcCap);
			if (s.isNull()) {
				gcOverflow = true;
				return false;
			}
			gcStack = s;
			gcCap *= 2;
		}
		Mem.setPtr(gcStack, 16 * gcTop, o);
		Mem.setI64(gcStack, 16 * gcTop + 8, 0);
		gcTop++;
		return true;
	}

	// after an overflow (gcOverflow): the objects copied since list entry c0
	// (from p0 on; null: its start), each scanned again (harmless for those
	// scanned already: what they reference is copied), until a pass leaves
	// none off. (Objects copied meanwhile go after the pass's position, but
	// for those in the current chunk when it is not the last entry: passes
	// until one does not overflow)
	@:hxmc.unsafe static function rescan(c0:Int, p0:Ptr) {
		while (gcOverflow) {
			gcOverflow = false;
			var c = c0;
			while (c < nchunks) {
				var p = c == c0 && !p0.isNull() ? p0 : Mem.getPtr(chunks, 24 * c);
				while (true) {
					var end = c == cur ? oldPtr : Mem.getPtr(chunks, 24 * c + 8);
					if (!p.ult(end)) break;
					var o = p.add(8);
					p = p.add(objBytes(o));
					scanObject(o);
				}
				c++;
			}
		}
	}

	@:hxmc.unsafe static function drain() {
		while (gcTop > 0) {
			var f = gcStack.add(16 * (gcTop - 1));
			var o = Mem.getPtr(f, 0);
			var n = nslotsOf(o), k = kindOf(o);
			var pm = k == K_OBJ ? ptrmapAt(tindexOf(o)) : Ptr.nil();
			if (k == K_RAW || (k == K_OBJ && pm.isNull())) {
				gcTop--;
				continue;
			}
			var i = Mem.getI64(f, 8).toInt();
			var pushed = false;
			while (i < n) {
				if (!pm.isNull() && ((Mem.getI32(pm, 4 * (i >> 5)) >>> (i & 31)) & 1) == 0) {
					i++;
					continue;
				}
				var v = Mem.getPtr(o, 8 * i);
				if (v.isNull()) {
					i++;
					continue;
				}
				var before = copies;
				var nv = fwd(v);
				Mem.setPtr(o, 8 * i, nv);
				i++;
				if (copies != before) {
					// copied just now: its subtree next (push may move the stack)
					Mem.setI64(f, 8, i);
					if (push(nv)) {
						pushed = true;
						break;
					}
				}
			}
			if (!pushed) gcTop--;
		}
	}

	@:hxmc.unsafe static function fwdRoot(p:Ptr):Ptr {
		var before = copies;
		var n = fwd(p);
		if (copies != before && push(n)) drain();
		return n;
	}

	@:hxmc.unsafe static function rootAt(slot:Ptr) {
		var v = Mem.getPtr(slot, 0);
		if (!v.isNull()) Mem.setPtr(slot, 0, fwdRoot(v));
	}

	@:hxmc.unsafe static function scanObject(o:Ptr) {
		var n = nslotsOf(o);
		switch kindOf(o) {
			case K_OBJ:
				var pm = ptrmapAt(tindexOf(o));
				if (pm.isNull()) return;
				for (i in 0...n)
					if (((Mem.getI32(pm, 4 * (i >> 5)) >>> (i & 31)) & 1) != 0) rootAt(o.add(8 * i));
			case K_PARR:
				for (i in 0...n)
					rootAt(o.add(8 * i));
			case _:
		}
	}

	@:hxmc.unsafe static function scanRoots() {
		var sp = Mem.tlsGet("rt_sp");
		var s = stackBase;
		while (s.ult(sp)) {
			rootAt(s);
			s = s.add(8);
		}
		var g = Mem.getPtr(Mem.sym("rt_globals"), 0);
		for (i in 0...nglobals)
			rootAt(g.add(8 * i));
		var e = Mem.tlsGet("rt_exn");
		if (!e.isNull()) Mem.tlsSet("rt_exn", fwdRoot(e));
	}

	@:hxmc.unsafe static function minorGc() {
		minors++;
		collections++;
		major = false;
		// (where the copies start: rescan's)
		var c0 = cur >= 0 ? cur : nchunks;
		var p0 = cur >= 0 ? oldPtr : Ptr.nil();
		scanRoots();
		for (i in 0...remLen)
			rootAt(Mem.getPtr(rem, 8 * i));
		remLen = 0;
		for (i in 0...robjsLen)
			scanObject(Mem.getPtr(robjs, 8 * i));
		robjsLen = 0;
		Wasm.memset(robjsRecent, 0, 8 * 256);
		rescan(c0, p0);
	}

	// Memory for the collection about to run to copy into (major or minor),
	// taken before it starts: a host may refuse memory.grow (browsers,
	// Android's Chrome early), and a collection cannot stop halfway, so one
	// that has its reservation never needs fresh memory. For the worst case:
	// it copies at most what the nursery holds and, a major one, what the old
	// space's chunks hold (its large objects stay in place: promote); the
	// nursery's objects over LARGE get a region each, rounded up to GRAN
	// (bigRegions). False: memory cannot grow so far (nothing taken)
	@:hxmc.unsafe static function reserveFor(maj:Bool, grow = true):Bool {
		syncCur();
		var copied:I64 = Mem.tlsGet("rt_young_ptr").diff(youngStart);
		var large = 0;
		if (maj)
			for (i in 0...nchunks)
				if (entryLarge(chunks, i)) large++ else copied += Mem.getPtr(chunks, 24 * i + 8).diff(Mem.getPtr(chunks, 24 * i));
		return reserve(maj, copied, bigRegions, large, grow);
	}

	// A major collection's reservation with memory grown for it, when memory
	// so grown stays within RT_GROW_MB and RT_MAX_MB (counting all of the
	// worst case as growth: the free memory it uses only lowers it). False:
	// past them, or the host refused memory.grow (the collection compacts)
	@:hxmc.unsafe static function reserveGrown():Bool {
		if (growFloor <= 0) return false;
		syncCur();
		var copied:I64 = Mem.tlsGet("rt_young_ptr").diff(youngStart);
		for (i in 0...nchunks)
			if (!entryLarge(chunks, i)) copied += Mem.getPtr(chunks, 24 * i + 8).diff(Mem.getPtr(chunks, 24 * i));
		var after = Heap.memoryBytes() + copied + copied / 7 + 2 * CHUNK + bigRegions;
		if (after > growFloor || (budget > 0 && after > budget)) return false;
		return reserveFor(true, true);
	}

	// A reservation for `copied` bytes of objects up to LARGE, `regions` of
	// the regions of larger ones (each more than LARGE) and `large` large
	// objects kept in place: the former fill chunks to within LARGE of their
	// end (an object that does not fit starts the next one: an eighth more,
	// and a chunk), free chunks first (the pool). The to-space's list gets
	// room for its entries too. What the collection does not use goes back
	// after it (unreserve). The copy's stack needs none: when it cannot grow,
	// the copy rescans (push)
	@:hxmc.unsafe static function reserve(maj:Bool, copied:I64, regions:I64, large:Int, grow = true):Bool {
		var nch = (copied + copied / 7 + 2 * CHUNK - 1) >> 20;
		var chunkBytes = nch << 20;
		var bytes = regions + (chunkBytes > poolBytes ? chunkBytes - poolBytes : 0);
		var entries = 1 + large + nch.toInt() + (regions >> 17).toInt();
		// (the to-space's list: a major collection's starts empty, in the list
		// that was the from-space's; a minor one's continues the old space's)
		var want = maj ? entries : nchunks + entries;
		if (maj && fromCap < want) {
			var l = Heap.tryRealloc(fromChunks, 24 * want);
			if (l.isNull()) return false;
			fromChunks = l;
			fromCap = want;
		} else if (!maj && chunksCap < want) {
			var l = Heap.tryRealloc(chunks, 24 * want);
			if (l.isNull()) return false;
			chunks = l;
			chunksCap = want;
		}
		if (bytes == 0) return true;
		if (bytes > (MAX_LARGE : I64)) {
			Heap.refuse(MAX_LARGE);
			return false;
		}
		var r = grow ? Heap.tryRegionAligned(bytes.toInt(), GRAN) : Heap.freeAligned(bytes.toInt(), GRAN);
		if (r.isNull()) return false;
		resPtr = r;
		resEnd = r.add(bytes.toInt());
		return true;
	}

	// what the collection left of its reservation, back to Heap
	@:hxmc.unsafe static function unreserve() {
		if (resPtr.ult(resEnd)) Heap.release(resPtr, resEnd.diff(resPtr).toInt());
		resPtr = Ptr.nil();
		resEnd = Ptr.nil();
	}

	// ---- the exact measure: when memory cannot grow for the worst case, a
	// trace marks what the collection would copy, without copying (the same
	// roots, the same objects: nothing runs between), and the reservation is
	// for that. A bit per 8 bytes of memory (memory's size / 64, taken for the
	// trace and given back); the copy's stack holds the objects to scan
	// (when it cannot grow, the marked objects are scanned again: markRescan)

	static var marks:Ptr;
	static var marksBytes:Int;
	static var markedBytes:I64; // of the objects up to LARGE the collection copies
	static var markedRegions:I64; // the regions of the larger ones it copies
	static var markMajor:Bool;
	static var markedObjs:Int; // the objects of the old space's chunks marked (compactOld)

	// what the collection about to run copies, measured, reserved (false:
	// memory cannot grow so far, for the marks or for the reservation)
	@:hxmc.unsafe static function reserveExact(maj:Bool):Bool {
		if (!markLive(maj)) return false;
		releaseMarks();
		var large = 0;
		if (maj)
			for (i in 0...nchunks)
				if (entryLarge(chunks, i)) large++;
		return reserve(maj, markedBytes, markedRegions, large);
	}

	@:hxmc.unsafe static function releaseMarks() {
		Heap.release(marks, marksBytes);
		marks = Ptr.nil();
	}

	// what the collection about to run would copy, marked: a bit per 8 bytes
	// of memory, at each live object's address (false: memory cannot grow
	// for the marks, nothing marked)
	@:hxmc.unsafe static function markLive(maj:Bool):Bool {
		var n = ((Heap.memoryBytes() >> 6) + 16).toInt();
		var before = Heap.freshFrom();
		marks = Heap.tryRegion(n);
		if (marks.isNull()) return false;
		marksBytes = n;
		Heap.zeroBelow(marks, (n + 15) & ~15, before);
		markMajor = maj;
		markedBytes = 0;
		markedRegions = 0;
		var sp = Mem.tlsGet("rt_sp");
		var s = stackBase;
		while (s.ult(sp)) {
			markRef(Mem.getPtr(s, 0));
			s = s.add(8);
		}
		var g = Mem.getPtr(Mem.sym("rt_globals"), 0);
		for (i in 0...nglobals)
			markRef(Mem.getPtr(g, 8 * i));
		markRef(Mem.tlsGet("rt_exn"));
		if (!maj) {
			for (i in 0...remLen)
				markRef(Mem.getPtr(Mem.getPtr(rem, 8 * i), 0));
			for (i in 0...robjsLen)
				markSlots(Mem.getPtr(robjs, 8 * i));
		}
		markDrain();
		while (gcOverflow) {
			gcOverflow = false;
			markRescan();
		}
		return true;
	}

	// v marked when the collection copies it (young; a major one: in the old
	// space's chunks) or, a major one, keeps it in place (a large object),
	// counted, and pushed to be scanned
	@:hxmc.unsafe static function markRef(v:Ptr) {
		if (v.isNull()) return;
		var young = inYoung(v);
		var g = young ? 0 : granOf(v);
		if (!young && (!markMajor || (g != G_OLD && g != G_LARGE))) return;
		var b = v.toI64() >>> 3;
		var at = (b >>> 3).toInt(), bit = 1 << (b & 7).toInt();
		var m = Mem.getU8(marks, at);
		if ((m & bit) != 0) return;
		Mem.setI8(marks, at, m | bit);
		var bytes = objBytes(v);
		if (g == G_OLD || (young && bytes <= LARGE)) markedBytes += bytes else if (young) markedRegions += (bytes + (GRAN - 1)) & ~(GRAN - 1);
		if (g == G_OLD) markedObjs++;
		push(v);
	}

	@:hxmc.unsafe static inline function marked(o:Ptr):Bool {
		var b = o.toI64() >>> 3;
		return (Mem.getU8(marks, (b >>> 3).toInt()) & (1 << (b & 7).toInt())) != 0;
	}

	// the references o holds, marked
	@:hxmc.unsafe static function markSlots(o:Ptr) {
		var n = nslotsOf(o);
		switch kindOf(o) {
			case K_OBJ:
				var pm = ptrmapAt(tindexOf(o));
				if (pm.isNull()) return;
				for (i in 0...n)
					if (((Mem.getI32(pm, 4 * (i >> 5)) >>> (i & 31)) & 1) != 0) markRef(Mem.getPtr(o, 8 * i));
			case K_PARR:
				for (i in 0...n)
					markRef(Mem.getPtr(o, 8 * i));
			case _:
		}
	}

	@:hxmc.unsafe static function markDrain() {
		while (gcTop > 0) {
			gcTop--;
			markSlots(Mem.getPtr(gcStack, 16 * gcTop));
		}
	}

	// after an overflow: every marked object (of the nursery, and a major
	// collection's old space) scanned again
	@:hxmc.unsafe static function markRescan() {
		var p = youngStart, end = Mem.tlsGet("rt_young_ptr");
		while (p.ult(end)) {
			var o = p.add(8);
			p = p.add(objBytes(o));
			if (marked(o)) {
				markSlots(o);
				markDrain();
			}
		}
		if (!markMajor) return;
		syncCur();
		for (c in 0...nchunks) {
			var q = Mem.getPtr(chunks, 24 * c), e = Mem.getPtr(chunks, 24 * c + 8);
			while (q.ult(e)) {
				var o = q.add(8);
				q = q.add(objBytes(o));
				if (marked(o)) {
					markSlots(o);
					markDrain();
				}
			}
		}
	}

	@:hxmc.unsafe static function majorGc(need:Int) {
		majors++;
		collections++;
		// the old space's chunks become the from-space; the to-space's are taken
		// as objects are copied (from the free chunks first)
		syncCur();
		var t = fromChunks;
		fromChunks = chunks;
		chunks = t;
		var tc = fromCap;
		fromCap = chunksCap;
		chunksCap = tc;
		nfrom = nchunks;
		nchunks = 0;
		cur = -1;
		oldPtr = Ptr.nil();
		oldEnd = Ptr.nil();
		oldBytes = 0;
		inPlace = 0;
		newState = G_TO;
		major = true;
		scanRoots();
		remLen = 0;
		robjsLen = 0;
		Wasm.memset(robjsRecent, 0, 8 * 256);
		rescan(0, Ptr.nil());
		major = false;
		newState = G_OLD;
		// the from-space's chunks to the pool, its large objects' regions back
		// to Heap, but for those promoted in place (G_TO: in the list already)
		for (i in 0...nfrom) {
			var start = Mem.getPtr(fromChunks, 24 * i);
			var size = entrySize(fromChunks, i);
			if (entryLarge(fromChunks, i) && granOf(start) == G_TO) continue;
			mark(start, size, 0);
			if (size == CHUNK && !entryLarge(fromChunks, i)) {
				Mem.setPtr(start, 0, pool);
				pool = start;
				poolBytes += CHUNK;
			} else
				Heap.release(start, size);
		}
		for (i in 0...nchunks)
			mark(Mem.getPtr(chunks, 24 * i), entrySize(chunks, i), entryLarge(chunks, i) ? G_LARGE : G_OLD);
		setLimit(need, true);
	}

	// after a major collection (of `need` bytes: an allocation's), the old
	// space's next limit; copying: the next major collection copies what is
	// live (else it compacts it in place)
	@:hxmc.unsafe static function setLimit(need:Int, copying:Bool) {
		// the next limit: `growth` percent of what is live (twice: room for as
		// much again; half as much once memory could not grow for a
		// collection's worst case, tight), room for what collectFor's test
		// asks of a minor collection (a nursery promoted whole) and for three
		// nurseries' promotions, but no more than what is live, and at most
		// half of what the rest of a wasm32 memory (4 GB) leaves: the next
		// collection's from-space and to-space must both fit (a compaction's
		// old space, all of it). (The growth
		// bounds a major collection's cost per byte promoted; the nurseries'
		// room spares a small old space major collections at nearly every
		// minor one. Four nurseries more whatever was live, as it was, gave 43
		// MB live with a 32 MB nursery a limit of 214 MB, issue #129: now 166
		// MB, and 101 MB once tight)
		var live = oldBytes;
		var room = tight ? live >> 1 : live * (growth - 100) / 100;
		if (room < (MIN_ROOM : I64)) room = MIN_ROOM;
		var more = (minorSize : I64) * 3;
		if (more > live || tight) more = tight ? 0 : live;
		var limit = live + room + more + (minorSize : I64) + (minorSize >> 3) + CHUNK + need;
		if (limit < (MIN_OLD : I64)) limit = MIN_OLD;
		var other = Heap.memoryBytes() - oldBytes - poolBytes;
		var cap = (((1 : I64) << 32) - (64 << 20) - other) >> (copying ? 1 : 0);
		if (limit > cap) limit = cap;
		// (RT_MAX_MB: what memory has room for, a collection's needs left out:
		// a nursery's promotion, the marks and the compaction's table, a 32nd
		// of memory)
		if (budget > 0) {
			var fits = budget - fixedBytes - nurseryCap - (minorSize : I64) - (Heap.memoryBytes() >> 5) - 4 * CHUNK;
			if (limit > fits) limit = fits;
		}
		var least = live + need + (minorSize : I64) + 2 * CHUNK;
		if (limit < least) limit = least;
		oldLimit = limit;
		if (stats) {
			Wasi.statLine("gc: major ", majors, (live >> 20).toInt(), (limit >> 20).toInt(), (Heap.memoryBytes() >> 20).toInt());
			if (inPlace >= (1 << 20)) {
				Wasi.writeLit(2, "gc: major ");
				Wasi.writeInt(2, majors);
				Wasi.writeLit(2, ": ");
				Wasi.writeInt(2, (inPlace >> 20).toInt());
				Wasi.writeLit(2, " MB of large objects kept in place\n");
			}
		}
	}

	// ---- a major collection that compacts the old space where it is
	// (Lisp 2's sliding compaction over the chunks' list): the nursery
	// evacuated first by a minor collection, what is live in the old space
	// marked (markLive), each live object's new address planned in the
	// list's order (the chunks' objects slide towards the list's start, each
	// chunk filled up to where the next object does not fit), every
	// reference updated, the objects moved, the chunks left empty freed.
	// Large objects stay where they are (their regions freed when dead). So a
	// major collection needs the old space, the marks (a 64th of memory) and
	// 4 bytes per live object, not room for a copy of what is live: its peak
	// is what the old space holds, not that and what is live.
	//
	// The plan writes each live object's new address over the upper half of
	// its header (an identity hash, a string's hash, an array's length: the
	// size of an object of a chunk is in the lower half), what was there
	// kept in `saved`, in the plan's order (4 bytes each, in 1 MB pieces:
	// free chunks first); the move puts it back.

	static var saved:Ptr; // the pieces
	static var npieces:Int;
	static inline var PIECE_SHIFT = 18; // (a piece's entries: a chunk's bytes / 4)

	@:hxmc.unsafe static inline function savedAt(k:Int):Ptr
		return Mem.getPtr(saved, 8 * (k >>> PIECE_SHIFT)).add(4 * (k & ((1 << PIECE_SHIFT) - 1)));

	// the pieces for n entries (false: memory cannot grow for them, none taken)
	@:hxmc.unsafe static function takeSaved(n:Int):Bool {
		npieces = (n >>> PIECE_SHIFT) + 1;
		saved = Heap.tryMalloc(8 * npieces);
		if (saved.isNull()) return false;
		for (i in 0...npieces) {
			var c = pool;
			if (!c.isNull()) {
				pool = Mem.getPtr(c, 0);
				poolBytes -= CHUNK;
			} else
				c = take(CHUNK);
			if (c.isNull()) {
				npieces = i;
				releaseSaved();
				return false;
			}
			Mem.setPtr(saved, 8 * i, c);
		}
		return true;
	}

	// the pieces back to the free chunks
	@:hxmc.unsafe static function releaseSaved() {
		for (i in 0...npieces) {
			var c = Mem.getPtr(saved, 8 * i);
			Mem.setPtr(c, 0, pool);
			pool = c;
			poolBytes += CHUNK;
		}
		Heap.free(saved);
		saved = Ptr.nil();
	}

	@:hxmc.unsafe static inline function fwdSlot(slot:Ptr) {
		var v = Mem.getPtr(slot, 0);
		if (!v.isNull() && granOf(v) == G_OLD) Mem.setPtr(slot, 0, newAddr(v));
	}

	// a live object of the old space's chunks: its new address (the plan's)
	@:hxmc.unsafe static inline function newAddr(v:Ptr):Ptr
		return new Ptr(((Mem.getI32(v, -4) : I64) << 32) >>> 32);

	// the references of the live object o updated
	@:hxmc.unsafe static function fwdSlots(o:Ptr) {
		var n = nslotsOf(o);
		switch kindOf(o) {
			case K_OBJ:
				var pm = ptrmapAt(tindexOf(o));
				if (pm.isNull()) return;
				for (i in 0...n)
					if (((Mem.getI32(pm, 4 * (i >> 5)) >>> (i & 31)) & 1) != 0) fwdSlot(o.add(8 * i));
			case K_PARR:
				for (i in 0...n)
					fwdSlot(o.add(8 * i));
			case _:
		}
	}

	// the next chunk (not a large object's region) of the list from i on (nchunks: none)
	@:hxmc.unsafe static inline function nextChunkEntry(i:Int):Int {
		while (i < nchunks && entryLarge(chunks, i))
			i++;
		return i;
	}

	// the old space compacted (the nursery empty: right after a minor
	// collection); false: memory cannot grow for the marks or what the plan
	// saves (nothing changed)
	@:hxmc.unsafe static function compactOld(need:Int):Bool {
		syncCur();
		markedObjs = 0;
		if (!markLive(true)) return false;
		var ends = Heap.tryMalloc(8 * nchunks + 8);
		if (ends.isNull() || !takeSaved(markedObjs)) {
			if (!ends.isNull()) Heap.free(ends);
			releaseMarks();
			return false;
		}
		majors++;
		// (the minor collection before was this one's part: one collection)
		minors--;
		// plan: each chunk's live objects, in the list's order, given their new
		// addresses from the list's first chunk on (the next chunk when one
		// does not fit: that chunk then ends where it would start)
		var d = nextChunkEntry(0);
		var dp = d < nchunks ? Mem.getPtr(chunks, 24 * d) : Ptr.nil();
		var de = d < nchunks ? dp.add(entrySize(chunks, d)) : Ptr.nil();
		for (i in 0...nchunks)
			Mem.setPtr(ends, 8 * i, Ptr.nil());
		var nsaved = 0;
		var s = d;
		while (s < nchunks) {
			var p = Mem.getPtr(chunks, 24 * s), end = Mem.getPtr(chunks, 24 * s + 8);
			while (p.ult(end)) {
				var o = p.add(8);
				var b = objBytes(o);
				if (marked(o)) {
					if (de.diff(dp) < (b : I64)) {
						Mem.setPtr(ends, 8 * d, dp);
						d = nextChunkEntry(d + 1);
						dp = Mem.getPtr(chunks, 24 * d);
						de = dp.add(entrySize(chunks, d));
					}
					Mem.setI32(savedAt(nsaved), 0, Mem.getI32(o, -4));
					nsaved++;
					Mem.setI32(o, -4, dp.add(8).toI64().toInt());
					dp = dp.add(b);
				}
				p = p.add(b);
			}
			s = nextChunkEntry(s + 1);
		}
		if (d < nchunks) Mem.setPtr(ends, 8 * d, dp);
		// every reference to the chunks' objects updated: the roots', and the
		// live objects' (theirs, and the large objects')
		var sp = Mem.tlsGet("rt_sp");
		var r = stackBase;
		while (r.ult(sp)) {
			fwdSlot(r);
			r = r.add(8);
		}
		var g = Mem.getPtr(Mem.sym("rt_globals"), 0);
		for (i in 0...nglobals)
			fwdSlot(g.add(8 * i));
		var exn = Mem.tlsGet("rt_exn");
		if (!exn.isNull() && granOf(exn) == G_OLD) Mem.tlsSet("rt_exn", newAddr(exn));
		for (i in 0...nchunks) {
			var p = Mem.getPtr(chunks, 24 * i), end = Mem.getPtr(chunks, 24 * i + 8);
			if (entryLarge(chunks, i)) {
				if (marked(p.add(8))) fwdSlots(p.add(8));
				continue;
			}
			while (p.ult(end)) {
				var o = p.add(8);
				if (marked(o)) fwdSlots(o);
				p = p.add(objBytes(o));
			}
		}
		// the objects moved, in the plan's order, their headers restored (each
		// to where it is or before: a move never overwrites an object not
		// moved yet, nor the header of one the walk has not passed)
		var s = nextChunkEntry(0);
		var k = 0;
		var moved:I64 = 0;
		while (s < nchunks) {
			var p = Mem.getPtr(chunks, 24 * s), end = Mem.getPtr(chunks, 24 * s + 8);
			while (p.ult(end)) {
				var o = p.add(8);
				var b = objBytes(o);
				p = p.add(b);
				if (!marked(o)) continue;
				var to = newAddr(o);
				Mem.setI32(o, -4, Mem.getI32(savedAt(k), 0));
				k++;
				if (to != o) {
					var src = o.add(-8), dst = to.add(-8);
					// (towards the start: a forward copy, word by word for a small object)
					if (b <= 64) {
						var i = 0;
						while (i < b) {
							Mem.setI64(dst, i, Mem.getI64(src, i));
							i += 8;
						}
					} else
						Wasm.memmove(dst, src, b);
					moved += b;
				}
			}
			s = nextChunkEntry(s + 1);
		}
		copiedBytes += moved;
		// the list: the chunks filled, the live large objects; the other
		// chunks to the pool, the dead large objects' regions back to Heap
		var k = 0;
		oldBytes = 0;
		inPlace = 0;
		for (i in 0...nchunks) {
			var start = Mem.getPtr(chunks, 24 * i);
			var size = entrySize(chunks, i);
			var large = entryLarge(chunks, i);
			var keep = large ? marked(start.add(8)) : !Mem.getPtr(ends, 8 * i).isNull();
			if (!keep) {
				mark(start, size, 0);
				if (large) Heap.release(start, size) else {
					Mem.setPtr(start, 0, pool);
					pool = start;
					poolBytes += CHUNK;
				}
				continue;
			}
			Mem.setPtr(chunks, 24 * k, start);
			Mem.setPtr(chunks, 24 * k + 8, large ? Mem.getPtr(chunks, 24 * i + 8) : Mem.getPtr(ends, 8 * i));
			Mem.setI64(chunks, 24 * k + 16, Mem.getI64(chunks, 24 * i + 16));
			if (large) inPlace += size;
			oldBytes += size;
			k++;
		}
		nchunks = k;
		cur = -1;
		oldPtr = Ptr.nil();
		oldEnd = Ptr.nil();
		Heap.free(ends);
		releaseSaved();
		releaseMarks();
		setLimit(need, false);
		if (stats) {
			Wasi.writeLit(2, "gc: major ");
			Wasi.writeInt(2, majors);
			Wasi.writeLit(2, ": compacted, ");
			Wasi.writeInt(2, (moved >> 20).toInt());
			Wasi.writeLit(2, " MB moved\n");
		}
		return true;
	}

	// after a minor collection that promoted `promoted` of the `used` bytes
	// allocated since the previous one: the native Gc.adaptNursery with one
	// thread, doubled after a collection that promoted more than a 16th and
	// halved after LOW_PROMOTION_AFTER in a row that promoted less than a
	// 64th, between MINOR_MIN and MINOR_MAX
	@:hxmc.unsafe static function adaptNursery(promoted:Int, used:Int) {
		if ((promoted : I64) * 16 > (used : I64)) {
			lowFor = 0;
			if (!growthOff && minorSize < MINOR_MAX) resizeNursery(minorSize * 2);
		} else if ((promoted : I64) * 64 < (used : I64)) {
			if (++lowFor >= LOW_PROMOTION_AFTER && minorSize > MINOR_MIN) {
				resizeNursery(minorSize >> 1);
				lowFor = 0;
			}
		} else
			lowFor = 0;
	}

	// (right after a minor collection: the nursery is empty, so it may move)
	@:hxmc.unsafe static function resizeNursery(size:Int) {
		if (stats) {
			Wasi.writeLit(2, "gc: nursery ");
			Wasi.writeInt(2, size >> 10);
			Wasi.writeLit(2, size > nurseryCap ? " KB (its region grown)\n" : " KB\n");
		}
		if (size > nurseryCap) {
			// its region grown in place when it is the last one, else a new one
			// (the old one freed: chunks and other regions reuse it); when
			// memory cannot grow so far, the nursery stays as it is
			var before = Heap.freshFrom();
			if (Heap.tryExtend(youngStart, nurseryCap, size)) {
				// (what it gained may hold what a region released lowering the top left)
				var hi = youngStart.add(size);
				if (youngStart.add(nurseryCap).ult(before)) youngDirty = hi.ult(before) ? hi : before;
				nurseryCap = size;
			} else {
				var r = Heap.tryRegion(size);
				if (r.isNull()) {
					if (stats) Wasi.writeLit(2, "gc: nursery not grown (memory cannot grow so far)\n");
					growthOff = true;
					return;
				}
				Heap.release(youngStart, nurseryCap);
				minorSize = size;
				placeNursery(r, size, before);
				return;
			}
		}
		minorSize = size;
		setYoungEnd(youngStart.add(size));
	}

	@:hxmc.unsafe static function collectFor(full:Bool, need:Int) {
		var t0 = Wasi.clockNs(1);
		var m0 = majors;
		var used = Mem.tlsGet("rt_young_ptr").diff(youngStart);
		allocBytes += used;
		var hi = Mem.tlsGet("rt_young_rlimit");
		if (youngDirty.ult(hi)) youngDirty = hi;
		if (verifying) verify(false);
		if (verifying) checkRemembered();
		// (what survives fills chunks to within LARGE of their end: an eighth more)
		if (!full && oldBytes + used + (used >> 3) + CHUNK > oldLimit) full = true;
		// (a major collection copies what is live when the free memory holds
		// it whatever it is, or memory grows for it below RT_GROW_MB, else it
		// compacts: a minor collection, then the old space compacted,
		// compactOld; memory does not grow for it. RT_COMPACT=2: it compacts)
		var compactNow = full && compacting && (forceCompact || !(reserveFor(true, false) || reserveGrown()));
		var copyReserved = full && !compactNow && compacting;
		if (compactNow) full = false;
		// the memory to copy into first, for the worst case (reserveFor), else
		// for what the collection copies, measured (reserveExact; from then on
		// the nursery shrinks to its floor and stops growing, what it holds
		// being much of a collection's worst case, and the limits tighter:
		// majorGc). When a major collection cannot have it, a minor one runs
		// if it can (the program goes on past the limit, and the next
		// collection tries a major one again: the memory freed meanwhile may
		// hold it); when neither can, what is live does not fit: the program
		// ends here, outside a collection
		var reserved = copyReserved || reserveFor(full);
		var pressed = !reserved;
		if (!reserved) {
			tight = true;
			reserved = reserveExact(full);
			if (reserved && stats) Wasi.writeLit(2, "gc: memory cannot grow for a collection's worst case: reserved what it copies\n");
		}
		if (!reserved && full && (reserveFor(false) || reserveExact(false))) {
			if (stats) Wasi.writeLit(2, "gc: a minor collection rather than a major one (memory cannot grow for what it copies)\n");
			full = false;
			reserved = true;
		}
		if (!reserved) Heap.outOfMemory();
		var before = copiedBytes;
		if (full) majorGc(need) else minorGc();
		unreserve();
		bigRegions = 0;
		if (!full) {
			youngBytes += used;
			promotedBytes += copiedBytes - before;
			if (!minorFixed && !pressed) adaptNursery((copiedBytes - before).toInt(), used.toInt());
		}
		if (pressed && !minorFixed) {
			growthOff = true;
			if (minorSize > MINOR_MIN) resizeNursery(MINOR_MIN);
		}
		emptyChunk();
		if (compactNow && !compactOld(need) && stats) Wasi.writeLit(2, "gc: no compaction (memory cannot grow for its marks)\n");
		if (verifying) Wasm.memset(youngStart, POISON, minorSize);
		if (verifying) verify(true);
		// the slots the frames left above the stack top (rt_sp_hw)
		var sp = Mem.tlsGet("rt_sp"), hw = Mem.tlsGet("rt_sp_hw");
		if (sp.ult(hw)) Wasm.memset(sp, 0, hw.diff(sp));
		Mem.tlsSet("rt_sp_hw", sp);
		var t1 = Wasi.clockNs(1);
		var ns:Float = cast(t1 - t0);
		var pause = ns * 1e-9;
		if (records.isNull()) records = Heap.malloc(32 * RECORDS);
		var r = records.add(32 * (nrecords % RECORDS));
		var start:Float = cast t0;
		Mem.setF64(r, 0, start * 1e-9);
		Mem.setF64(r, 8, start * 1e-9); // (one thread: stopped at once)
		Mem.setF64(r, 16, start * 1e-9 + pause);
		Mem.setF64(r, 24, majors != m0 ? 1.0 : 0.0);
		nrecords++;
		lastPause = pause;
		totalPause += pause;
		if (pause > maxPause) maxPause = pause;
		if (majors == m0) minorSecs += pause else majorSecs += pause;
	}

	// RT_VERIFY=1: before and after each collection, the old space is checked
	// object by object (sane headers; after it, references to nothing young);
	// the free nursery is filled with a byte pattern at startup and after each
	// collection (as the native Gc.hx does), so that an allocation that is not initialized
	// reads the pattern from its first use, and so does a reference the
	// collection did not see (a missing root)
	static var verifying:Bool;
	static inline var POISON = 0xA5;

	static inline function poisonWord():I64
		return ((0xA5A5A5A5 : I64) << 32) | (((0xA5A5A5A5 : I64) << 32) >>> 32);

	@:hxmc.unsafe static function verify(after:Bool) {
		syncCur();
		var nt = Mem.getI32(Mem.sym("rt_ntypes"), 0);
		var count = 0;
		for (c in 0...nchunks) {
			var p = Mem.getPtr(chunks, 24 * c);
			var end = Mem.getPtr(chunks, 24 * c + 8);
			while (p.ult(end)) {
				var o = p.add(8);
				var n = nslotsOf(o), k = kindOf(o), t = tindexOf(o);
				if (t >= nt || end.diff(o) < ((8 * n) : I64)) bad("gc: verify: bad header (minor, chunk, offset) ", minors, c, o.diff(Mem.getPtr(chunks, 24 * c)).toInt());
				var pm = k == K_OBJ ? ptrmapAt(t) : Ptr.nil();
				if (k == K_PARR || !pm.isNull())
					for (i in 0...n) {
						if (k == K_OBJ && ((Mem.getI32(pm, 4 * (i >> 5)) >>> (i & 31)) & 1) == 0) continue;
						var v = Mem.getPtr(o, 8 * i);
						if (v.isNull()) continue;
						// (above the memory: the tagged word of a scalar, of the
						// encoding and not the nursery's pattern, an uninitialized
						// slot's; a double of those bits is reported too)
						if ((v.toI64() >>> 32) != (0 : I64)) {
							var w = v.toI64();
							if (!Tagged.isScalar(w) || !Tagged.valid(w) || w == poisonWord()) bad("gc: verify: a word neither a reference nor a scalar's (object, slot, type) ", count, i, t);
							continue;
						}
						if (after && inYoung(v)) bad("gc: verify: young reference after a collection (object, slot, type) ", count, i, t);
						if (isOld(v) && isFwdAt(v)) bad("gc: verify: reference to a bad header (object, slot, type) ", count, i, t);
					}
				p = p.add(8 * (n + 1));
				count++;
			}
		}
	}

	// RT_VERIFY=1, before each collection: every young reference in the old
	// space is in a remembered slot or object (the write barrier missed none)
	@:hxmc.unsafe static function checkRemembered() {
		var cap = 1;
		while (cap < 2 * (remLen + robjsLen) + 16)
			cap <<= 1;
		var tab = Heap.calloc(cap, 8);
		inline function add(p:Ptr) {
			var h = (p.toI64() >> 3).toInt() & (cap - 1);
			while (!Mem.getPtr(tab, 8 * h).isNull() && Mem.getPtr(tab, 8 * h) != p)
				h = (h + 1) & (cap - 1);
			Mem.setPtr(tab, 8 * h, p);
		}
		inline function has(p:Ptr):Bool {
			var h = (p.toI64() >> 3).toInt() & (cap - 1);
			var r = false;
			while (!Mem.getPtr(tab, 8 * h).isNull()) {
				if (Mem.getPtr(tab, 8 * h) == p) {
					r = true;
					break;
				}
				h = (h + 1) & (cap - 1);
			}
			return r;
		}
		for (i in 0...remLen)
			add(Mem.getPtr(rem, 8 * i));
		for (i in 0...robjsLen)
			add(Mem.getPtr(robjs, 8 * i));
		syncCur();
		var count = 0;
		for (c in 0...nchunks) {
			var p = Mem.getPtr(chunks, 24 * c);
			var end = Mem.getPtr(chunks, 24 * c + 8);
			while (p.ult(end)) {
				var o = p.add(8);
				var n = nslotsOf(o), k = kindOf(o), t = tindexOf(o);
				var pm = k == K_OBJ ? ptrmapAt(t) : Ptr.nil();
				if (k == K_PARR || !pm.isNull()) {
					if (!has(o))
						for (i in 0...n) {
							if (k == K_OBJ && ((Mem.getI32(pm, 4 * (i >> 5)) >>> (i & 31)) & 1) == 0) continue;
							var v = Mem.getPtr(o, 8 * i);
							if (!v.isNull() && inYoung(v) && !has(o.add(8 * i))) bad("gc: verify: unremembered young reference (object, slot, type) ", count, i, t);
						}
				}
				p = p.add(8 * (n + 1));
				count++;
			}
		}
		Heap.free(tab);
	}

	@:hxmc.unsafe static function bad(lit:String, a:Int, b:Int, c:Int) {
		Wasi.writeLit(2, lit);
		Wasi.writeInt(2, a);
		Wasi.writeLit(2, " ");
		Wasi.writeInt(2, b);
		Wasi.writeLit(2, " ");
		Wasi.writeInt(2, c);
		Wasi.writeLit(2, "\n");
		Wasi.exit(99);
	}

	// ---- hxmc.NativeGc

	@:hxmc.collects public static function collect(full:Bool):Void
		collectFor(full, 0);

	// The old space's limit while no major collection has run (RT_OLD_MB, 32
	// MB by default, which wins over this), as the native Gc.setOldLimit
	// (hxmc.NativeGc.setOldLimit works on both): a program that keeps most of
	// what it allocates until it exits (a compiler's syntax trees and types)
	// raises it, so that its first major collections do not move what it is
	// still building (tsc-haxe). It only raises it, and at most to 3 GB, where
	// a compaction of the old space still fits in a 4 GB memory (its marks,
	// its table, the nursery: a quarter of it), within what the rest of
	// memory leaves, and within RT_MAX_MB's room when set, as setLimit caps
	// the limits a compacting major collection sets. With RT_COMPACT=0 a
	// major collection copies: half of what the rest leaves (about 2 GB)
	@:hxmc.unsafe public static function setOldLimit(mb:Int):Void {
		if (majors > 0 || mb <= 0 || Wasi.envInt("RT_OLD_MB", -1) >= 0) return;
		var l:I64 = (mb : I64) << 20;
		var other = Heap.memoryBytes() - oldBytes - poolBytes;
		var cap = (((1 : I64) << 32) - (64 << 20) - other) >> (compacting ? 0 : 1);
		var most:I64 = (3 : I64) << 30;
		if (cap > most) cap = most;
		if (budget > 0) {
			var fits = budget - fixedBytes - nurseryCap - (minorSize : I64) - (Heap.memoryBytes() >> 5) - 4 * CHUNK;
			if (cap > fits) cap = fits;
		}
		if (l > cap) l = cap;
		if (oldLimit < l) oldLimit = l;
	}

	// (finalisers never run: WebAssembly programs have no resources to free behind values)
	@:hxmc.unsafe public static function finalise(fn:Dynamic->Void, v:Dynamic):Void {}

	@:hxmc.unsafe public static function runFinalisers():Void {}

	// ---- hxmc.GcStats

	// bytes allocated since the start, in the nursery and in the old space
	@:hxmc.unsafe public static function bytesAllocated():Float {
		var f:Float = cast(allocBytes + largeBytes + Mem.tlsGet("rt_young_ptr").diff(youngStart));
		return f;
	}

	// (one thread)
	@:hxmc.unsafe public static function threadBytesAllocated():Float
		return bytesAllocated();

	@:hxmc.unsafe public static function recordField(k:Int, field:Int):Float
		return Mem.getF64(records, 32 * (k % RECORDS) + 8 * field);

	@:hxmc.unsafe public static function recordCount():Int
		return nrecords;

	@:hxmc.unsafe public static function clock():Float {
		var ns:Float = cast Wasi.clockNs(1);
		return ns * 1e-9;
	}

	@:hxmc.unsafe public static function counts(which:Int):Int
		return which == 0 ? collections : which == 1 ? minors : majors;

	@:hxmc.unsafe public static function pause(which:Int):Float
		return which == 0 ? lastPause : which == 1 ? totalPause : maxPause;

	// RT_STATS at the program's end (Exit.mainDone), as the native Gc.report:
	// "gc: <n> minor (<s>s), <m> major (<s>s), old <a> MB used; promoted <p> of <y> MB"
	@:hxmc.unsafe public static function report() {
		if (!stats) return;
		Wasi.writeLit(2, "gc: ");
		Wasi.writeInt(2, minors);
		Wasi.writeLit(2, " minor (");
		writeSecs(minorSecs);
		Wasi.writeLit(2, "s), ");
		Wasi.writeInt(2, majors);
		Wasi.writeLit(2, " major (");
		writeSecs(majorSecs);
		Wasi.writeLit(2, "s), old ");
		Wasi.writeInt(2, (oldBytes >> 20).toInt());
		Wasi.writeLit(2, " MB used; promoted ");
		Wasi.writeInt(2, (promotedBytes >> 20).toInt());
		Wasi.writeLit(2, " of ");
		Wasi.writeInt(2, (youngBytes >> 20).toInt());
		Wasi.writeLit(2, " MB\n");
	}

	// seconds with two decimals
	@:hxmc.unsafe static function writeSecs(s:Float) {
		var c = Std.int(s * 100 + 0.5);
		Wasi.writeInt(2, Std.int(c / 100));
		if (c % 100 < 10) Wasi.writeLit(2, ".0") else Wasi.writeLit(2, ".");
		Wasi.writeInt(2, c % 100);
	}

	// what the old space's chunks and regions hold, and the nursery up to its
	// allocation pointer (hxmc.GcStats.liveBytes)
	@:hxmc.unsafe public static function liveBytes():Float {
		syncCur();
		var b:I64 = Mem.tlsGet("rt_young_ptr").diff(youngStart);
		for (i in 0...nchunks)
			b += Mem.getPtr(chunks, 24 * i + 8).diff(Mem.getPtr(chunks, 24 * i));
		var f:Float = cast b;
		return f;
	}

	@:hxmc.unsafe public static function heapBytes():Float {
		var b:Float = cast oldLimit;
		return b + minorSize;
	}

	@:hxmc.unsafe public static function reached():Bool
		return false;

	// (no object sizes: 0)
	// (no census of the heap on WebAssembly)
	public static function objsize(v:Dynamic, exclude:Array<Dynamic>, out:Array<Dynamic>):Float {
		hxmc.rt.C.Rt.rt_throw("Gc.objsize is not supported on WebAssembly");
		return 0;
	}
}
