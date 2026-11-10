package hxmc.rt;

import hxmc.I64;
import hxmc.rt.C;
import hxmc.rt.GcCore.*;
import hxmc.unsafe.*;

// Foreign objects (docs/plans/foreign-objects.md): the objects of a
// reference-counted object system outside the heap (Objective-C's, COM's,
// GObject's, a JVM's through JNI), held by Haxe objects. What does not
// depend on the system is here; a system is a kind, a row of the kind
// table: its hooks (C functions: libobjc's, or @:hxmc.callback
// @:hxmc.unsafe ones of the runtime or of a program) and its flags. Nothing
// in the collector names a kind: it calls scan (roots) and sweep (after a
// collection), which read the table. Objective-C (ObjCKind) is the first.
//
// - **Peers**: a Haxe object paired with a foreign one (a Haxe class
//   extending a foreign class): (object, reference) entries. The Haxe
//   object's first slot holds the reference (the one its pairing made).
//   As Xamarin's toggle references, an entry is a root exactly while the
//   foreign side retains the object beyond that reference (the kind's
//   toggle: its count above the threshold, or a state the system's
//   notification set), and otherwise weak: its Haxe object found dead, the
//   reference is released and the entry freed (a free entry: a null
//   object, the next free index in the reference's word). Entry 0 is never
//   used: an index of 0 in the foreign object is one the foreign side made,
//   its Haxe object not made yet (FnLower.objcAdopt).
// - **Detached peers** (detach): the Haxe object gives its reference up at
//   once; its entry stays a root while the foreign object lives, tracked by
//   a weak cell of the kind's, and is freed with the Haxe object without a
//   release.
// - **Boxes**: a foreign object where a Haxe reference goes (Dynamic, an
//   element, a type parameter) is its one box, so that == and maps see one
//   object per foreign object: found by the kind's identity key (and its
//   `same` test), a native handle (Gc.nativeNew) holding a reference,
//   released once the box dies.
// - **Owned fields**: a foreign reference in a field of a Haxe object (a
//   closure's capture, a variable's box, a class's field): (object,
//   offset) entries, the field's reference released (or, for a weak field,
//   its cell destroyed) once the object dies. Unowned fields hold the
//   reference only, and have no entry.
// - **Releases** (and every other call into the foreign system the
//   collector makes) happen with the world stopped only for a kind that
//   says it may (RELEASE_IN_STOP: libobjc's release, whose deallocs that
//   run Haxe code put themselves off with defer). Another kind's are put
//   off: queued for a thread (the kind's choice: any, the main one, the one
//   that made the reference), which runs them in a safe region at its next
//   allocation slow path, when Gc.collect returns, or from runDeferred (an
//   event loop's); the kind's wake hook is told when a collection queued
//   calls for another thread.
// - **Pressure**: a peer or a box promoted to the old space keeps its
//   foreign object (memory the heap does not see) until a major collection;
//   RT_PEER_BUDGET of them (1000; 0: off) since the last one start the next.
//
// The tables are malloc'd and guarded by `lock`, taken whatever the
// number of threads (a TOGGLE_NOTIFY kind's notification, a COM or Java
// thread the runtime attached, comes from a thread the runtime may not have
// counted yet); the collector reads them with the world stopped, without
// it. The kind table never moves, so its hooks are read without the lock.
@:hxmc.native @:keep @:allow(hxmc.rt)
class Foreign {
	// ---- a kind's descriptor: a C struct of words (rt_foreign_kind copies it)
	public static inline var K_NAME = 0; // const char *: the kind's name (reports)
	public static inline var K_FLAGS = 8; // the flags below
	public static inline var K_THRESHOLD = 16; // TOGGLE_COUNT, TOGGLE_RELEASE: a count above it keeps the Haxe object
	public static inline var K_RETAIN = 24; // void *retain(void *ref): +1, the reference to store (ref itself, or a new handle)
	public static inline var K_RELEASE = 32; // intptr_t release(void *ref): -1, the count left (TOGGLE_RELEASE; else unused)
	public static inline var K_COUNT = 40; // intptr_t count(void *ref): the count now (TOGGLE_COUNT)
	public static inline var K_IDENTITY = 48; // void *identity(void *ref): the key of its box (null: ref)
	public static inline var K_SAME = 56; // intptr_t same(void *a, void *b): one object (null: equal keys are)
	public static inline var K_PEER = 64; // intptr_t peer(void *ref): its peer entry (-1: none; null: never paired)
	public static inline var K_WEAK_INIT = 72; // void weak_init(void **cell, void *ref)
	public static inline var K_WEAK_LOAD = 80; // void *weak_load(void **cell): +1, or null once it is gone
	public static inline var K_WEAK_DESTROY = 88; // void weak_destroy(void **cell)
	public static inline var K_BATCH_BEGIN = 96; // void *batch_begin(void): around releases (null: none)
	public static inline var K_BATCH_END = 104; // void batch_end(void *token)
	public static inline var K_WAKE = 112; // void wake(intptr_t thread): calls were queued for that thread (null: none)
	public static inline var KIND_BYTES = 120;
	// (the runtime's words after the descriptor: the token of the batch the sweeps run in)
	static inline var K_TOKEN = 120;
	static inline var RECORD = 128;

	// the toggle (at most one): a count read (TOGGLE_COUNT), a count that
	// release returns after a retain (TOGGLE_RELEASE: COM's AddRef/Release),
	// a state the system's notification sets (TOGGLE_NOTIFY: toggle, from
	// GObject's toggle references); none: never kept by the foreign side
	public static inline var TOGGLE_COUNT = 1;
	public static inline var TOGGLE_RELEASE = 2;
	public static inline var TOGGLE_NOTIFY = 4;
	// releases with the world stopped, by the collecting thread (else put off)
	public static inline var RELEASE_IN_STOP = 8;
	// put off releases run on the thread that made the reference (an
	// apartment's), or on the main thread (a UI toolkit's); else on any
	public static inline var RELEASE_ON_MAKER = 16;
	public static inline var RELEASE_ON_MAIN = 32;
	public static inline var MAX_KINDS = 64;

