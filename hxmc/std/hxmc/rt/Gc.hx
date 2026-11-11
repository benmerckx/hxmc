package hxmc.rt;

import hxmc.I64;
import hxmc.rt.Layouts as L;
import hxmc.rt.Threads.Mutator;
import hxmc.rt.Os.Report;
import hxmc.rt.C;
import hxmc.rt.GcCore.*;
import hxmc.unsafe.*;

// The collector and allocator of the native targets (once hxmc/c/rt.c;
// WebAssembly's is wasm/Gc.hx, single-threaded over linear memory, with the
// same objects, nursery, promotion and depth-first copying).
//
// Precise and generational in the style of OCaml's: bump allocation in a
// nursery, copying minor collections promote survivors to the old space,
// which is collected by copying too. Roots: the threads' shadow stacks
// (reference locals live across a GC point), the globals table (rt_globals),
// the remembered sets (the write barrier), the threads' entry closures,
// Tls values and current exceptions, the finalisers, the closures
// Objective-C blocks call (blockNew), and the peers of foreign objects their
// systems keep (Foreign.scan; Foreign.sweep after a collection).
//
// Threads (Threads): each thread allocates in its own chunk of the nursery
// (a TLAB: rt_young_ptr/rt_young_limit, taken from youngNext) and records
// old-to-young stores in its own remembered set (its Mutator record); a
// collection stops every other thread at a safepoint (an allocation slow
// path) or in a safe region (a blocking call), see Threads.worldStop, and
// works on their records. With one thread a TLAB is a chunk of 32 KB
// (RT_ZCHUNK_KB).
//
// The nursery's size (unless RT_MINOR_KB fixes it) follows what survives
// it and the threads that allocate (adaptNursery): it doubles after a minor
// collection that promoted more than a 16th of what was allocated since the
// last one (objects that live a little longer than a cycle, e.g. a tree
// being built, are copied fewer times, and fewer of them reach the old
// space and its major collections: the port typing itself, a third less
// time in the collector and a third less peak memory at 16 MB than at 4),
// and halves after 8 collections that promoted less than a 64th; programs
// whose objects die young keep 4 MB, which stays in the caches. Between a
// floor of 4 MB per allocating thread, at most 32 MB, and a ceiling of 16 MB
// per allocating thread, up to 256 MB (MINOR_MIN, FLOOR_MAX, MINOR_CAP,
// MINOR_MAX): one budget, split into TLABs; threads that fill it together
// stop together, so each collection costs all of them a pause, and what each
// of them is working on survives it. The ceiling grows with the threads so
// that each of them can allocate as much between two collections as a single
// thread would (the tool's parallel code generation, 12 threads: sharing
// 32 MB, a third of its time went to serial minor collections and it
// promoted 1.3 GB of short-lived data); past the floor, only what survives
// grows it, so threads whose objects die young keep a small nursery. A
// thread counts when it took a TLAB since the last collection; the count
// grows at once and shrinks after 16 collections with fewer threads (a
// parallel phase starts and ends its workers' allocation).
//
// A TLAB is a 16th of the nursery, at most 64 KB (TLAB_MAX; RT_TLAB_KB; in
// fresh pages, up to a 2 MB boundary: tlabRefill): zeroed when taken, it is
// still in the L2 cache for the allocations that use it, and its refill is
// the thread's safepoint, so a small one keeps a stop of the world from
// waiting long for the other threads (2 MB TLABs: zeroing that missed the
// caches, and half a second waiting for threads).
//
// Allocation zeroes in bulk: a TLAB is zeroed when it is taken (in the L1
// cache, right before the allocations that use it), so every object
// allocated in the nursery starts zeroed and no allocation zeroes its own
// slots. Two limits: rt_young_rlimit is the TLAB's end, compared by
// allocations whose every slot is written before it is read (Mem.allocRaw);
// rt_young_limit, compared by those that rely on the zeros, is the same but
// with RT_VERIFY=1, where the free nursery holds a byte pattern instead of
// zeros and it is null: those allocations then take the slow path, which
// zeroes them, while the others still read the pattern if they read before
// writing.
//
// Every function here but the allocation slow path, the finalisers' calls
// and NativeGc's entry points is @:hxmc.unsafe: it runs while objects move,
// with raw addresses.
@:hxmc.native @:keep @:allow(hxmc.rt)
class Gc {
	static inline var K_OBJ = 0;
	static inline var K_PARR = 1;
	static inline var K_RAW = 2;
	static inline var T_FWD = 0xFFFF;
	static inline var T_NATIVE = Types.T_NATIVE; // a native handle
	static inline var T_NATIVE_REFS = Types.T_NATIVE_REFS; // one holding references
	static inline var MINOR_MAX = 256 << 20;
	static inline var MINOR_MIN = 4 << 20; // per allocating thread
	static inline var FLOOR_MAX = 32 << 20;
	static inline var MINOR_CAP = 16 << 20; // per allocating thread
	static inline var TLAB_MAX = 64 << 10;
	static inline var HUGE_PAGE = 2 << 20;
	static inline var FEWER_THREADS_AFTER = 16;
	static inline var LOW_PROMOTION_AFTER = 8;
	static inline var POISON = 0xA5;

	// ---- the running thread's state (Threads.publish copies what the
	// collector needs into its record while it is stopped)
	@:hxmc.threadLocal("rt_young_ptr") static var yptr:Ptr;
	@:hxmc.threadLocal("rt_young_limit") static var ylim:Ptr;
	@:hxmc.threadLocal("rt_young_rlimit") static var yrlim:Ptr;
	// the shadow stack's top, and the highest it reached since the last
	// collection: each collection zeroes the slots in [rt_sp, rt_sp_hw), so a
	// slot above rt_sp holds 0 or a reference stored since: a new frame needs
	// no zeroing, whatever the collector finds in it is a valid (if dead)
	// reference
	@:hxmc.threadLocal("rt_sp") static var sp:Ptr;
	@:hxmc.threadLocal("rt_sp_hw") static var hw:Ptr;
	@:hxmc.threadLocal("rt_hcur") static var hcur:Ptr; // the innermost try's handler
	@:hxmc.threadLocal("rt_exn") static var exn:Ptr; // the exception being thrown (a root)
	@:hxmc.threadLocal static var finalsRunning:Int;

	// ---- the nursery: [rt_young_start, rt_young_end), fixed between collections
	@:hxmc.export("rt_young_start") static var youngStart:Ptr;
	@:hxmc.export("rt_young_end") static var youngEnd:Ptr;
	@:hxmc.export("hxmc_young_next") static var youngNext:Ptr; // the free part: TLABs are taken from here
	static var youngDirty:Ptr; // the nursery above this holds zeros (never used since fresh or released)
	static var minorSize:I64;
	static var tlabSize:I64; // with several threads (RT_TLAB_KB; default a 16th of the nursery, at most TLAB_MAX)
	static var zchunk:I64; // RT_ZCHUNK_KB
	static var minorFixed:Bool; // RT_MINOR_KB sets the nursery size
	// the threads that took a TLAB in this cycle (a thread counts once per
	// epoch, which each collection advances), the count the size follows,
	// and the collections since a cycle had as many
	@:hxmc.export("hxmc_allocating") static var allocating:Int;
	static var epoch:Int;
	@:hxmc.threadLocal static var myEpoch:Int;
	static var mutators:Int;
	static var fewerFor:Int;
	static var fewerMax:Int;
	static var promotionSize:I64; // the size what survives asks for
	static var lowFor:Int; // collections in a row that promoted little
	static var hugePages:Bool; // RT_HUGE
	// RT_VERIFY=1: the free nursery is filled with a byte pattern at startup
	// and after every collection, so that an allocation that is not
	// initialized reads the pattern from its first use (not zeros before the
	// first collection and dead objects after it), and so does a reference a
	// collection did not see (a missing root: the object it pointed to has moved)
	static var poison:Bool;

	// ---- the old space: it alternates between two large reserved regions;
	// oldEnd is a soft limit, set after each major collection to `growth`
	// percent of the live size (RT_OLD_GROWTH, 300: three times), with room
	// for the live set to grow on after collections that freed little
	// (growthMult, majorLimit), but no more than half the memory (ramBytes)
	// or the region (regionBytes)
	static var growth:Int;
	static var growthMult:Int;
	static var prevLive:I64; // what the previous major collection left live
	static var ramBytes:I64; // physical memory (Linux; 0: unknown)
	static var oldStart:Ptr;
	@:hxmc.export("hxmc_old_ptr") static var oldPtr:Ptr;
	static var oldEnd:Ptr;
	// 16 GB each; on Windows they are 2 GB by default (RT_REGION_MB), and a
	// reservation that fails is retried at half the size down to 512 MB
	static var regionBytes:I64;
	// a program with compressed references (@:hxmc.compact: a type of
	// Types.hasCompact) keeps its nursery and regions below 32 GB (GcCore.getC:
	// an address shifted right by 3 fits 32 bits), reserved from 1 GB up at
	// fixed addresses (compactNext), each region at most half of what is left
	static var compactHeap:Bool;
	// (false where the program has no such type: GcCore.compactTypes, a constant)
	static inline function compactWindow():Bool
		return compactTypes() && compactHeap;

	static var compactNext:I64;
	static inline var COMPACT_LIMIT:Int = 32;
	// where the compressed references' heap ends: 32 GB, on macOS the end of
	// the image's __HXHEAP segment (macWindow)
	static var compactLimit:I64;
	static var region0:Ptr;
	static var region1:Ptr;
	static var curRegion:Int;
	static var fromStart:Ptr;
	static var fromEnd:Ptr;
	static var releasePages:Bool;
	// core dumps (Linux: Os.coreDump): each region and the nursery are left
	// out of one but for what the heap may use of them, [region, dumpTop0 or
	// dumpTop1) and [youngStart, youngDump): a core of a program that touched
	// a page of its 32 GB of regions was 32 GB, written out as zeros through a
	// pipe in minutes (#43)
	static var dumpTop0:Ptr;
	static var dumpTop1:Ptr;
	static var youngDump:Ptr;
	// the calling thread's C stack (the main thread's: Start.runMain, a
	// thread's: Os.threadStackCoreDump; null: unknown), for Faults.dumpStacks
	@:hxmc.threadLocal("rt_cstack_lo") static var cstackLo:Ptr;
	@:hxmc.threadLocal("rt_cstack_hi") static var cstackHi:Ptr;

	@:hxmc.export("rt_globals") static var globals:Ptr;
	static var nglobals:Int;
	// the table's room: a Mir host (a compiler that loads code, Mem.mirHost)
	// has spare slots for the globals of what it loads (macro.Loader), taken
	// in place: compiled code keeps the table's address across calls (Opt.MConst)
	static var globalsCap:Int;
	public static inline var SPARE_GLOBALS = 65536;

	static var stats:Bool;
	static var minors:Int;
	// every collection, and the major ones (both move objects: hxmc.rt.IdHash)
	@:hxmc.export("hxmc_gc_majors") static var majors:Int;
	@:hxmc.export("hxmc_gc_count") static var collections:Int;
	static var minorSecs:Float; // RT_STATS
	static var youngBytes:I64; // RT_STATS: allocated in the nursery, and promoted from it
	static var promotedBytes:I64;
	static var majorSecs:Float;
	// hxmc.GcStats (always kept: a few additions and two clock reads per
	// collection): bytes allocated in the nursery up to the last collection
	// (what each thread's TLAB used of it), and straight in the old space
	// (large objects); the collections' pauses (stopping the world to resuming it)
	static var allocBytes:I64;
	@:hxmc.export("hxmc_gc_large_bytes") static var largeBytes:I64;
	static var lastPause:Float;
	static var totalPause:Float;
	static var maxPause:Float;
	// the last RECORDS collections (hxmc.GcStats.records): their start (the
	// collecting thread's request), the world stopped, their end (seconds on
	// Os.now's clock), and 1.0 for a major one; nrecords counts them all
	public static inline var RECORDS = 64;
	static var records:Ptr;
	static var nrecords:Int;

	// ---- finalisers (Gc.finalise in Eval): OCaml's Gc.finalise semantics. A
	// finaliser's function is a root; its value is a root of minor collections
	// only (they promote it), and a major collection that finds it unreachable
	// copies it back (it lives on for the call) and queues the call. Queued
	// calls run at the next allocation slow path or NativeGc.runFinalisers,
	// in the reverse order of registration for values found dead together.
	// (fn, value) pairs; the lock guards registration and dequeuing (the
	// collector runs with every thread stopped)
	static var finals:Ptr;
	static var nfinals:Int;
	static var finalsCap:Int;
	static var finalQueue:Ptr;
	static var finalQhead:Int;
	static var finalQlen:Int;
	static var finalQcap:Int;
	static var finalsLock:Ptr;

	// ---- native handles: freed once their T_NATIVE object is found
	// unreachable: (object, resource, free function) triples
	static var natives:Ptr;
	static var nnatives:Int;
	static var nativesCap:Int;
	static var nativesLock:Ptr;
	// macOS (no pipe2, accept4 or SOCK_CLOEXEC): a descriptor the runtime creates
	// gets FD_CLOEXEC under this lock, which fork takes too, so no child forked
	// meanwhile inherits it (PosixSys.cloexecFds, PosixSys.spawn)
	public static var fdLock:Ptr;
	static var deadNatives:Ptr;
	static var deadCap:Int;

	// ---- weak slots: references to Haxe objects that the collector does not
	// follow. A slot (an index from 1: 0 is no slot) holds an object's
	// address, or null; after every collection, minor and major, a slot whose
	// object moved holds its new address, one whose object died null
	// (sweepWeak: O(slots) per collection, as Foreign.sweepPeers). A free slot holds
	// the index of the next free one, shifted left and tagged odd (an
	// object's address is even). Any thread takes, reads, writes and frees
	// them (under weakLock); the collecting thread sweeps them with the world
	// stopped. Nothing here is Objective-C's: its mode classes' @:hxmc.weak
	// fields of Haxe values hold one each (hxmc.ir.ObjC.IVAR_WEAK_GC).
	static var weakSlots:Ptr;
	static var nweak:Int; // (slot 0 made with the first, never taken)
	static var weakCap:Int;
	static var weakFreeHead:Int; // 0: none free
	static var weakLock:Ptr;

	// a slot holding o (null too)
	@:hxmc.export("rt_weak_new") static function weakNew(o:Dynamic):Int {
		lockLeaf(weakLock);
		var i = weakFreeHead;
		if (i != 0) {
			weakFreeHead = (Mem.getPtr(weakSlots, 8 * i).toI64() >> 1).toInt();
		} else {
			if (nweak == weakCap) {
				weakCap = weakCap == 0 ? 64 : weakCap * 2;
				weakSlots = LibC.realloc(weakSlots, (weakCap : I64) * 8);
			}
			if (nweak == 0) {
				Mem.setPtr(weakSlots, 0, Ptr.ofI64(1));
				nweak = 1;
			}
			i = nweak++;
		}
		Mem.setPtr(weakSlots, 8 * i, Mem.addr(o));
		unlockLeaf(weakLock);
		return i;
	}

	// the object slot i holds: null once it died (or a free slot's)
	@:hxmc.export("rt_weak_get") static function weakGet(i:Int):Dynamic {
		lockLeaf(weakLock);
		var p = i > 0 && i < nweak && Mem.getI32(weakSlots, 8 * i) & 1 == 0 ? Mem.getPtr(weakSlots, 8 * i) : Ptr.nil();
		unlockLeaf(weakLock);
		return Mem.obj(p);
	}

	// slot i (taken) holds o from now on
	@:hxmc.export("rt_weak_set") static function weakSet(i:Int, o:Dynamic):Void {
		lockLeaf(weakLock);
		if (i > 0 && i < nweak && Mem.getI32(weakSlots, 8 * i) & 1 == 0) Mem.setPtr(weakSlots, 8 * i, Mem.addr(o));
		unlockLeaf(weakLock);
	}

	// slot i given back
	@:hxmc.export("rt_weak_free") static function weakFree(i:Int):Void {
		lockLeaf(weakLock);
		if (i > 0 && i < nweak && Mem.getI32(weakSlots, 8 * i) & 1 == 0) {
			Mem.setPtr(weakSlots, 8 * i, Ptr.ofI64(((weakFreeHead : I64) << 1) | 1));
			weakFreeHead = i;
		}
		unlockLeaf(weakLock);
	}

	// after a collection of the nursery (and of [lo, hi) for a major one): the
	// slots' objects moved, or dead and the slots null
	@:hxmc.unsafe static function sweepWeak(lo:Ptr, hi:Ptr) {
		for (i in 1...nweak) {
			var o = Mem.getPtr(weakSlots, 8 * i);
			if (o.isNull() || Mem.getI32(weakSlots, 8 * i) & 1 != 0 || !(inYoung(o) || (lo.ult(o) && !hi.ult(o)))) continue;
			Mem.setPtr(weakSlots, 8 * i, isFwd(hdrW0(o)) ? fwdAddr(o) : Ptr.nil());
		}
	}

	// ---- Objective-C blocks (hxmc.ir.ObjC.blockOf): a Haxe function made a
	// block is a heap block (_Block_copy of one built in blockNew's frame)
	// whose capture is the index of an entry here: (closure, count) pairs,
	// the count the heap blocks referring to the entry. The block's copy
	// helper (blockCopy: _Block_copy calls it) adds one, its dispose helper
	// (blockDispose: libclosure calls it as it frees the block) takes one;
	// at zero the entry is free (a null closure, the next free index in the
	// count's word). An entry with a closure is a root (scanBlocks), from
	// blockNew on: the copy that counts it follows without a GC point. A
	// minor collection scans only the entries made since the last collection
	// (blockRecent): the others' closures are old, which only a major one moves.
	// The table is chunks of BLOCK_CHUNK entries that never move, so that an
	// invoke reads its closure without the lock (blockGet: it runs out of
	// any safe region, so no collection moves the closure meanwhile, and the
	// block it was called with keeps the entry). The helpers run on any
	// thread, in any state (in a safe region while the collector runs: it
	// takes the lock to scan), so the lock is taken with one thread too.
	static inline var BLOCK_CHUNK = 1024;
	static inline var BLOCK_CHUNKS = 4096;
	static inline var BLOCK_SIZE = 40; // Block_layout's 32 bytes, the index
	static inline var BLOCK_HAS_COPY_DISPOSE = 1 << 25;
	static inline var BLOCK_IS_GLOBAL = 1 << 28;
	static var blockChunks:Ptr; // BLOCK_CHUNKS chunks' addresses (null: none yet)
	static var nblocks:Int;
	static var blockFree:Int; // (-1 from init, as Foreign.peerFree)
	static var blocksLock:Ptr;
	static var blockRecent:Ptr; // the indices of the entries made since the last collection
	static var nrecent:Int;
	static var recentCap:Int;

