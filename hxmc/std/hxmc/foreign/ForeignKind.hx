package hxmc.foreign;

import hxmc.unsafe.*;

// A kind of foreign objects: the objects of a reference-counted object
// system outside the heap, held by Haxe objects (docs/plans/foreign-objects.md;
// the runtime's hxmc.rt.Foreign, which Objective-C is the first kind of).
// For a runtime client of a system (COM's, JNI's) and tests: the hooks are
// C functions (a library's, or @:hxmc.callback @:hxmc.unsafe ones), and
// the references Ptr. Native targets only.
abstract ForeignKind(Int) {
	public static inline var TOGGLE_COUNT = hxmc.rt.Foreign.TOGGLE_COUNT;
	public static inline var TOGGLE_RELEASE = hxmc.rt.Foreign.TOGGLE_RELEASE;
	public static inline var TOGGLE_NOTIFY = hxmc.rt.Foreign.TOGGLE_NOTIFY;
	public static inline var RELEASE_IN_STOP = hxmc.rt.Foreign.RELEASE_IN_STOP;
	public static inline var RELEASE_ON_MAKER = hxmc.rt.Foreign.RELEASE_ON_MAKER;
	public static inline var RELEASE_ON_MAIN = hxmc.rt.Foreign.RELEASE_ON_MAIN;

	inline function new(k:Int)
		this = k;

	// a kind of these hooks (KindHooks: each field the C function of the
	// descriptor's word of its name, Foreign.K_*)
	public static function register(h:KindHooks):ForeignKind {
		var d = LibC.malloc(hxmc.rt.Foreign.KIND_BYTES);
		LibC.memset(d, 0, hxmc.rt.Foreign.KIND_BYTES);
		Mem.setPtr(d, hxmc.rt.Foreign.K_NAME, h.name);
		Mem.setI64(d, hxmc.rt.Foreign.K_FLAGS, h.flags);
		Mem.setI64(d, hxmc.rt.Foreign.K_THRESHOLD, h.threshold);
		Mem.setPtr(d, hxmc.rt.Foreign.K_RETAIN, h.retain);
		Mem.setPtr(d, hxmc.rt.Foreign.K_RELEASE, h.release);
		Mem.setPtr(d, hxmc.rt.Foreign.K_COUNT, h.count);
		Mem.setPtr(d, hxmc.rt.Foreign.K_IDENTITY, h.identity);
		Mem.setPtr(d, hxmc.rt.Foreign.K_SAME, h.same);
		Mem.setPtr(d, hxmc.rt.Foreign.K_PEER, h.peer);
		Mem.setPtr(d, hxmc.rt.Foreign.K_WEAK_INIT, h.weakInit);
		Mem.setPtr(d, hxmc.rt.Foreign.K_WEAK_LOAD, h.weakLoad);
		Mem.setPtr(d, hxmc.rt.Foreign.K_WEAK_DESTROY, h.weakDestroy);
		Mem.setPtr(d, hxmc.rt.Foreign.K_BATCH_BEGIN, h.batchBegin);
		Mem.setPtr(d, hxmc.rt.Foreign.K_BATCH_END, h.batchEnd);
		Mem.setPtr(d, hxmc.rt.Foreign.K_WAKE, h.wake);
		var k = @:privateAccess hxmc.rt.Foreign.register(d);
		LibC.free(d);
		return new ForeignKind(k);
	}

	// o paired with ref, which o's first field (a Ptr) holds from now on: the
	// reference the pairing gave o (ref +1, not retained here). o lives while
	// the foreign side holds ref beyond it (the kind's toggle). Its entry's
	// index, for the foreign side to keep (the kind's peer hook reads it back)
	public inline function pair(o:{}, ref:Ptr):Int {
		Mem.setPtr(Mem.addr(o), 0, ref);
		return @:privateAccess hxmc.rt.Foreign.pair(this, o, ref, true);
	}

	// the Haxe object of entry i (null: none)
	public inline function peer(i:Int):Dynamic
		return @:privateAccess hxmc.rt.Foreign.peerGet(i);

	// TOGGLE_NOTIFY: the foreign side holds entry i's object beyond the Haxe
	// object's reference (strong), or no longer does (any thread)
	public static inline function toggle(i:Int, strong:Bool):Void
		@:privateAccess hxmc.rt.Foreign.toggle(i, strong ? 1 : 0);

	// ref where a reference goes: its peer's Haxe object, else its one box
	// (retained; released once the box dies)
	public inline function box(ref:Ptr):Dynamic
		return @:privateAccess hxmc.rt.Foreign.box(this, ref);

	// the reference of a box or a peer of this kind (null: v is neither)
	public inline function refOf(v:Dynamic):Ptr
		return @:privateAccess hxmc.rt.Foreign.refOf(this, v);

	// the reference at byte offset `offset` of o (retained by whoever stored
	// it) released once o dies
	public inline function own(o:{}, offset:Int):Void
		@:privateAccess hxmc.rt.Foreign.own(this, o, offset);

	// a weak field's cell (null), for weakSet and weakGet; at byte offset
	// `offset` of o once ownWeak registered it, destroyed with o
	public static inline function weakCell():Ptr
		return @:privateAccess hxmc.rt.Foreign.weakCell();

	public inline function ownWeak(o:{}, offset:Int):Void
		@:privateAccess hxmc.rt.Foreign.ownWeak(this, o, offset);

	// the cell refers to ref (weakly: null once ref's object is gone)
	public function weakSet(cell:Ptr, ref:Ptr):Void {
		var f = Mem.getPtr(@:privateAccess hxmc.rt.Foreign.rec(this), hxmc.rt.Foreign.K_WEAK_DESTROY);
		if (!Mem.getPtr(cell, 0).isNull()) Ind.call1(f, cell);
		Ind.call2(Mem.getPtr(@:privateAccess hxmc.rt.Foreign.rec(this), hxmc.rt.Foreign.K_WEAK_INIT), cell, ref);
	}

	// the cell's object as a value (its box or peer), null once it is gone
	public function weakGet(cell:Ptr):Dynamic {
		var rec = @:privateAccess hxmc.rt.Foreign.rec(this);
		var r = Ind.call1(Mem.getPtr(rec, hxmc.rt.Foreign.K_WEAK_LOAD), cell);
		if (r.isNull()) return null;
		var b = box(r);
		Ind.call1(Mem.getPtr(rec, hxmc.rt.Foreign.K_RELEASE), r);
		return b;
	}

	// v (a peer or a box of this kind) gives up its reference now (a peer
	// stays reachable from the foreign side while its object lives)
	public inline function detach(v:Dynamic):Void
		@:privateAccess hxmc.rt.Foreign.detach(this, v);

	// f(a, b) put off for this thread when it cannot run Haxe code now (not in
	// a safe region: a destructor the collector's release ran), as
	// Objective-C's deallocs are: true when put off, false when f may run now
	public inline function deferHere(f:Ptr, a:Ptr, b:Ptr):Bool
		return @:privateAccess hxmc.rt.Foreign.deferHere(this, f, a, b);

	// the calls put off for this thread (or any thread): an event loop's
	public static inline function runDeferred():Void
		@:privateAccess hxmc.rt.Foreign.runDeferred();
}

// A kind's hooks (Foreign.K_*): null for none
@:publicFields class KindHooks {
	var name:Ptr = Ptr.nil();
	var flags:Int = 0;
	var threshold:Int = 1;
	var retain:Ptr = Ptr.nil();
	var release:Ptr = Ptr.nil();
	var count:Ptr = Ptr.nil();
	var identity:Ptr = Ptr.nil();
	var same:Ptr = Ptr.nil();
	var peer:Ptr = Ptr.nil();
	var weakInit:Ptr = Ptr.nil();
	var weakLoad:Ptr = Ptr.nil();
	var weakDestroy:Ptr = Ptr.nil();
	var batchBegin:Ptr = Ptr.nil();
	var batchEnd:Ptr = Ptr.nil();
	var wake:Ptr = Ptr.nil();

	function new() {}
}

@:hxmc.c @:hxmc.fast private extern class Ind {
	@:hxmc.indirect static function call1(f:Ptr, a:Ptr):Ptr;
	@:hxmc.indirect static function call2(f:Ptr, a:Ptr, b:Ptr):Ptr;
}