	static var kinds:Ptr; // MAX_KINDS records (index 0 none), never moved
	static var nkinds:Int;
	// a kind registered whose toggle or weak cells are read before the stop
	// (no RELEASE_IN_STOP: beforeStop)
	static var preStop:Bool;
	static var lock:Ptr; // the tables (and kinds' registration)

	// ---- peers: (object, reference, weak cell, kind | STRONG, maker) entries
	static inline var PEER_BYTES = 32;
	static inline var STRONG = 0x100; // the foreign side holds more than our reference (TOGGLE_NOTIFY's notification; beforeStop's toggle)
	static inline var ALIVE = 0x200; // detached, of a kind without RELEASE_IN_STOP: its object lived at beforeStop
	static var peers:Ptr;
	static var npeers:Int;
	static var peersCap:Int;
	static var peerFree:Int; // (-1 from init, Gc.init)
	// a kind per type index (0: none): the types whose objects are paired (refOf)
	static var typeKinds:Ptr;

	// ---- owned fields: (object, offset (a weak field's: -(offset + 1)), kind, maker)
	static inline var OWNED_BYTES = 24;
	static var owned:Ptr;
	static var nowned:Int;
	static var ownedCap:Int;

	// ---- boxes: an open-addressing table of (key, box, kind, maker), its
	// capacity a power of two; rebuilt after a collection (sweepBoxes)
	static inline var BOX_BYTES = 24;
	static var boxes:Ptr;
	static var boxesCap:Int;
	static var nboxes:Int;

	// what a sweep found dead: (reference, kind, maker, weak)
	static inline var DEAD_BYTES = 24;
	static var dead:Ptr;
	static var ndead:Int;
	static var deadCap:Int;

	// ---- calls put off: (function, a, b, kind, thread (0: any)), run as
	// function(a, b) in a safe region inside the kind's batch, newest first
	static inline var DEFER_BYTES = 32;
	static var deferred:Ptr;
	static var ndeferred:Int;
	static var deferredCap:Int;
	static var deferLock:Ptr;
	// the calls queued per thread, read without deferLock (runDeferred's
	// check): a 32-bit count for any thread (0), then PENDING_SLOTS for thread
	// ids modulo PENDING_SLOTS (threads sharing one only look in vain)
	static inline var PENDING_SLOTS = 256;
	static var pending:Ptr;
	// above zero: this thread may make no call into a foreign system now
	// (JNI's critical region: JniKind.arrayCritical), so it runs no calls put
	// off, puts off its releases, and reads no hook before a stop
	@:hxmc.threadLocal static var holdDeferred:Int;
	static var ended:Ptr;
	static var endedCap:Int;
	// (kind, thread) pairs to wake once the world resumes (wakeQueued)
	static var wakes:Ptr;
	static var nwakes:Int;

	// ---- pressure (RT_PEER_BUDGET): peers and boxes gone old since the last major collection
	static var promoted:Int;
	static var atMajor:Int; // (RT_STATS: promoted when the last major started)
	static var budget:Int;

	@:hxmc.unsafe static function init() {
		lock = LibC.malloc(Os.MUTEX_BYTES);
		Os.mutexInit(lock);
		deferLock = LibC.malloc(Os.MUTEX_BYTES);
		Os.mutexInit(deferLock);
		pending = LibC.malloc(4 * (PENDING_SLOTS + 1));
		LibC.memset(pending, 0, 4 * (PENDING_SLOTS + 1));
		peerFree = -1;
		budget = Os.envInt("RT_PEER_BUDGET", 1000);
	}

	// whether a collection has foreign entries to scan or sweep
	static inline function any():Bool
		return npeers > 0 || nowned > 0 || nboxes > 0;

	// ---- kinds

	@:hxmc.unsafe static inline function rec(k:Int):Ptr
		return kinds.add(RECORD * k);

	@:hxmc.unsafe static inline function hook(k:Int, off:Int):Ptr
		return Mem.getPtr(kinds, RECORD * k + off);

	@:hxmc.unsafe static inline function flags(k:Int):Int
		return Mem.getI64(kinds, RECORD * k + K_FLAGS).toInt();

	@:hxmc.unsafe static inline function inStop(k:Int):Bool
		return flags(k) & RELEASE_IN_STOP != 0;

	// a kind made of the descriptor d (KIND_BYTES, copied): its index, from 1
	@:hxmc.unsafe static function register(d:Ptr):Int {
		Os.lock(lock);
		var k = registerLocked(d);
		Os.unlock(lock);
		return k;
	}

	@:hxmc.unsafe static function registerLocked(d:Ptr):Int {
		if (kinds.isNull()) {
			kinds = LibC.malloc(RECORD * MAX_KINDS);
			LibC.memset(kinds, 0, RECORD * MAX_KINDS);
			nkinds = 1;
		}
		if (nkinds == MAX_KINDS) Gc.dieC(Mem.cstr("hxmc: too many kinds of foreign objects\n"));
		var k = nkinds++;
		LibC.memcpy(rec(k), d, KIND_BYTES);
		if (!inStop(k) && (flags(k) & (TOGGLE_COUNT | TOGGLE_RELEASE) != 0 || !hook(k, K_WEAK_LOAD).isNull())) preStop = true;
		return k;
	}

	// one of kind k's hooks replaced (a client that learns its functions late:
	// ObjCKind, from generated code)
	@:hxmc.unsafe static inline function setHook(k:Int, off:Int, f:Ptr)
		Mem.setPtr(kinds, RECORD * k + off, f);