	@:hxmc.unsafe static inline function blockEntry(i:Int):Ptr
		return Mem.getPtr(blockChunks, 8 * (i >> 10)).add(16 * (i & (BLOCK_CHUNK - 1)));

	// a heap block calling f through invoke (an entry of hxmc.ir.ObjC.invoke),
	// autoreleased: the descriptor of its signature (the C string sig) made
	// at the first block of it, in the program's word `cell`; flags as libclosure
	// has them (BLOCK_HAS_SIGNATURE, x86-64's BLOCK_USE_STRET); libclosure's
	// and libobjc's functions and the stack blocks' class come as addresses
	// (the runtime does not link either)
	@:hxmc.export("rt_objc_block_new") @:hxmc.unsafe static function blockNew(f:Dynamic, invoke:Ptr, cell:Ptr, sig:Ptr, flags:Int, stackIsa:Ptr, blockCopyFn:Ptr,
			autorelease:Ptr):Ptr {
		var p = Mem.addr(f);
		Os.lock(blocksLock);
		var d = Mem.getPtr(cell, 0);
		if (d.isNull()) {
			// (Block_descriptor: reserved, size, copy, dispose, signature, layout)
			d = LibC.malloc(48);
			Mem.setI64(d, 0, 0);
			Mem.setI64(d, 8, BLOCK_SIZE);
			Mem.setPtr(d, 16, Callback.addr(blockCopy));
			Mem.setPtr(d, 24, Callback.addr(blockDispose));
			Mem.setPtr(d, 32, sig);
			Mem.setI64(d, 40, 0);
			Mem.setPtr(cell, 0, d);
		}
		var i = blockFree;
		if (i >= 0) {
			blockFree = Mem.getI64(blockEntry(i), 8).toInt();
		} else {
			if (blockChunks.isNull()) {
				blockChunks = LibC.malloc(8 * BLOCK_CHUNKS);
				LibC.memset(blockChunks, 0, 8 * BLOCK_CHUNKS);
			}
			if (nblocks == BLOCK_CHUNK * BLOCK_CHUNKS) dieC(Mem.cstr("too many blocks made of Haxe functions alive\n"));
			if (nblocks & (BLOCK_CHUNK - 1) == 0) Mem.setPtr(blockChunks, 8 * (nblocks >> 10), LibC.malloc(16 * BLOCK_CHUNK));
			i = nblocks++;
		}
		var e = blockEntry(i);
		Mem.setPtr(e, 0, p);
		Mem.setI64(e, 8, 0);
		if (nrecent == recentCap) {
			recentCap = recentCap == 0 ? 64 : recentCap * 2;
			blockRecent = LibC.realloc(blockRecent, (recentCap : I64) * 4);
		}
		Mem.setI32(blockRecent, 4 * nrecent++, i);
		Os.unlock(blocksLock);
		// (the stack block: Block_layout, then the index)
		var b = Mem.stack(BLOCK_SIZE);
		Mem.setPtr(b, 0, stackIsa);
		Mem.setI32(b, 8, flags | BLOCK_HAS_COPY_DISPOSE);
		Mem.setI32(b, 12, 0);
		Mem.setPtr(b, 16, invoke);
		Mem.setPtr(b, 24, d);
		Mem.setI64(b, 32, (i : I64));
		return Ind.call1(autorelease, Ind.call1(blockCopyFn, b));
	}

	// a heap block made of block src (dst, its copy): one more referring to the
	// entry. Without the lock: only blockNew's stack block is ever copied
	// (_Block_copy of a heap block retains it), in blockNew, and nothing
	// else writes the entry before the block exists
	@:hxmc.callback @:hxmc.unsafe static function blockCopy(dst:Ptr, src:Ptr):Void {
		var e = blockEntry(Mem.getI64(src, BLOCK_SIZE - 8).toInt());
		Mem.setI64(e, 8, Mem.getI64(e, 8) + 1);
	}

	// heap block b freed: one less; none, the entry is free (its closure no root)
	@:hxmc.callback @:hxmc.unsafe static function blockDispose(b:Ptr):Void {
		var i = Mem.getI64(b, BLOCK_SIZE - 8).toInt();
		var e = blockEntry(i);
		Os.lock(blocksLock);
		var n = Mem.getI64(e, 8) - 1;
		if (n == 0) {
			Mem.setPtr(e, 0, Ptr.nil());
			Mem.setI64(e, 8, (blockFree : I64));
			blockFree = i;
		} else Mem.setI64(e, 8, n);
		Os.unlock(blocksLock);
	}

	// the closure of block b (made by blockNew; a global block of a closure
	// capturing nothing, in the data: its address, hxmc.ir.ObjC.GLOBAL_BLOCK),
	// for its invoke
	@:hxmc.export("rt_objc_block_get") static function blockGet(b:Ptr):Dynamic {
		var c = Mem.getPtr(b, BLOCK_SIZE - 8);
		return Mem.obj(Mem.getI32(b, 8) & BLOCK_IS_GLOBAL != 0 ? c : Mem.getPtr(blockEntry(c.toI64().toInt()), 0));
	}

	// the closure of block b when blockNew made it with this invoke (of the
	// closure's signature), else null: a block becoming a function again is
	// that function (hxmc.ir.ObjC.blockFunction)
	@:hxmc.export("rt_objc_block_fn") static function blockFn(b:Ptr, invoke:Ptr):Dynamic {
		if (Mem.getPtr(b, 16) != invoke) return null;
		if (Mem.getI32(b, 8) & BLOCK_IS_GLOBAL != 0) return blockGet(b);
		if (Mem.getI32(b, 8) & BLOCK_HAS_COPY_DISPOSE == 0) return null;
		var d = Mem.getPtr(b, 24);
		if (Mem.getPtr(d, 16) != Callback.addr(blockCopy) || Mem.getI64(d, 8) != (BLOCK_SIZE : I64)) return null;
		return blockGet(b);
	}

	// the entries' closures: roots (scanRoots); a minor collection's, the recent ones'
	@:hxmc.unsafe static function scanBlocks(root:Bool) {
		Os.lock(blocksLock);
		var n = major ? nblocks : nrecent;
		for (k in 0...n) {
			var e = blockEntry(major ? k : Mem.getI32(blockRecent, 4 * k));
			var o = Mem.getPtr(e, 0);
			if (!o.isNull()) Mem.setPtr(e, 0, fwdAs(o, root));
		}
		nrecent = 0;
		Os.unlock(blocksLock);
	}

	// ---- the copy: depth-first, an object's descendants are copied right
	// after it, close to the order in which the compiler then walks its
	// trees; Cheney's breadth-first scan scatters them. A major collection
	// copies in preorder; a minor one copies an object's young children
	// together right after it, then the first one's, and so on (drainMinor:
	// each object is scanned once, and the cache misses of the children's
	// headers overlap). RT_BFS=1 selects the breadth-first scan. The stack
	// holds (object, next slot) pairs.
	static var gcStack:Ptr;
	static var gcTop:Int;
	static var gcCap:Int;
	static var gcBfs:Bool;
	static var major:Bool; // which forwarding runs

	// ---- objects: the header at -8, its type index first (Types), which says
	// what the rest is (a record's slots, an array's words and length, a
	// string's hash and length) and how to scan; forwarded: T_FWD, the copy's
	// address in slot 0 (every object on the heap has one: an empty string or
	// NativeArray is the static one). Read through GcCore (hdrW0, isFwd,
	// fwdAddr, setFwd, wordsOf, nslotsOf, kindOf, objBytes, ptrmapOf,
	// isPtrSlot), which wasm/Gc.hx shares.

	// (an object's address is past its header: in (start, end] of the space it
	// is in, end itself for an object of no slots (a header constructor's,
	// GcCore.fwdLow) ending the space. The nursery's allocations end 8 bytes
	// short of youngEnd (youngTop), so its test, generated code's too, is
	// [start, end).)
	static inline function inYoung(p:Ptr):Bool
		return !p.ult(youngStart) && p.ult(youngEnd);

	static inline function inFrom(p:Ptr):Bool
		return fromStart.ult(p) && !fromEnd.ult(p);

	static inline function inOld(p:Ptr):Bool
		return oldStart.ult(p) && !oldPtr.ult(p);

	// where the nursery's allocations end: 8 bytes short of youngEnd where an
	// object may have no slots (its address its end: inYoung)
	static inline function youngTop():Ptr
		return fwdLow() ? youngEnd.add(-8) : youngEnd;

	static inline function region(i:Int):Ptr
		return i == 0 ? region0 : region1;

	static inline function lockLeaf(l:Ptr)
		if (Threads.mt != 0) Os.lock(l);

	static inline function unlockLeaf(l:Ptr)
		if (Threads.mt != 0) Os.unlock(l);

	// ---- forwarding: minor collections copy live nursery objects to the end
	// of the old space, major ones the nursery's and the from-space's

	// a young or from-space object's copy at the end of the old space, made
	// now unless it was already (its header then says so, slot 0 has the copy)
	@:hxmc.unsafe static function copyOut(p:Ptr):Ptr
		return copyIn(p);

	// (inline in the drain loops: no call per copied object)
	static inline function copyIn(p:Ptr):Ptr {
		var w0 = hdrW0(p);
		return if (isFwd(w0)) fwdAddr(p) else copyTo(p, wordsOf(p, w0));
	}

	// p (its payload's words: n) copied
	static inline function copyTo(p:Ptr, n:Int):Ptr {
		var words = n + 1;
		var dst = oldPtr, s = p.add(-8);
		#if hxmc.census
		if (census != 0 && !major) Census.countPromoted(Mem.getI64(s, 0), (words : I64) << 3);
		#end
		if (words <= 8) { // most objects: a few words, no call (unrolled)
			do {
				Mem.setI64(dst, 0, Mem.getI64(s, 0));
				if (words == 1) break;
				Mem.setI64(dst, 8, Mem.getI64(s, 8));
				if (words == 2) break;
				Mem.setI64(dst, 16, Mem.getI64(s, 16));
				if (words == 3) break;
				Mem.setI64(dst, 24, Mem.getI64(s, 24));
				if (words == 4) break;
				Mem.setI64(dst, 32, Mem.getI64(s, 32));
				if (words == 5) break;
				Mem.setI64(dst, 40, Mem.getI64(s, 40));
				if (words == 6) break;
				Mem.setI64(dst, 48, Mem.getI64(s, 48));
				if (words == 7) break;
				Mem.setI64(dst, 56, Mem.getI64(s, 56));
			} while (false);
		} else
			LibC.memcpy(dst, s, (words : I64) << 3);
		oldPtr = dst.add(words << 3);
		var n = dst.add(8);
		setFwd(p, n);
		return n;
	}

	static inline function minorForward(p:Ptr):Ptr
		return inYoung(p) ? copyOut(p) : p;

	static inline function majorForward(p:Ptr):Ptr
		return inYoung(p) || inFrom(p) ? copyOut(p) : p;

	static inline function fwd(p:Ptr):Ptr
		return major ? majorForward(p) : minorForward(p);

	// a root forwarded, then everything reachable from it that is still to
	// copy (depth-first), or forwarded alone (the breadth-first scan)
	@:hxmc.unsafe static function fwdAs(p:Ptr, root:Bool):Ptr
		return root ? fwdRoot(p) : fwd(p);

	// (few values live across the copies' calls: they stay in registers; one
	// loop per forwarding)
	@:hxmc.unsafe static function drain()
		if (major) drainMajor() else drainMinor();

	// a minor collection's: each object is scanned once, when popped, its
	// young children copied together right after it (their headers' cache
	// misses overlap) and pushed, the first one on top. No call in the loop
	// but the stack's growth, before the scan, and few values live across
	// the scan (the nursery's bounds and the stack are read where used): the
	// scan's values stay in registers (with one word of the pointer map:
	// objects of more than SMALL_SLOTS slots are scanned out of the loop,
	// LARGE_SLICE slots at a time, scanLarge, which also keeps the stack
	// small).
	@:hxmc.unsafe static function drainMinor() {
		while (gcTop > 0) {
			if (gcTop + 2 * SMALL_SLOTS + 1 > gcCap) reserve(gcTop + 2 * SMALL_SLOTS + 1);
			var top = gcTop - 1;
			var o = Mem.getPtr(gcStack, top << 4);
			var w0 = hdrW0(o);
			var n = wordsOf(o, w0);
			if (n > SMALL_SLOTS)
				scanLarge(o);
			else {
				// (gcTop: where its children go, until they are reversed)
				gcTop = top;
				pushed(scanYoung(o, w0, n, top));
			}
		}
	}

	static inline var SMALL_SLOTS = 32;

	// a large object on top of the stack: its next LARGE_SLICE slots (from
	// the entry's slot index), the entry left below the children they push
	// while slots remain
	@:hxmc.unsafe static function scanLarge(o:Ptr) {
		if (gcTop + LARGE_SLICE > gcCap) reserve(gcTop + LARGE_SLICE);
		var at = gcTop - 1;
		var e = gcStack.add(at << 4);
		var w0 = hdrW0(o);
		var n = wordsOf(o, w0);
		var k = Types.kindOfWord(w0);
		var pm = Ptr.nil();
		if (k == K_OBJ) {
			pm = ptrmapOf(o);
			if (pm.isNull()) {
				gcTop = at;
				return;
			}
		} else if (k != K_PARR) { // (raw: a root fwdRoot pushed)
			gcTop = at;
			return;
		}
		var from = Mem.getI32(e, 8);
		var to = from + LARGE_SLICE;
		if (to < n) {
			Mem.setI32(e, 8, to);
		} else {
			to = n;
			gcTop = at;
		}
		var top = gcTop;
		var i = from;
		if (pm.isNull()) {
			while (i < to) {
				top = minorSlot(o, i, top);
				i++;
			}
		} else
			while (i < to) {
				if ((Mem.getI32At(pm, 0, i >> 5) >>> (i & 31)) & 1 != 0) top = minorSlot(o, i, top);
				i++;
			}
		pushed(top);
	}

	static inline var LARGE_SLICE = 256;

	// o's young children copied (its header's first word w0, its words n),
	// pushed from gcStack[top] (which has room for all of them): the new top
	static inline function scanYoung(o:Ptr, w0:Int, n:Int, top:Int):Int {
		var t = top;
		var k = Types.kindOfWord(w0);
		if (k == K_OBJ) {
			var ti = w0 & 0xFFFF;
			if (ti == Types.T_ARRAY)
				t = minorSlotWith(o, 1, t, true); // (its storage: arrTrim)
			else {
				// (at most SMALL_SLOTS slots: one word of the map)
				var pm = ptrmapOfType(ti);
				var m = pm.isNull() ? 0 : Mem.getI32(pm, 0);
				var i = 0;
				while (m != 0) {
					if (m & 1 != 0) t = minorSlot(o, i, t);
					m = m >>> 1;
					i++;
				}
				if (compactAt(ti)) t = minorCompact(o, pm, n, t);
			}
		} else if (k == K_PARR) {
			var i = 0;
			while (i < n) {
				t = minorSlot(o, i, t);
				i++;
			}
		}
		return t;
	}

	// o's compressed references (pm: its type's pointer map, the compact map
	// after it) forwarded, as scanYoung's slots: the new top (a call, out of
	// the scan's loop: the copy inlined once more for the compact map's
	// words would cost every program's collections)
	@:hxmc.unsafe static function minorCompact(o:Ptr, pm:Ptr, n:Int, top:Int):Int {
		// (no slots: a header constructor's, its argument in the header, cmapHalf)
		if (n == 0) return minorSlotAny(o, -1, top, false, true);
		var t = minorHalves(o, cmapLo(pm), 0, top);
		return minorHalves(o, cmapHi(pm), 32, t);
	}

	// the compressed references of o in the map word m (of halves from h)
	static inline function minorHalves(o:Ptr, m:Int, h:Int, top:Int):Int {
		var t = top, i = h;
		while (m != 0) {
			if (m & 1 != 0) t = minorSlotAny(o, i, t, false, true);
			m = m >>> 1;
			i++;
		}
		return t;
	}

	// the children pushed from gcTop to top, reversed (pushed in slot order:
	// the first one goes on top)
	static inline function pushed(top:Int) {
		var a = gcTop, b = top - 1;
		gcTop = top;
		var stack = gcStack;
		while (a < b) {
			var x = Mem.getPtr(stack, a << 4);
			Mem.setPtr(stack, a << 4, Mem.getPtr(stack, b << 4));
			Mem.setPtr(stack, b << 4, x);
			a++;
			b--;
		}
	}

	// slot i of o (copied, or old) forwarded; a young object copied now is
	// pushed when it has references (at gcStack[top], which has room): the
	// new top
	static inline function minorSlot(o:Ptr, i:Int, top:Int):Int
		return minorSlotAny(o, i, top, false, false);

	// (arr: o is an Array, slot i its storage, copied as arrTrim says)
	static inline function minorSlotWith(o:Ptr, i:Int, top:Int, arr:Bool):Int
		return minorSlotAny(o, i, top, arr, false);

