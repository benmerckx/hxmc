import hxmc.NativeGc;
import hxmc.foreign.ForeignKind;
import hxmc.unsafe.*;

// Foreign objects (hxmc.rt.Foreign, docs/plans/foreign-objects.md) over a
// small reference-counted object system in C (ForeignKinds.c), as three
// kinds: A as Objective-C is (its count read, released with the world
// stopped, a destructor that runs Haxe code putting itself off), B as COM
// would be (the count from a retain and a release, releases put off to the
// thread that made the reference, its wake hook told), C with toggle
// notifications (GObject's), from a thread the runtime does not know too.
// Toggle references on and off, one box per object, native handles that are
// not boxes, weak, owned and unowned fields, detach, finalisers' order and
// thread, releases put off past a collection (B's hooks never called with
// the world stopped; the threads told; the order kept; the main thread's
// own run as it ends), and many objects with cycles through native retains.
@:hxmc.c extern class FO {
	static function fo_new(id:Int):Ptr;
	static function fo_retain(o:Ptr):Ptr;
	static function fo_release(o:Ptr):Int;
	static function fo_count(o:Ptr):Int;
	static function fo_id(o:Ptr):Int;
	static function fo_set_peer(o:Ptr, i:Int):Void;
	static function fo_hold(a:Ptr, i:Int, b:Ptr):Void;
	static function fo_on_tag(f:Ptr):Void;
	static function fo_on_free(f:Ptr):Void;
	static function fo_live():Int;
	static function fo_made():Int;
	static function fo_batches():Int;
	static function fo_batch_ends():Int;
	static function fo_wakes():Int;
	static function fo_nfreed():Int;
	static function fo_freed(i:Int):Int;
	static function fo_freed_tag(i:Int):Int;
	static function fo_clear_log():Void;
	static function fo_nweak(o:Ptr):Int;
	static function fo_on_stopped(f:Ptr):Void;
	static function fo_b_in_stop():Int;
	static function fo_notifier(f:Ptr, i:Int, n:Int):Void;
	static function fo_notifier_done():Int;
}

// a peer: its first field the reference (ForeignKind.pair)
class Peer {
	public var ref:Ptr;
	public var name:String;
	// a field owning a reference (ForeignKind.own)
	public var held:Ptr;

	public function new(name:String)
		this.name = name;
}

class WeakHolder {
	public var cell:Ptr;

	public function new() {}
}

class Unowned {
	public var ref:Ptr;

	public function new(r:Ptr)
		ref = r;
}

@:hxmc.c @:hxmc.fast private extern class Ind {
	@:hxmc.indirect static function call2(f:Ptr, a:Ptr, b:Ptr):Ptr;
}

class ForeignKinds {
	static var A:ForeignKind;
	static var B:ForeignKind;
	static var C:ForeignKind;
	// (written by onFree, with the world stopped too: no heap)
	static var freedInStop = 0;
	static var freedOutOfStop = 0;
	static var deferredDeallocs = 0;
	static var deallocs:Array<String> = [];
	static var finalised:Array<String> = [];
	// the thread's tag, which the C side logs a free with (tagNow)
	@:hxmc.threadLocal static var tag:Int;

	@:hxmc.callback @:hxmc.unsafe static function tagNow():Int
		return tag;

	// an object freed (ForeignKinds.c): its destructor, for ids 700..799, runs
	// Haxe code (dealloc), put off when the thread cannot run it now
	@:hxmc.callback @:hxmc.unsafe static function onFree(o:Ptr, id:Int):Void {
		if ((@:privateAccess hxmc.rt.Threads.collector).isNull()) freedOutOfStop++ else freedInStop++;
		if (id < 700 || id >= 800) return;
		if (A.deferHere(Callback.addr(dealloc), Ptr.ofI64((id : Int64)), Ptr.nil())) deferredDeallocs++ else
			Ind.call2(Callback.addr(dealloc), Ptr.ofI64((id : Int64)), Ptr.nil());
	}

	@:hxmc.callback static function dealloc(id:Ptr, b:Ptr):Void
		deallocs.push(id.toI64() + " on " + tag);

	// (ForeignKinds.c's B hooks: whether this is the collecting thread, with the world stopped)
	@:hxmc.callback @:hxmc.unsafe static function stoppedNow():Int {
		var c = @:privateAccess hxmc.rt.Threads.collector;
		return !c.isNull() && c == hxmc.rt.Threads.self ? 1 : 0;
	}