	@:hxmc.unsafe static function batchBegin(k:Int):Ptr {
		var f = hook(k, K_BATCH_BEGIN);
		return f.isNull() ? Ptr.nil() : Ind.call0(f);
	}

	@:hxmc.unsafe static function batchEnd(k:Int, token:Ptr) {
		var f = hook(k, K_BATCH_END);
		if (!f.isNull()) Ind.call1(f, token);
	}

	// around the sweeps: the batch of every kind that releases with the world stopped
	@:hxmc.unsafe static function sweepsBegin() {
		for (k in 1...nkinds)
			if (inStop(k)) Mem.setPtr(rec(k), K_TOKEN, batchBegin(k));
	}

	@:hxmc.unsafe static function sweepsEnd() {
		for (k in 1...nkinds)
			if (inStop(k)) batchEnd(k, Mem.getPtr(rec(k), K_TOKEN));
	}

	@:hxmc.unsafe static inline function me():Int {
		var m = Threads.self;
		return m.isNull() ? 0 : m.value.id;
	}

	// ---- peers

	// o paired with ref, of kind k (o's first slot holds ref); typed: o's
	// type is a class's whose objects are paired (refOf: not a value an
	// Objective-C exception carries, ObjCExceptions). Its entry's index
	static function pair(k:Int, o:Dynamic, ref:Ptr, typed:Bool):Int {
		var p = Mem.addr(o);
		var t = Types.tindex(o);
		var maker = me();
		Os.lock(lock);
		if (typed) {
			if (typeKinds.isNull()) {
				typeKinds = LibC.malloc(65536);
				LibC.memset(typeKinds, 0, 65536);
			}
			Mem.setI8(typeKinds, t, k);
		}
		var i = peerFree;
		if (i >= 0) {
			peerFree = Mem.getPtr(peers, PEER_BYTES * i + 8).toI64().toInt();
		} else {
			if (npeers == peersCap) {
				peersCap = peersCap == 0 ? 64 : peersCap * 2;
				peers = LibC.realloc(peers, (peersCap : I64) * PEER_BYTES);
			}
			if (npeers == 0) {
				LibC.memset(peers, 0, PEER_BYTES);
				npeers = 1;
			}
			i = npeers++;
		}
		var e = peers.add(PEER_BYTES * i);
		Mem.setPtr(e, 0, p);
		Mem.setPtr(e, 8, ref);
		Mem.setPtr(e, 16, Ptr.nil());
		// (a toggle read before the stop: kept until the first read, beforeStop,
		// as one made after it and before the stop must be)
		Mem.setI32(e, 24, countedBefore(k) ? k | STRONG : k);
		Mem.setI32(e, 28, maker);
		// (made in the old space, as large or pretenured objects are: only a
		// major collection frees it, as one promoted: sweepPeers counts those)
		if (!Gc.inYoung(p)) promoted++;
		Os.unlock(lock);
		return i;
	}

	// the Haxe object of entry i (null: a free entry)
	static function peerGet(i:Int):Dynamic {
		Os.lock(lock);
		var p = i >= 0 && i < npeers ? Mem.getPtr(peers, PEER_BYTES * i) : Ptr.nil();
		Os.unlock(lock);
		return Mem.obj(p);
	}

	// TOGGLE_NOTIFY: whether the foreign side holds entry i's object beyond
	// the Haxe object's reference, from the system's notification (any
	// thread, any state: GObject's toggle notify). One that races a
	// collection counts from the next one.
	@:hxmc.unsafe static function toggle(i:Int, strong:Int):Void {
		Os.lock(lock);
		if (i > 0 && i < npeers) {
			var e = peers.add(PEER_BYTES * i);
			var w = Mem.getI32(e, 24);
			Mem.setI32(e, 24, strong != 0 ? w | STRONG : w & ~STRONG);
		}
		Os.unlock(lock);
	}

	// kind k's toggle is a count read by its hooks, which may not be called
	// with the world stopped (no RELEASE_IN_STOP): read before it, beforeStop
	@:hxmc.unsafe static inline function countedBefore(k:Int):Bool
		return flags(k) & (TOGGLE_COUNT | TOGGLE_RELEASE) != 0 && !inStop(k);

	// whether the foreign side keeps entry e's object (k its kind), by its
	// hooks: count, or retain then release
	@:hxmc.unsafe static inline function counted(k:Int, e:Ptr):Bool {
		var f = flags(k);
		var ref = Mem.getPtr(e, 8);
		return if (f & TOGGLE_COUNT != 0) Ind.call1(hook(k, K_COUNT), ref).toI64() > Mem.getI64(rec(k), K_THRESHOLD);
		else if (f & TOGGLE_RELEASE != 0) Ind.call1(hook(k, K_RELEASE), Ind.call1(hook(k, K_RETAIN), ref)).toI64() > Mem.getI64(rec(k), K_THRESHOLD);
		else false;
	}

	// with the world stopped: whether the foreign side keeps entry e's object
	// (k its kind): its hooks for a kind that may be called in the stop, else
	// what was recorded before it (TOGGLE_NOTIFY's notification, beforeStop)
	@:hxmc.unsafe static inline function kept(k:Int, e:Ptr):Bool
		return inStop(k) ? counted(k, e) : Mem.getI32(e, 24) & STRONG != 0;