	// (c: i is the 4-byte half of a compressed reference)
	static inline function minorSlotAny(o:Ptr, i:Int, top:Int, arr:Bool, c:Bool):Int {
		var t = top;
		var v = getRefAt(o, i, c);
		if (!v.ult(youngStart) && v.ult(youngEnd)) {
			var vw0 = hdrW0(v);
			if (isFwd(vw0))
				setRefAt(o, i, c, fwdAddr(v));
			else {
				// (copyTo, without the call of memcpy)
				var words = wordsOf(v, vw0) + 1;
				var th:I64 = arr ? arrTrim(o, v, vw0) : (0 : I64);
				if (th.toInt() != 0) words = trimWords(th) + 1;
				var dst = oldPtr;
				#if hxmc.census
				if (census != 0) Census.countPromoted(Mem.getI64(v, -8), (words : I64) << 3);
				#end
				if (words <= 8) {
					do {
						Mem.setI64(dst, 0, Mem.getI64(v, -8));
						if (words == 1) break;
						Mem.setI64(dst, 8, Mem.getI64(v, 0));
						if (words == 2) break;
						Mem.setI64(dst, 16, Mem.getI64(v, 8));
						if (words == 3) break;
						Mem.setI64(dst, 24, Mem.getI64(v, 16));
						if (words == 4) break;
						Mem.setI64(dst, 32, Mem.getI64(v, 24));
						if (words == 5) break;
						Mem.setI64(dst, 40, Mem.getI64(v, 32));
						if (words == 6) break;
						Mem.setI64(dst, 48, Mem.getI64(v, 40));
						if (words == 7) break;
						Mem.setI64(dst, 56, Mem.getI64(v, 48));
					} while (false);
				} else {
					var j = 0;
					while (j < words) {
						Mem.setI64At(dst, 0, j, Mem.getI64At(v, -8, j));
						j++;
					}
				}
				if (th.toInt() != 0) Mem.setI64(dst, 0, th);
				oldPtr = dst.add(words << 3);
				var nv = dst.add(8);
				setFwd(v, nv);
				setRefAt(o, i, c, nv);
				if (!Types.isRawArray(vw0)) {
					Mem.setPtr(gcStack, t << 4, nv);
					Mem.setI32(gcStack, (t << 4) + 8, 0);
					t++;
				}
			}
		}
		return t;
	}

	// An Array's storage keeps room for the Array's length only once the
	// Array is copied with it (promoted, or by a major collection): its
	// growth by doubling leaves on average a quarter of it unused, which
	// would stay so (most arrays are done growing when they survive). The
	// storage's header as copied (its words and length, the capacity: the
	// Array's length, Boxes.roomFor), or 0: copied as it is (an empty Array,
	// one full already, storage of another kind (another thread's change of
	// the kind between its storage and its kind) or a long one's header).
	// Nothing else keeps an Array's storage across a GC point but the
	// runtime's checks that the storage did not change at an allocation
	// (Boxes.arrGrow): they find the copy; reading at most the length. The
	// elements past the length are zero, so the copy's are too.
	static inline function arrTrim(o:Ptr, v:Ptr, vw0:Int):I64 {
		var kind = Mem.getI32(o, 4);
		var len = Mem.getI32(o, 0);
		var cap = Mem.getI32(v, -4);
		var ncap = kind == Types.AK_BOOL ? (len + 7) & ~7 : kind == Types.AK_I32 ? (len + 1) & ~1 : len;
		return if (vw0 & 0xFFFF != Types.naType(kind) || len <= 0 || !Mem.ult(ncap, cap) || vw0 >>> 16 == 0xFFFF) (0 : I64) else {
			var nw = kind == Types.AK_BOOL ? ncap >> 3 : kind == Types.AK_I32 ? ncap >> 1 : ncap;
			Types.arrayHdr((vw0 & 0xFFFF) | (nw << 16), ncap);
		}
	}

	// the payload's words of arrTrim's header
	static inline function trimWords(th:I64):Int
		return (th.toInt() >>> 16) & 0xFFFF;

	// room for this many entries on the collector's stack
	@:hxmc.unsafe static function reserve(entries:Int) {
		while (gcCap < entries)
			gcCap *= 2;
		gcStack = LibC.realloc(gcStack, (gcCap : I64) * 16);
	}

	@:hxmc.unsafe static function drainMajor()
		drainWith(true);

	static inline function drainWith(maj:Bool) {
		while (gcTop > 0) {
			var o = Mem.getPtr(gcStack, (gcTop - 1) << 4);
			var w0 = hdrW0(o); // (never forwarded: copied just now)
			var k = Types.kindOfWord(w0);
			var pm = Ptr.nil();
			if (k != K_PARR) {
				if (k != K_OBJ) { // K_RAW: no references
					gcTop--;
					continue;
				}
				pm = ptrmapOf(o);
				if (pm.isNull()) {
					gcTop--;
					continue;
				}
			}
			var n = wordsOf(o, w0);
			var i = Mem.getI32(gcStack, ((gcTop - 1) << 4) + 8);
			var pushed = false;
			// (compressed references: the entries of the compact map after the
			// slots, n to 3n - 1, or n alone: cmapHalves, cmapHalf)
			var lim = !pm.isNull() && compactAt(w0 & 0xFFFF) ? n + cmapHalves(n) : n;
			while (i < lim) {
				var c = compactTypes() && i >= n;
				var j = c ? i - n : i;
				if (c ? !isCompactHalf(pm, j) : !pm.isNull() && (Mem.getI32At(pm, 0, i >> 5) >>> (i & 31)) & 1 == 0) {
					i++;
					continue;
				}
				if (c) j = cmapHalf(n, j);
				var v = getRefAt(o, j, c);
				i++;
				if (v.isNull()) continue;
				// (branches rather than inYoung(v) || inFrom(v): no booleans in registers)
				if (v.ult(youngStart) || !v.ult(youngEnd)) {
					if (!maj) continue;
					if (!fromStart.ult(v) || fromEnd.ult(v)) continue; // (inFrom)
				}
				var vw0 = hdrW0(v);
				if (isFwd(vw0)) {
					setRefAt(o, j, c, fwdAddr(v));
					continue;
				}
				// copied now: its subtree next (an Array's storage: arrTrim)
				var th:I64 = w0 & 0xFFFF == Types.T_ARRAY ? arrTrim(o, v, vw0) : (0 : I64);
				var nv = copyTo(v, th.toInt() != 0 ? trimWords(th) : wordsOf(v, vw0));
				if (th.toInt() != 0) Mem.setI64(nv, -8, th);
				setRefAt(o, j, c, nv);
				Mem.setI32(gcStack, ((gcTop - 1) << 4) + 8, i);
				push(nv);
				pushed = true;
				break;
			}
			if (!pushed) gcTop--;
		}
	}

	static inline function push(o:Ptr) {
		if (gcTop == gcCap) grow();
		var e = gcStack.add(gcTop << 4);
		Mem.setPtr(e, 0, o);
		Mem.setI32(e, 8, 0);
		gcTop++;
	}

	@:hxmc.unsafe static function grow() {
		gcCap *= 2;
		gcStack = LibC.realloc(gcStack, (gcCap : I64) * 16);
	}

	@:hxmc.unsafe static function fwdRoot(p:Ptr):Ptr {
		var before = oldPtr;
		var n = fwd(p);
		if (oldPtr != before) {
			push(n);
			drain();
		}
		return n;
	}

	@:hxmc.unsafe static function scanObject(o:Ptr, root:Bool) {
		var n = nslotsOf(o);
		switch kindOf(o) {
			case K_OBJ:
				var pm = ptrmapOf(o);
				if (pm.isNull()) return;
				var w = 0;
				while (w * 32 < n) {
					var m = Mem.getI32(pm, 4 * w);
					var i = w * 32;
					while (m != 0) {
						if (m & 1 != 0) {
							var v = Mem.getPtr(o, 8 * i);
							if (!v.isNull()) Mem.setPtr(o, 8 * i, fwdAs(v, root));
						}
						m = m >>> 1;
						i++;
					}
					w++;
				}
				if (compactAt(tindexOf(o)))
					for (j in 0...cmapHalves(n))
						if (isCompactHalf(pm, j)) {
							var h = cmapHalf(n, j);
							var v = getC(o, h);
							if (!v.isNull()) setC(o, h, fwdAs(v, root));
						}
			case K_PARR:
				for (i in 0...n) {
					var v = Mem.getPtr(o, 8 * i);
					if (!v.isNull()) Mem.setPtr(o, 8 * i, fwdAs(v, root));
				}
			case _:
		}
	}

	// the breadth-first scan of what was copied from `scan` on
	@:hxmc.unsafe static function scanFrom(scan:Ptr) {
		while (scan.ult(oldPtr)) {
			var o = scan.add(8);
			scan = scan.add(objBytes(o));
			scanObject(o, false);
		}
	}

	@:hxmc.unsafe static function scanStack(base:Ptr, top:Ptr, root:Bool) {
		var s = base;
		if (root) {
			while (s.ult(top)) {
				var v = Mem.getPtr(s, 0);
				if (!v.isNull()) Mem.setPtr(s, 0, fwdRoot(v));
				s = s.add(8);
			}
		} else
			while (s.ult(top)) {
				var v = Mem.getPtr(s, 0);
				if (!v.isNull()) Mem.setPtr(s, 0, fwd(v));
				s = s.add(8);
			}
	}

	// the collector's own thread first (its stack), then the others' (their
	// entry closures, Tls values, stacks and current exceptions), the
	// globals, the collector's current exception, the finalisers
	@:hxmc.unsafe static function scanRoots(root:Bool) {
		var me = Threads.self;
		scanStack(me.value.base, me.value.sp, root);
		var t = Threads.allThreads;
		while (!t.isNull()) {
			if (!t.value.job.isNull()) t.value.job = fwdAs(t.value.job, root);
			if (!t.value.tls.isNull()) t.value.tls = fwdAs(t.value.tls, root);
			if (t != me && t.value.started != 0) {
				scanStack(t.value.base, t.value.sp, root);
				if (!t.value.exn.isNull()) t.value.exn = fwdAs(t.value.exn, root);
			}
			t = t.value.next;
		}
		for (i in 0...nglobals) {
			var v = Mem.getPtr(globals, 8 * i);
			if (!v.isNull()) Mem.setPtr(globals, 8 * i, fwdAs(v, root));
		}
		if (!me.value.exn.isNull()) me.value.exn = fwdAs(me.value.exn, root);
		for (i in 0...nfinals)
			Mem.setPtr(finals, 16 * i, fwdAs(Mem.getPtr(finals, 16 * i), root));
		for (i in finalQhead...finalQlen) {
			Mem.setPtr(finalQueue, 16 * i, fwdAs(Mem.getPtr(finalQueue, 16 * i), root));
			Mem.setPtr(finalQueue, 16 * i + 8, fwdAs(Mem.getPtr(finalQueue, 16 * i + 8), root));
		}
		if (Foreign.npeers > 0) Foreign.scan(root);
		if (nblocks > 0 && (major || nrecent > 0)) scanBlocks(root);
	}

	// ---- remembered sets: every started thread's, and the ended threads'

	@:hxmc.unsafe static function forgetObjs(m:Ptr<Mutator>) {
		m.value.robjsLen = 0;
		LibC.memset(m.value.recent, 0, 8 * 256);
	}

	@:hxmc.unsafe static function forwardRemembered(m:Ptr<Mutator>, root:Bool) {
		var rem = m.value.rem;
		for (i in 0...m.value.remLen) {
			var s = Mem.getPtr(rem, 8 * i);
			if (compactTypes() && s.toI64().toInt() & 1 != 0) { // (a compressed reference's 4 bytes, tagged: remember)
				s = s.add(-1);
				var v = getC(s, 0);
				if (!v.isNull()) setC(s, 0, fwdAs(v, root));
				continue;
			}
			var v = Mem.getPtr(s, 0);
			if (!v.isNull()) Mem.setPtr(s, 0, fwdAs(v, root));
		}
		m.value.remLen = 0;
		for (i in 0...m.value.robjsLen)
			scanObject(Mem.getPtr(m.value.robjs, 8 * i), root);
		forgetObjs(m);
	}

	@:hxmc.unsafe static function forwardAllRemembered(root:Bool) {
		var t = Threads.allThreads;
		while (!t.isNull()) {
			if (t.value.started != 0) forwardRemembered(t, root);
			t = t.value.next;
		}
		forwardRemembered(Threads.deadMut, root);
	}

	@:hxmc.unsafe static function clearAllRemembered() {
		var t = Threads.allThreads;
		while (!t.isNull()) {
			if (t.value.started != 0) {
				t.value.remLen = 0;
				forgetObjs(t);
			}
			t = t.value.next;
		}
		Threads.deadMut.value.remLen = 0;
		forgetObjs(Threads.deadMut);
	}

	// ---- native handles: (object, resource, free function, aux) entries

	static inline var NATIVE_BYTES = 32;

	// a T_NATIVE object holding the C resource p (slot 0) and nrefs reference
	// slots after it (slots 1..nrefs, null at first, set through the write
	// barrier: what the C resource points into stays alive while the handle
	// does; the object is then K_PARR, and slot 0, outside the heap, is left
	// alone by the collector); freeFn(p) (a no-GC @:hxmc.callback or a C
	// function) frees p once it is unreachable
	@:hxmc.host("rt_native_new_refs") static function nativeNew(p:Ptr, freeFn:Ptr, nrefs:Int):Dynamic {
		var o:Dynamic = nrefs > 0 ? Mem.alloc(1 + nrefs, T_NATIVE_REFS, K_PARR) : Mem.alloc(1, T_NATIVE, K_RAW);
		nativeRegister(o, p, freeFn, 0);
		return o;
	}

	// a T_NATIVE object holding the foreign reference p (Foreign.box), and
	// tag in a second slot (the only native handles of two: Foreign.isBox):
	// freeFn a function, or a kind (below Foreign.MAX_KINDS) whose releases
	// are put off, aux the thread that made it (Foreign.nativeFree)
	static function nativeNewBox(p:Ptr, freeFn:Ptr, aux:Int, tag:I64):Dynamic {
		var o:Dynamic = Mem.alloc(2, T_NATIVE, K_RAW);
		Mem.setI64(Mem.addr(o), 8, tag);
		nativeRegister(o, p, freeFn, aux);
		return o;
	}

	@:hxmc.unsafe static function nativeRegister(o:Dynamic, p:Ptr, freeFn:Ptr, aux:Int) {
		Mem.setPtr(Mem.addr(o), 0, p);
		lockLeaf(nativesLock);
		if (nnatives == nativesCap) {
			nativesCap = nativesCap == 0 ? 256 : nativesCap * 2;
			natives = LibC.realloc(natives, (nativesCap : I64) * NATIVE_BYTES);
		}
		var e = natives.add(NATIVE_BYTES * nnatives);
		Mem.setPtr(e, 0, Mem.addr(o));
		Mem.setPtr(e, 8, p);
		Mem.setPtr(e, 16, freeFn);
		Mem.setI64(e, 24, (aux : I64));
		nnatives++;
		unlockLeaf(nativesLock);
	}

	// after a collection of the nursery (and of [lo, hi) for a major one). The
	// handles found dead together are freed newest first: a resource that
	// points into another one (an SSL context into its configuration) is
	// usually created after it.
	@:hxmc.unsafe static function sweepNatives(lo:Ptr, hi:Ptr) {
		var live = 0, ndead = 0;
		for (i in 0...nnatives) {
			var e = natives.add(NATIVE_BYTES * i);
			var o = Mem.getPtr(e, 0);
			if (inYoung(o) || (lo.ult(o) && !hi.ult(o))) {
				if (!isFwd(hdrW0(o))) {
					if (ndead == deadCap) {
						deadCap = deadCap == 0 ? 64 : deadCap * 2;
						deadNatives = LibC.realloc(deadNatives, (deadCap : I64) * NATIVE_BYTES);
					}
					LibC.memcpy(deadNatives.add(NATIVE_BYTES * ndead), e, NATIVE_BYTES);
					ndead++;
					continue;
				}
				o = fwdAddr(o);
			}
			var d = natives.add(NATIVE_BYTES * live);
			if (d != e) LibC.memcpy(d, e, NATIVE_BYTES);
			Mem.setPtr(d, 0, o);
			live++;
		}
		nnatives = live;
		while (ndead > 0) {
			ndead--;
			var e = deadNatives.add(NATIVE_BYTES * ndead);
			var f = Mem.getPtr(e, 16);
			if (f.ult(Ptr.ofI64(Foreign.MAX_KINDS))) Foreign.nativeFree(f.toI64().toInt(), Mem.getPtr(e, 8), Mem.getI64(e, 24).toInt());
			else Ind.call1(f, Mem.getPtr(e, 8));
		}
	}

	// the native handles, then the foreign objects (Foreign.sweep), inside the
	// batches of the kinds that release with the world stopped
	@:hxmc.unsafe static function sweepNativesForeign(lo:Ptr, hi:Ptr) {
		var batch = Foreign.nkinds > 1 && (Foreign.any() || nnatives > 0);
		if (batch) Foreign.sweepsBegin();
		sweepNatives(lo, hi);
		if (Foreign.any()) Foreign.sweep(lo, hi);
		if (batch) Foreign.sweepsEnd();
	}

	// ---- collections

	@:hxmc.unsafe static function minor() {
		var t0 = stats ? Os.now() : 0.0;
		var m0 = majors;
		minorCollect();
		if (majors == m0) {
			if (nweak > 0) sweepWeak(Ptr.nil(), Ptr.nil());
			sweepNativesForeign(Ptr.nil(), Ptr.nil());
		}
		if (stats && majors == m0) minorSecs += Os.now() - t0;
	}

	@:hxmc.unsafe static function minorCollect() {
		var youngUsed = youngNext.diff(youngStart);
		var par = parReady(youngUsed);
		// (in parallel, the PLABs' rest: a 32nd of what they hold at most, and a PLAB per thread)
		var room = par ? youngUsed + youngUsed / 32 + (parThreads : I64) * PLAB_BYTES : youngUsed;
		if (oldEnd.diff(oldPtr) < room + 64 || (Foreign.budget > 0 && Foreign.promoted >= Foreign.budget)) {
			majorAndTime(0);
			return;
		}
		minors++;
		collections++;
		var scan = oldPtr;
		major = false;
		if (par) {
			var r0 = stats ? Os.now() : 0.0;
			scanRoots(false);
			for (i in 0...nfinals)
				Mem.setPtr(finals, 16 * i + 8, minorForward(Mem.getPtr(finals, 16 * i + 8)));
			var r1 = stats ? Os.now() : 0.0;
			#if hxmc.gc_prefault
			if (pfState > 0) {
				Os.lock(pfLock);
				parPopTo = pfDoneTo.ult(oldPtr) ? oldPtr : pfDoneTo;
				Os.unlock(pfLock);
			} else if (pfState == 0)
				parPopTo = oldEnd; // (not started: small heaps fault in as they go)
			#end
			parMinor(scan);
			clearAllRemembered();
			if (stats) {
				parRootSecs += r1 - r0;
				parCopySecs += Os.now() - r1;
				parRootBytes += parRootsEnd.diff(scan);
			}
			return;
		}
		if (!gcBfs) {
			scanRoots(true);
			for (i in 0...nfinals)
				Mem.setPtr(finals, 16 * i + 8, fwdRoot(Mem.getPtr(finals, 16 * i + 8)));
			forwardAllRemembered(true);
			return;
		}
		scanRoots(false);
		for (i in 0...nfinals)
			Mem.setPtr(finals, 16 * i + 8, minorForward(Mem.getPtr(finals, 16 * i + 8)));
		forwardAllRemembered(false);
		scanFrom(scan);
	}