	// a toggle notification from the native side's thread (fo_notifier_run)
	@:hxmc.callback @:hxmc.unsafe static function notifyNow(i:Int, strong:Int):Void
		ForeignKind.toggle(i, strong != 0);

	static function kind(name:Ptr, flags:Int, peer:Bool, counted:Bool):ForeignKind {
		var h = new KindHooks();
		h.name = name;
		h.flags = flags;
		h.threshold = 1;
		h.retain = counted ? Mem.sym("fo_retain_b") : Mem.sym("fo_retain");
		h.release = counted ? Mem.sym("fo_release_b") : Mem.sym("fo_release");
		h.count = counted ? Mem.sym("fo_count_b") : Mem.sym("fo_count");
		h.identity = Mem.sym("fo_identity");
		if (peer) h.peer = Mem.sym("fo_peer");
		h.weakInit = Mem.sym("fo_weak_init");
		h.weakLoad = counted ? Mem.sym("fo_weak_load_b") : Mem.sym("fo_weak_load");
		h.weakDestroy = counted ? Mem.sym("fo_weak_destroy_b") : Mem.sym("fo_weak_destroy");
		h.batchBegin = Mem.sym("fo_batch_begin");
		h.batchEnd = Mem.sym("fo_batch_end");
		h.wake = Mem.sym("fo_wake");
		return ForeignKind.register(h);
	}

	@:hxmc.unsafe static function offsetOf(o:Dynamic, sentinel:Ptr):Int {
		var p = Mem.addr(o);
		for (i in 0...8)
			if (Mem.getPtr(p, 8 * i) == sentinel) return 8 * i;
		return -1;
	}

	static var heldOffset = -1;
	static var cellOffset = -1;

	static function collect(n:Int)
		for (i in 0...n)
			NativeGc.collect(true);

	static function freedLog():String {
		var r = [for (i in 0...FO.fo_nfreed()) FO.fo_freed(i) + "@" + FO.fo_freed_tag(i)];
		FO.fo_clear_log();
		return r.join(" ");
	}

	// ---- toggle references: a peer lives while the native side holds its object beyond it

	static var holder:Ptr;

	static function pairOne(k:ForeignKind, id:Int):Int {
		var o = FO.fo_new(id);
		var p = new Peer("p" + id);
		var i = k.pair(p, o);
		FO.fo_set_peer(o, i);
		return i;
	}

	static function toggles() {
		holder = FO.fo_new(100);
		var i = pairOne(A, 1);
		var o = A.refOf(A.peer(i));
		FO.fo_hold(holder, 0, o);
		trace("toggle: count " + FO.fo_count(o) + ", the box of the object is its peer: " + (A.box(o) == A.peer(i)));
		collect(2);
		trace("held natively, after collections: peer " + (A.peer(i) : Peer).name + ", live " + FO.fo_live());
		FO.fo_hold(holder, 0, Ptr.nil());
		collect(1);
		trace("let go natively: peer " + A.peer(i) + ", freed " + freedLog() + ", live " + FO.fo_live());
		// (B: the count from a retain and a release)
		var j = pairOne(B, 2);
		FO.fo_hold(holder, 0, B.refOf(B.peer(j)));
		collect(2);
		trace("B held: peer " + (B.peer(j) : Peer).name);
		FO.fo_hold(holder, 0, Ptr.nil());
		collect(1);
		trace("B let go: peer " + B.peer(j) + ", freed " + freedLog());
		// (C: notifications)
		var c = pairOne(C, 3);
		ForeignKind.toggle(c, true);
		collect(2);
		trace("C notified strong: peer " + (C.peer(c) : Peer).name + ", live " + FO.fo_live());
		ForeignKind.toggle(c, false);
		collect(1);
		trace("C notified weak: peer " + C.peer(c) + ", freed " + freedLog());
		var ok = notifiedElsewhere();
		collect(1);
		var n = FO.fo_nfreed();
		FO.fo_clear_log();
		trace("notified by another thread: " + ok + ", then freed " + n + ", live " + FO.fo_live());
	}

