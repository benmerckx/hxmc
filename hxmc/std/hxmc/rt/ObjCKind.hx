package hxmc.rt;

import hxmc.Platform;
import hxmc.I64;
import hxmc.rt.C;
import hxmc.unsafe.*;

// Objective-C as a kind of foreign objects (Foreign; docs/interop.md,
// "Memory"): the entry points generated code calls (hxmc.ir.ObjC,
// FnLower), over Foreign's peers, boxes and owned fields. Its hooks are
// libobjc's: objc_retain, objc_release, _objc_rootRetainCount (the
// toggle: a count above 1, the Haxe object's own reference), the weak
// variables (objc_initWeak, objc_loadWeakRetained, objc_destroyWeak), the
// peer entry an instance of a Haxe class extending an Objective-C one names
// in its instance variable hxmc_peer (peerOf), and an autorelease pool
// around releases (a dealloc they run autoreleases: a view its subviews,
// AppKit its caches' entries; a collection outside the run loop's pools
// would leak all that, "autoreleased with no pool in place"). Its releases
// run with the world stopped: libobjc's release runs no Haxe code, and a
// dealloc that would (an Objective-C mode class's) puts itself off
// (deallocDefer). The runtime does not link libobjc: its functions come as
// addresses from generated code, or are found by name (dlsym), once the
// kind is registered (at the first object that needs it).
@:hxmc.native @:keep @:allow(hxmc.rt)
class ObjCKind {
	// (0: not registered yet; published with a release store once its record
	// and the functions below are written, read with an acquire load: known)
	@:hxmc.export("rt_objc_kind") static var kind:Int;
	static var getClass:Ptr;
	static var getIvar:Ptr;
	static var ivarOffset:Ptr;
	static var poolPush:Ptr;
	static var poolPop:Ptr;

	// the kind once registered (0: not yet)
	@:hxmc.unsafe static inline function known():Int
		return Atomic.load32(Mem.sym("rt_objc_kind"));

	// the kind, registered at the first call
	@:hxmc.unsafe static function k():Int {
		var k = known();
		if (k != 0) return k;
		Os.lock(Foreign.lock);
		if (kind == 0) {
			getClass = sym(Mem.cstr("object_getClass"));
			getIvar = sym(Mem.cstr("class_getInstanceVariable"));
			ivarOffset = sym(Mem.cstr("ivar_getOffset"));
			var d = Mem.stack(120);
			LibC.memset(d, 0, Foreign.KIND_BYTES);
			Mem.setPtr(d, Foreign.K_NAME, Mem.cstr("objc"));
			Mem.setI64(d, Foreign.K_FLAGS, Foreign.TOGGLE_COUNT | Foreign.RELEASE_IN_STOP);
			Mem.setI64(d, Foreign.K_THRESHOLD, 1);
			Mem.setPtr(d, Foreign.K_RETAIN, sym(Mem.cstr("objc_retain")));
			Mem.setPtr(d, Foreign.K_RELEASE, sym(Mem.cstr("objc_release")));
			Mem.setPtr(d, Foreign.K_COUNT, sym(Mem.cstr("_objc_rootRetainCount")));
			Mem.setPtr(d, Foreign.K_PEER, Callback.addr(peerOf));
			Mem.setPtr(d, Foreign.K_WEAK_INIT, sym(Mem.cstr("objc_initWeak")));
			Mem.setPtr(d, Foreign.K_WEAK_LOAD, sym(Mem.cstr("objc_loadWeakRetained")));
			Mem.setPtr(d, Foreign.K_WEAK_DESTROY, sym(Mem.cstr("objc_destroyWeak")));
			Mem.setPtr(d, Foreign.K_BATCH_BEGIN, Callback.addr(batchBegin));
			Mem.setPtr(d, Foreign.K_BATCH_END, Callback.addr(batchEnd));
			Atomic.store32(Mem.sym("rt_objc_kind"), Foreign.registerLocked(d));
		}
		Os.unlock(Foreign.lock);
		return kind;
	}

	@:hxmc.unsafe static inline function sym(name:Ptr):Ptr
		return @:privateAccess ObjCExceptions.fn(name);