	// ---- parallel collections (RT_GC_THREADS: the threads that copy,
	// the collecting one included; by default as many as the processors, at
	// most PAR_MAX; 1: none). Linux x86-64, with threads, and a nursery that
	// held at least PAR_MIN_YOUNG. The collecting thread forwards the roots
	// alone, without scanning what they reach (copied, they are [scan, oldPtr)
	// after it); then every copying thread scans, depth-first on its own stack
	// as drainMinor does: the roots' copies, ROOT_BATCH at a time, then what
	// it copies itself, into its own chunk of the old space (a PLAB of
	// PLAB_BYTES, taken from its end with an atomic addition; an object of
	// more than PLAB_DIRECT bytes straight at the end). Two threads that reach
	// the same young object race for it with a compare-and-swap of its
	// header's first word: the winner sets T_BUSY, copies it, then T_FWD; the
	// other waits for T_FWD. A thread with entries to spare gives half of its
	// stack (its oldest entries: the largest subtrees) to a shared pool while
	// another one is idle; the copying is over when all of them are idle with
	// nothing left to take. What a PLAB has left is filled with a raw object
	// (the old space stays parsable).
	//
	// Major collections copy the same way (parMajorCopy, parSlot's maj):
	// the nursery's and the from-space's objects, into the other region,
	// from the roots alone (no remembered sets); the finalisers' values,
	// weak slots, native handles and foreign peers are then handled as by a
	// serial one. Threads that fault in fresh pages together wait for each
	// other in the kernel (8 threads: 2.6 GB in 0.93 s, one: 0.28 s), so the
	// collecting thread first faults in what the copy is expected to fill
	// (Os.populate: what was collected, times the last major collection's
	// survival plus an eighth); the pages past the new limit go back after
	// it. With the prefaulter (-D hxmc.gc-prefault), past what it expects
	// the copying threads fault in one at a time, as in a minor collection
	// (parPopulate), so it expects no more than the last major collection's
	// survival, and half before the first (SURVIVAL_FIRST), where it
	// expected all of it: the first major collection of the native
	// self-build found 348 MB live of 800 MB collected and faulted in 826 MB
	// next to the from-space and the nursery, its peak (1.74 GB, 1.45 GB
	// with half; 1.82 GB and 1.40 GB in one thread, where the end of the
	// build is the peak then). Serial when the copy, with what its PLABs may
	// leave, might not fit in the region.
	static inline var T_BUSY = 0xFFFE;
	static inline var PAR_MAX = 8;
	static inline var PAR_MIN_YOUNG = 1 << 20;
	static inline var PLAB_BYTES = 32 << 10;
	static inline var PLAB_DIRECT = 1 << 10;
	static inline var ROOT_BATCH = 64;
	static inline var SHARE_MIN = 16;
	static var parThreads:Int; // RT_GC_THREADS (0: not read yet)
	static var parHelpers:Int; // the helper threads started (they wait for parGen to change)
	static var parLock:Ptr;
	static var parCond:Ptr;
	static var parDoneCond:Ptr;
	static var parGen:Int;
	static var parDone:Int; // the helpers through with this collection
	static var parN:Int; // the threads copying in it
	@:hxmc.export("hxmc_par_idle") static var parIdle:Int; // out of work (read without the lock)
	@:hxmc.export("hxmc_par_end") static var parEnd:Int;
	@:hxmc.export("hxmc_par_pool_len") static var parPoolLen:Int;
	static var parPool:Ptr; // entries given away (as gcStack's: an object and a slot index)
	static var parPoolCap:Int;
	static var parCursor:Ptr; // the roots' copies not taken yet: [parCursor, parRootsEnd)
	static var parRootsEnd:Ptr;
	// the remembered sets, taken REM_BATCH slots or ROBJS_BATCH objects at a
	// time: of parMuts[parMut] (the started threads', then the ended ones'),
	// its slots from parOff (parInObjs false), then its objects
	static var parMuts:Ptr;
	static var parMutsLen:Int;
	static var parMutsCap:Int;
	static var parMut:Int;
	static var parOff:Int;
	static var parInObjs:Bool;
	static inline var REM_BATCH = 1024;
	static inline var ROBJS_BATCH = 64;
	@:hxmc.threadLocal static var pRem:Ptr; // remembered slots taken (pRemLen of them), not forwarded yet
	@:hxmc.threadLocal static var pRemLen:Int;
	static var parMajor:Bool; // the copying is a major collection's (parMajorCopy)
	static var parMajors:Int; // RT_STATS: the major collections that copied in parallel
	// the share of what the last major collection collected that it found
	// live, in 1024ths (1024 before the first), and the end of the pages
	// the last parallel one faulted in
	static var survival:Int;
	static inline var SURVIVAL_FIRST = 512;
	static var popEnd:Ptr;
	static var parPopSecs:Float; // RT_STATS: their faulting in of the to-space
	static var parCopies:Int; // RT_STATS: the parallel collections, their phases' seconds, the roots' copies' bytes
	static var parRootSecs:Float;
	static var parCopySecs:Float;
	static var parRootBytes:I64;
	@:hxmc.threadLocal static var pStack:Ptr;
	@:hxmc.threadLocal static var pTop:Int;
	@:hxmc.threadLocal static var pCap:Int;
	@:hxmc.threadLocal static var pPlab:Ptr;
	@:hxmc.threadLocal static var pPlabEnd:Ptr;

	// whether this minor collection copies in parallel (the helpers started
	// with the first one that does)
	@:hxmc.unsafe static function parReady(youngUsed:I64):Bool {
		#if (hxmc.shared || hxmc.dev_host || hxmc.census)
		return false;
		#else
		if (parThreads == 0) {
			var n = Os.envInt("RT_GC_THREADS", 0);
			if (n <= 0) {
				n = Os.cpus();
				if (n > PAR_MAX) n = PAR_MAX;
			}
			parThreads = n < 1 || Mem.os() != 0 || Mem.arm() ? 1 : n;
		}
		if (parThreads < 2 || Threads.mt == 0 || gcBfs || youngUsed < (PAR_MIN_YOUNG : I64)) return false;
		if (parHelpers == 0) {
			parLock = LibC.malloc(Os.MUTEX_BYTES);
			Os.mutexInit(parLock);
			parCond = LibC.malloc(Os.COND_BYTES);
			Os.condInit(parCond, false);
			parDoneCond = LibC.malloc(Os.COND_BYTES);
			Os.condInit(parDoneCond, false);
			parPoolCap = 1024;
			parPool = LibC.malloc((parPoolCap : I64) * 16);
			var i = 1;
			while (i < parThreads && Os.spawn(Callback.addr(parHelper), Ptr.nil(), 256 << 10)) {
				parHelpers++;
				i++;
			}
			if (parHelpers == 0) {
				parThreads = 1;
				return false;
			}
		}
		return true;
		#end
	}

	// the copying of a minor collection whose roots' copies start at scan
	@:hxmc.unsafe static function parMinor(scan:Ptr) {
		parCopies++;
		parMutsLen = 0;
		var t = Threads.allThreads;
		while (!t.isNull()) {
			if (t.value.started != 0) parAddMut(t);
			t = t.value.next;
		}
		parAddMut(Threads.deadMut);
		parMajor = false;
		parRun(scan);
	}

	// the copying of a major collection whose roots' copies start at scan (no
	// remembered sets: a major collection traces from the roots alone)
	@:hxmc.unsafe static function parMajorCopy(scan:Ptr) {
		parMajors++;
		parMutsLen = 0;
		parMajor = true;
		parRun(scan);
		parMajor = false;
	}

	@:hxmc.unsafe static function parRun(scan:Ptr) {
		parCursor = scan;
		parRootsEnd = oldPtr;
		parMut = 0;
		parOff = 0;
		parInObjs = false;
		parN = parHelpers + 1;
		parIdle = 0;
		parEnd = 0;
		parPoolLen = 0;
		Os.lock(parLock);
		parDone = 0;
		parGen++;
		Os.broadcast(parCond);
		Os.unlock(parLock);
		parWork();
		Os.lock(parLock);
		while (parDone < parHelpers)
			Os.condWait(parDoneCond, parLock);
		Os.unlock(parLock);
	}

	@:hxmc.callback @:hxmc.unsafe static function parHelper(arg:Ptr):Ptr {
		var gen = 0;
		Os.lock(parLock);
		while (true) {
			while (parGen == gen)
				Os.condWait(parCond, parLock);
			gen = parGen;
			Os.unlock(parLock);
			parWork();
			Os.lock(parLock);
			parDone++;
			if (parDone == parHelpers) Os.signal(parDoneCond);
		}
		return Ptr.nil();
	}

	@:hxmc.unsafe static function parAddMut(m:Ptr<Mutator>) {
		if (parMutsLen == parMutsCap) {
			parMutsCap = parMutsCap == 0 ? 16 : parMutsCap * 2;
			parMuts = LibC.realloc(parMuts, (parMutsCap : I64) * 8);
		}
		Mem.setPtr(parMuts, 8 * parMutsLen, m);
		parMutsLen++;
	}

	// remembered slots forwarded (their copies pushed)
	@:hxmc.unsafe static function parRemembered(a:Ptr, n:Int) {
		parReserve(pTop + n);
		var t = pTop;
		var j = 0;
		while (j < n) {
			var s = Mem.getPtr(a, 8 * j);
			// (a compressed reference's 4 bytes, tagged: remember)
			t = compactTypes() && s.toI64().toInt() & 1 != 0 ? parSlotAny(s.add(-1), 0, t, false, false, true) : parSlot(s, 0, t, false);
			j++;
		}
		pTop = t;
	}

	// one thread's part of the copying
	@:hxmc.unsafe static function parWork() {
		if (pStack.isNull()) {
			pCap = 4096;
			pStack = LibC.malloc((pCap : I64) * 16);
		}
		pTop = 0;
		pPlab = Ptr.nil();
		pPlabEnd = Ptr.nil();
		pRemLen = 0;
		do {
			if (pRemLen > 0) {
				parRemembered(pRem, pRemLen);
				pRemLen = 0;
			}
			parDrain();
		} while (parTake());
		parFill(pPlab, pPlabEnd);
		pPlab = Ptr.nil();
		pPlabEnd = Ptr.nil();
	}

	// entries taken from the pool or the roots' copies onto the empty stack;
	// false: the copying is over
	@:hxmc.unsafe static function parTake():Bool {
		Os.lock(parLock);
		while (true) {
			if (parPoolLen > 0) {
				var k = (parPoolLen + 1) >> 1;
				if (k > 256) k = 256;
				parReserve(k);
				parPoolLen -= k;
				LibC.memcpy(pStack, parPool.add(parPoolLen << 4), (k : I64) * 16);
				pTop = k;
				Os.unlock(parLock);
				return true;
			}
			if (parMut < parMutsLen) {
				var m:Ptr<Mutator> = Mem.getPtr(parMuts, 8 * parMut);
				if (!parInObjs) {
					var n = m.value.remLen - parOff;
					if (n > REM_BATCH) n = REM_BATCH;
					if (n > 0) {
						pRem = m.value.rem.add(8 * parOff);
						pRemLen = n;
						parOff += n;
						Os.unlock(parLock);
						return true;
					}
					parInObjs = true;
					parOff = 0;
				}
				var n = m.value.robjsLen - parOff;
				if (n > ROBJS_BATCH) n = ROBJS_BATCH;
				if (n > 0) {
					parReserve(n);
					var t = 0;
					var j = 0;
					while (j < n) {
						var o = Mem.getPtr(m.value.robjs, 8 * (parOff + j));
						if (kindOf(o) != K_RAW) {
							Mem.setPtr(pStack, t << 4, o);
							Mem.setI32(pStack, (t << 4) + 8, 0);
							t++;
						}
						j++;
					}
					parOff += n;
					pTop = t;
					Os.unlock(parLock);
					return true;
				}
				parMut++;
				parOff = 0;
				parInObjs = false;
				continue;
			}
			if (parCursor.ult(parRootsEnd)) {
				parReserve(ROOT_BATCH);
				var c = parCursor;
				var t = 0;
				var i = 0;
				while (i < ROOT_BATCH && c.ult(parRootsEnd)) {
					var o = c.add(8);
					c = c.add(objBytes(o));
					if (kindOf(o) != K_RAW) {
						Mem.setPtr(pStack, t << 4, o);
						Mem.setI32(pStack, (t << 4) + 8, 0);
						t++;
					}
					i++;
				}
				parCursor = c;
				pTop = t;
				Os.unlock(parLock);
				return true;
			}
			if (parEnd != 0) {
				Os.unlock(parLock);
				return false;
			}
			parIdle++;
			if (parIdle == parN) {
				Atomic.store32(Mem.sym("hxmc_par_end"), 1);
				Os.unlock(parLock);
				return false;
			}
			Os.unlock(parLock);
			while (Atomic.load32(Mem.sym("hxmc_par_pool_len")) == 0 && Atomic.load32(Mem.sym("hxmc_par_end")) == 0) {}
			Os.lock(parLock);
			parIdle--;
		}
		return false;
	}

	// the oldest half of the stack given to the pool
	@:hxmc.unsafe static function parShare() {
		var k = pTop >> 1;
		Os.lock(parLock);
		if (parPoolLen + k > parPoolCap) {
			while (parPoolLen + k > parPoolCap)
				parPoolCap *= 2;
			parPool = LibC.realloc(parPool, (parPoolCap : I64) * 16);
		}
		LibC.memcpy(parPool.add(parPoolLen << 4), pStack, (k : I64) * 16);
		Atomic.store32(Mem.sym("hxmc_par_pool_len"), parPoolLen + k);
		Os.unlock(parLock);
		LibC.memmove(pStack, pStack.add(k << 4), ((pTop - k) : I64) * 16);
		pTop -= k;
	}

	@:hxmc.unsafe static function parReserve(entries:Int) {
		if (entries <= pCap) return;
		while (pCap < entries)
			pCap *= 2;
		pStack = LibC.realloc(pStack, (pCap : I64) * 16);
	}

	// [a, b) as one raw object
	@:hxmc.unsafe static function parFill(a:Ptr, b:Ptr) {
		if (a.isNull() || !a.ult(b)) return;
		var words = b.diff(a).toInt() >> 3;
		Mem.setI32(a, 0, Types.T_BYTES | ((words - 1) << 16));
		Mem.setI32(a, 4, 0);
	}

	// room for an object of `bytes` (with its header) in the old space: a new
	// PLAB (the rest of the last one filled), or for a large one its own
	@:hxmc.unsafe static function parAlloc(bytes:Int):Ptr {
		if (bytes > PLAB_DIRECT) {
			var d = Ptr.ofI64(Atomic.add64(Mem.sym("hxmc_old_ptr"), (bytes : I64)));
			#if hxmc.gc_prefault
			parPopulate(d.add(bytes));
			#end
			return d;
		}
		parFill(pPlab, pPlabEnd);
		var p = Ptr.ofI64(Atomic.add64(Mem.sym("hxmc_old_ptr"), (PLAB_BYTES : I64)));
		#if hxmc.gc_prefault
		parPopulate(p.add(PLAB_BYTES));
		#end
		// (zeroed by rep stosb, which writes whole lines without reading them:
		// the copies then write to the cache, not read each line from memory first)
		Mem.zero(p, PLAB_BYTES);
		pPlab = p.add(bytes);
		pPlabEnd = p.add(PLAB_BYTES);
		return p;
	}

	#if hxmc.gc_prefault
	// the old space up to `end` faulted in before a copying thread writes
	// it: past what the prefaulter did (parPopTo), one thread at a time faults
	// in the next PF_CATCHUP with Os.populate while the others wait (threads
	// that fault in the same huge page together wait for each other in the
	// kernel: t3code-server without the prefaulter, 2.7 GB promoted, 1.1 s
	// more copying)
	static inline var PF_CATCHUP = 4 << 20;
	@:hxmc.export("hxmc_par_pop_to") static var parPopTo:Ptr;
	@:hxmc.export("hxmc_par_pop_busy") static var parPopBusy:Int;
	static var parPopBytes:I64; // RT_STATS: what the copying threads faulted in

	@:hxmc.unsafe static function parPopulate(end:Ptr) {
		if (pfState < 0) return;
		while (Ptr.ofI64(Atomic.load64(Mem.sym("hxmc_par_pop_to"))).ult(end)) {
			if (Atomic.cas32(Mem.sym("hxmc_par_pop_busy"), 0, 1) == 0) {
				var a = parPopTo;
				if (a.ult(end)) {
					var x = end.toI64() + (PF_CATCHUP - 1);
					var b = Ptr.ofI64(x - (x & ((HUGE_PAGE : I64) - 1)));
					if (oldEnd.ult(b)) b = oldEnd;
					if (b.ult(end)) b = end; // (never short of it: the loop ends)
					var y = a.toI64();
					var a4 = Ptr.ofI64(y - (y & 4095));
					Os.populate(a4, b.diff(a4));
					parPopBytes += b.diff(a);
					Atomic.store64(Mem.sym("hxmc_par_pop_to"), b.toI64());
				}
				Atomic.store32(Mem.sym("hxmc_par_pop_busy"), 0);
			}
		}
	}
	#end