	// notifications from a thread the runtime does not know (one thread of the
	// runtime's so far), while the tables grow
	static function notifiedElsewhere():Bool {
		var n = pairOne(C, 4);
		var kept = C.peer(n);
		FO.fo_notifier(Callback.addr(notifyNow), n, 200000);
		@:privateAccess hxmc.rt.Os.spawn(Mem.sym("fo_notifier_run"), Ptr.nil(), 1 << 20);
		var many = [for (i in 0...3000) C.peer(pairOne(C, 5000 + i))];
		while (FO.fo_notifier_done() == 0)
			Sys.sleep(0.001);
		ForeignKind.toggle(n, false);
		return many.length == 3000 && kept == C.peer(n);
	}

	// ---- native handles that are not boxes: no hook called on what they hold

	static function notBoxes() {
		var a = new haxe.atomic.AtomicInt(7);
		var m = new sys.thread.Mutex();
		var none = true;
		for (k in [A, B, C]) {
			none = none && k.refOf(a) == Ptr.nil() && k.refOf(m) == Ptr.nil();
			k.detach(a);
			k.detach(m);
		}
		m.acquire();
		m.release();
		var o = FO.fo_new(12);
		var kept = otherKindsBox(o);
		FO.fo_release(o);
		collect(1);
		trace("not boxes: refOf null " + none + ", untouched " + (a.load() == 7) + ", another kind's box kept " + kept + ", freed " + freedLog());
	}

	static function otherKindsBox(o:Ptr):Bool {
		var x = A.box(o);
		B.detach(x);
		return A.refOf(x) == o;
	}

	// ---- one box per object

	static function boxes() {
		var o = FO.fo_new(10), q = FO.fo_new(11);
		var x = A.box(o), y = A.box(o), z = A.box(q);
		trace("boxes: same " + (x == y) + ", other " + (x == z) + ", indexOf " + [z, x].indexOf(y) + ", unboxed " + (A.refOf(x) == o)
			+ ", count " + FO.fo_count(o) + ", another kind's " + (B.refOf(x) == Ptr.nil()));
		var m = new haxe.ds.ObjectMap<Dynamic, Int>();
		m.set(x, 1);
		m.set(y, 2);
		trace("a map: " + m.get(A.box(o)) + ", one key " + [for (k in m.keys()) k].length);
		FO.fo_release(o);
		FO.fo_release(q);
	}

	// ---- weak and unowned fields

	// (cells: weak fields of one object, more than ForeignKinds.c's first array)
	static function manyWeak() {
		var o = FO.fo_new(22);
		var n = weakCells(o);
		collect(1);
		trace("10 weak cells: " + n + ", then " + FO.fo_nweak(o));
		FO.fo_release(o);
		FO.fo_clear_log();
	}

	static function weakCells(o:Ptr):Int {
		var ws = [for (i in 0...10) makeWeak(o)];
		return ws.length == 10 ? FO.fo_nweak(o) : -1;
	}

	static function makeWeak(o:Ptr):WeakHolder {
		var w = new WeakHolder();
		w.cell = ForeignKind.weakCell();
		if (cellOffset < 0) cellOffset = offsetOf(w, w.cell);
		A.ownWeak(w, cellOffset);
		A.weakSet(w.cell, o);
		return w;
	}

	static function weakAlive(w:WeakHolder):Bool
		return A.weakGet(w.cell) != null;

	static function weak() {
		var o = FO.fo_new(20);
		var w = makeWeak(o);
		trace("weak: alive " + weakAlive(w) + ", count " + FO.fo_count(o));
		collect(1); // (weakAlive's box gone)
		FO.fo_release(o);
		trace("weak after the release: alive " + weakAlive(w) + ", freed " + freedLog());
		w = null;
		collect(1);
		// unowned: the reference only, nothing retained or released
		var u = FO.fo_new(21);
		var h = new Unowned(u);
		trace("unowned: count " + FO.fo_count(h.ref) + ", id " + FO.fo_id(h.ref));
		h = null;
		collect(1);
		trace("unowned holder gone: count " + FO.fo_count(u) + ", freed " + freedLog());
		FO.fo_release(u);
		trace("released: freed " + freedLog());
	}

	// ---- owned fields

	static function own(o:Ptr) {
		var p = new Peer("owner");
		p.held = FO.fo_retain(o);
		if (heldOffset < 0) heldOffset = offsetOf(p, p.held);
		A.own(p, heldOffset);
	}