	// before a collection stops the world, out of the stop, on the thread
	// about to collect (Gc.collectFor): what scan needs to know of the kinds
	// whose hooks may not run in the stop (no RELEASE_IN_STOP: a JVM's may
	// block on its own safepoint, a COM proxy's calls its apartment): the
	// toggle of each of their entries (STRONG) and whether a detached one's
	// object lives (ALIVE, the weak cell loaded, the reference released after
	// the lock, by the kind's thread rule). A change between this and the stop
	// counts from the next collection: an entry paired meanwhile is kept
	// (pair), one detached meanwhile lives (detach), one let go stays one more
	// collection; a retain racing the stop is seen at the next one, as a
	// retain racing the scan of a RELEASE_IN_STOP kind is.
	@:hxmc.unsafe static function beforeStop() {
		var loaded = Ptr.nil();
		var nloaded = 0;
		// (no hook may run on this thread now, holdDeferred: every entry kept)
		var hold = holdDeferred > 0;
		Os.lock(lock);
		for (i in 1...npeers) {
			var e = peers.add(PEER_BYTES * i);
			if (Mem.getPtr(e, 0).isNull()) continue;
			var w = Mem.getI32(e, 24);
			var k = w & 0xFF;
			if (inStop(k)) continue;
			var cell = Mem.getPtr(e, 16);
			if (hold) {
				if (!cell.isNull()) Mem.setI32(e, 24, w | ALIVE) else if (countedBefore(k)) Mem.setI32(e, 24, w | STRONG);
			} else if (!cell.isNull()) {
				// (a detached entry's reference may be gone: only its cell is read)
				var live = Ind.call1(hook(k, K_WEAK_LOAD), cell);
				Mem.setI32(e, 24, live.isNull() ? w & ~ALIVE : w | ALIVE);
				if (!live.isNull()) {
					if (nloaded & (nloaded - 1) == 0) loaded = LibC.realloc(loaded, ((nloaded == 0 ? 1 : 2 * nloaded) : I64) * 16);
					Mem.setPtr(loaded, 16 * nloaded, live);
					Mem.setI32(loaded, 16 * nloaded + 8, k);
					Mem.setI32(loaded, 16 * nloaded + 12, Mem.getI32(e, 28));
					nloaded++;
				}
			} else if (countedBefore(k)) {
				// (a reference the entry holds: a detach takes the lock before it lets go)
				Mem.setI32(e, 24, counted(k, e) ? w | STRONG : w & ~STRONG);
			}
		}
		Os.unlock(lock);
		// (a last release may run a destructor that comes back to the tables)
		for (j in 0...nloaded)
			releaseNow(Mem.getI32(loaded, 16 * j + 8), Mem.getPtr(loaded, 16 * j), Mem.getI32(loaded, 16 * j + 12));
		if (!loaded.isNull()) LibC.free(loaded);
	}

	// the entries the foreign side keeps, and the detached ones whose object
	// lives: roots (Gc.scanRoots)
	@:hxmc.unsafe static function scan(root:Bool) {
		for (i in 0...npeers) {
			var e = peers.add(PEER_BYTES * i);
			var o = Mem.getPtr(e, 0);
			if (o.isNull()) continue;
			var k = Mem.getI32(e, 24) & 0xFF;
			var cell = Mem.getPtr(e, 16);
			if (!cell.isNull()) {
				// (detached: a root while its object lives, whatever retains it; its
				// reference may be gone, so only the weak cell is read, here for a
				// kind that may be called in the stop, else before it: beforeStop)
				if (inStop(k)) {
					var live = Ind.call1(hook(k, K_WEAK_LOAD), cell);
					if (live.isNull()) continue;
					Ind.call1(hook(k, K_RELEASE), live);
				} else if (Mem.getI32(e, 24) & ALIVE == 0) continue;
				Mem.setPtr(e, 0, Gc.fwdAs(o, root));
				continue;
			}
			if (kept(k, e)) {
				// (a young one kept by the foreign side: promoted, as sweepPeers counts the others)
				if (!Gc.major && Gc.inYoung(o) && !isFwd(hdrW0(o))) promoted++;
				Mem.setPtr(e, 0, Gc.fwdAs(o, root));
			}
		}
	}

	// ---- detaching: the Haxe object o of kind k (or a box) gives up its
	// reference now; nothing when o is neither, or k has no weak cells
	@:hxmc.unsafe static function detach(k:Int, o:Dynamic):Void {
		if (o == null) return;
		var ref = refOf(k, o);
		if (ref.isNull()) return;
		if (isBox(k, Mem.addr(o))) {
			detachBox(k, Mem.addr(o), ref);
			return;
		}
		var i = peerIndex(k, ref);
		if (i < 0) return;
		if (hook(k, K_WEAK_INIT).isNull()) return;
		var cell = LibC.malloc(8);
		Mem.setPtr(cell, 0, Ptr.nil());
		Ind.call2(hook(k, K_WEAK_INIT), cell, ref);
		Os.lock(lock);
		var e = peers.add(PEER_BYTES * i);
		var ok = i > 0 && i < npeers && Mem.getPtr(e, 8) == ref && !Mem.getPtr(e, 0).isNull() && Mem.getPtr(e, 16).isNull();
		var haxe = ok ? Mem.getPtr(e, 0) : Ptr.nil();
		var maker = ok ? Mem.getI32(e, 28) : 0;
		if (ok) {
			Mem.setPtr(e, 16, cell);
			// (its object lives: a root until beforeStop finds it gone)
			Mem.setI32(e, 24, Mem.getI32(e, 24) | ALIVE);
		}
		Os.unlock(lock);
		if (!ok) {
			Ind.call1(hook(k, K_WEAK_DESTROY), cell);
			LibC.free(cell);
			return;
		}
		Mem.setPtr(haxe, 0, Ptr.nil());
		releaseNow(k, ref, maker);
	}