	// the peer entry of id: the index in its instance variable (ObjC.PEER_IVAR)
	// when its class is a Haxe class's, else -1
	@:hxmc.callback @:hxmc.unsafe static function peerOf(id:Ptr):Ptr {
		var ivar = Ind.call2(getIvar, Ind.call1(getClass, id), Mem.cstr("hxmc_peer"));
		return ivar.isNull() ? Ptr.ofI64(-1) : Ptr.ofI64((Mem.getI32(id.addL(Ind.call1(ivarOffset, ivar).toI64()), 0) : I64));
	}

	@:hxmc.callback @:hxmc.unsafe static function batchBegin():Ptr
		return poolPushAny();

	@:hxmc.callback @:hxmc.unsafe static function batchEnd(pool:Ptr):Void
		poolEnd(pool);

	// ---- peers (hxmc.ir.ObjC): an instance of a Haxe class extending an
	// Objective-C one is two objects, the Haxe one and its Objective-C
	// object, whose instance variable holds the index of their entry. The
	// Haxe object holds one reference to the id (the one alloc made)

	@:hxmc.unsafe(gc) @:hxmc.export("rt_objc_peer_add") static function peerAdd(o:Dynamic, id:Ptr, retainCount:Ptr, release:Ptr):Int
		return pair(o, id, retainCount, release, true);

	// o paired with id; typed: o's type is a class's whose objects are
	// paired (not a value an Objective-C exception carries: ObjCExceptions)
	@:hxmc.unsafe(gc) static function pair(o:Dynamic, id:Ptr, retainCount:Ptr, release:Ptr, typed:Bool):Int {
		var k = k();
		Foreign.setHook(k, Foreign.K_COUNT, retainCount);
		Foreign.setHook(k, Foreign.K_RELEASE, release);
		return Foreign.pair(k, o, id, typed);
	}

	// the Haxe object of entry i (null: a free entry)
	@:hxmc.export("rt_objc_peer_get") static function peerGet(i:Int):Dynamic
		return Foreign.peerGet(i);

	// hxmc.objc.Peers.detach: o (the Haxe object, or a box of its id: an id
	// typed as its Objective-C class, a view a parent's subviews gave) gives
	// up its id now (Foreign.detach)
	@:hxmc.unsafe public static function detach(o:Dynamic):Void {
		if (Platform.os() != 1 || o == null) return;
		var k = known();
		if (k != 0) Foreign.detach(k, o);
	}

	// ---- pools: one on Apple's systems whatever the heap holds (nil: no libobjc)
	@:hxmc.unsafe public static function poolPushAny():Ptr {
		if (Platform.os() != 1) return Ptr.nil();
		if (poolPush.isNull()) {
			poolPush = @:privateAccess sym(Mem.cstr("objc_autoreleasePoolPush"));
			poolPop = @:privateAccess sym(Mem.cstr("objc_autoreleasePoolPop"));
			if (poolPush.isNull() || poolPop.isNull()) return Ptr.nil();
		}
		return Ind.call0(poolPush);
	}

	@:hxmc.unsafe public static function poolEnd(pool:Ptr) {
		if (!pool.isNull()) Ind.call1(poolPop, pool);
	}

	// ---- deallocs put off: an Objective-C mode class's dealloc (its entry,
	// hxmc.ir.ObjC.entry) sent where Haxe code cannot run, by a release the
	// runtime makes outside any safe region: the collector's sweeps (the ids
	// of dead Haxe objects, with the world stopped), Peers.detach. Put off for
	// the thread that sent it (Foreign.defer), which sends it again later,
	// from a safe region: at its next allocation's slow path (as finalisers),
	// when Gc.collect returns, or as it ends. The object stays allocated
	// meanwhile (deallocating: weak references to it already read nil).
	// Whether the dealloc imp of object self is put off (1) or runs now (0):
	// put off unless the calling thread is one of the runtime's in a safe
	// region (or none of the runtime's: Objective-C's own threads)
	@:hxmc.export("rt_objc_dealloc_defer") @:hxmc.unsafe static function deallocDefer(self:Ptr, imp:Ptr):Int
		return Foreign.deferHere(k(), imp, self, Ptr.nil()) ? 1 : 0;

