package hxmc.rt.wasm;

import hxmc.I64;
import hxmc.rt.Types.*;
import hxmc.rt.GcCore.*;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Ptr;

// The collector and allocator of WebAssembly programs: the native Gc.hx's
// generational copying collector with one thread, in Haxe over linear
// memory (docs/hxmc.md, "WebAssembly"). Same objects, nursery, promotion
// and depth-first copying as the native Gc.hx (whose comments explain them); the
// differences: memory comes from Heap (it grows, it is never given back),
// the old space is a list of chunks rather than a contiguous semispace (a
// major collection copies into chunks taken as it goes, then the from-space's
// chunks are kept for reuse: no to-space sized for the worst case, no
// semispaces that outgrow the holes their predecessors left, which a 4 GB
// memory cannot afford), no thread handshake (one thread, thread-locals are
// globals), no native handles (no C resources), and finalisers are
// registered but never run. Every function here is
// @:hxmc.noGc: it runs while objects move, with raw addresses.
@:hxmc.wasm @:keep
class Gc {
	static inline var MINOR_MAX = 32 << 20;
	static inline var MINOR_MIN = 4 << 20;
	static inline var LOW_PROMOTION_AFTER = 8;
	static inline var MIN_OLD = 16 << 20;
	static inline var STACK_MB = 4; // the shadow stack's default (RT_STACK_MB)
	static inline var CHUNK = 1 << 20;
	static inline var LARGE = 128 << 10; // larger objects get a region of their own
	static inline var GRAN_SHIFT = 16; // chunks and regions start at multiples of 64 KB
	static inline var GRAN = 1 << GRAN_SHIFT;

	static var nurseryCap:Int; // the nursery's region (from youngStart): its largest size so far
	static var youngStart:Ptr;
	static var youngEnd:Ptr;
	static var youngDirty:Ptr; // the nursery above this holds zeros (never used yet)
	static var zchunk:Int; // RT_ZCHUNK_KB
	static var minorSize:Int;
	static var minorFixed:Bool;
	// the old space: chunks of CHUNK bytes and the regions of large objects,
	// listed as (start, used end, size)
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
	static var pool:Ptr; // free chunks, linked through their first word
	static var poolBytes:I64;
	// a byte per 64 KB of memory: 1 in the old space (the from-space during a
	// major collection), 2 in its to-space, 0 elsewhere
	static var gran:Ptr;
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

	// (the header: read through GcCore, as the native Gc.hx reads it)
	static inline function inYoung(p:Ptr):Bool
		return !p.ult(youngStart) && p.ult(youngEnd);

	static inline function inFrom(p:Ptr):Bool
		return Mem.getU8(gran, (p.toI64() >>> GRAN_SHIFT).toInt()) == 1;

	static inline function isOld(p:Ptr):Bool
		return Mem.getU8(gran, (p.toI64() >>> GRAN_SHIFT).toInt()) != 0;

	// ---- startup

	@:hxmc.export("rt_init") @:hxmc.noGc static function init(ng:Int, argc:Int, argv:Ptr):Void {
		Heap.malloc(0); // (the heap's tables)
		Wasi.init();
		var m = Wasi.envInt("RT_MINOR_KB", -1);
		minorFixed = m >= 0;
		minorSize = (m >= 0 ? m : 4096) << 10;
		if (minorSize < 4096) minorSize = 4096;
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
		gcCap = 4096;
		gcStack = Heap.malloc(16 * gcCap);
		hxmc.rt.Boxes.init();
		// the type objects (rt_type_objs: two words each, DataGen)
		var nt = Mem.getI32(Mem.sym("rt_ntypes"), 0);
		var to = Mem.sym("rt_type_objs");
		for (t in 0...nt) {
			Mem.setI64(to, 16 * t, Types.recordHdr(T_TYPEOBJ, 1));
			Mem.setI64(to, 16 * t + 8, t);
		}
	}

	@:hxmc.noGc static function setYoungEnd(e:Ptr) {
		youngEnd = e;
		Mem.setPtr(Mem.sym("rt_young_end"), 0, e);
	}