	// a foreign object no Haxe object is paired with: box its box, which every
	// Haxe holder shares (boxFind). Released now, not when the box dies: the
	// box holds null from here on, its native entry nothing to release, and
	// its place in the boxes a tombstone (boxGone), so that the object boxed
	// again later gets a box of its own
	@:hxmc.unsafe static function detachBox(k:Int, box:Ptr, ref:Ptr) {
		var found = false;
		Gc.lockLeaf(Gc.nativesLock);
		for (i in 0...Gc.nnatives) {
			var e = Gc.natives.add(Gc.NATIVE_BYTES * i);
			if (Mem.getPtr(e, 0) == box) {
				Mem.setPtr(e, 8, Ptr.nil());
				// (nothing to release: its free function a kind's, nativeFree, which skips null)
				Mem.setPtr(e, 16, Ptr.ofI64((k : I64)));
				found = true;
				break;
			}
		}
		Gc.unlockLeaf(Gc.nativesLock);
		if (!found) return;
		var maker = 0;
		Os.lock(lock);
		var i = boxSlot(key(k, ref), boxesCap);
		while (true) {
			var e = boxes.add(BOX_BYTES * i);
			var key = Mem.getPtr(e, 0);
			if (key.isNull()) break;
			if (key != boxGone() && Mem.getPtr(e, 8) == box) {
				maker = Mem.getI32(e, 20);
				Mem.setPtr(e, 0, boxGone());
				break;
			}
			i = (i + 1) & (boxesCap - 1);
		}
		Os.unlock(lock);
		Mem.setPtr(box, 0, Ptr.nil());
		releaseNow(k, ref, maker);
	}

	// (entry e freed: its weak cell destroyed, if detached)
	@:hxmc.unsafe static function undetach(k:Int, e:Ptr) {
		var cell = Mem.getPtr(e, 16);
		if (cell.isNull()) return;
		Mem.setPtr(e, 16, Ptr.nil());
		Ind.call1(hook(k, K_WEAK_DESTROY), cell);
		LibC.free(cell);
	}

	// the peer entry of ref (its kind's hook; -1: none)
	@:hxmc.unsafe static function peerIndex(k:Int, ref:Ptr):Int {
		var f = hook(k, K_PEER);
		return f.isNull() ? -1 : Ind.call1(f, ref).toI64().toInt();
	}

	// ---- releases: now (the calling thread runs Haxe code, out of a stop) or
	// put off, by the kind's thread rule; maker the thread that made it

	@:hxmc.unsafe static function target(k:Int, maker:Int):Int {
		var f = flags(k);
		return f & RELEASE_ON_MAKER != 0 ? maker : f & RELEASE_ON_MAIN != 0 ? 1 : 0;
	}

	// out of a stop: on this thread unless the kind wants another one (then
	// put off for it, and that thread woken: detach's, beforeStop's)
	@:hxmc.unsafe static function releaseNow(k:Int, ref:Ptr, maker:Int) {
		var t = target(k, maker);
		if (holdDeferred > 0 && t == 0) t = me();
		if (t != 0 && (t != me() || holdDeferred > 0)) {
			t = defer(k, hook(k, K_RELEASE), ref, Ptr.nil(), t);
			var wake = hook(k, K_WAKE);
			if (t != 0 && t != me() && !wake.isNull()) Ind.call1(wake, Ptr.ofI64((t : I64)));
			return;
		}
		var token = batchBegin(k);
		Ind.call1(hook(k, K_RELEASE), ref);
		batchEnd(k, token);
	}

	// with the world stopped (the sweeps' end)
	@:hxmc.unsafe static function releaseOrDefer(k:Int, ref:Ptr, maker:Int) {
		if (inStop(k)) Ind.call1(hook(k, K_RELEASE), ref) else stopDefer(k, hook(k, K_RELEASE), ref, Ptr.nil(), target(k, maker));
	}

	// a native handle's free function that is a kind (Gc.sweepNatives: a box of
	// a kind whose releases are put off; aux its maker)
	@:hxmc.unsafe static function nativeFree(k:Int, ref:Ptr, maker:Int) {
		if (!ref.isNull()) stopDefer(k, hook(k, K_RELEASE), ref, Ptr.nil(), target(k, maker));
	}

	// ---- calls put off

	// (the slot of pending counting thread t's calls)
	@:hxmc.unsafe static inline function pendingAt(t:Int):Ptr
		return pending.add(t == 0 ? 0 : 4 + 4 * (t & (PENDING_SLOTS - 1)));

	// f(a, b) put off for thread t (0: any), of kind k (its batch): the thread
	// it is for (any, once t ended)
	@:hxmc.unsafe static function defer(k:Int, f:Ptr, a:Ptr, b:Ptr, t:Int):Int {
		Os.lock(deferLock);
		if (t > 0 && t < endedCap && Mem.getU8(ended, t >> 3) & (1 << (t & 7)) != 0) t = 0;
		if (ndeferred == deferredCap) {
			deferredCap = deferredCap == 0 ? 16 : deferredCap * 2;
			deferred = LibC.realloc(deferred, (deferredCap : I64) * DEFER_BYTES);
		}
		var e = deferred.add(DEFER_BYTES * ndeferred);
		Mem.setPtr(e, 0, f);
		Mem.setPtr(e, 8, a);
		Mem.setPtr(e, 16, b);
		Mem.setI32(e, 24, k);
		Mem.setI32(e, 28, t);
		ndeferred++;
		Atomic.add32(pendingAt(t), 1);
		Os.unlock(deferLock);
		return t;
	}

	// f(a, b) put off for this thread when it cannot run Haxe code now: it is
	// one of the runtime's, out of a safe region (a release the runtime made:
	// the sweeps', with the world stopped, or detach's). False: f may run now
	// (in a safe region, or on a thread the runtime does not know)
	@:hxmc.unsafe static function deferHere(k:Int, f:Ptr, a:Ptr, b:Ptr):Bool {
		var m = Threads.self;
		if (m.isNull() || m.value.state == @:privateAccess Threads.SAFE) return false;
		defer(k, f, a, b, m.value.id);
		return true;
	}

