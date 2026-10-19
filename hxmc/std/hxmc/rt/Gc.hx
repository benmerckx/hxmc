package hxmc.rt;

import hxmc.I64;
import hxmc.rt.Layouts as L;
import hxmc.rt.Threads.Mutator;
import hxmc.rt.Os.Report;
import hxmc.rt.C;
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
// Tls values and current exceptions, and the finalisers.
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
// and NativeGc's entry points is @:hxmc.noGc: it runs while objects move,
// with raw addresses.
@:hxmc.native @:keep @:allow(hxmc.rt)
class Gc {
	static inline var K_OBJ = 0;
	static inline var K_PARR = 1;
	static inline var K_RAW = 2;
	static inline var K_FWD = 15;
	static inline var T_NATIVE = 16; // a native handle
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
	// oldEnd is a soft limit, set after each major collection to three times
	// the live size
	static var oldStart:Ptr;
	@:hxmc.export("hxmc_old_ptr") static var oldPtr:Ptr;
	static var oldEnd:Ptr;
	// 16 GB each; on Windows they are 2 GB by default (RT_REGION_MB), and a
	// reservation that fails is retried at half the size down to 512 MB
	static var regionBytes:I64;
	static var region0:Ptr;
	static var region1:Ptr;
	static var curRegion:Int;
	static var fromStart:Ptr;
	static var fromEnd:Ptr;
	static var releasePages:Bool;

	@:hxmc.export("rt_globals") static var globals:Ptr;
	static var nglobals:Int;

	static var stats:Bool;
	static var minors:Int;
	static var majors:Int;
	static var minorSecs:Float; // RT_STATS
	static var youngBytes:I64; // RT_STATS: allocated in the nursery, and promoted from it
	static var promotedBytes:I64;
	static var majorSecs:Float;

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

	// ---- objects (the header word at -8; slot count bits 0..27, kind
	// 28..31, type index 32..47)

	static inline function hdrLo(p:Ptr):Int
		return Mem.getI32(p, -8);

	static inline function nslotsOf(p:Ptr):Int
		return hdrLo(p) & 0x0FFFFFFF;

	static inline function kindOf(p:Ptr):Int
		return (hdrLo(p) >>> 28) & 15;

	static inline function objBytes(p:Ptr):Int
		return 8 * (nslotsOf(p) + 1);

	// the type's pointer map (a bit per slot), or null
	static inline function ptrmapOf(p:Ptr):Ptr
		return Types.ptrmap(Types.ty(Mem.getU16(p, -4)));

	static inline function isPtrSlot(pm:Ptr, i:Int):Bool
		return ((Mem.getI32At(pm, 0, i >> 5) >>> (i & 31)) & 1) != 0;

	static inline function inYoung(p:Ptr):Bool
		return !p.ult(youngStart) && p.ult(youngEnd);

	static inline function inFrom(p:Ptr):Bool
		return !p.ult(fromStart) && p.ult(fromEnd);

	static inline function inOld(p:Ptr):Bool
		return !p.ult(oldStart) && p.ult(oldPtr);

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
	@:hxmc.noGc static function copyOut(p:Ptr):Ptr
		return copyIn(p);

	// (inline in the drain loops: no call per copied object)
	static inline function copyIn(p:Ptr):Ptr {
		var lo = hdrLo(p);
		return if ((lo >>> 28) & 15 == K_FWD) Mem.getPtr(p, 0) else copyTo(p, lo);
	}