	// the copy of v, a young object another thread is copying or copied
	@:hxmc.unsafe static function parWaitFwd(v:Ptr):Ptr {
		while (!isFwd(Atomic.load32(v.add(-8)))) {}
		return fwdAddr(v);
	}

	// drainMinor's loop on this thread's stack (a major collection's: the
	// from-space's objects copied too)
	@:hxmc.unsafe static function parDrain()
		if (parMajor) parDrainMajor() else parDrainMinor();

	@:hxmc.unsafe static function parDrainMinor()
		parDrainWith(false);

	@:hxmc.unsafe static function parDrainMajor()
		parDrainWith(true);

	static inline function parDrainWith(maj:Bool) {
		while (pTop > 0) {
			if (pTop > SHARE_MIN && Atomic.load32(Mem.sym("hxmc_par_idle")) > 0) parShare();
			if (pTop + 2 * SMALL_SLOTS + 1 > pCap) parReserve(pTop + 2 * SMALL_SLOTS + 1);
			var top = pTop - 1;
			var o = Mem.getPtr(pStack, top << 4);
			var w0 = hdrW0(o);
			var n = wordsOf(o, w0);
			if (n > SMALL_SLOTS) {
				if (maj) parScanLargeMajor(o) else parScanLarge(o);
			} else {
				pTop = top;
				parPushed(parScanYoung(o, w0, n, top, maj));
			}
		}
	}

	// scanLarge's
	@:hxmc.unsafe static function parScanLarge(o:Ptr)
		parScanLargeWith(o, false);

	@:hxmc.unsafe static function parScanLargeMajor(o:Ptr)
		parScanLargeWith(o, true);

	static inline function parScanLargeWith(o:Ptr, maj:Bool) {
		parReserve(pTop + LARGE_SLICE);
		var at = pTop - 1;
		var e = pStack.add(at << 4);
		var w0 = hdrW0(o);
		var n = wordsOf(o, w0);
		var k = Types.kindOfWord(w0);
		var pm = Ptr.nil();
		if (k == K_OBJ) pm = ptrmapOf(o);
		if ((k == K_OBJ && pm.isNull()) || (k != K_OBJ && k != K_PARR))
			pTop = at; // (no references)
		else {
			var from = Mem.getI32(e, 8);
			var to = from + LARGE_SLICE;
			if (to < n) {
				Mem.setI32(e, 8, to);
			} else {
				to = n;
				pTop = at;
			}
			var top = pTop;
			var i = from;
			if (pm.isNull()) {
				while (i < to) {
					top = parSlot(o, i, top, maj);
					i++;
				}
			} else
				while (i < to) {
					if ((Mem.getI32At(pm, 0, i >> 5) >>> (i & 31)) & 1 != 0) top = parSlot(o, i, top, maj);
					i++;
				}
			parPushed(top);
		}
	}

	static inline function parScanYoung(o:Ptr, w0:Int, n:Int, top:Int, maj:Bool):Int {
		var t = top;
		var k = Types.kindOfWord(w0);
		if (k == K_OBJ) {
			var ti = w0 & 0xFFFF;
			if (ti == Types.T_ARRAY)
				t = parSlotWith(o, 1, t, maj, true); // (its storage: arrTrim)
			else {
				var pm = ptrmapOfType(ti);
				var m = pm.isNull() ? 0 : Mem.getI32(pm, 0);
				var i = 0;
				while (m != 0) {
					if (m & 1 != 0) t = parSlot(o, i, t, maj);
					m = m >>> 1;
					i++;
				}
				if (compactAt(ti)) t = maj ? parCompactMajor(o, pm, n, t) : parCompactMinor(o, pm, n, t);
			}
		} else if (k == K_PARR) {
			var i = 0;
			while (i < n) {
				t = parSlot(o, i, t, maj);
				i++;
			}
		}
		return t;
	}

	// minorCompact's
	@:hxmc.unsafe static function parCompactMinor(o:Ptr, pm:Ptr, n:Int, top:Int):Int {
		if (n == 0) return parSlotAny(o, -1, top, false, false, true);
		var t = parHalves(o, cmapLo(pm), 0, top, false);
		return parHalves(o, cmapHi(pm), 32, t, false);
	}

	@:hxmc.unsafe static function parCompactMajor(o:Ptr, pm:Ptr, n:Int, top:Int):Int {
		if (n == 0) return parSlotAny(o, -1, top, true, false, true);
		var t = parHalves(o, cmapLo(pm), 0, top, true);
		return parHalves(o, cmapHi(pm), 32, t, true);
	}

	// minorHalves'
	static inline function parHalves(o:Ptr, m:Int, h:Int, top:Int, maj:Bool):Int {
		var t = top, i = h;
		while (m != 0) {
			if (m & 1 != 0) t = parSlotAny(o, i, t, maj, false, true);
			m = m >>> 1;
			i++;
		}
		return t;
	}

	static inline function parPushed(top:Int) {
		var a = pTop, b = top - 1;
		pTop = top;
		var stack = pStack;
		while (a < b) {
			var x = Mem.getPtr(stack, a << 4);
			Mem.setPtr(stack, a << 4, Mem.getPtr(stack, b << 4));
			Mem.setPtr(stack, b << 4, x);
			a++;
			b--;
		}
	}

	// minorSlot's, the copy raced for (maj: a major collection's, which
	// copies the from-space's objects too)
	static inline function parSlot(o:Ptr, i:Int, top:Int, maj:Bool):Int
		return parSlotWith(o, i, top, maj, false);

	// (arr: o is an Array, slot i its storage, copied as arrTrim says)
	static inline function parSlotWith(o:Ptr, i:Int, top:Int, maj:Bool, arr:Bool):Int
		return parSlotAny(o, i, top, maj, arr, false);

	// (c: i is the 4-byte half of a compressed reference)
	static inline function parSlotAny(o:Ptr, i:Int, top:Int, maj:Bool, arr:Bool, c:Bool):Int {
		var t = top;
		var v = getRefAt(o, i, c);
		if (!v.ult(youngStart) && v.ult(youngEnd))
			t = parCopySlot(o, i, top, v, arr, c);
		else if (maj && fromStart.ult(v) && !fromEnd.ult(v)) // (inFrom)
			t = parCopySlot(o, i, top, v, arr, c);
		return t;
	}

	// slot i of o, v (young, or in the from-space), forwarded: the new top
	// (c: the 4-byte half i, a compressed reference)
	static inline function parCopySlot(o:Ptr, i:Int, top:Int, v:Ptr, arr:Bool, c:Bool):Int {
		var t = top;
		{
			var vw0 = Atomic.load32(v.add(-8));
			if (isFwd(vw0))
				setRefAt(o, i, c, fwdAddr(v));
			else if (vw0 & 0xFFFF != T_BUSY && Atomic.cas32(v.add(-8), vw0, (vw0 & 0xFFFF0000) | T_BUSY) == vw0) {
				var words = wordsOf(v, vw0) + 1;
				var th:I64 = arr ? arrTrim(o, v, vw0) : (0 : I64);
				if (th.toInt() != 0) words = trimWords(th) + 1;
				var bytes = words << 3;
				var dst = pPlab;
				if (pPlabEnd.ult(dst.add(bytes)) || dst.isNull())
					dst = parAlloc(bytes);
				else
					pPlab = dst.add(bytes);
				if (words <= 8) {
					do {
						Mem.setI64(dst, 0, Mem.getI64(v, -8));
						if (words == 1) break;
						Mem.setI64(dst, 8, Mem.getI64(v, 0));
						if (words == 2) break;
						Mem.setI64(dst, 16, Mem.getI64(v, 8));
						if (words == 3) break;
						Mem.setI64(dst, 24, Mem.getI64(v, 16));
						if (words == 4) break;
						Mem.setI64(dst, 32, Mem.getI64(v, 24));
						if (words == 5) break;
						Mem.setI64(dst, 40, Mem.getI64(v, 32));
						if (words == 6) break;
						Mem.setI64(dst, 48, Mem.getI64(v, 40));
						if (words == 7) break;
						Mem.setI64(dst, 56, Mem.getI64(v, 48));
					} while (false);
				} else {
					var j = 0;
					while (j < words) {
						Mem.setI64At(dst, 0, j, Mem.getI64At(v, -8, j));
						j++;
					}
				}
				if (th.toInt() != 0) Mem.setI64(dst, 0, th) else Mem.setI32(dst, 0, vw0); // (the header as it was, not T_BUSY)
				var nv = dst.add(8);
				setFwdAddr(v, nv);
				Atomic.store32(v.add(-8), (vw0 & 0xFFFF0000) | Types.T_FWD);
				setRefAt(o, i, c, nv);
				if (!Types.isRawArray(vw0)) {
					Mem.setPtr(pStack, t << 4, nv);
					Mem.setI32(pStack, (t << 4) + 8, 0);
					t++;
				}
			} else
				setRefAt(o, i, c, parWaitFwd(v));
		}
		return t;
	}

	@:hxmc.unsafe static function majorAndTime(need:I64) {
		var t0 = stats ? Os.now() : 0.0;
		majorCollect(need);
		if (stats) majorSecs += Os.now() - t0;
	}

	@:hxmc.unsafe static function majorCollect(need:I64) {
		majors++;
		collections++;
		Foreign.atMajor = Foreign.promoted;
		Foreign.promoted = 0;
		#if hxmc.gc_prefault
		if (pfState > 0) prefaultCancel();
		#end
		fromStart = oldStart;
		fromEnd = oldPtr;
		// (the to-space is the other region, reserved whole, so the copy
		// never needs memory it does not have, but for what does not fit in
		// it: an end here rather than a write past it. The limit keeps a
		// nursery's room below the region's end, so only an old space that
		// fills its region, and a larger nursery, comes here)
		var fromPop = popEnd;
		popEnd = Ptr.nil();
		var young = youngNext.diff(youngStart);
		var copied = fromEnd.diff(fromStart) + young;
		// (in parallel, what the PLABs leave: a 32nd of what they hold at most,
		// and a PLAB per thread; copied serially when that does not fit)
		var par = parReady(copied) && copied + copied / 32 + (parThreads : I64) * PLAB_BYTES <= regionBytes;
		if (par) copied += copied / 32 + (parThreads : I64) * PLAB_BYTES;
		if (copied > regionBytes) die("out of memory: what a major collection may copy does not fit in the old space's region (RT_REGION_MB)\n");
		curRegion ^= 1;
		oldStart = region(curRegion);
		oldPtr = oldStart;
		dumpOld(oldStart.addL(copied)); // (what it copies at most)
		var scan = oldPtr;
		major = true;
		if (par) {
			// (as a parallel minor collection: the roots forwarded alone, then
			// what their copies reach copied by every copying thread, into
			// pages faulted in first: Os.populate)
			var p0 = stats ? Os.now() : 0.0;
			var pop = copied;
			#if hxmc.gc_prefault
			// (what it is expected to copy, the rest caught up: parPopulate,
			// within what it copies at most, the limit meanwhile)
			var catchUp = pfState >= 0;
			var expect = catchUp ? (majors > 1 ? survival : SURVIVAL_FIRST) : survival + 128;
			#else
			var expect = survival + 128;
			#end
			if (expect < 1024) pop = copied / 1024 * expect;
			popEnd = oldStart.addL(pop);
			Os.populate(oldStart, pop);
			if (stats) parPopSecs += Os.now() - p0;
			#if hxmc.gc_prefault
			oldEnd = oldStart.addL(copied);
			parPopTo = catchUp ? popEnd : Ptr.ofI64(-1);
			#end
			scanRoots(false);
			clearAllRemembered();
			parMajorCopy(scan);
			#if hxmc.gc_prefault
			if (catchUp && popEnd.ult(parPopTo)) popEnd = parPopTo;
			#end
		} else {
			scanRoots(!gcBfs);
			clearAllRemembered();
			if (gcBfs) scanFrom(scan);
		}
		if (nfinals > 0) {
			// values not copied yet are unreachable: queue their calls (newest
			// first), then copy them and what they reach
			var live = 0, q0 = finalQlen;
			var i = nfinals;
			while (i-- > 0) {
				var v = Mem.getPtr(finals, 16 * i + 8);
				if ((inYoung(v) || inFrom(v)) && !isFwd(hdrW0(v))) {
					if (finalQlen == finalQcap) {
						finalQcap = finalQcap == 0 ? 64 : finalQcap * 2;
						finalQueue = LibC.realloc(finalQueue, (finalQcap : I64) * 16);
					}
					LibC.memcpy(finalQueue.add(16 * finalQlen), finals.add(16 * i), 16);
					finalQlen++;
					Mem.setPtr(finals, 16 * i, Ptr.nil());
				}
			}
			for (j in 0...nfinals)
				if (!Mem.getPtr(finals, 16 * j).isNull()) {
					var v = Mem.getPtr(finals, 16 * j + 8);
					if (inYoung(v) || inFrom(v)) v = fwdAddr(v);
					Mem.setPtr(finals, 16 * live, Mem.getPtr(finals, 16 * j));
					Mem.setPtr(finals, 16 * live + 8, v);
					live++;
				}
			nfinals = live;
			for (j in q0...finalQlen) {
				var v = Mem.getPtr(finalQueue, 16 * j + 8);
				Mem.setPtr(finalQueue, 16 * j + 8, gcBfs ? majorForward(v) : fwdRoot(v));
			}
			if (gcBfs) scanFrom(scan);
		}
		major = false;
		if (nweak > 0) sweepWeak(fromStart, fromEnd);
		sweepNativesForeign(fromStart, fromEnd);
		// the from-space goes back to the system (RT_RELEASE=0 keeps it
		// resident, so the next major collection copies into faulted-in pages:
		// a little less system time for as much more memory as the old space held)
		// (with what the last parallel one faulted in past its end there)
		var relEnd = fromEnd;
		if (!fromPop.ult(fromStart) && fromPop.ult(fromStart.addL(regionBytes)) && relEnd.ult(fromPop)) relEnd = fromPop;
		if (releasePages) Os.decommit(fromStart, relEnd.diff(fromStart));
		var from = region(curRegion ^ 1);
		Os.coreDump(from, (curRegion == 0 ? dumpTop1 : dumpTop0).diff(from), false);
		if (curRegion == 0) dumpTop1 = from else dumpTop0 = from;
		var collected = fromEnd.diff(fromStart) + young;
		majorLimit(collected, need);
		survival = collected > 0 ? (oldPtr.diff(oldStart) * 1024 / collected).toInt() : 1024;
		// (pages faulted in past the limit: back to the system)
		if (par && oldEnd.ult(popEnd)) {
			var x = oldEnd.toI64() + ((2 << 20) - 1);
			var e = Ptr.ofI64(x - (x & ((2 << 20) - 1)));
			if (e.ult(popEnd)) Os.decommit(e, popEnd.diff(e));
		}
		dumpOld(oldEnd);
		if (stats) {
			var r = new Report(Mem.stack(Report.BYTES));
			r.str("gc: major ");
			r.int(majors, 0);
			r.str(": ");
			r.int(oldPtr.diff(oldStart) >> 20, 0);
			r.str(" MB live of ");
			r.int(fromEnd.diff(fromStart) >> 20, 0);
			r.str(" MB, limit ");
			r.int(oldEnd.diff(oldStart) >> 20, 0);
			r.str(" MB (growth x");
			r.int(growthMult, 0);
			r.str(")");
			if (Foreign.npeers > 0) {
				r.str("; pairs gone old since the previous ");
				r.int(Foreign.atMajor, 0);
			}
			r.str("\n");
			r.flush();
		}
		#if hxmc.census
		if (census == 2) censusNow(Mem.cstr("major collection"));
		#end
	}

	// the old space's next limit, after a major collection of `collected`
	// bytes (the from-space and the nursery) for an allocation of `need`:
	// `growth` percent of what is live (the base), and after collections that
	// freed little, room for the live set to grow on. Graded backoff: a
	// collection that freed little (a quarter or less of what it collected)
	// found data that lives on, as a compiler's trees, symbols and types;
	// each copies the whole live set, and copying it again soon frees as
	// little. The first such collection sets growthMult to MULT_FIRST, each
	// next one in a row doubles it (up to MULT_MAX); one that frees more than
	// half starts it over at 1, one in between keeps it (and gives no room:
	// a synthetic cache growing to 1.6 GB, 1.1 GB live of 1.7 at its second
	// major collection, a 5.4 GB limit and 22% more peak RSS with it). After
	// one that freed little, the limit has room on top of the base for
	// growthMult times what the live set grew by since the previous major
	// collection (prevLive), but no more than what is live or a 32nd of the
	// physical memory (ramBytes), whichever is more (a 16th, or twice what is
	// live: 50% more peak RSS for that cache, 25% for one replaced whole each
	// phase). The room is a bet that the program keeps growing as fast, and
	// once it stops (a compilation server between builds, a cache
	// that is full and churns) all of it fills with garbage before the next
	// collection. (Multiplying the growth by 4, 8 and 16 instead gave limits
	// of 12, 24 and 48 times what was live, capped only by half the memory or
	// the 16 GB region: the Haxe compilation server, 200 MB live after its
	// first build's first major collection, a limit of 2.5 GB and 1.5 GB more
	// peak RSS than without the backoff; a synthetic cache growing to 3 GB,
	// then churning, a 16 GB limit and 19 GB peak RSS against 10.7.) The front
	// end on hxmc's sources: 201 MB live at its first major collection, the
	// base 667 MB, 850 MB used at the end; without the room a second major
	// collection of 400 MB live, 270 MB more peak RSS. tsc-haxe on
	// t3code-server: 280 MB live, then 1.9 GB used at the end. The limit stays
	// below half the physical memory unless what is live needs more, and
	// within the region (regionBytes, 16 GB: on a large machine the cap that
	// binds first).
	static inline var MULT_FIRST = 4;
	static inline var MULT_MAX = 16;