	// defer, from the collecting thread with the world stopped: the thread it
	// is for (t, or any once t ended), when not this one, woken once the world
	// resumes (the kind's wake hook)
	@:hxmc.unsafe static function stopDefer(k:Int, f:Ptr, a:Ptr, b:Ptr, t:Int) {
		t = defer(k, f, a, b, t);
		if (t == 0 || t == me() || hook(k, K_WAKE).isNull()) return;
		for (j in 0...nwakes)
			if (Mem.getI32(wakes, 8 * j) == k && Mem.getI32(wakes, 8 * j + 4) == t) return;
		if (nwakes & (nwakes - 1) == 0) wakes = LibC.realloc(wakes, ((nwakes == 0 ? 1 : 2 * nwakes) : I64) * 8);
		Mem.setI32(wakes, 8 * nwakes, k);
		Mem.setI32(wakes, 8 * nwakes + 4, t);
		nwakes++;
	}

	// after the world resumed (Gc.collectFor): the threads with new calls told
	@:hxmc.unsafe static function wakeQueued() {
		var n = nwakes;
		nwakes = 0;
		for (j in 0...n)
			Ind.call1(hook(Mem.getI32(wakes, 8 * j), K_WAKE), Ptr.ofI64((Mem.getI32(wakes, 8 * j + 4) : I64)));
	}

	// the calls put off for this thread (or any), newest first, each in a safe
	// region inside its kind's batch (an Objective-C pool: what a dealloc
	// autoreleases goes with it rather than into the thread's pool). Nothing
	// to do costs two loads (pending); each round takes all of this thread's
	// calls in one pass, the others' keeping their order, and runs them out of
	// the lock (what they put off runs in the next round)
	@:hxmc.unsafe static function runDeferred() {
		var m = me();
		if (holdDeferred > 0) return;
		while (true) {
			if (Atomic.load32(pending) == 0 && (m == 0 || Atomic.load32(pendingAt(m)) == 0)) return;
			Os.lock(deferLock);
			var n = 0, mine = 0, any = 0, keep = 0;
			var batch = LibC.malloc((ndeferred : I64) * DEFER_BYTES);
			for (j in 0...ndeferred) {
				var e = deferred.add(DEFER_BYTES * j);
				var t = Mem.getI32(e, 28);
				if (t == 0 || t == m) {
					LibC.memcpy(batch.add(DEFER_BYTES * n++), e, DEFER_BYTES);
					if (t == 0) any++ else mine++;
				} else {
					if (keep != j) LibC.memcpy(deferred.add(DEFER_BYTES * keep), e, DEFER_BYTES);
					keep++;
				}
			}
			ndeferred = keep;
			Atomic.add32(pending, -any);
			if (mine > 0) Atomic.add32(pendingAt(m), -mine);
			Os.unlock(deferLock);
			var j = n;
			while (j-- > 0) {
				var e = batch.add(DEFER_BYTES * j);
				var k = Mem.getI32(e, 24);
				var region = Leaf.rt_blocking_enter();
				var token = batchBegin(k);
				Ind.call2(Mem.getPtr(e, 0), Mem.getPtr(e, 8), Mem.getPtr(e, 16));
				batchEnd(k, token);
				Regions.end(region);
			}
			LibC.free(batch);
			if (n == 0) return;
		}
	}

	// thread t ended (Threads.exit): what it had left to run, and what is put
	// off for it from now on, any thread's (ended: a bit per thread id, which
	// is never reused)
	@:hxmc.unsafe static function threadExit(t:Int) {
		Os.lock(deferLock);
		if (t >= endedCap) {
			var cap = endedCap == 0 ? 1024 : endedCap;
			while (cap <= t)
				cap *= 2;
			ended = LibC.realloc(ended, (cap >> 3 : I64));
			LibC.memset(ended.add(endedCap >> 3), 0, ((cap - endedCap) >> 3 : I64));
			endedCap = cap;
		}
		Mem.setI8(ended, t >> 3, Mem.getU8(ended, t >> 3) | (1 << (t & 7)));
		var moved = 0;
		for (j in 0...ndeferred)
			if (Mem.getI32(deferred, DEFER_BYTES * j + 28) == t) {
				Mem.setI32(deferred, DEFER_BYTES * j + 28, 0);
				moved++;
			}
		if (moved > 0) {
			Atomic.add32(pendingAt(t), -moved);
			Atomic.add32(pending, moved);
		}
		Os.unlock(deferLock);
	}

	// ---- boxes

	// a foreign reference of kind k where a Haxe reference goes: the Haxe
	// object of its peer, else its one box (retained: the native handle
	// releases it once the box dies)
	static function box(k:Int, ref:Ptr):Dynamic {
		if (ref.isNull()) return null;
		var i = peerIndex(k, ref);
		if (i >= 0) return peerGet(i);
		var key = key(k, ref);
		Os.lock(lock);
		var found = boxFind(k, key, ref);
		Os.unlock(lock);
		if (!found.isNull()) return Mem.obj(found);
		var held = Ind.call1(hook(k, K_RETAIN), ref);
		var maker = me();
		var o = Gc.nativeNewBox(held, inStop(k) ? hook(k, K_RELEASE) : Ptr.ofI64((k : I64)), maker, boxTag(k));
		Os.lock(lock);
		// (another thread's box made meanwhile: that one; this one dies, released)
		found = boxFind(k, key, ref);
		if (found.isNull()) boxAdd(k, key, Mem.addr(o), maker);
		Os.unlock(lock);
		return found.isNull() ? o : Mem.obj(found);
	}

	@:hxmc.unsafe static inline function key(k:Int, ref:Ptr):Ptr {
		var f = hook(k, K_IDENTITY);
		return f.isNull() ? ref : Ind.call1(f, ref);
	}

	// a box's second slot: its kind, tagged. Boxes are the only native handles
	// of two slots (Gc.nativeNewBox), so that a native handle of another kind,
	// or not a foreign object at all (a mutex, an Ssl context, an AtomicInt's
	// cell), is told apart without calling a hook on what it holds (refOf)
	static inline var BOX_TAG = 0x464F0000;