	static function owned() {
		var o = FO.fo_new(30);
		own(o);
		trace("owned: count " + FO.fo_count(o));
		collect(1);
		trace("owner gone: count " + FO.fo_count(o));
		FO.fo_release(o);
		trace("freed " + freedLog());
	}

	// ---- detach

	static function detached() {
		var i = pairOne(A, 40);
		var o = A.refOf(A.peer(i));
		FO.fo_hold(holder, 1, o);
		A.detach(A.peer(i));
		trace("detached: count " + FO.fo_count(o) + ", its reference " + ((A.peer(i) : Peer).ref == Ptr.nil()));
		collect(2);
		trace("held natively: peer " + (A.peer(i) : Peer).name);
		FO.fo_hold(holder, 1, Ptr.nil());
		trace("let go natively: freed at once " + freedLog());
		collect(1);
		trace("peer then " + A.peer(i));
		// a box: released at once, the object boxed again a new box
		var q = FO.fo_new(41);
		var b = A.box(q);
		A.detach(b);
		trace("box detached: count " + FO.fo_count(q) + ", a new box " + (A.box(q) != b) + ", unboxed " + (A.refOf(b) == Ptr.nil()));
		FO.fo_release(q);
		collect(1);
		trace("freed " + freedLog());
		// B's: its weak cell loaded before the stop, destroyed after it
		var j = pairOne(B, 42);
		FO.fo_hold(holder, 2, B.refOf(B.peer(j)));
		B.detach(B.peer(j));
		collect(2);
		trace("B detached, held natively: peer " + (B.peer(j) : Peer).name);
		FO.fo_hold(holder, 2, Ptr.nil());
		trace("let go natively: freed at once " + freedLog());
		collect(2);
		trace("peer then " + B.peer(j));
	}

	// ---- finalisers: Haxe's first (newest first), then the releases; a
	// destructor running Haxe code put off past the stop, run on its thread

	static function finalisable() {
		for (id in [701, 702, 703]) {
			// (held by a local while the finaliser's closure is made)
			var peer = A.peer(pairOne(A, id));
			NativeGc.finalise(p -> finalised.push((p : Peer).name), peer);
		}
	}

	static function finalisers() {
		finalisable();
		collect(1);
		NativeGc.runFinalisers();
		trace("finalised " + finalised + ", live " + FO.fo_live());
		var before = freedInStop;
		collect(1);
		trace("released with the world stopped: " + (freedInStop - before) + ", freed " + freedLog() + ", deallocs put off "
			+ deferredDeallocs + ", run " + deallocs);
		// one released out of a collection runs at once
		var o = FO.fo_new(704);
		FO.fo_release(o);
		trace("released by Haxe code: deallocs " + deallocs + ", freed " + freedLog());
	}

	// ---- releases put off: B's, past the stop, on the thread that made them

	static function madeOnMain() {
		var i = pairOne(B, 50);
		var b = B.box(FO.fo_new(51));
		FO.fo_release(B.refOf(b));
	}

	static function makeBoxes(k:ForeignKind, n:Int, base:Int) {
		for (i in 0...n) {
			var o = FO.fo_new(base + i);
			k.box(o);
			FO.fo_release(o);
		}
	}

	static var handed:Dynamic;