	@:hxmc.unsafe static function majorLimit(collected:I64, need:I64) {
		var live = oldPtr.diff(oldStart);
		if (growthMult < 1) growthMult = 1;
		var little = live * 4 >= collected * 3;
		if (little) {
			growthMult = growthMult == 1 ? MULT_FIRST : growthMult < MULT_MAX ? growthMult * 2 : MULT_MAX;
		} else if (live * 2 < collected)
			growthMult = 1;
		var limit = live * (growth : I64) / 100 + minorSize * 4 + need;
		if (little && live > prevLive) {
			var room = (live - prevLive) * growthMult;
			var most = live;
			if (most < ramBytes / 32) most = ramBytes / 32;
			limit += room < most ? room : most;
		}
		prevLive = live;
		if (limit < ((64 << 20) : I64)) limit = 64 << 20;
		if (ramBytes > 0 && limit > ramBytes / 2) limit = ramBytes / 2;
		// (room for what is live and the allocation it collected for, whatever
		// the growth: RT_OLD_GROWTH below 100 left a large object no room, and
		// its allocation collected again and again)
		var least = live + need + minorSize;
		if (limit < least) limit = least;
		if (limit > regionBytes - minorSize) limit = regionBytes - minorSize;
		oldEnd = oldStart.addL(limit);
	}

	// [region, top) of the old space's region in a core dump (2 MB aligned:
	// huge pages stay whole)
	@:hxmc.unsafe static function dumpOld(top:Ptr) {
		var d = curRegion == 0 ? dumpTop0 : dumpTop1;
		var a = top.toI64() + ((2 << 20) - 1);
		top = Ptr.ofI64(a - (a & ((2 << 20) - 1)));
		var end = oldStart.addL(regionBytes);
		if (end.ult(top)) top = end;
		if (!d.ult(top)) return;
		Os.coreDump(d, top.diff(d), true);
		if (curRegion == 0) dumpTop0 = top else dumpTop1 = top;
	}

	// the nursery up to its size in a core dump
	@:hxmc.unsafe static function dumpYoung() {
		if (!youngDump.ult(youngEnd)) return;
		Os.coreDump(youngDump, youngEnd.diff(youngDump), true);
		youngDump = youngEnd;
	}

	// whether compressed references are on (a type has them: the heap and the
	// image are below 32 GB); a Mir host lowers the code it loads with them
	// then, which its data must be in reach of (hxmc.macro.Loader.compactHost)
	public static function compactRefs():Bool
		return compactWindow();

	// bytes of zeroed pages below 32 GB, past the heap (compressed references
	// on: the data of code a Mir host loads, hxmc.macro.Loader.alloc); null
	// when none is left, or without compressed references. Never released.
	@:hxmc.unsafe public static function reserveLow(bytes:I64):Ptr
		return compactWindow() ? heapReserve(bytes) : Ptr.nil();

	// macOS: the heap's window, the image's __HXHEAP segment (LinkMachO.heapWindow),
	// found in the image's load commands: its address there plus the image's
	// slide (where the image is, __dso_handle, its Mach-O header, less
	// __TEXT's address there). The heap goes nowhere else: without it
	// (an image another linker wrote), the program stops
	@:hxmc.unsafe static function macWindow() {
		// (the test here too: an older tool keeps the function, and __dso_handle is Mach-O's)
		if (Mem.os() == 1) {
			var h = Mem.sym("__dso_handle");
			var n = Mem.getI32(h, 16);
			var c = h.add(32);
			var text:I64 = -1, at:I64 = -1, size:I64 = 0;
			for (k in 0...n) {
				if (Mem.getI32(c, 0) == 0x19) { // LC_SEGMENT_64: its name at 8, 16 bytes
					var a = Mem.getI32(c, 8), b = Mem.getI32(c, 12), z = Mem.getI32(c, 16);
					if (a == 0x45545F5F && b == 0x5458 && z == 0) text = Mem.getI64(c, 24); // __TEXT
					if (a == 0x58485F5F && b == 0x50414548 && z == 0) { // __HXHEAP
						at = Mem.getI64(c, 24);
						size = Mem.getI64(c, 32);
					}
				}
				c = c.add(Mem.getI32(c, 4));
			}
			if (text < 0 || at < 0) die("no heap window (__HXHEAP) in the executable: its compressed references (@:hxmc.compact) need one\n");
			compactNext = h.toI64() - text + at;
			var end = compactNext + size;
			if (end < compactLimit) compactLimit = end;
		}
	}

	// address space for the heap: anywhere, or with compressed references
	// the first free range from compactNext on (2 MB aligned, past what is
	// taken in 256 MB steps) that ends below 32 GB (null: none)
	@:hxmc.unsafe static function heapReserve(bytes:I64):Ptr {
		if (!compactWindow()) return Os.reserve(bytes);
		var at = (compactNext + ((2 << 20) - 1)) & ~(((2 : I64) << 20) - 1);
		if (Mem.os() == 1) {
			// (macOS: the image's segment, the program's own: mapped over)
			if (compactLimit - at < bytes) return Ptr.nil();
			var p = Os.mapOver(Ptr.ofI64(at), bytes);
			if (!p.isNull()) compactNext = at + bytes;
			return p;
		}
		while (compactLimit - at >= bytes) {
			var p = Os.reserveAt(Ptr.ofI64(at), bytes);
			if (!p.isNull()) {
				compactNext = at + bytes;
				return p;
			}
			at += (256 : I64) << 20;
		}
		return Ptr.nil();
	}

	// The nursery: a reserved range (pages committed as touched) that it grows
	// and shrinks in, so resizing allocates nothing.
	@:hxmc.unsafe static function nurseryAlloc(bytes:I64):Ptr {
		var reserve:I64 = bytes > (MINOR_MAX : I64) ? bytes : MINOR_MAX;
		var p = heapReserve(reserve + (2 << 20));
		if (p.isNull() && compactWindow()) die("cannot reserve the nursery below 32 GB (@:hxmc.compact)\n");
		if (p.isNull()) die("cannot reserve the nursery\n");
		Os.coreDump(p, reserve + (2 << 20), false);
		#if (hxmc.shared || hxmc.dev_host)
		nurseryBase = p;
		nurseryBytes = reserve + (2 << 20);
		#end
		var a = p.toI64() + ((2 << 20) - 1);
		p = Ptr.ofI64(a - (a & ((2 << 20) - 1))); // 2 MB aligned (huge pages)
		if (hugePages) Os.hugePages(p, reserve);
		return p;
	}

	// (the nursery is empty: between collections)
	@:hxmc.unsafe static function resizeNursery(size:I64) {
		// (macOS: MADV_DONTNEED may leave the pages as they were, so they stay
		// dirty: the nursery grows again into them)
		if (size < minorSize && Os.decommit(youngStart.addL(size), minorSize - size) && Mem.os() != 1) {
			// zeros again above (pages are released whole: the partial page below
			// the next 64 KB boundary stays dirty)
			var z = youngStart.addL((size + 0xFFFF) - ((size + 0xFFFF) & 0xFFFF));
			if (z.ult(youngDirty)) youngDirty = z;
		}
		minorSize = size;
		youngEnd = youngStart.addL(minorSize);
		dumpYoung();
		if (!Os.has("RT_TLAB_KB")) tlabSize = minorSize / 16 < (TLAB_MAX : I64) ? minorSize / 16 : TLAB_MAX;
		if (stats) {
			var r = new Report(Mem.stack(Report.BYTES));
			r.str("gc: nursery ");
			r.int(minorSize >> 10, 0);
			r.str(" KB\n");
			r.flush();
		}
	}

	// after a minor collection that promoted `promoted` of `used` bytes, by
	// `threads` threads (the policy above)
	@:hxmc.unsafe static function adaptNursery(promoted:I64, used:I64, threads:Int) {
		adaptThreads(threads);
		var floor:I64 = (MINOR_MIN : I64) * mutators;
		var ceiling:I64 = (MINOR_CAP : I64) * mutators;
		if (floor > (FLOOR_MAX : I64)) floor = FLOOR_MAX;
		if (ceiling > (MINOR_MAX : I64)) ceiling = MINOR_MAX;
		if (promoted * 16 > used) {
			lowFor = 0;
			if (promotionSize < ceiling) promotionSize *= 2;
		} else if (promoted * 64 < used) {
			if (++lowFor >= LOW_PROMOTION_AFTER && promotionSize > (MINOR_MIN : I64)) {
				promotionSize = promotionSize / 2;
				lowFor = 0;
			}
		} else
			lowFor = 0;
		var size = promotionSize < floor ? floor : promotionSize > ceiling ? ceiling : promotionSize;
		if (size != minorSize) resizeNursery(size);
	}

	// the threads that allocated in the cycle that ended: more at once, fewer
	// after FEWER_THREADS_AFTER collections (then the most of those cycles)
	@:hxmc.unsafe static function adaptThreads(n:Int) {
		if (n < 1) n = 1;
		if (n >= mutators) {
			mutators = n;
			fewerFor = 0;
			fewerMax = 0;
		} else {
			if (n > fewerMax) fewerMax = n;
			if (++fewerFor >= FEWER_THREADS_AFTER) {
				mutators = fewerMax;
				fewerFor = 0;
				fewerMax = 0;
			}
		}
	}

	// the slots a thread's frames left above its stack top (see rt_sp_hw)
	@:hxmc.unsafe static function zeroAbove(m:Ptr<Mutator>) {
		if (m.value.sp.ult(m.value.hw)) LibC.memset(m.value.sp, 0, m.value.hw.diff(m.value.sp));
		m.value.hw = m.value.sp;
	}

	#if hxmc.gc_prefault
	// ---- the old space's pages, faulted in ahead of the minor collections
	// by a helper thread (Linux; RT_PREFAULT=0: none). Opt-in, with -D
	// hxmc.gc-prefault (the compilers' builds pass it): it trades CPU time
	// for wall time (the HaxeBenchmarks' alloc: 7.6% less wall time, 20%
	// more CPU time). A page a collection copies into for the first time
	// costs it a fault and the kernel's zeroing of the page (the port's
	// self-build: a tenth of the time of its main thread's minor
	// collections), on the collection's critical path. After each minor
	// collection the helper is asked for the pages up to twice as much past
	// the end of the old space as the collection promoted (PF_MIN to PF_MAX;
	// RT_PF_AHEAD: in quarters of it, 8 by default, 0: none). What the next
	// one copies past what the helper did, a parallel copy faults in with
	// Os.populate, a thread at a time (parPopulate): t3code-server with 4
	// quarters, 10 MB less memory and 0.5% more time; with none, 20 MB to
	// 57 MB less and 3% to 5% more time on large programs (without that, 25%
	// more: the copying threads faulted in the same huge pages together). It
	// touches each page with an atomic addition of zero, which leaves a word
	// the collector or an allocation of a large object writes meanwhile as
	// it is. It starts once the old space passes PF_START (small programs
	// never start it), and a major collection drops what is left of its
	// requests (pfGen). It never runs Haxe code: it is no mutator,
	// collections do not wait for it.
	static inline var PF_START = 16 << 20;
	static inline var PF_MIN = 4 << 20;
	static inline var PF_MAX = 128 << 20;
	static inline var PF_STEP = 256 << 10;
	static var pfState:Int; // 0: not started, 1: started, -1: none
	static var pfLock:Ptr;
	static var pfCond:Ptr;
	static var pfFrom:Ptr; // the pages to touch: [pfFrom, pfTo) (under pfLock)
	static var pfTo:Ptr;
	@:hxmc.export("hxmc_pf_gen") static var pfGen:Int; // major collections (Atomic)
	static var pfDoneTo:Ptr; // the pages below it are faulted in (under pfLock; null: none since a major collection)
	static var pfAhead:Int; // RT_PF_AHEAD + 1 (0: not read yet): how far ahead, in quarters of the last promotion (default 8)

	// after a minor collection that promoted `promoted` bytes
	@:hxmc.unsafe static function prefaultAhead(promoted:I64) {
		if (pfState == 0) {
			if (oldPtr.diff(oldStart) < (PF_START : I64)) return;
			if (Mem.os() != 0) {
				pfState = -1;
				return;
			}
			pfLock = LibC.malloc(Os.MUTEX_BYTES);
			Os.mutexInit(pfLock);
			pfCond = LibC.malloc(Os.COND_BYTES);
			Os.condInit(pfCond, false);
			pfFrom = oldPtr;
			pfTo = oldPtr;
			if (!Os.spawn(Callback.addr(prefaulter), Ptr.nil(), 256 << 10)) {
				pfState = -1;
				return;
			}
			pfState = 1;
		}
		if (pfAhead == 0) pfAhead = Os.envInt("RT_PF_AHEAD", 8) + 1;
		var want = promoted * (pfAhead - 1) / 4;
		var ahead = want < (PF_MIN : I64) ? (PF_MIN : I64) : want > (PF_MAX : I64) ? (PF_MAX : I64) : want;
		if (pfAhead == 1) ahead = 0;
		var to = oldPtr.addL(ahead);
		if (oldEnd.ult(to)) to = oldEnd;
		Os.lock(pfLock);
		if (pfFrom.ult(oldPtr)) pfFrom = oldPtr; // (the collector is past them)
		if (pfTo.ult(to)) {
			pfTo = to;
			Os.signal(pfCond);
		}
		Os.unlock(pfLock);
	}

	// (a major collection moves the old space)
	@:hxmc.unsafe static function prefaultCancel() {
		Os.lock(pfLock);
		Atomic.add32(Mem.sym("hxmc_pf_gen"), 1);
		pfFrom = Ptr.nil();
		pfTo = Ptr.nil();
		pfDoneTo = Ptr.nil();
		Os.unlock(pfLock);
	}

	// the helper thread: PF_STEP of the requested pages at a time
	@:hxmc.callback @:hxmc.unsafe static function prefaulter(arg:Ptr):Ptr {
		var page:I64 = Os.pageSize();
		Os.lock(pfLock);
		while (true) {
			while (!pfFrom.ult(pfTo))
				Os.condWait(pfCond, pfLock);
			var a = pfFrom;
			var b = a.add(PF_STEP);
			if (pfTo.ult(b)) b = pfTo;
			pfFrom = b;
			var gen = Atomic.load32(Mem.sym("hxmc_pf_gen"));
			Os.unlock(pfLock);
			var x = a.toI64() + (page - 1);
			var p = Ptr.ofI64(x - (x & (page - 1)));
			while (p.ult(b) && Atomic.load32(Mem.sym("hxmc_pf_gen")) == gen) {
				Atomic.add64(p, 0);
				p = p.addL(page);
			}
			Os.lock(pfLock);
			if (Atomic.load32(Mem.sym("hxmc_pf_gen")) == gen && pfDoneTo.ult(b)) pfDoneTo = b;
		}
		return Ptr.nil();
	}
	#end

	// a collection, with every other thread stopped (unless another thread
	// collected meanwhile: the caller then retries its allocation)
	@:hxmc.unsafe static function collectFor(full:Bool, need:I64) {
		var s0 = Os.now();
		// (what the scan needs of the foreign kinds that may not be called in the stop)
		if (Foreign.preStop && Foreign.npeers > 0) Foreign.beforeStop();
		if (!Threads.worldStop()) return;
		var p0 = Os.now();
		var m0 = majors;
		var handed = youngNext.diff(youngStart);
		if (youngDirty.ult(youngNext)) youngDirty = youngNext;
		#if hxmc.census
		if (census != 0) Census.countYoung(youngStart, youngNext);
		#end
		if (full) majorAndTime(need) else {
			var before = oldPtr;
			var used = youngNext.diff(youngStart);
			minor();
			if (majors == m0) {
				youngBytes += used;
				promotedBytes += oldPtr.diff(before);
				if (!minorFixed) adaptNursery(oldPtr.diff(before), used, allocating);
				#if hxmc.gc_prefault
				if (pfState >= 0) prefaultAhead(oldPtr.diff(before));
				#end
			}
		}
		allocating = 0;
		epoch++;
		youngNext = youngStart;
		if (poison) LibC.memset(youngStart, POISON, minorSize);
		// the nursery is empty again: every thread takes a new TLAB at its next
		// allocation (what their TLABs had left was not allocated)
		var me = Threads.self;
		var t = Threads.allThreads;
		while (!t.isNull()) {
			if (t.value.started != 0) {
				if (!t.value.yptr.isNull() && t.value.yptr.ult(t.value.yrlim)) handed -= t.value.yrlim.diff(t.value.yptr);
				if (!t.value.runEnd.isNull() && t.value.yrlim.ult(t.value.runEnd)) handed -= t.value.runEnd.diff(t.value.yrlim);
				t.value.runEnd = Ptr.nil();
				if (!t.value.yptr.isNull() && !t.value.tlabStart.isNull()) t.value.allocated += t.value.yptr.diff(t.value.tlabStart);
				t.value.tlabStart = Ptr.nil();
				t.value.yptr = Ptr.nil();
				t.value.ylim = Ptr.nil();
				t.value.yrlim = Ptr.nil();
			}
			t = t.value.next;
		}
		zeroAbove(me);
		t = Threads.allThreads;
		while (!t.isNull()) {
			if (t.value.started != 0) zeroAbove(t);
			t = t.value.next;
		}
		allocBytes += handed;
		var end = Os.now();
		var pause = end - s0;
		record(s0, p0, end, majors != m0);
		lastPause = pause;
		totalPause += pause;
		if (pause > maxPause) maxPause = pause;
		Threads.worldResume();
		// (the threads a collection put calls off for: told, Foreign.stopDefer)
		if (Foreign.nwakes > 0) Foreign.wakeQueued();
	}

	// ---- allocation