	@:hxmc.unsafe static inline function boxTag(k:Int):I64
		return ((BOX_TAG | k) : I64);

	// whether the object at p is a box of kind k (detached or not)
	@:hxmc.unsafe static inline function isBox(k:Int, p:Ptr):Bool
		return tindexOf(p) == Types.T_NATIVE && nslotsOf(p) == 2 && Mem.getI64(p, 8) == boxTag(k);

	// a detached box's key (detachBox): probed past, dropped by the next sweep
	@:hxmc.unsafe static inline function boxGone():Ptr
		return Ptr.nil().add(1);

	@:hxmc.unsafe static inline function boxSlot(key:Ptr, cap:Int):Int
		return ((key.toI64() >>> 4).toInt() * 0x9E3779B1) & (cap - 1);

	@:hxmc.unsafe static function boxFind(k:Int, key:Ptr, ref:Ptr):Ptr {
		if (nboxes == 0) return Ptr.nil();
		var same = hook(k, K_SAME);
		var i = boxSlot(key, boxesCap);
		while (true) {
			var e = boxes.add(BOX_BYTES * i);
			var x = Mem.getPtr(e, 0);
			if (x.isNull()) return Ptr.nil();
			if (x == key && Mem.getI32(e, 16) == k) {
				var b = Mem.getPtr(e, 8);
				if (same.isNull() || !Ind.call2(same, Mem.getPtr(b, 0), ref).isNull()) return b;
			}
			i = (i + 1) & (boxesCap - 1);
		}
	}

	@:hxmc.unsafe static function boxAdd(k:Int, key:Ptr, box:Ptr, maker:Int) {
		if (2 * (nboxes + 1) > boxesCap) boxRehash(boxesCap == 0 ? 64 : boxesCap * 2);
		boxPut(key, box, k, maker);
		nboxes++;
	}

	@:hxmc.unsafe static function boxPut(key:Ptr, box:Ptr, k:Int, maker:Int) {
		var i = boxSlot(key, boxesCap);
		while (!Mem.getPtr(boxes, BOX_BYTES * i).isNull())
			i = (i + 1) & (boxesCap - 1);
		var e = boxes.add(BOX_BYTES * i);
		Mem.setPtr(e, 0, key);
		Mem.setPtr(e, 8, box);
		Mem.setI32(e, 16, k);
		Mem.setI32(e, 20, maker);
	}

	@:hxmc.unsafe static function boxRehash(cap:Int) {
		var old = boxes, oldCap = boxesCap;
		boxes = LibC.malloc((cap : I64) * BOX_BYTES);
		LibC.memset(boxes, 0, (cap : I64) * BOX_BYTES);
		boxesCap = cap;
		for (i in 0...oldCap) {
			var e = old.add(BOX_BYTES * i);
			if (!Mem.getPtr(e, 0).isNull()) boxPut(Mem.getPtr(e, 0), Mem.getPtr(e, 8), Mem.getI32(e, 16), Mem.getI32(e, 20));
		}
		if (!old.isNull()) LibC.free(old);
	}

	// the reference of a box, or of a peer (null: none): slot 0 both (a paired
	// class's hidden field is its first: hxmc.ir.Lower.classInfo)
	static function unbox(o:Dynamic):Ptr
		return o == null ? Ptr.nil() : Mem.getPtr(Mem.addr(o), 0);

	// the reference of v when it is a foreign object of kind k (its box; an
	// object of a type whose objects are paired with k's: pair), else null:
	// v of any type. No hook is called: a native handle is a box of k's by its
	// tag (isBox), not by what its slot holds, which only k's hooks could read
	static function refOf(k:Int, v:Dynamic):Ptr {
		if (v == null) return Ptr.nil();
		var p = Mem.addr(v);
		var t = Types.tindex(v);
		if (t == Types.T_NATIVE) return isBox(k, p) ? Mem.getPtr(p, 0) : Ptr.nil();
		Os.lock(lock);
		var paired = !typeKinds.isNull() && Mem.getU8(typeKinds, t) == k;
		Os.unlock(lock);
		return paired ? Mem.getPtr(p, 0) : Ptr.nil();
	}

	// ---- owned fields

	// the reference at offset off in o (retained by its store) released once o dies
	static function own(k:Int, o:Dynamic, offset:Int):Void
		addOwned(k, Mem.addr(o), (offset : I64));

	// a weak field: it holds a cell outside the heap (the kind's weak variable:
	// a field moves with its object), destroyed with o and freed
	static function ownWeak(k:Int, o:Dynamic, offset:Int):Void
		addOwned(k, Mem.addr(o), -((offset : I64) + 1));

	@:hxmc.unsafe static function addOwned(k:Int, p:Ptr, off:I64) {
		var maker = me();
		Os.lock(lock);
		if (nowned == ownedCap) {
			ownedCap = ownedCap == 0 ? 64 : ownedCap * 2;
			owned = LibC.realloc(owned, (ownedCap : I64) * OWNED_BYTES);
		}
		var e = owned.add(OWNED_BYTES * nowned);
		Mem.setPtr(e, 0, p);
		Mem.setI64(e, 8, off);
		Mem.setI32(e, 16, k);
		Mem.setI32(e, 20, maker);
		nowned++;
		Os.unlock(lock);
	}

	// a new weak cell: null
	static function weakCell():Ptr {
		var cell = LibC.malloc(8);
		Mem.setPtr(cell, 0, Ptr.nil());
		return cell;
	}

	// (a weak cell of a dead holder, put off: destroyed, freed)
	@:hxmc.callback @:hxmc.unsafe static function dropCell(cell:Ptr, k:Ptr):Void {
		Ind.call1(hook(k.toI64().toInt(), K_WEAK_DESTROY), cell);
		LibC.free(cell);
	}