	static function deferred() {
		var before = freedInStop;
		madeOnMain();
		collect(1);
		trace("B put off: in the stop " + (freedInStop - before) + ", freed after it " + freedLog() + ", batches " + (FO.fo_batches() == FO.fo_batch_ends()));
		var toMain = new sys.thread.Lock(), toThread = new sys.thread.Lock();
		var report = "";
		sys.thread.Thread.create(() -> {
			tag = 2;
			makeBoxes(B, 10, 600);
			var o = FO.fo_new(620);
			handed = B.box(o);
			FO.fo_release(o);
			toMain.release();
			toThread.wait();
			makeBoxes(B, 10, 610);
			toMain.release();
			toThread.wait();
			ForeignKind.runDeferred();
			report = freedLog();
			toMain.release();
		});
		toMain.wait();
		// (the main thread's own between the thread's: the queue keeps the thread's order)
		makeBoxes(B, 5, 660);
		toThread.release();
		toMain.wait();
		// (a box detached on another thread than its maker's: put off for it, and it told)
		var wakes = FO.fo_wakes();
		B.detach(handed);
		handed = null;
		var detachWoke = FO.fo_wakes() > wakes;
		wakes = FO.fo_wakes();
		collect(2);
		trace("made on a thread: after the main thread's collections, live " + FO.fo_live() + ", freed " + freedLog() + ", woken " + (FO.fo_wakes() > wakes)
			+ ", by detach " + detachWoke);
		toThread.release();
		toMain.wait();
		trace("the thread ran them: " + report);
		// a thread that ended: what is put off for it runs on any thread
		var done = new sys.thread.Lock();
		sys.thread.Thread.create(() -> {
			tag = 3;
			makeBoxes(B, 5, 650);
			done.release();
		});
		done.wait();
		while ((@:privateAccess hxmc.rt.Threads.nthreads) > 1)
			Sys.sleep(0.001);
		var wakes = FO.fo_wakes();
		collect(1);
		trace("made on a thread that ended: freed " + freedLog() + ", it woken " + (FO.fo_wakes() > wakes));
	}

	// ---- many objects, and cycles through native retains

	static function cycle(id:Int) {
		// a holds b natively; b's peer owns a: a cycle through both heaps
		// (each held by a local until the native side holds it)
		var pa:Peer = A.peer(pairOne(A, id));
		var pb:Peer = A.peer(pairOne(A, id + 1));
		var a = pa.ref, b = pb.ref;
		FO.fo_hold(a, 0, b);
		pb.held = FO.fo_retain(a);
		A.own(pb, heldOffset);
		cycles.push(a);
	}

	// (each cycle's a: not a reference of a Haxe object)
	static var cycles:Array<Ptr> = [];

	static function makeCycles(n:Int)
		for (c in 0...n)
			cycle(1000 + 2 * c);

	static function many() {
		var live0 = FO.fo_live();
		makeBoxes(A, 5000, 10000);
		collect(1);
		trace("5000 boxes: live " + (FO.fo_live() - live0) + ", freed " + FO.fo_nfreed());
		FO.fo_clear_log();
		makeCycles(300);
		collect(3);
		trace("300 cycles: live " + (FO.fo_live() - live0) + ", freed " + FO.fo_nfreed());
		// broken natively: each cycle's a lets go of b (its peer, a's peer and a follow)
		breakCycles();
		var n = 0;
		while (FO.fo_live() > live0 && n < 10) {
			collect(1);
			n++;
		}
		trace("broken: live " + (FO.fo_live() - live0) + ", freed " + FO.fo_nfreed() + ", in " + n + " collections");
		FO.fo_clear_log();
	}

	static function breakCycles() {
		for (a in cycles)
			FO.fo_hold(a, 0, Ptr.nil());
		cycles = [];
	}

	// (put off for the main thread at the end of main: run as it ends)
	@:hxmc.callback static function lastWords(a:Ptr, b:Ptr):Void
		trace("put off by the main thread at its end: run on " + tag);

	static function main() {
		tag = 1;
		FO.fo_on_tag(Callback.addr(tagNow));
		FO.fo_on_free(Callback.addr(onFree));
		FO.fo_on_stopped(Callback.addr(stoppedNow));
		A = kind(Mem.cstr("a"), ForeignKind.TOGGLE_COUNT | ForeignKind.RELEASE_IN_STOP, true, false);
		B = kind(Mem.cstr("b"), ForeignKind.TOGGLE_RELEASE | ForeignKind.RELEASE_ON_MAKER, true, true);
		C = kind(Mem.cstr("c"), ForeignKind.TOGGLE_NOTIFY, true, false);
		toggles();
		boxes();
		collect(1);
		trace("boxes gone: freed " + freedLog());
		notBoxes();
		weak();
		manyWeak();
		owned();
		detached();
		finalisers();
		deferred();
		many();
		trace("in the stop " + (freedInStop > 0) + ", balanced batches " + (FO.fo_batches() == FO.fo_batch_ends()) + ", live "
			+ (FO.fo_live() - 1) + " of " + FO.fo_made() + ", B's hooks with the world stopped " + FO.fo_b_in_stop());
		A.deferHere(Callback.addr(lastWords), Ptr.nil(), Ptr.nil());
	}
}