	// a TLAB with room for `bytes`, zeroed (but under RT_VERIFY: the pattern;
	// the whole free nursery then with one thread), but for its first `bytes`
	// when raw: an object without references that its allocation writes
	// whole (allocNow) takes them. The rest of the thread's
	// TLAB starts it when that was the last one taken (with one thread,
	// always: the free nursery stays contiguous). youngDirty changes only
	// while the world is stopped.
	@:hxmc.unsafe static function tlabRefill(bytes:Int, raw:Bool):Bool {
		if (myEpoch != epoch) {
			myEpoch = epoch;
			Atomic.add32(Mem.sym("hxmc_allocating"), 1);
		}
		var many = Atomic.load32(Mem.sym("rt_nthreads")) > 1;
		var want:I64 = many ? tlabSize : poison ? ((1 : I64) << 62) : zchunk;
		if (want < bytes) want = bytes;
		var me = Threads.self;
		// the next TLAB of the thread's run of fresh pages (see below): no
		// atomic, and a safepoint every TLAB as in dirty pages
		var re = me.value.runEnd;
		if (!re.isNull()) {
			if (!yptr.isNull() && yrlim.ult(re) && re.diff(yptr) >= (bytes : I64)) {
				var e = yptr.addL(want);
				if (re.ult(e)) e = re;
				var z = raw && yrlim.ult(yptr.add(bytes)) ? yptr.add(bytes) : yrlim;
				var ze = e.ult(youngDirty) ? e : youngDirty;
				if (!poison && z.ult(ze)) Mem.zero(z, ze.diff(z));
				yrlim = e;
				ylim = poison ? Ptr.nil() : e;
				return true;
			}
			me.value.runEnd = Ptr.nil();
		}
		var cell = Mem.sym("hxmc_young_next");
		var p = Ptr.ofI64(Atomic.load64(cell));
		while (true) {
			var s = !yptr.isNull() && p == yrlim ? yptr : p;
			var avail = youngTop().diff(s);
			if (avail < bytes) return false;
			var e = s.addL(want < avail ? want : avail);
			// with several threads, a TLAB that reaches untouched memory (above
			// youngDirty: fresh pages, after a start or a growth) takes the
			// pages up to a 2 MB boundary as the thread's run (runEnd), its next
			// TLABs cut from it, so that threads do not fault in the same 2 MB together:
			// with transparent huge pages, each of them would get a huge page
			// of its own, zeroed by the kernel, all but one thrown away (the
			// tool's code generation, its nursery growing to 256 MB under 12
			// threads: 1.5 s of kernel time). Fresh pages need no zeroing of
			// ours, so the run costs nothing but its share of the nursery
			var run = Ptr.nil();
			if (many && youngDirty.ult(e)) {
				var x = e.toI64() + (HUGE_PAGE - 1);
				run = Ptr.ofI64(x - (x & (HUGE_PAGE - 1))); // (the nursery starts 2 MB aligned)
				if (youngTop().ult(run)) run = youngTop();
			}
			var seen = Ptr.ofI64(Atomic.cas64(cell, p.toI64(), (run.isNull() ? e : run).toI64()));
			if (seen == p) {
				// (the run's pages are the thread's, handed out a TLAB at a
				// time: a thread with 2 MB to allocate in before its next
				// safepoint kept the others waiting at a stop of the world,
				// webpack 3 to 11 ms a stop when the nursery grew in steps)
				if (!run.isNull() && e.ult(run)) me.value.runEnd = run;
				// (a new run of TLABs: the last one's bytes are the thread's)
				if (s != yptr || yptr.isNull()) {
					if (!yptr.isNull() && !me.value.tlabStart.isNull()) me.value.allocated += yptr.diff(me.value.tlabStart);
					me.value.tlabStart = s;
				}
				// (below p: the rest of the thread's TLAB, zeroed already; a raw
				// object's bytes, at s, are its allocation's to write)
				var z = raw && p.ult(s.add(bytes)) ? s.add(bytes) : p;
				var ze = e.ult(youngDirty) ? e : youngDirty;
				if (!poison && z.ult(ze)) Mem.zero(z, ze.diff(z));
				yptr = s;
				yrlim = e;
				ylim = poison ? Ptr.nil() : e;
				return true;
			}
			p = seen;
		}
	}

	// room for `bytes` in the thread's TLAB, refilled if needed (false: the nursery is full)
	static inline function youngRoom(bytes:Int, raw:Bool):Bool
		return yrlim.diff(yptr) >= bytes || tlabRefill(bytes, raw);

	@:hxmc.host("rt_alloc_slow") @:hxmc.collects static function allocSlow(header:I64, bytes:Int):Ptr {
		// RT_VERIFY: every allocation comes here (no TLAB limit, tlabRefill),
		// so one in a safe region, which another thread may be collecting
		// through, is caught (Blocking.enter, a @:hxmc.blocking job)
		if (poison && Threads.inRegion())
			die("hxmc: allocation in a safe region (between Blocking.enter and leave, or in a blocking call): another thread may collect meanwhile (RT_VERIFY)\n");
		// a safepoint: the caller's live references are rooted here
		Threads.safepoint();
		// likewise for finaliser calls queued by an earlier major collection
		if (finalQlen != 0 && finalsRunning == 0) callFinalisers(false);
		if (Foreign.ndeferred != 0) Foreign.runDeferred();
		return allocNow(header, bytes, false);
	}

	// allocSlow for an allocation that writes every slot before reading it
	// (Mem.allocRaw, Mem.allocArrayRaw: GcPaths.allocSlowRaw), of an object
	// without references (Types.K_RAW: a string, the storage of numbers),
	// which is not zeroed: no scan reads its slots
	@:hxmc.collects static function allocSlowRaw(header:I64, bytes:Int):Ptr {
		if (poison && Threads.inRegion())
			die("hxmc: allocation in a safe region (between Blocking.enter and leave, or in a blocking call): another thread may collect meanwhile (RT_VERIFY)\n");
		Threads.safepoint();
		if (finalQlen != 0 && finalsRunning == 0) callFinalisers(false);
		if (Foreign.ndeferred != 0) Foreign.runDeferred();
		return allocNow(header, bytes, true);
	}

	@:hxmc.unsafe static function allocNow(header:I64, bytes:Int, raw:Bool):Ptr {
		var p:Ptr;
		// large objects go straight to the old space (with one thread, unless
		// the free nursery has room: they may die young)
		if ((bytes : I64) > (minorSize >> 2) && !(Atomic.load32(Mem.sym("rt_nthreads")) == 1 && youngRoom(bytes, raw))) {
			Atomic.add64(Mem.sym("hxmc_gc_large_bytes"), bytes);
			Threads.self.value.allocated += bytes;
			var cell = Mem.sym("hxmc_old_ptr");
			p = Ptr.ofI64(Atomic.load64(cell));
			while (true) {
				if (oldEnd.diff(p) < bytes) {
					collectFor(true, bytes);
					p = Ptr.ofI64(Atomic.load64(cell));
					// (the region cannot hold it even after a major collection:
					// another would not help, and the loop would never end)
					if (oldStart.addL(regionBytes - minorSize).diff(p) < bytes) die("out of memory: an object does not fit in the old space's region (RT_REGION_MB)\n");
					continue;
				}
				var seen = Ptr.ofI64(Atomic.cas64(cell, p.toI64(), p.add(bytes).toI64()));
				if (seen == p) break;
				p = seen;
			}
		} else {
			while (!youngRoom(bytes, raw))
				collectFor(false, 0); // (room already: another thread collected meanwhile)
			p = yptr;
			yptr = p.add(bytes);
			Mem.setI64(p, 0, header);
			// (zeroed with its TLAB, but for the pattern of RT_VERIFY, which a raw one keeps)
			if (poison && !raw) LibC.memset(p.add(8), 0, bytes - 8);
			return p.add(8);
		}
		Mem.setI64(p, 0, header);
		if (!raw) LibC.memset(p.add(8), 0, bytes - 8);
		#if hxmc.census
		if (census != 0) Census.countAlloc(header, bytes);
		#end
		return p.add(8);
	}

	// ---- the write barrier's slow path (generated code's inline part and
	// GcPaths: obj is old, the slot now holds a young pointer and held none)

	@:hxmc.host("rt_write_barrier") @:hxmc.unsafe static function writeBarrier(obj:Ptr, slot:Ptr, v:Ptr):Void
		remember(slot);

	// (slot: an 8-byte slot's address, or a compressed reference's (4 bytes,
	// @:hxmc.compact) plus 1: forwardRemembered, parRemembered)
	@:hxmc.unsafe static inline function remember(slot:Ptr) {
		var m = Threads.self;
		var n = m.value.remLen;
		if (n == m.value.remCap) {
			m.value.remCap = n == 0 ? 4096 : n * 2;
			m.value.rem = LibC.realloc(m.value.rem, (m.value.remCap : I64) * 8);
		}
		Mem.setPtr(m.value.rem, 8 * n, slot);
		m.value.remLen = n + 1;
	}

	// old objects whose every slot may hold a young pointer, scanned whole by
	// the next minor collection (per thread); a small cache drops repeated
	// entries for one object
	@:hxmc.unsafe static function rememberObj(obj:Ptr) {
		var m = Threads.self;
		var h = (obj.toI64() >> 4).toInt() & 255;
		if (Mem.getPtr(m.value.recent, 8 * h) == obj) return;
		Mem.setPtr(m.value.recent, 8 * h, obj);
		if (m.value.robjsLen == m.value.robjsCap) {
			m.value.robjsCap = m.value.robjsCap == 0 ? 256 : m.value.robjsCap * 2;
			m.value.robjs = LibC.realloc(m.value.robjs, (m.value.robjsCap : I64) * 8);
		}
		Mem.setPtr(m.value.robjs, 8 * m.value.robjsLen, obj);
		m.value.robjsLen = m.value.robjsLen + 1;
	}

	// a compressed reference (@:hxmc.compact) stored by the runtime (Dynamic
	// access, reflection: Dyn.storeSlot) into 4-byte half h of o, with
	// MemLower.setCompact's write barrier
	@:hxmc.unsafe static function storeCompact(o:Dynamic, h:Int, v:Dynamic) {
		var p = Mem.addr(o), x = Mem.addr(v);
		var prev = getC(p, h);
		setC(p, h, x);
		if (inYoung(x) && !inYoung(p) && !inYoung(prev)) remember(p.add(4 * h + 1));
	}

	// after a bulk move or copy of references into obj (memmove in natives):
	// the remembered set records slots, so every slot now holding a young
	// pointer is recorded again. A long range (e.g. Array.insert at the front
	// of a large array, as the port does for OCaml's `x :: l`) remembers the
	// whole object once instead: recording its slots made the set grow by the
	// array's length at every insertion (16M entries, 128 MB, on the
	// self-compile).
	@:hxmc.host("rt_barrier_range") @:hxmc.unsafe static function barrierRange(obj:Dynamic, from:Ptr, n:Int):Void {
		var o = Mem.addr(obj);
		if (inYoung(o)) return;
		if (n > 16) {
			rememberObj(o);
			return;
		}
		for (i in 0...n)
			if (inYoung(Mem.getPtr(from, 8 * i))) remember(from.add(8 * i));
	}

	// ---- finalisers

	// Gc.finalise f v: values outside the heap (static objects, null) are
	// never collected, so their finalisers never run
	@:hxmc.unsafe public static function finalise(fn:Dynamic, val:Dynamic):Void {
		var v = Mem.addr(val);
		if (v.isNull() || !(inYoung(v) || inOld(v))) return;
		lockLeaf(finalsLock);
		if (nfinals == finalsCap) {
			finalsCap = finalsCap == 0 ? 64 : finalsCap * 2;
			finals = LibC.realloc(finals, (finalsCap : I64) * 16);
		}
		Mem.setPtr(finals, 16 * nfinals, Mem.addr(fn));
		Mem.setPtr(finals, 16 * nfinals + 8, v);
		nfinals++;
		unlockLeaf(finalsLock);
	}

	// a collection now: minor or major (full), as OCaml's Gc.minor/full_major
	@:hxmc.collects public static function collect(full:Bool):Void {
		collectFor(full, 0);
		if (Foreign.ndeferred != 0) Foreign.runDeferred();
	}

	// the queued finalisers (an exception escapes, as from OCaml's Gc.full_major)
	public static function runFinalisers():Void
		callFinalisers(true);

	// calls the queued finalisers (an exception escapes when propagate is
	// set; otherwise, at an allocation, it is reported)
	static function callFinalisers(propagate:Bool) {
		if (finalsRunning != 0) return;
		finalsRunning = 1;
		while (true) {
			var i = dequeue();
			if (i < 0) break;
			// (read before the next GC point: the queue is a root until dequeued)
			var f:Dynamic = Mem.getRef(finalQueue, 16 * i);
			var v:Dynamic = Mem.getRef(finalQueue, 16 * i + 8);
			dequeued(i);
			try {
				f(v);
			} catch (e:Dynamic) {
				if (propagate) {
					finalsRunning = 0;
					throw e;
				}
				uncaught("Uncaught exception in a finaliser: ", e);
			}
		}
		finalsRunning = 0;
	}

	// the next call's index in the queue, under its lock (released by dequeued), or -1
	@:hxmc.unsafe static function dequeue():Int {
		lockLeaf(finalsLock);
		if (finalQhead >= finalQlen) {
			unlockLeaf(finalsLock);
			return -1;
		}
		return finalQhead;
	}

	@:hxmc.unsafe static function dequeued(i:Int) {
		if (++finalQhead == finalQlen) finalQhead = finalQlen = 0;
		unlockLeaf(finalsLock);
	}

	// an exception nothing caught, on stderr: prefix, then Std.string(e)
	static function uncaught(prefix:String, e:Dynamic) {
		exn = Ptr.nil();
		var s = Str.toUtf8(prefix + Std.string(e) + "\n");
		Os.write(s, LibC.strlen(s).toInt());
		LibC.free(s);
	}

	// ---- startup (from rt_init, Start): the heap's reservations and the
	// main thread's shadow stack (its bottom)

	@:hxmc.unsafe static function init(ng:Int):Ptr {
		// (a type with compressed references: hxmc.DataGen's flag, Types.hasCompact)
		// (or forwarding in the header, GcCore.fwdLow: every program with
		// Mem.compact, its objects may have no slot)
		compactHeap = fwdLow();
		if (compactTypes())
			for (t in 0...Mem.getI32(Mem.sym("rt_ntypes"), 0))
				if (Types.hasCompact(Types.ty(t))) compactHeap = true;
		// (a Mir host, Mem.mirHost: from 2 GB, above the native tier's window,
		// where the code it loads goes: hxmc.macro.Loader.WINDOW_LO to WINDOW_HI)
		compactNext = ((Mem.mirHost() == 1 ? 2 : 1) : I64) << 30;
		compactLimit = (COMPACT_LIMIT : I64) << 30;
		// (macOS: in the image's __HXHEAP segment, LinkMachO.heapWindow)
		if (Mem.os() == 1 && compactWindow()) macWindow();
		// (the image's static objects, which compressed references reach too:
		// below 32 GB at the executable's fixed address, hxmc.Main.compactRefs)
		if (compactWindow() && !Mem.sym("rt_types").ult(Ptr.ofI64((COMPACT_LIMIT : I64) << 30))) die("the executable is loaded above 32 GB: its compressed references (@:hxmc.compact) cannot reach it\n");
		var m = Os.getenv("RT_MINOR_KB");
		minorFixed = !m.isNull();
		minorSize = minorFixed ? (Os.atoi(m) : I64) << 10 : (MINOR_MIN : I64);
		// (16 KB at least: an allocation of up to 4 KB is always made in the
		// nursery, allocNow, which generated code assumes: its stores into an
		// object allocated since the last collection point have no write
		// barrier, Opt.freshTargets, and Fold makes allocations of up to 4 KB)
		if (minorSize < 16384) minorSize = 16384;
		promotionSize = minorSize;
		mutators = 1;
		epoch = 1;
		stats = Os.has("RT_STATS");
		#if hxmc.census
		census = Os.envInt("RT_CENSUS", 0);
		#end
		releasePages = Os.envInt("RT_RELEASE", 1) != 0;
		gcBfs = Os.has("RT_BFS");
		#if hxmc.gc_prefault
		if (Os.envInt("RT_PREFAULT", 1) == 0) pfState = -1;
		#if (hxmc.shared || hxmc.dev_host)
		// (a shared library's runtime gives its heap back and is closed,
		// releaseHeap: no helper thread left running in it)
		pfState = -1;
		#end
		#end
		// transparent huge pages for the heap: the old space grows by hundreds of
		// MB and is copied into fresh pages, so 4 KB page faults add up
		hugePages = L.MADV_HUGEPAGE != 0 && Os.envInt("RT_HUGE", 0) != 0; // opt-in: it costs more kernel time than it saves here
		youngStart = nurseryAlloc(minorSize);
		youngEnd = youngStart.addL(minorSize);
		youngDump = youngStart;
		dumpYoung();
		youngNext = youngStart; // rt_young_ptr = rt_young_limit = null: the first allocation takes a TLAB
		youngDirty = youngStart; // fresh pages
		poison = Os.has("RT_VERIFY");
		if (poison) LibC.memset(youngStart, POISON, minorSize);
		zchunk = (Os.envInt("RT_ZCHUNK_KB", 32) : I64) << 10;
		if (zchunk < 4096) zchunk = 4096;
		var tk = Os.getenv("RT_TLAB_KB");
		tlabSize = tk.isNull() ? (minorSize / 16 < (TLAB_MAX : I64) ? minorSize / 16 : TLAB_MAX) : (Os.atoi(tk) : I64) << 10;
		if (tlabSize < 4096) tlabSize = 4096;
		regionBytes = (16 : I64) << 30;
		var rm = Os.getenv("RT_REGION_MB");
		if (!rm.isNull()) regionBytes = (Os.atoi(rm) : I64) << 20;
		var regionsAt = compactNext;
		if (compactWindow()) {
			// (two regions in what is left below 32 GB, in 1 GB steps: 15 GB each after a 256 MB nursery)
			var room = ((compactLimit - compactNext) / 2) & ~(((1 : I64) << 30) - 1);
			if (regionBytes > room) regionBytes = room;
		}
		var i = 0;
		while (i < 2) {
			var r = heapReserve(regionBytes);
			if (r.isNull() && regionBytes > ((512 : I64) << 20)) {
				// (macOS's window stays reserved: no access again, not unmapped)
				if (i == 1) {
					if (Mem.os() == 1 && compactWindow()) Os.guard(region0, regionBytes) else Os.release(region0, regionBytes);
				}
				regionBytes = regionBytes / 2;
				compactNext = regionsAt;
				i = 0;
				continue;
			}
			if (r.isNull() && compactWindow()) die("cannot reserve the heap below 32 GB (@:hxmc.compact)\n");
			if (r.isNull()) die("cannot reserve heap\n");
			if (hugePages) Os.hugePages(r, regionBytes);
			Os.coreDump(r, regionBytes, false);
			if (i == 0) region0 = r else region1 = r;
			i++;
		}
		oldStart = region0;
		oldPtr = region0;
		oldEnd = oldStart.addL((Os.envInt("RT_OLD_MB", 256) : I64) << 20); // fewer major collections early on
		growth = Os.envInt("RT_OLD_GROWTH", 300);
		growthMult = 1;
		prevLive = 0;
		survival = 1024;
		ramBytes = Os.physicalBytes();
		if (oldStart.addL(regionBytes - minorSize).ult(oldEnd)) oldEnd = oldStart.addL(regionBytes - minorSize);
		dumpTop0 = region0;
		dumpTop1 = region1;
		dumpOld(oldEnd);
		// the shadow stack: reserved, committed as touched, with a guard page
		// above it: as deep as the main C stack (rt_run_main)
		var sbytes:I64 = (1 : I64) << 30, page = Os.pageSize();
		var sstack = Os.reserve(sbytes + page);
		if (sstack.isNull()) die("cannot reserve the shadow stack\n");
		#if (hxmc.shared || hxmc.dev_host)
		sstackBase = sstack;
		sstackBytes = sbytes + page;
		#end
		Os.guard(sstack.addL(sbytes), page);
		Os.stackCoreDump(sstack, sbytes, false);
		sp = sstack;
		hw = sstack;
		nglobals = ng;
		gcCap = 4096;
		gcStack = LibC.malloc((gcCap : I64) * 16);
		finalsLock = LibC.malloc(Os.MUTEX_BYTES);
		Os.mutexInit(finalsLock);
		nativesLock = LibC.malloc(Os.MUTEX_BYTES);
		Os.mutexInit(nativesLock);
		Foreign.init();
		weakLock = LibC.malloc(Os.MUTEX_BYTES);
		Os.mutexInit(weakLock);
		blocksLock = LibC.malloc(Os.MUTEX_BYTES);
		Os.mutexInit(blocksLock);
		blockFree = -1;
		fdLock = LibC.malloc(Os.MUTEX_BYTES);
		Os.mutexInit(fdLock);
		return sstack;
	}