	// the nursery in the region r of cap bytes (empty: at startup, or right
	// after a minor collection); what the region holds below `before`
	// (Heap.freshFrom() before it was taken) may not be zeros
	@:hxmc.noGc static function placeNursery(r:Ptr, cap:Int, before:Ptr) {
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

	@:hxmc.export("rt_stack_overflow") @:hxmc.noGc static function stackOverflow():Void {
		Wasi.writeLit(2, "stack overflow: the shadow stack's ");
		Wasi.writeInt(2, stackMb);
		Wasi.writeLit(2, " MB are full (RT_STACK_MB sets its size)\n");
		Wasi.exit(2);
	}

	// the stack of frame slots (_start, DataGen): its end and its top
	@:hxmc.export("rt_cstack_lo") @:hxmc.noGc static function cstackLo():Ptr
		return cstackBase.add(CSTACK_RESERVE);

	@:hxmc.export("rt_cstack_top") @:hxmc.noGc static function cstackTop():Ptr
		return cstackBase.add((stackMb << 20) + CSTACK_RESERVE);

	// a frame would go below rt_cstack_lo (WasmGen's prologue). Without a
	// frame itself: the reserve below the end becomes the stack for the message
	@:hxmc.export("rt_cstack_overflow") @:hxmc.noGc static function cstackOverflow():Void {
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

	@:hxmc.noGc static function emptyChunk() {
		Mem.tlsSet("rt_young_ptr", youngStart);
		Mem.tlsSet("rt_young_rlimit", youngStart);
		Mem.tlsSet("rt_young_limit", youngStart);
	}

	// the next chunk, from the allocation pointer, with room for bytes (false: none)
	@:hxmc.noGc static function nextChunk(bytes:Int):Bool {
		var p = Mem.tlsGet("rt_young_ptr");
		var avail = youngEnd.diff(p);
		if (avail < (bytes : I64)) return false;
		var take:I64 = verifying ? avail : (bytes > zchunk ? bytes : zchunk);
		if (take > avail) take = avail;
		var e = p.add(take.toInt());
		if (!verifying) {
			// (up to the old chunk's end the nursery is zeroed already)
			var z = Mem.tlsGet("rt_young_rlimit");
			if (z.ult(p)) z = p;
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

	@:hxmc.export("rt_alloc_slow") @:hxmc.collects static function allocSlow(header:I64, bytes:Int):Ptr {
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
		} else {
			if (Mem.tlsGet("rt_young_rlimit").diff(Mem.tlsGet("rt_young_ptr")) < (bytes : I64) && !nextChunk(bytes)) {
				collectFor(false, 0);
				nextChunk(bytes);
			}
			p = Mem.tlsGet("rt_young_ptr");
			Mem.tlsSet("rt_young_ptr", p.add(bytes));
			Mem.setI64(p, 0, header);
			// (zeroed with its chunk, but for the pattern of RT_VERIFY)
			if (verifying) Wasm.memset(p.add(8), 0, bytes - 8);
			return p.add(8);
		}
		Mem.setI64(p, 0, header);
		Wasm.memset(p.add(8), 0, bytes - 8);
		return p.add(8);
	}

	// ---- the old space

	// `bytes` in the old space (null: memory cannot grow so far)
	@:hxmc.noGc static function oldAlloc(bytes:Int):Ptr {
		var p = oldPtr;
		if (oldEnd.diff(p) >= (bytes : I64)) {
			oldPtr = p.add(bytes);
			return p;
		}
		return oldAllocSlow(bytes);
	}

	@:hxmc.noGc static function oldAllocSlow(bytes:Int):Ptr {
		if (bytes > LARGE) {
			var size = (bytes + (GRAN - 1)) & ~(GRAN - 1);
			var r = Heap.tryRegionAligned(size, GRAN);
			if (!r.isNull()) addChunk(r, r.add(bytes), size);
			return r;
		}
		var c = pool;
		if (!c.isNull()) {
			pool = Mem.getPtr(c, 0);
			poolBytes -= CHUNK;
		} else {
			c = Heap.tryRegionAligned(CHUNK, GRAN);
			if (c.isNull()) return c;
		}
		syncCur();
		cur = nchunks;
		addChunk(c, c, CHUNK);
		oldPtr = c.add(bytes);
		oldEnd = c.add(CHUNK);
		return c;
	}

	@:hxmc.noGc static function addChunk(start:Ptr, end:Ptr, size:Int) {
		if (nchunks == chunksCap) {
			chunksCap *= 2;
			chunks = Heap.realloc(chunks, 24 * chunksCap);
		}
		Mem.setPtr(chunks, 24 * nchunks, start);
		Mem.setPtr(chunks, 24 * nchunks + 8, end);
		Mem.setI64(chunks, 24 * nchunks + 16, size);
		nchunks++;
		oldBytes += size;
		mark(start, size, newState);
	}

	@:hxmc.noGc static function mark(start:Ptr, size:Int, state:Int) {
		var g = (start.toI64() >>> GRAN_SHIFT).toInt();
		for (i in 0...(size >> GRAN_SHIFT))
			Mem.setI8(gran, g + i, state);
	}

	// the current chunk's used end into the list
	@:hxmc.noGc static function syncCur() {
		if (cur >= 0) Mem.setPtr(chunks, 24 * cur + 8, oldPtr);
	}

	// ---- the write barrier

	@:hxmc.export("hxmc_barrier_slow") @:hxmc.noGc static function barrierSlow(obj:Ptr, slot:Ptr, v:Ptr, prev:Ptr):Void {
		if (inYoung(v) && !inYoung(prev)) remember(slot);
	}

	@:hxmc.export("rt_write_barrier") @:hxmc.noGc static function writeBarrier(obj:Ptr, slot:Ptr, v:Ptr):Void
		remember(slot);

	@:hxmc.noGc static function remember(slot:Ptr) {
		if (remLen == remCap) {
			remCap *= 2;
			rem = Heap.realloc(rem, 8 * remCap);
		}
		Mem.setPtr(rem, 8 * remLen, slot);
		remLen++;
	}

	@:hxmc.noGc static function rememberObj(o:Ptr) {
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

	@:hxmc.export("rt_barrier_range") @:hxmc.noGc static function barrierRange(obj:Ptr, from:Ptr, n:Int):Void {
		if (inYoung(obj)) return;
		if (n > 16) {
			rememberObj(obj);
			return;
		}
		for (i in 0...n)
			if (inYoung(Mem.getPtr(from, 8 * i))) remember(from.add(8 * i));
	}

	// ---- collection

	@:hxmc.noGc static function copyTo(dst:Ptr, obj:Ptr):Ptr {
		var words = nslotsOf(obj) + 1;
		var s = obj.add(-8);
		if (words <= 8) {
			for (i in 0...words)
				Mem.setI64(dst, 8 * i, Mem.getI64(s, 8 * i));
		} else
			Wasm.memcpy(dst, s, 8 * words);
		return dst.add(8);
	}

	@:hxmc.noGc static function forwardTo(p:Ptr, n:Ptr)
		setFwd(p, n);

	@:hxmc.noGc static function fwd(p:Ptr):Ptr {
		if (!inYoung(p) && !(major && inFrom(p))) return p;
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

	@:hxmc.noGc static function push(o:Ptr) {
		if (gcTop == gcCap) {
			gcCap *= 2;
			gcStack = Heap.realloc(gcStack, 16 * gcCap);
		}
		Mem.setPtr(gcStack, 16 * gcTop, o);
		Mem.setI64(gcStack, 16 * gcTop + 8, 0);
		gcTop++;
	}

	@:hxmc.noGc static function drain() {
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
					// copied just now: its subtree next
					Mem.setI64(f, 8, i);
					push(nv);
					pushed = true;
					break;
				}
			}
			if (!pushed) gcTop--;
		}
	}

	@:hxmc.noGc static function fwdRoot(p:Ptr):Ptr {
		var before = copies;
		var n = fwd(p);
		if (copies != before) {
			push(n);
			drain();
		}
		return n;
	}

	@:hxmc.noGc static function rootAt(slot:Ptr) {
		var v = Mem.getPtr(slot, 0);
		if (!v.isNull()) Mem.setPtr(slot, 0, fwdRoot(v));
	}

	@:hxmc.noGc static function scanObject(o:Ptr) {
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

	@:hxmc.noGc static function scanRoots() {
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

	@:hxmc.noGc static function minorGc() {
		var used = Mem.tlsGet("rt_young_ptr").diff(youngStart);
		// (what survives fills chunks to within LARGE of their end: an eighth more)
		if (oldBytes + used + (used >> 3) + CHUNK > oldLimit) {
			majorGc(0);
			return;
		}
		minors++;
		collections++;
		major = false;
		scanRoots();
		for (i in 0...remLen)
			rootAt(Mem.getPtr(rem, 8 * i));
		remLen = 0;
		for (i in 0...robjsLen)
			scanObject(Mem.getPtr(robjs, 8 * i));
		robjsLen = 0;
		Wasm.memset(robjsRecent, 0, 8 * 256);
	}

	@:hxmc.noGc static function majorGc(need:Int) {
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
		newState = 2;
		major = true;
		scanRoots();
		remLen = 0;
		robjsLen = 0;
		Wasm.memset(robjsRecent, 0, 8 * 256);
		major = false;
		newState = 1;
		for (i in 0...nfrom) {
			var start = Mem.getPtr(fromChunks, 24 * i);
			var size = Mem.getI64(fromChunks, 24 * i + 16).toInt();
			mark(start, size, 0);
			if (size == CHUNK) {
				Mem.setPtr(start, 0, pool);
				pool = start;
				poolBytes += CHUNK;
			} else
				Heap.release(start, size);
		}
		for (i in 0...nchunks)
			mark(Mem.getPtr(chunks, 24 * i), Mem.getI64(chunks, 24 * i + 16).toInt(), 1);
		// the next limit: twice what is live and room for the nursery, but at
		// most half of what the rest of a wasm32 memory (4 GB) leaves: the next
		// collection's from-space and to-space must both fit
		var live = oldBytes;
		var limit = live * 2 + (minorSize : I64) * 4 + need;
		if (limit < (MIN_OLD : I64)) limit = MIN_OLD;
		var other = Heap.memoryBytes() - oldBytes - poolBytes;
		var cap = (((1 : I64) << 32) - (64 << 20) - other) >> 1;
		if (limit > cap) limit = cap;
		var least = live + need + (minorSize : I64) + 2 * CHUNK;
		if (limit < least) limit = least;
		oldLimit = limit;
		if (stats) Wasi.statLine("gc: major ", majors, (live >> 20).toInt(), (limit >> 20).toInt(), (Heap.memoryBytes() >> 20).toInt());
	}

	// after a minor collection that promoted `promoted` of the `used` bytes
	// allocated since the previous one: the native Gc.adaptNursery with one
	// thread, doubled after a collection that promoted more than a 16th and
	// halved after LOW_PROMOTION_AFTER in a row that promoted less than a
	// 64th, between MINOR_MIN and MINOR_MAX
	@:hxmc.noGc static function adaptNursery(promoted:Int, used:Int) {
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
	@:hxmc.noGc static function resizeNursery(size:Int) {
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

	@:hxmc.noGc static function collectFor(full:Bool, need:Int) {
		var hi = Mem.tlsGet("rt_young_rlimit");
		if (youngDirty.ult(hi)) youngDirty = hi;
		if (verifying) verify(false);
		if (verifying) checkRemembered();
		if (full) majorGc(need) else {
			var before = copiedBytes;
			var m0 = majors;
			var used = Mem.tlsGet("rt_young_ptr").diff(youngStart).toInt();
			minorGc();
			if (!minorFixed && majors == m0) adaptNursery((copiedBytes - before).toInt(), used);
		}
		emptyChunk();
		if (verifying) Wasm.memset(youngStart, POISON, minorSize);
		if (verifying) verify(true);
		// the slots the frames left above the stack top (rt_sp_hw)
		var sp = Mem.tlsGet("rt_sp"), hw = Mem.tlsGet("rt_sp_hw");
		if (sp.ult(hw)) Wasm.memset(sp, 0, hw.diff(sp));
		Mem.tlsSet("rt_sp_hw", sp);
	}

	// RT_VERIFY=1: before and after each collection, the old space is checked
	// object by object (sane headers; after it, references to nothing young);
	// the free nursery is filled with a byte pattern at startup and after each
	// collection (as the native Gc.hx does), so that an allocation that is not initialized
	// reads the pattern from its first use, and so does a reference the
	// collection did not see (a missing root)
	static var verifying:Bool;
	static inline var POISON = 0xA5;

	@:hxmc.noGc static function verify(after:Bool) {
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
	@:hxmc.noGc static function checkRemembered() {
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

	@:hxmc.noGc static function bad(lit:String, a:Int, b:Int, c:Int) {
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

	// (finalisers never run: WebAssembly programs have no resources to free behind values)
	@:hxmc.noGc public static function finalise(fn:Dynamic->Void, v:Dynamic):Void {}

	@:hxmc.noGc public static function runFinalisers():Void {}

	@:hxmc.noGc public static function heapBytes():Float {
		var b:Float = cast oldLimit;
		return b + minorSize;
	}

	@:hxmc.noGc public static function reached():Bool
		return false;

	// (no object sizes: 0)
	// (no census of the heap on WebAssembly)
	public static function objsize(v:Dynamic, exclude:Array<Dynamic>, out:Array<Dynamic>):Float {
		hxmc.rt.C.Rt.rt_throw("Gc.objsize is not supported on WebAssembly");
		return 0;
	}
}