	// ---- after a collection of the nursery (and of [lo, hi) for a major one)

	@:hxmc.unsafe static inline function collected(o:Ptr, lo:Ptr, hi:Ptr):Bool
		return Gc.inYoung(o) || (lo.ult(o) && !hi.ult(o)); // (an object's address: in (lo, hi], Gc.inFrom)

	@:hxmc.unsafe static function sweep(lo:Ptr, hi:Ptr) {
		if (npeers > 0) sweepPeers(lo, hi);
		if (nowned > 0) sweepOwned(lo, hi);
		if (nboxes > 0) sweepBoxes(lo, hi);
	}

	@:hxmc.unsafe static function addDead(ref:Ptr, k:Int, maker:Int, weak:Bool) {
		if (ndead == deadCap) {
			deadCap = deadCap == 0 ? 64 : deadCap * 2;
			dead = LibC.realloc(dead, (deadCap : I64) * DEAD_BYTES);
		}
		var d = dead.add(DEAD_BYTES * ndead++);
		Mem.setPtr(d, 0, ref);
		Mem.setI32(d, 8, k);
		Mem.setI32(d, 12, maker);
		Mem.setI64(d, 16, weak ? 1 : 0);
	}

	// what a sweep found dead, in the order it found it: released (a weak
	// cell destroyed) now or put off
	@:hxmc.unsafe static function releaseDead() {
		var n = ndead;
		ndead = 0;
		for (j in 0...n) {
			var d = dead.add(DEAD_BYTES * j);
			var ref = Mem.getPtr(d, 0);
			var k = Mem.getI32(d, 8);
			if (Mem.getI64(d, 16) == 0) releaseOrDefer(k, ref, Mem.getI32(d, 12)) else if (inStop(k)) {
				Ind.call1(hook(k, K_WEAK_DESTROY), ref);
				LibC.free(ref);
			} else
				stopDefer(k, Callback.addr(dropCell), ref, Ptr.ofI64((k : I64)), target(k, Mem.getI32(d, 12)));
		}
	}

	// the entries whose Haxe object moved, or died (its reference released)
	@:hxmc.unsafe static function sweepPeers(lo:Ptr, hi:Ptr) {
		for (i in 0...npeers) {
			var e = peers.add(PEER_BYTES * i);
			var o = Mem.getPtr(e, 0);
			if (o.isNull() || !collected(o, lo, hi)) continue;
			if (isFwd(hdrW0(o))) {
				Mem.setPtr(e, 0, fwdAddr(o));
				if (lo.isNull() && Mem.getPtr(e, 16).isNull()) promoted++;
				continue;
			}
			var k = Mem.getI32(e, 24) & 0xFF;
			// (a detached one: its weak cell destroyed, now or put off as a release is)
			var cell = Mem.getPtr(e, 16);
			if (cell.isNull()) addDead(Mem.getPtr(e, 8), k, Mem.getI32(e, 28), false);
			else if (inStop(k)) undetach(k, e);
			else addDead(cell, k, Mem.getI32(e, 28), true);
			Mem.setPtr(e, 16, Ptr.nil());
			Mem.setPtr(e, 0, Ptr.nil());
			Mem.setPtr(e, 8, Ptr.ofI64((peerFree : I64)));
			Mem.setI32(e, 24, 0);
			peerFree = i;
		}
		releaseDead();
	}

	@:hxmc.unsafe static function sweepOwned(lo:Ptr, hi:Ptr) {
		var live = 0;
		for (i in 0...nowned) {
			var e = owned.add(OWNED_BYTES * i);
			var o = Mem.getPtr(e, 0);
			var off = Mem.getI64(e, 8);
			if (collected(o, lo, hi)) {
				if (!isFwd(hdrW0(o))) {
					var weak = off < 0;
					var v = Mem.getPtr(o.addL(weak ? -off - 1 : off), 0);
					if (!v.isNull()) addDead(v, Mem.getI32(e, 16), Mem.getI32(e, 20), weak);
					continue;
				}
				o = fwdAddr(o);
			}
			var d = owned.add(OWNED_BYTES * live++);
			if (d != e) LibC.memcpy(d, e, OWNED_BYTES);
			Mem.setPtr(d, 0, o);
		}
		nowned = live;
		releaseDead();
	}

	// the dead boxes' entries dropped (their native handles release), the
	// moved ones' addresses updated
	@:hxmc.unsafe static function sweepBoxes(lo:Ptr, hi:Ptr) {
		var live = 0;
		for (i in 0...boxesCap) {
			var e = boxes.add(BOX_BYTES * i);
			var o = Mem.getPtr(e, 8);
			if (Mem.getPtr(e, 0).isNull()) continue;
			if (Mem.getPtr(e, 0) == boxGone()) {
				Mem.setPtr(e, 0, Ptr.nil());
				continue;
			}
			if (collected(o, lo, hi)) {
				if (!isFwd(hdrW0(o))) {
					Mem.setPtr(e, 0, Ptr.nil());
					continue;
				}
				// (promoted by a minor collection: its object kept alive until a
				// major one, as a peer's: RT_PEER_BUDGET counts both)
				if (lo.isNull() && Gc.inYoung(o)) promoted++;
				Mem.setPtr(e, 8, fwdAddr(o));
			}
			live++;
		}
		nboxes = live;
		boxRehash(boxesCap);
	}
}

// calls through C function pointers (the kinds' hooks)
@:hxmc.c @:hxmc.fast private extern class Ind {
	@:hxmc.indirect static function call0(f:Ptr):Ptr;
	@:hxmc.indirect static function call1(f:Ptr, a:Ptr):Ptr;
	@:hxmc.indirect static function call2(f:Ptr, a:Ptr, b:Ptr):Ptr;
}