	#if (hxmc.shared || hxmc.dev_host)
	// a shared library's reservations (releaseHeap)
	static var nurseryBase:Ptr;
	static var nurseryBytes:I64;
	static var sstackBase:Ptr;
	static var sstackBytes:I64;

	// A shared library's runtime whose program has ended, before the library
	// is closed (hxmc dev's host: a build swapped out): the heap, the nursery
	// and the main shadow stack given back to the system. Nothing of the
	// heap is used after this (the program's threads have ended).
	@:hxmc.unsafe public static function releaseHeap() {
		Faults.uninstall(); // (its handler's code goes with the library)
		if (!region0.isNull()) Os.release(region0, regionBytes);
		if (!region1.isNull()) Os.release(region1, regionBytes);
		if (!nurseryBase.isNull()) Os.release(nurseryBase, nurseryBytes);
		if (!sstackBase.isNull()) Os.release(sstackBase, sstackBytes);
		region0 = region1 = nurseryBase = sstackBase = Ptr.nil();
		LibC.free(gcStack);
		LibC.free(globals);
		gcStack = globals = Ptr.nil();
	}
	#end

	static inline function die(msg:String)
		dieC(Mem.cstr(msg));

	@:hxmc.unsafe static function dieC(msg:Ptr) {
		var r = new Report(Mem.stack(Report.BYTES));
		r.cstr(msg, 0, -1);
		r.flush();
		Os.exit(2);
	}

	// ---- reports (atexit: RT_STATS, the census)

	// RSS and its peak in KB, from /proc (Linux; 0 elsewhere)
	@:hxmc.unsafe static function procRss(out:Ptr) {
		Mem.setI64(out, 0, 0);
		Mem.setI64(out, 8, 0);
		if (Mem.os() != 0) return;
		var fd = Posix.open(Mem.cstr("/proc/self/status"), 0x80000, 0); // O_CLOEXEC
		if (fd < 0) return;
		var buf = Mem.stack(8192);
		var n = 0;
		while (n < 8191) {
			var r = Posix.read(fd, buf.add(n), (8191 - n : I64)).toInt();
			if (r <= 0) break;
			n += r;
		}
		Posix.close(fd);
		Mem.setI8(buf, n, 0);
		var line = 0;
		while (line < n) {
			if (startsWith(buf.add(line), Mem.cstr("VmRSS:"))) Mem.setI64(out, 0, Os.atoi(buf.add(line + 6)));
			if (startsWith(buf.add(line), Mem.cstr("VmHWM:"))) Mem.setI64(out, 8, Os.atoi(buf.add(line + 6)));
			while (line < n && Mem.getU8(buf, line) != "\n".code)
				line++;
			line++;
		}
	}

	// p starts with the C string s
	@:hxmc.unsafe static function startsWith(p:Ptr, s:Ptr):Bool {
		var i = 0;
		while (Mem.getU8(s, i) != 0) {
			if (Mem.getU8(p, i) != Mem.getU8(s, i)) return false;
			i++;
		}
		return true;
	}

	@:hxmc.callback @:hxmc.unsafe static function report():Void {
		if (stats) {
			var rss = Mem.stack(16);
			procRss(rss);
			var r = new Report(Mem.stack(Report.BYTES));
			r.str("gc: RSS ");
			r.int(Mem.getI64(rss, 0) >> 10, 0);
			r.str(" MB, peak ");
			r.int(Mem.getI64(rss, 8) >> 10, 0);
			r.str(" MB; old ");
			r.int(oldPtr.diff(oldStart) >> 20, 0);
			r.str(" MB used of ");
			r.int(oldEnd.diff(oldStart) >> 20, 0);
			r.str(" MB limit\n");
			r.flush();
		}
		#if hxmc.census
		if (census != 0) {
			var c = census;
			Census.countYoung(youngStart, youngNext);
			census = 0;
			majorAndTime(0);
			censusNow(Mem.cstr("exit"));
			Census.allocReport();
			census = c;
		}
		#end
		if (stats) {
			var r = new Report(Mem.stack(Report.BYTES));
			r.str("gc: ");
			r.int(minors, 0);
			r.str(" minor (");
			r.fixed(minorSecs, 2, 0);
			r.str("s), ");
			r.int(majors, 0);
			r.str(" major (");
			r.fixed(majorSecs, 2, 0);
			r.str("s), old ");
			r.int(oldPtr.diff(oldStart) >> 20, 0);
			r.str(" MB used; promoted ");
			r.int(promotedBytes >> 20, 0);
			r.str(" of ");
			r.int(youngBytes >> 20, 0);
			r.str(" MB");
			if (Foreign.npeers > 0) {
				r.str("; pairs ");
				r.int(Foreign.npeers, 0);
				r.str(", old since the last major ");
				r.int(Foreign.promoted, 0);
			}
			if (parCopies > 0 || parMajors > 0) {
				r.str("; in parallel ");
				r.int(parCopies, 0);
				r.str(" minor, ");
				r.int(parMajors, 0);
				r.str(" major");
				if (parMajors > 0) {
					r.str(" (faulting in ");
					r.fixed(parPopSecs, 3, 0);
					r.str("s)");
				}
				r.str(" (");
				r.int(parThreads, 0);
				r.str(" threads; roots ");
				r.fixed(parRootSecs, 3, 0);
				r.str("s, ");
				r.int(parRootBytes >> 20, 0);
				r.str(" MB; copying ");
				r.fixed(parCopySecs, 3, 0);
				r.str("s");
				#if hxmc.gc_prefault
				r.str(", faulting in ");
				r.int(parPopBytes >> 20, 0);
				r.str(" MB");
				#end
				r.str(")");
			}
			r.str("\n");
			r.flush();
		}
	}

	#if hxmc.census
	// a debug build (-D hxmc.census): RT_CENSUS=1, a census of the heap at
	// exit; 2, also after each major collection (Census)
	static var census:Int;

	@:hxmc.unsafe static function censusNow(when:Ptr) {
		var me = Threads.self;
		Census.run(oldStart, oldPtr, when, minorSize, oldEnd.diff(oldStart), (me.value.remCap + me.value.robjsCap : I64) * 8,
			(gcCap : I64) * 16, sp.diff(me.value.base), minors, majors, nglobals);
		Census.why(oldStart, oldPtr, globals, nglobals);
	}
	#end

	// The old space's soft limit while no major collection has run (RT_OLD_MB,
	// 256 MB by default, which wins over this): a program that knows it keeps
	// more than that from the start (a compiler's syntax trees and types)
	// raises it, so its first major collection does not copy what it is
	// still building (tsc-haxe).
	@:hxmc.noGc public static function setOldLimit(mb:Int):Void {
		if (majors > 0 || Os.has("RT_OLD_MB")) return;
		var e = oldStart.addL((mb : I64) << 20);
		if (oldStart.addL(regionBytes - minorSize).ult(e)) e = oldStart.addL(regionBytes - minorSize);
		if (oldEnd.ult(e)) {
			oldEnd = e;
			dumpOld(oldEnd);
		}
	}

	// ---- hxmc.NativeGc's measurements (the port's server/memory, in place
	// of OCaml's Objsize and Gc heap words)

	// ---- hxmc.GcStats

	// bytes allocated since the start: in the nursery (up to the calling
	// thread's allocation pointer; other threads' TLABs whole) and in the old space
	@:hxmc.unsafe public static function bytesAllocated():Float {
		var b = allocBytes + Atomic.load64(Mem.sym("hxmc_gc_large_bytes")) + youngNext.diff(youngStart);
		if (!yptr.isNull() && yptr.ult(yrlim)) b -= yrlim.diff(yptr);
		var re = Threads.self.value.runEnd;
		if (!re.isNull() && yrlim.ult(re)) b -= re.diff(yrlim);
		var f:Float = cast b;
		return f;
	}

	// the calling thread's
	@:hxmc.unsafe public static function threadBytesAllocated():Float {
		var m = Threads.self;
		var b = m.value.allocated;
		if (!yptr.isNull() && !m.value.tlabStart.isNull()) b += yptr.diff(m.value.tlabStart);
		var f:Float = cast b;
		return f;
	}

	@:hxmc.unsafe static function record(start:Float, stopped:Float, end:Float, major:Bool) {
		if (records.isNull()) records = LibC.malloc(32 * RECORDS);
		var r = records.add(32 * (nrecords % RECORDS));
		Mem.setF64(r, 0, start);
		Mem.setF64(r, 8, stopped);
		Mem.setF64(r, 16, end);
		Mem.setF64(r, 24, major ? 1.0 : 0.0);
		nrecords++;
	}

	// the field (0 start, 1 stopped, 2 end, 3 major) of collection k (counted
	// from 0; one of the last RECORDS)
	@:hxmc.unsafe public static function recordField(k:Int, field:Int):Float
		return Mem.getF64(records, 32 * (k % RECORDS) + 8 * field);

	@:hxmc.unsafe public static function recordCount():Int
		return nrecords;

	@:hxmc.unsafe public static function clock():Float
		return Os.now();

	@:hxmc.unsafe public static function counts(which:Int):Int
		return which == 0 ? collections : which == 1 ? minors : majors;

	@:hxmc.unsafe public static function pause(which:Int):Float
		return which == 0 ? lastPause : which == 1 ? totalPause : maxPause;

	// what the old space holds (large objects included) and the nursery up to
	// what the threads took of it (hxmc.GcStats.liveBytes)
	@:hxmc.unsafe public static function liveBytes():Float {
		var b:Float = cast(Ptr.ofI64(Atomic.load64(Mem.sym("hxmc_old_ptr"))).diff(oldStart) + Ptr.ofI64(Atomic.load64(Mem.sym("hxmc_young_next"))).diff(youngStart));
		return b;
	}

	// the bytes the heap spaces take
	@:hxmc.unsafe public static function heapBytes():Float {
		var o:Float = cast oldEnd.diff(oldStart);
		var y:Float = cast youngEnd.diff(youngStart);
		return o + y;
	}

	static var objsizeReached:Bool;

	@:hxmc.unsafe public static function reached():Bool
		return objsizeReached;

	static inline function inHeap(p:Ptr):Bool
		return !p.isNull() && (inYoung(p) || inOld(p));

	// a set of addresses: (keys, capacity, length) at s; open addressing
	@:hxmc.unsafe static function psetNew(s:Ptr, cap:Int) {
		var k = LibC.malloc((cap : I64) * 8);
		LibC.memset(k, 0, (cap : I64) * 8);
		Mem.setPtr(s, 0, k);
		Mem.setI64(s, 8, cap);
		Mem.setI64(s, 16, 0);
	}

	@:hxmc.unsafe static function psetSlot(keys:Ptr, cap:I64, p:Ptr):Int {
		var h = (p.toI64() >>> 3) * (((0x9E3779B9 : I64) << 32) | ((0x7F4A7C15 : I64) & 0xFFFFFFFF));
		var i = (h & (cap - 1)).toInt();
		while (true) {
			var k = Mem.getPtr(keys, 8 * i);
			if (k.isNull() || k == p) return i;
			i = ((i + 1 : I64) & (cap - 1)).toInt();
		}
	}

	// adds p; false if it was there already
	@:hxmc.unsafe static function psetAdd(s:Ptr, p:Ptr):Bool {
		var cap = Mem.getI64(s, 8), len = Mem.getI64(s, 16);
		if ((len + 1) * 2 > cap) {
			var keys = Mem.getPtr(s, 0);
			var ncap = cap * 2;
			var nk = LibC.malloc(ncap * 8);
			LibC.memset(nk, 0, ncap * 8);
			for (i in 0...cap.toInt()) {
				var k = Mem.getPtr(keys, 8 * i);
				if (!k.isNull()) Mem.setPtr(nk, 8 * psetSlot(nk, ncap, k), k);
			}
			LibC.free(keys);
			Mem.setPtr(s, 0, nk);
			Mem.setI64(s, 8, ncap);
			cap = ncap;
		}
		var keys = Mem.getPtr(s, 0);
		var i = psetSlot(keys, cap, p);
		if (!Mem.getPtr(keys, 8 * i).isNull()) return false;
		Mem.setPtr(keys, 8 * i, p);
		Mem.setI64(s, 16, len + 1);
		return true;
	}

	@:hxmc.unsafe static function psetHas(s:Ptr, p:Ptr):Bool {
		var keys = Mem.getPtr(s, 0);
		return !Mem.getPtr(keys, 8 * psetSlot(keys, Mem.getI64(s, 8), p)).isNull();
	}

	@:hxmc.unsafe static function psetAddArray(s:Ptr, a:Dynamic) {
		var ap = Mem.addr(a);
		if (ap.isNull() || Mem.getI32(ap, 4) != Types.AK_PTR) return;
		var d = Mem.getPtr(ap, 8);
		if (d.isNull()) return;
		for (i in 0...Mem.getI32(ap, 0)) {
			var v = Mem.getPtr(d, 8 * i);
			if (!v.isNull()) psetAdd(s, v);
		}
	}

	// the bytes of the heap objects reachable from v, headers included,
	// without entering the objects of the array `exclude`; reaching an object
	// of the array `out` sets the flag reached() returns (and is not entered
	// either). Objects outside the heap (static data) are neither counted nor entered.
	@:hxmc.unsafe public static function objsize(v:Dynamic, exclude:Dynamic, out:Dynamic):Float {
		var seen = Mem.stack(24), ex = Mem.stack(24), outs = Mem.stack(24);
		psetNew(seen, 1024);
		psetNew(ex, 64);
		psetNew(outs, 64);
		psetAddArray(ex, exclude);
		psetAddArray(outs, out);
		var sp = 0, cap = 1024;
		var stack = LibC.malloc((cap : I64) * 8);
		var bytes = 0.0;
		objsizeReached = false;
		var vp = Mem.addr(v);
		if (inHeap(vp)) Mem.setPtr(stack, 8 * sp++, vp);
		while (sp > 0) {
			var o = Mem.getPtr(stack, 8 * --sp);
			if (psetHas(ex, o)) continue;
			if (psetHas(outs, o)) {
				objsizeReached = true;
				continue;
			}
			if (!psetAdd(seen, o)) continue;
			bytes += objBytes(o);
			var n = nslotsOf(o), k = kindOf(o);
			var pm = k == K_OBJ ? ptrmapOf(o) : Ptr.nil();
			var lim = !pm.isNull() && compactAt(tindexOf(o)) ? n + cmapHalves(n) : n;
			for (i in 0...lim) {
				if (i >= n) {
					if (!isCompactHalf(pm, i - n)) continue;
				} else if (k == K_OBJ) {
					if (pm.isNull() || !isPtrSlot(pm, i)) continue;
				} else if (k != K_PARR)
					break;
				var c = i >= n ? getC(o, cmapHalf(n, i - n)) : Mem.getPtr(o, 8 * i);
				if (!inHeap(c)) continue;
				if (sp == cap) {
					cap *= 2;
					stack = LibC.realloc(stack, (cap : I64) * 8);
				}
				Mem.setPtr(stack, 8 * sp++, c);
			}
		}
		LibC.free(stack);
		LibC.free(Mem.getPtr(seen, 0));
		LibC.free(Mem.getPtr(ex, 0));
		LibC.free(Mem.getPtr(outs, 0));
		return bytes;
	}

	// ---- the runtime's own roots on the shadow stack (once rt.h's RT_ROOT): o stays
	// alive (and its slot up to date) until popRoots(the first slot)

	@:hxmc.unsafe static function pushRoot(o:Dynamic):Ptr {
		var r = sp;
		sp = r.add(8);
		if (hw.ult(sp)) hw = sp;
		Mem.setRef(r, 0, o);
		return r;
	}

	@:hxmc.unsafe static inline function popRoots(first:Ptr)
		sp = first;
}

// calls through C function pointers (the native handles' free functions)
@:hxmc.c @:hxmc.fast private extern class Ind {
	@:hxmc.indirect static function call0(f:Ptr):Ptr;
	@:hxmc.indirect static function call1(f:Ptr, a:Ptr):Ptr;
	@:hxmc.indirect static function call2(f:Ptr, a:Ptr, b:Ptr):Ptr;
	@:hxmc.indirect static function call3(f:Ptr, a:Ptr, b:Ptr, c:Ptr):Ptr;
}