	// ---- ids in fields of Haxe objects (hxmc.ir.ObjC): each such field (a
	// closure's capture, a captured variable's box) holds a reference to its id
	// (its stores retain and release, FnLower), which the object's death gives
	// back, registered by the constructor (where the closure or the box is made)
	@:hxmc.export("rt_objc_own") static function own(o:Dynamic, offset:Int, release:Ptr):Void {
		var k = k();
		Foreign.setHook(k, Foreign.K_RELEASE, release);
		Foreign.own(k, o, offset);
	}

	// a weak id field (@:hxmc.weak): it holds a cell outside the heap, the
	// variable objc_storeWeak knows (a field moves with its object), which
	// the object's death destroys (objc_destroyWeak) and frees
	@:hxmc.export("rt_objc_own_weak") static function ownWeak(o:Dynamic, offset:Int, destroyWeak:Ptr):Void {
		var k = k();
		Foreign.setHook(k, Foreign.K_WEAK_DESTROY, destroyWeak);
		Foreign.ownWeak(k, o, offset);
	}

	// a new weak variable for such a field: nil
	@:hxmc.unsafe(gc) @:hxmc.export("rt_objc_weak_cell") static function weakCell():Ptr
		return Foreign.weakCell();

	// an id where a reference goes (Dynamic, an element, a type parameter):
	// the Haxe object of an instance of a Haxe class extending an Objective-C
	// one, else the id's one box (Foreign.box). libobjc's functions come as
	// addresses (the runtime does not link libobjc).
	@:hxmc.unsafe(gc) @:hxmc.export("rt_objc_box") static function idBox(id:Ptr, retain:Ptr, release:Ptr, getClass:Ptr, getIvar:Ptr, ivarOffset:Ptr):Dynamic {
		if (id.isNull()) return null;
		var k = k();
		ObjCKind.getClass = getClass;
		ObjCKind.getIvar = getIvar;
		ObjCKind.ivarOffset = ivarOffset;
		Foreign.setHook(k, Foreign.K_RETAIN, retain);
		Foreign.setHook(k, Foreign.K_RELEASE, release);
		return Foreign.box(k, id);
	}

	// the id of a box, or of an instance of a Haxe class extending an
	// Objective-C one (null: nil): slot 0 both
	@:hxmc.unsafe(gc) @:hxmc.export("rt_objc_unbox") static function idUnbox(o:Dynamic):Ptr
		return Foreign.unbox(o);

	// the id of v when it is an Objective-C object (a box of an id; an object
	// of a type whose objects are paired), else nil: v of any type
	@:hxmc.unsafe(gc) static function idOf(v:Dynamic):Ptr {
		var k = known();
		return k == 0 ? Ptr.nil() : Foreign.refOf(k, v);
	}

	// whether v (of any type: a caught value, a Dynamic) is an Objective-C
	// object that is a kind of the class cls, or conforms to the protocol
	// cls: sel (isKindOfClass:, conformsToProtocol:) sent with msgSend
	// (libobjc's, as an address)
	@:hxmc.unsafe(gc) @:hxmc.export("rt_objc_is") static function objcIs(v:Dynamic, cls:Ptr, sel:Ptr, msgSend:Ptr):Bool {
		var id = idOf(v);
		// (BOOL: the result's low byte)
		return !id.isNull() && Ind.call3(msgSend, id, sel, cls).toI64().toInt() & 0xff != 0;
	}
}

@:hxmc.c @:hxmc.fast private extern class Ind {
	@:hxmc.indirect static function call0(f:Ptr):Ptr;
	@:hxmc.indirect static function call1(f:Ptr, a:Ptr):Ptr;
	@:hxmc.indirect static function call2(f:Ptr, a:Ptr, b:Ptr):Ptr;
	@:hxmc.indirect static function call3(f:Ptr, a:Ptr, b:Ptr, c:Ptr):Ptr;
}