	static inline function copyTo(p:Ptr, lo:Int):Ptr {
		var words = (lo & 0x0FFFFFFF) + 1;
		var dst = oldPtr, s = p.add(-8);
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
		Mem.setI32(p, -8, (lo & 0x0FFFFFFF) | (K_FWD << 28));
		Mem.setPtr(p, 0, n);
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
	@:hxmc.noGc static function fwdAs(p:Ptr, root:Bool):Ptr
		return root ? fwdRoot(p) : fwd(p);

	// (few values live across the copies' calls: they stay in registers; one
	// loop per forwarding)
	@:hxmc.noGc static function drain()
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
	@:hxmc.noGc static function drainMinor() {
		while (gcTop > 0) {
			if (gcTop + SMALL_SLOTS + 1 > gcCap) reserve(gcTop + SMALL_SLOTS + 1);
			var top = gcTop - 1;
			var o = Mem.getPtr(gcStack, top << 4);
			var lo = hdrLo(o);
			if (lo & 0x0FFFFFFF > SMALL_SLOTS)
				scanLarge(o);
			else {
				// (gcTop: where its children go, until they are reversed)
				gcTop = top;
				pushed(scanYoung(o, lo, top));
			}
		}
	}

	static inline var SMALL_SLOTS = 32;

	// a large object on top of the stack: its next LARGE_SLICE slots (from
	// the entry's slot index), the entry left below the children they push
	// while slots remain
	@:hxmc.noGc static function scanLarge(o:Ptr) {
		if (gcTop + LARGE_SLICE > gcCap) reserve(gcTop + LARGE_SLICE);
		var at = gcTop - 1;
		var e = gcStack.add(at << 4);
		var lo = hdrLo(o);
		var n = lo & 0x0FFFFFFF;
		var pm = Ptr.nil();
		if (lo >>> 28 == K_OBJ) {
			pm = ptrmapOf(o);
			if (pm.isNull()) {
				gcTop = at;
				return;
			}
		} else if (lo >>> 28 != K_PARR) { // (raw: a root fwdRoot pushed)
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
			if (i == 0 && Mem.getU16(o, -4) == Types.T_NATIVE_ARRAY) i = 1;
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

	// o's young children copied, pushed from gcStack[top] (which has room
	// for all of them): the new top
	static inline function scanYoung(o:Ptr, lo:Int, top:Int):Int {
		var t = top;
		var n = lo & 0x0FFFFFFF;
		var k = lo >>> 28;
		if (k == K_OBJ) {
			// (at most SMALL_SLOTS slots: one word of the map)
			var pm = ptrmapOf(o);
			var m = pm.isNull() ? 0 : Mem.getI32(pm, 0);
			var i = 0;
			while (m != 0) {
				if (m & 1 != 0) t = minorSlot(o, i, t);
				m = m >>> 1;
				i++;
			}
		} else if (k == K_PARR) {
			var i = Mem.getU16(o, -4) == Types.T_NATIVE_ARRAY ? 1 : 0;
			while (i < n) {
				t = minorSlot(o, i, t);
				i++;
			}
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
	static inline function minorSlot(o:Ptr, i:Int, top:Int):Int {
		var t = top;
		var v = Ptr.ofI64(Mem.getI64At(o, 0, i));
		if (!v.ult(youngStart) && v.ult(youngEnd)) {
			var vlo = hdrLo(v);
			if (vlo >>> 28 == K_FWD)
				Mem.setI64At(o, 0, i, Mem.getI64(v, 0));
			else {
				// (copyTo, without the call of memcpy)
				var words = (vlo & 0x0FFFFFFF) + 1;
				var dst = oldPtr;
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
				oldPtr = dst.add(words << 3);
				var nv = dst.add(8);
				Mem.setI32(v, -8, (vlo & 0x0FFFFFFF) | (K_FWD << 28));
				Mem.setPtr(v, 0, nv);
				Mem.setI64At(o, 0, i, nv.toI64());
				if (vlo >>> 28 == K_OBJ || vlo >>> 28 == K_PARR) {
					Mem.setPtr(gcStack, t << 4, nv);
					Mem.setI32(gcStack, (t << 4) + 8, 0);
					t++;
				}
			}
		}
		return t;
	}

	// room for this many entries on the collector's stack
	@:hxmc.noGc static function reserve(entries:Int) {
		while (gcCap < entries)
			gcCap *= 2;
		gcStack = LibC.realloc(gcStack, (gcCap : I64) * 16);
	}

	@:hxmc.noGc static function drainMajor()
		drainWith(true);

	static inline function drainWith(maj:Bool) {
		while (gcTop > 0) {
			var o = Mem.getPtr(gcStack, (gcTop - 1) << 4);
			var lo = hdrLo(o);
			var k = lo >>> 28; // (never forwarded: copied just now)
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
			var n = lo & 0x0FFFFFFF;
			var i = Mem.getI32(gcStack, ((gcTop - 1) << 4) + 8);
			if (i == 0 && k == K_PARR && Mem.getU16(o, -4) == Types.T_NATIVE_ARRAY) i = 1;
			var pushed = false;
			while (i < n) {
				if (!pm.isNull() && (Mem.getI32At(pm, 0, i >> 5) >>> (i & 31)) & 1 == 0) {
					i++;
					continue;
				}
				var v = Ptr.ofI64(Mem.getI64At(o, 0, i));
				i++;
				if (v.isNull()) continue;
				// (branches rather than inYoung(v) || inFrom(v): no booleans in registers)
				if (v.ult(youngStart) || !v.ult(youngEnd)) {
					if (!maj) continue;
					if (v.ult(fromStart) || !v.ult(fromEnd)) continue;
				}
				var vlo = hdrLo(v);
				if ((vlo >>> 28) & 15 == K_FWD) {
					Mem.setI64At(o, 0, i - 1, Mem.getI64(v, 0));
					continue;
				}
				// copied now: its subtree next
				var nv = copyTo(v, vlo);
				Mem.setI64At(o, 0, i - 1, nv.toI64());
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

	@:hxmc.noGc static function grow() {
		gcCap *= 2;
		gcStack = LibC.realloc(gcStack, (gcCap : I64) * 16);
	}

	@:hxmc.noGc static function fwdRoot(p:Ptr):Ptr {
		var before = oldPtr;
		var n = fwd(p);
		if (oldPtr != before) {
			push(n);
			drain();
		}
		return n;
	}

	@:hxmc.noGc static function scanObject(o:Ptr, root:Bool) {
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
			case K_PARR:
				for (i in (Mem.getU16(o, -4) == Types.T_NATIVE_ARRAY ? 1 : 0)...n) {
					var v = Mem.getPtr(o, 8 * i);
					if (!v.isNull()) Mem.setPtr(o, 8 * i, fwdAs(v, root));
				}
			case _:
		}
	}

	// the breadth-first scan of what was copied from `scan` on
	@:hxmc.noGc static function scanFrom(scan:Ptr) {
		while (scan.ult(oldPtr)) {
			var o = scan.add(8);
			scan = scan.add(objBytes(o));
			scanObject(o, false);
		}
	}

	@:hxmc.noGc static function scanStack(base:Ptr, top:Ptr, root:Bool) {
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
	@:hxmc.noGc static function scanRoots(root:Bool) {
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
	}

	// ---- remembered sets: every started thread's, and the ended threads'

	@:hxmc.noGc static function forgetObjs(m:Ptr<Mutator>) {
		m.value.robjsLen = 0;
		LibC.memset(m.value.recent, 0, 8 * 256);
	}

	@:hxmc.noGc static function forwardRemembered(m:Ptr<Mutator>, root:Bool) {
		var rem = m.value.rem;
		for (i in 0...m.value.remLen) {
			var s = Mem.getPtr(rem, 8 * i);
			var v = Mem.getPtr(s, 0);
			if (!v.isNull()) Mem.setPtr(s, 0, fwdAs(v, root));
		}
		m.value.remLen = 0;
		for (i in 0...m.value.robjsLen)
			scanObject(Mem.getPtr(m.value.robjs, 8 * i), root);
		forgetObjs(m);
	}

	@:hxmc.noGc static function forwardAllRemembered(root:Bool) {
		var t = Threads.allThreads;
		while (!t.isNull()) {
			if (t.value.started != 0) forwardRemembered(t, root);
			t = t.value.next;
		}
		forwardRemembered(Threads.deadMut, root);
	}

	@:hxmc.noGc static function clearAllRemembered() {
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

	// ---- native handles

	// a T_NATIVE object holding the C resource p (slot 0) and nrefs reference
	// slots after it (slots 1..nrefs, null at first, set through the write
	// barrier: what the C resource points into stays alive while the handle
	// does; the object is then K_PARR, and slot 0, outside the heap, is left
	// alone by the collector); freeFn(p) (a no-GC @:hxmc.callback or a C
	// function) frees p once it is unreachable
	@:hxmc.host("rt_native_new_refs") static function nativeNew(p:Ptr, freeFn:Ptr, nrefs:Int):Dynamic {
		var o:Dynamic = Mem.alloc(1 + nrefs, T_NATIVE, nrefs > 0 ? K_PARR : K_RAW);
		nativeRegister(o, p, freeFn);
		return o;
	}

	@:hxmc.noGc static function nativeRegister(o:Dynamic, p:Ptr, freeFn:Ptr) {
		Mem.setPtr(Mem.addr(o), 0, p);
		lockLeaf(nativesLock);
		if (nnatives == nativesCap) {
			nativesCap = nativesCap == 0 ? 256 : nativesCap * 2;
			natives = LibC.realloc(natives, (nativesCap : I64) * 24);
		}
		var e = natives.add(24 * nnatives);
		Mem.setPtr(e, 0, Mem.addr(o));
		Mem.setPtr(e, 8, p);
		Mem.setPtr(e, 16, freeFn);
		nnatives++;
		unlockLeaf(nativesLock);
	}

	// after a collection of the nursery (and of [lo, hi) for a major one). The
	// handles found dead together are freed newest first: a resource that
	// points into another one (an SSL context into its configuration) is
	// usually created after it.
	@:hxmc.noGc static function sweepNatives(lo:Ptr, hi:Ptr) {
		var live = 0, ndead = 0;
		for (i in 0...nnatives) {
			var e = natives.add(24 * i);
			var o = Mem.getPtr(e, 0);
			if (inYoung(o) || (!o.ult(lo) && o.ult(hi))) {
				if (kindOf(o) != K_FWD) {
					if (ndead == deadCap) {
						deadCap = deadCap == 0 ? 64 : deadCap * 2;
						deadNatives = LibC.realloc(deadNatives, (deadCap : I64) * 24);
					}
					LibC.memcpy(deadNatives.add(24 * ndead), e, 24);
					ndead++;
					continue;
				}
				o = Mem.getPtr(o, 0);
			}
			var d = natives.add(24 * live);
			if (d != e) LibC.memcpy(d, e, 24);
			Mem.setPtr(d, 0, o);
			live++;
		}
		nnatives = live;
		while (ndead > 0) {
			ndead--;
			var e = deadNatives.add(24 * ndead);
			Ind.call1(Mem.getPtr(e, 16), Mem.getPtr(e, 8));
		}
	}

	// ---- collections

	@:hxmc.noGc static function minor() {
		var t0 = stats ? Os.now() : 0.0;
		var m0 = majors;
		minorCollect();
		if (majors == m0) sweepNatives(Ptr.nil(), Ptr.nil());
		if (stats && majors == m0) minorSecs += Os.now() - t0;
	}

	@:hxmc.noGc static function minorCollect() {
		var youngUsed = youngNext.diff(youngStart);
		if (oldEnd.diff(oldPtr) < youngUsed + 64) {
			majorAndTime(0);
			return;
		}
		minors++;
		var scan = oldPtr;
		major = false;
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

	@:hxmc.noGc static function majorAndTime(need:I64) {
		var t0 = stats ? Os.now() : 0.0;
		majorCollect(need);
		if (stats) majorSecs += Os.now() - t0;
	}

	@:hxmc.noGc static function majorCollect(need:I64) {
		majors++;
		#if hxmc.gc_prefault
		if (pfState > 0) prefaultCancel();
		#end
		fromStart = oldStart;
		fromEnd = oldPtr;
		curRegion ^= 1;
		oldStart = region(curRegion);
		oldPtr = oldStart;
		var scan = oldPtr;
		major = true;
		scanRoots(!gcBfs);
		clearAllRemembered();
		if (gcBfs) scanFrom(scan);
		if (nfinals > 0) {
			// values not copied yet are unreachable: queue their calls (newest
			// first), then copy them and what they reach
			var live = 0, q0 = finalQlen;
			var i = nfinals;
			while (i-- > 0) {
				var v = Mem.getPtr(finals, 16 * i + 8);
				if ((inYoung(v) || inFrom(v)) && kindOf(v) != K_FWD) {
					if (finalQlen == finalQcap) {
						finalQcap = finalQcap == 0 ? 64 : finalQcap * 2;
						finalQueue = LibC.realloc(finalQueue, (finalQcap : I64) * 16);
					}
					LibC.memcpy(finalQueue.add(16 * finalQlen), finals.add(16 * i), 16);
					finalQlen++;
					Mem.setPtr(finals, 16 * i, Ptr.nil());
				}
			}
			for (i in 0...nfinals)
				if (!Mem.getPtr(finals, 16 * i).isNull()) {
					var v = Mem.getPtr(finals, 16 * i + 8);
					if (inYoung(v) || inFrom(v)) v = Mem.getPtr(v, 0);
					Mem.setPtr(finals, 16 * live, Mem.getPtr(finals, 16 * i));
					Mem.setPtr(finals, 16 * live + 8, v);
					live++;
				}
			nfinals = live;
			for (i in q0...finalQlen) {
				var v = Mem.getPtr(finalQueue, 16 * i + 8);
				Mem.setPtr(finalQueue, 16 * i + 8, gcBfs ? majorForward(v) : fwdRoot(v));
			}
			if (gcBfs) scanFrom(scan);
		}
		major = false;
		sweepNatives(fromStart, fromEnd);
		// the from-space goes back to the system (RT_RELEASE=0 keeps it
		// resident, so the next major collection copies into faulted-in pages:
		// a little less system time for as much more memory as the old space held)
		if (releasePages) Os.decommit(fromStart, fromEnd.diff(fromStart));
		var live = oldPtr.diff(oldStart);
		var limit = live * 3 + minorSize * 4 + need;
		if (limit < ((64 << 20) : I64)) limit = 64 << 20;
		if (limit > regionBytes) limit = regionBytes;
		oldEnd = oldStart.addL(limit);
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
			r.str(" MB\n");
			r.flush();
		}
		#if hxmc.census
		if (census == 2) censusNow(Mem.cstr("major collection"));
		#end
	}

	// The nursery: a reserved range (pages committed as touched) that it grows
	// and shrinks in, so resizing allocates nothing.
	@:hxmc.noGc static function nurseryAlloc(bytes:I64):Ptr {
		var reserve:I64 = bytes > (MINOR_MAX : I64) ? bytes : MINOR_MAX;
		var p = Os.reserve(reserve + (2 << 20));
		if (p.isNull()) die("cannot reserve the nursery\n");
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
	@:hxmc.noGc static function resizeNursery(size:I64) {
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
	@:hxmc.noGc static function adaptNursery(promoted:I64, used:I64, threads:Int) {
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
	@:hxmc.noGc static function adaptThreads(n:Int) {
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
	@:hxmc.noGc static function zeroAbove(m:Ptr<Mutator>) {
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
	// collection the helper is asked for the pages up to as much past the
	// end of the old space as the collection promoted (PF_MIN to PF_MAX); it
	// touches each page with an atomic addition of zero, which leaves a word
	// the collector or an allocation of a large object writes meanwhile as
	// it is. It starts once the old space passes PF_START (small programs
	// never start it), and a major collection drops what is left of its
	// requests (pfGen). It never runs Haxe code: it is no mutator,
	// collections do not wait for it.
	static inline var PF_START = 64 << 20;
	static inline var PF_MIN = 4 << 20;
	static inline var PF_MAX = 16 << 20;
	static inline var PF_STEP = 256 << 10;
	static var pfState:Int; // 0: not started, 1: started, -1: none
	static var pfLock:Ptr;
	static var pfCond:Ptr;
	static var pfFrom:Ptr; // the pages to touch: [pfFrom, pfTo) (under pfLock)
	static var pfTo:Ptr;
	@:hxmc.export("hxmc_pf_gen") static var pfGen:Int; // major collections (Atomic)

	// after a minor collection that promoted `promoted` bytes
	@:hxmc.noGc static function prefaultAhead(promoted:I64) {
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
		var ahead = promoted < (PF_MIN : I64) ? (PF_MIN : I64) : promoted > (PF_MAX : I64) ? (PF_MAX : I64) : promoted;
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
	@:hxmc.noGc static function prefaultCancel() {
		Os.lock(pfLock);
		Atomic.add32(Mem.sym("hxmc_pf_gen"), 1);
		pfFrom = Ptr.nil();
		pfTo = Ptr.nil();
		Os.unlock(pfLock);
	}

	// the helper thread: PF_STEP of the requested pages at a time
	@:hxmc.callback @:hxmc.noGc static function prefaulter(arg:Ptr):Ptr {
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
		}
		return Ptr.nil();
	}
	#end

	// a collection, with every other thread stopped (unless another thread
	// collected meanwhile: the caller then retries its allocation)
	@:hxmc.noGc static function collectFor(full:Bool, need:I64) {
		if (!Threads.worldStop()) return;
		if (youngDirty.ult(youngNext)) youngDirty = youngNext;
		if (full) majorAndTime(need) else {
			var before = oldPtr;
			var m0 = majors;
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
		// the nursery is empty again: every thread takes a new TLAB at its next allocation
		var me = Threads.self;
		var t = Threads.allThreads;
		while (!t.isNull()) {
			if (t.value.started != 0) {
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
		Threads.worldResume();
	}

	// ---- allocation

	// a TLAB with room for `bytes`, zeroed (but under RT_VERIFY: the pattern;
	// the whole free nursery then with one thread). The rest of the thread's
	// TLAB starts it when that was the last one taken (with one thread,
	// always: the free nursery stays contiguous). youngDirty changes only
	// while the world is stopped.
	@:hxmc.noGc static function tlabRefill(bytes:Int):Bool {
		if (myEpoch != epoch) {
			myEpoch = epoch;
			Atomic.add32(Mem.sym("hxmc_allocating"), 1);
		}
		var many = Atomic.load32(Mem.sym("rt_nthreads")) > 1;
		var want:I64 = many ? tlabSize : poison ? ((1 : I64) << 62) : zchunk;
		if (want < bytes) want = bytes;
		var cell = Mem.sym("hxmc_young_next");
		var p = Ptr.ofI64(Atomic.load64(cell));
		while (true) {
			var s = !yptr.isNull() && p == yrlim ? yptr : p;
			var avail = youngEnd.diff(s);
			if (avail < bytes) return false;
			var e = s.addL(want < avail ? want : avail);
			// with several threads, a TLAB that reaches untouched memory (above
			// youngDirty: fresh pages, after a start or a growth) ends at a 2 MB
			// boundary, so that threads do not fault in the same 2 MB together:
			// with transparent huge pages, each of them would get a huge page
			// of its own, zeroed by the kernel, all but one thrown away (the
			// tool's code generation, its nursery growing to 256 MB under 12
			// threads: 1.5 s of kernel time). Fresh pages need no zeroing of
			// ours, so the larger TLAB costs nothing but its share of the nursery
			if (many && youngDirty.ult(e)) {
				var x = e.toI64() + (HUGE_PAGE - 1);
				e = Ptr.ofI64(x - (x & (HUGE_PAGE - 1))); // (the nursery starts 2 MB aligned)
				if (youngEnd.ult(e)) e = youngEnd;
			}
			var seen = Ptr.ofI64(Atomic.cas64(cell, p.toI64(), e.toI64()));
			if (seen == p) {
				// (below p: the rest of the thread's TLAB, zeroed already)
				if (!poison && p.ult(youngDirty)) Mem.zero(p, (e.ult(youngDirty) ? e : youngDirty).diff(p));
				yptr = s;
				yrlim = e;
				ylim = poison ? Ptr.nil() : e;
				return true;
			}
			p = seen;
		}
	}

	// room for `bytes` in the thread's TLAB, refilled if needed (false: the nursery is full)
	static inline function youngRoom(bytes:Int):Bool
		return yrlim.diff(yptr) >= bytes || tlabRefill(bytes);

	@:hxmc.host("rt_alloc_slow") @:hxmc.collects static function allocSlow(header:I64, bytes:Int):Ptr {
		// a safepoint: the caller's live references are rooted here
		Threads.safepoint();
		// likewise for finaliser calls queued by an earlier major collection
		if (finalQlen != 0 && finalsRunning == 0) callFinalisers(false);
		return allocNow(header, bytes);
	}

	@:hxmc.noGc static function allocNow(header:I64, bytes:Int):Ptr {
		var p:Ptr;
		// large objects go straight to the old space (with one thread, unless
		// the free nursery has room: they may die young)
		if ((bytes : I64) > (minorSize >> 2) && !(Atomic.load32(Mem.sym("rt_nthreads")) == 1 && youngRoom(bytes))) {
			var cell = Mem.sym("hxmc_old_ptr");
			p = Ptr.ofI64(Atomic.load64(cell));
			while (true) {
				if (oldEnd.diff(p) < bytes) {
					collectFor(true, bytes);
					p = Ptr.ofI64(Atomic.load64(cell));
					continue;
				}
				var seen = Ptr.ofI64(Atomic.cas64(cell, p.toI64(), p.add(bytes).toI64()));
				if (seen == p) break;
				p = seen;
			}
		} else {
			while (!youngRoom(bytes))
				collectFor(false, 0); // (room already: another thread collected meanwhile)
			p = yptr;
			yptr = p.add(bytes);
			Mem.setI64(p, 0, header);
			// (zeroed with its TLAB, but for the pattern of RT_VERIFY)
			if (poison) LibC.memset(p.add(8), 0, bytes - 8);
			return p.add(8);
		}
		Mem.setI64(p, 0, header);
		LibC.memset(p.add(8), 0, bytes - 8);
		return p.add(8);
	}

	// ---- the write barrier's slow path (generated code's inline part and
	// GcPaths: obj is old, the slot now holds a young pointer and held none)

	@:hxmc.host("rt_write_barrier") @:hxmc.noGc static function writeBarrier(obj:Ptr, slot:Ptr, v:Ptr):Void
		remember(slot);

	@:hxmc.noGc static inline function remember(slot:Ptr) {
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
	@:hxmc.noGc static function rememberObj(obj:Ptr) {
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

	// after a bulk move or copy of references into obj (memmove in natives):
	// the remembered set records slots, so every slot now holding a young
	// pointer is recorded again. A long range (e.g. Array.insert at the front
	// of a large array, as the port does for OCaml's `x :: l`) remembers the
	// whole object once instead: recording its slots made the set grow by the
	// array's length at every insertion (16M entries, 128 MB, on the
	// self-compile).
	@:hxmc.host("rt_barrier_range") @:hxmc.noGc static function barrierRange(obj:Dynamic, from:Ptr, n:Int):Void {
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
	@:hxmc.noGc public static function finalise(fn:Dynamic, val:Dynamic):Void {
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
	@:hxmc.collects public static function collect(full:Bool):Void
		collectFor(full, 0);

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
	@:hxmc.noGc static function dequeue():Int {
		lockLeaf(finalsLock);
		if (finalQhead >= finalQlen) {
			unlockLeaf(finalsLock);
			return -1;
		}
		return finalQhead;
	}

	@:hxmc.noGc static function dequeued(i:Int) {
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

	@:hxmc.noGc static function init(ng:Int):Ptr {
		var m = Os.getenv("RT_MINOR_KB");
		minorFixed = !m.isNull();
		minorSize = minorFixed ? (Os.atoi(m) : I64) << 10 : (MINOR_MIN : I64);
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
		var i = 0;
		while (i < 2) {
			var r = Os.reserve(regionBytes);
			if (r.isNull() && regionBytes > ((512 : I64) << 20)) {
				if (i == 1) Os.release(region0, regionBytes);
				regionBytes = regionBytes / 2;
				i = 0;
				continue;
			}
			if (r.isNull()) die("cannot reserve heap\n");
			if (hugePages) Os.hugePages(r, regionBytes);
			if (i == 0) region0 = r else region1 = r;
			i++;
		}
		oldStart = region0;
		oldPtr = region0;
		oldEnd = oldStart.addL((Os.envInt("RT_OLD_MB", 256) : I64) << 20); // fewer major collections early on
		if (oldStart.addL(regionBytes).ult(oldEnd)) oldEnd = oldStart.addL(regionBytes);
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
		sp = sstack;
		hw = sstack;
		nglobals = ng;
		gcCap = 4096;
		gcStack = LibC.malloc((gcCap : I64) * 16);
		finalsLock = LibC.malloc(Os.MUTEX_BYTES);
		Os.mutexInit(finalsLock);
		nativesLock = LibC.malloc(Os.MUTEX_BYTES);
		Os.mutexInit(nativesLock);
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
	@:hxmc.noGc public static function releaseHeap() {
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

	@:hxmc.noGc static function dieC(msg:Ptr) {
		var r = new Report(Mem.stack(Report.BYTES));
		r.cstr(msg, 0, -1);
		r.flush();
		Os.exit(2);
	}

	// ---- reports (atexit: RT_STATS, the census)

	// RSS and its peak in KB, from /proc (Linux; 0 elsewhere)
	@:hxmc.noGc static function procRss(out:Ptr) {
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
	@:hxmc.noGc static function startsWith(p:Ptr, s:Ptr):Bool {
		var i = 0;
		while (Mem.getU8(s, i) != 0) {
			if (Mem.getU8(p, i) != Mem.getU8(s, i)) return false;
			i++;
		}
		return true;
	}

	@:hxmc.callback @:hxmc.noGc static function report():Void {
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
			census = 0;
			majorAndTime(0);
			censusNow(Mem.cstr("exit"));
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
			r.str(" MB\n");
			r.flush();
		}
	}

	#if hxmc.census
	// a debug build (-D hxmc.census): RT_CENSUS=1, a census of the heap at
	// exit; 2, also after each major collection (Census)
	static var census:Int;

	@:hxmc.noGc static function censusNow(when:Ptr) {
		var me = Threads.self;
		Census.run(oldStart, oldPtr, when, minorSize, oldEnd.diff(oldStart), (me.value.remCap + me.value.robjsCap : I64) * 8,
			(gcCap : I64) * 16, sp.diff(me.value.base), minors, majors, nglobals);
	}
	#end

	// ---- hxmc.NativeGc's measurements (the port's server/memory, in place
	// of OCaml's Objsize and Gc heap words)

	// the bytes the heap spaces take
	@:hxmc.noGc public static function heapBytes():Float {
		var o:Float = cast oldEnd.diff(oldStart);
		var y:Float = cast youngEnd.diff(youngStart);
		return o + y;
	}

	static var objsizeReached:Bool;

	@:hxmc.noGc public static function reached():Bool
		return objsizeReached;

	static inline function inHeap(p:Ptr):Bool
		return !p.isNull() && (inYoung(p) || inOld(p));

	// a set of addresses: (keys, capacity, length) at s; open addressing
	@:hxmc.noGc static function psetNew(s:Ptr, cap:Int) {
		var k = LibC.malloc((cap : I64) * 8);
		LibC.memset(k, 0, (cap : I64) * 8);
		Mem.setPtr(s, 0, k);
		Mem.setI64(s, 8, cap);
		Mem.setI64(s, 16, 0);
	}

	@:hxmc.noGc static function psetSlot(keys:Ptr, cap:I64, p:Ptr):Int {
		var h = (p.toI64() >>> 3) * (((0x9E3779B9 : I64) << 32) | ((0x7F4A7C15 : I64) & 0xFFFFFFFF));
		var i = (h & (cap - 1)).toInt();
		while (true) {
			var k = Mem.getPtr(keys, 8 * i);
			if (k.isNull() || k == p) return i;
			i = ((i + 1 : I64) & (cap - 1)).toInt();
		}
	}

	// adds p; false if it was there already
	@:hxmc.noGc static function psetAdd(s:Ptr, p:Ptr):Bool {
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

	@:hxmc.noGc static function psetHas(s:Ptr, p:Ptr):Bool {
		var keys = Mem.getPtr(s, 0);
		return !Mem.getPtr(keys, 8 * psetSlot(keys, Mem.getI64(s, 8), p)).isNull();
	}

	@:hxmc.noGc static function psetAddArray(s:Ptr, a:Dynamic) {
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
	@:hxmc.noGc public static function objsize(v:Dynamic, exclude:Dynamic, out:Dynamic):Float {
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
			for (i in 0...n) {
				if (k == K_OBJ) {
					if (pm.isNull() || !isPtrSlot(pm, i)) continue;
				} else if (k != K_PARR)
					break;
				if (i == 0 && Mem.getU16(o, -4) == Types.T_NATIVE_ARRAY) continue;
				var c = Mem.getPtr(o, 8 * i);
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

	@:hxmc.noGc static function pushRoot(o:Dynamic):Ptr {
		var r = sp;
		sp = r.add(8);
		if (hw.ult(sp)) hw = sp;
		Mem.setRef(r, 0, o);
		return r;
	}

	@:hxmc.noGc static inline function popRoots(first:Ptr)
		sp = first;
}

// calls through C function pointers (the native handles' free functions)
@:hxmc.c @:hxmc.fast private extern class Ind {
	@:hxmc.indirect static function call1(f:Ptr, a:Ptr):Ptr;
}
