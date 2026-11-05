package hxmc.rt;

import hxmc.I64;
import hxmc.rt.C;
import hxmc.unsafe.*;

// COM as a kind of foreign objects (Foreign; docs/interop.md, "COM"): the
// entry points generated code calls (hxmc.ir.Com, FnLower), over Foreign's
// peers and boxes.
//
// - **Foreign objects** (an interface pointer a call returned) are boxes:
//   one per interface pointer, keyed by the object's identity
//   (QueryInterface(IID_IUnknown), the canonical IUnknown) and told apart
//   by the pointer (same), so a box's reference is always of the interface
//   it was boxed as. A box holds one reference (AddRef), released once the
//   box dies, put off to the thread that boxed it (RELEASE_ON_MAKER: an
//   apartment-threaded object's Release belongs to its apartment's thread),
//   which runs it at its next allocation, when Gc.collect returns, from
//   Com.runDeferred (its message loop's, woken by a thread message: wake),
//   or as it ends.
// - **Haxe objects** of classes implementing COM interfaces are peers: the
//   runtime's own COM object (a block of malloc'd memory: its count, its
//   peer entry, its class's descriptor, then one vtable pointer per
//   interface; each vtable's word -1 its pointer's offset in the block),
//   made at the object's first use as a COM pointer and paired with it.
//   The block's QueryInterface, AddRef and Release are this class's (C
//   functions that touch the block only: any thread, any state). The toggle
//   is TOGGLE_RELEASE (IUnknown has no count query), on the block's own
//   count, so reading it in a collection's stop reads no foreign memory: the
//   Haxe object lives while COM holds the block beyond the pairing's
//   reference. The block is freed when its count reaches zero: the pairing's
//   reference, released once the Haxe object died.
// - **Calls** of Haxe objects' methods (Lower's thunks) find the Haxe object
//   through the block (self); a thread the runtime did not start is
//   attached first, as Objective-C's callbacks attach theirs.
//
// The runtime links no COM library: ole32's, oleaut32's and user32's
// functions are found by name (LoadLibraryA, GetProcAddress) at their first
// use. Windows only (@:hxmc.os): elsewhere the lowering makes every COM
// operation a throw.
@:hxmc.os("windows") @:keep @:allow(hxmc.rt) @:allow(hxmc.com) @:access(hxmc.rt.Str)
class ComKind {
	static inline var S_OK = 0;
	static inline var E_NOINTERFACE = 0x80004002;
	static inline var E_POINTER = 0x80004003;
	static inline var E_FAIL = 0x80004005;
	static inline var E_UNEXPECTED = 0x8000FFFF;
	// the thread message that wakes an apartment's message loop for the
	// releases put off for it (WM_APP + 0x3C3: Com.WM_DEFERRED)
	public static inline var WM_DEFERRED = 0x8000 + 0x3C3;

	// ---- a Haxe object's block: its count (the pairing's reference and
	// COM's), its peer entry, its descriptor, its interfaces' vtables
	static inline var B_COUNT = 0;
	static inline var B_ENTRY = 8;
	static inline var B_DESC = 16;
	static inline var B_IFACES = 24;

	// ---- a class's descriptor (rt_com_desc, filled by the class's
	// descriptor function: hxmc.ir.Com): the number of interfaces, the
	// offset of the object's field holding its block, then per interface its
	// vtable, the number of its IIDs and their words (its own first, then
	// its bases' but IUnknown's; four 32-bit words each)
	static inline var D_N = 0;
	static inline var D_FIELD = 8;
	static inline var D_IFACES = 16;
	static inline var IFACE_BYTES = 24; // vtable, niids, iids
	static inline var MAX_IIDS = 16;

	// (0: not registered yet; published with a release store once registered,
	// read with an acquire load: known)
	@:hxmc.export("rt_com_kind") static var kind:Int;
	// (blockOf: a Haxe object's block made and paired at most once)
	static var blockLock:Ptr;
	// a descriptor per type index (the Haxe classes implementing COM
	// interfaces): the table published once filled, each entry once its
	// descriptor is (release stores; read lock-free with acquire loads)
	@:hxmc.export("rt_com_types") static var types:Ptr;
	// the GUIDs of strings interned (guid): chunks of IIDS_PER_CHUNK, 16 bytes
	// each after a word linking the previous chunk, never freed (an
	// interface's IID is the program's data: hxmc.ir.Com)
	static inline var IIDS_PER_CHUNK = 64;
	static var iids:Ptr;
	static var niids:Int;
	// a thread's Win32 id per runtime thread id (Com.init), for wake: read
	// under Foreign.lock, which noteThread's realloc takes
	static var tids:Ptr;
	static var tidsCap:Int;
	// the system's functions, found at their first use
	static var ole32:Ptr;
	static var oleaut32:Ptr;
	static var fCoTaskMemAlloc:Ptr;
	static var fCoCreateInstance:Ptr;
	static var fVariantClear:Ptr;
	static var fCoTaskMemFree:Ptr;
	static var fSysAllocStringLen:Ptr;
	static var fSysFreeString:Ptr;
	static var fPostThreadMessageW:Ptr;

	// the kind once registered (0: not yet)
	@:hxmc.unsafe static inline function known():Int
		return Atomic.load32(Mem.sym("rt_com_kind"));

	// the kind, registered at the first call
	@:hxmc.unsafe static function k():Int {
		var k = known();
		if (k != 0) return k;
		Os.lock(Foreign.lock);
		if (kind == 0) {
			var d = Mem.stack(120);
			LibC.memset(d, 0, Foreign.KIND_BYTES);
			Mem.setPtr(d, Foreign.K_NAME, Mem.cstr("com"));
			Mem.setI64(d, Foreign.K_FLAGS, Foreign.TOGGLE_RELEASE | Foreign.RELEASE_ON_MAKER);
			Mem.setI64(d, Foreign.K_THRESHOLD, 1);
			Mem.setPtr(d, Foreign.K_RETAIN, Callback.addr(retain));
			Mem.setPtr(d, Foreign.K_RELEASE, Callback.addr(release));
			Mem.setPtr(d, Foreign.K_IDENTITY, Callback.addr(identity));
			Mem.setPtr(d, Foreign.K_SAME, Callback.addr(same));
			Mem.setPtr(d, Foreign.K_PEER, Callback.addr(peerOf));
			Mem.setPtr(d, Foreign.K_WAKE, Callback.addr(wake));
			blockLock = LibC.malloc(Os.MUTEX_BYTES);
			Os.mutexInit(blockLock);
			Atomic.store32(Mem.sym("rt_com_kind"), Foreign.registerLocked(d));
		}
		Os.unlock(Foreign.lock);
		return kind;
	}

	// ---- calls through vtables (slot i of the interface pointer p)

	@:hxmc.unsafe static inline function slot(p:Ptr, i:Int):Ptr
		return Mem.getPtr(Mem.getPtr(p, 0), 8 * i);

	@:hxmc.unsafe static inline function addRefOf(p:Ptr):Int
		return Ind.call1(slot(p, 1), p).toI64().toInt();

	@:hxmc.unsafe static inline function releaseOf(p:Ptr):Int
		return Ind.call1(slot(p, 2), p).toI64().toInt();

	// QueryInterface(riid, ppv): the HRESULT
	@:hxmc.unsafe static inline function queryOf(p:Ptr, riid:Ptr, ppv:Ptr):Int
		return Ind.call3(slot(p, 0), p, riid, ppv).toI64().toInt();

	// ---- the kind's hooks: C functions (any thread, out of a collection's
	// stop: the toggle's retain and release, on the runtime's own blocks,
	// before it, Foreign.beforeStop)

	@:hxmc.callback @:hxmc.unsafe static function retain(ref:Ptr):Ptr {
		addRefOf(ref);
		return ref;
	}

	// (the count left: ULONG, zero-extended). A foreign object's Release in a
	// safe region (a proxy's last one is a call to its apartment; a
	// destructor may call back into Haxe): this hook runs on a thread of the
	// runtime's (detach's, a put-off call's: in a region already), never in
	// a collection's stop; the toggle's releases of the runtime's own blocks
	// are made before it, under Foreign's lock, without a region
	@:hxmc.callback @:hxmc.unsafe static function release(ref:Ptr):Ptr {
		if (Mem.getPtr(Mem.getPtr(ref, 0), 16) == Callback.addr(releaseSelf)) return Ptr.ofI64((releaseOf(ref) : I64) & 0xFFFFFFFF);
		var region = Leaf.rt_blocking_enter();
		var n = releaseOf(ref);
		Regions.end(region);
		return Ptr.ofI64((n : I64) & 0xFFFFFFFF);
	}

	// the object's identity: its canonical IUnknown (borrowed), else ref
	// (outside a safe region: a proxy's QueryInterface(IID_IUnknown) is its
	// proxy manager's, answered in this apartment)
	@:hxmc.callback @:hxmc.unsafe static function identity(ref:Ptr):Ptr {
		var out = Mem.stack(16);
		Mem.setPtr(out, 0, Ptr.nil());
		if (queryOf(ref, unknownIid(), out) < 0) return ref;
		var u = Mem.getPtr(out, 0);
		if (u.isNull()) return ref;
		releaseOf(u);
		return u;
	}

	// two references of one object are one box when they are one pointer
	// (an interface pointer's box calls through its own vtable)
	@:hxmc.callback @:hxmc.unsafe static function same(a:Ptr, b:Ptr):Ptr
		return a == b ? Ptr.ofI64(1) : Ptr.nil();

	// the peer entry of ref: the block's, when ref is one of the runtime's
	// own COM objects (its QueryInterface this class's), else -1
	@:hxmc.callback @:hxmc.unsafe static function peerOf(ref:Ptr):Ptr {
		var vt = Mem.getPtr(ref, 0);
		if (Mem.getPtr(vt, 0) != Callback.addr(queryInterface)) return Ptr.ofI64(-1);
		return Mem.getPtr(baseOf(ref), B_ENTRY);
	}

	// releases were put off for runtime thread t: its message loop told
	// (PostThreadMessageW; none when t never called Com.init)
	@:hxmc.callback @:hxmc.unsafe static function wake(t:Ptr):Void {
		var i = t.toI64().toInt();
		// (noteThread reallocs the table under the lock; PostThreadMessageW,
		// which does not block, after it)
		Os.lock(Foreign.lock);
		var tid = i > 0 && i < tidsCap ? Mem.getI32(tids, 4 * i) : 0;
		var post = fPostThreadMessageW;
		Os.unlock(Foreign.lock);
		if (tid == 0 || post.isNull()) return;
		Ind.call4(post, Ptr.ofI64((tid : I64) & 0xFFFFFFFF), Ptr.ofI64(WM_DEFERRED), Ptr.nil(), Ptr.nil());
	}

	// ---- the runtime's own COM objects (a Haxe object's block)

	@:hxmc.unsafe static inline function baseOf(self:Ptr):Ptr
		return self.addL(-Mem.getI64(Mem.getPtr(self, 0), -8));

	@:hxmc.callback @:hxmc.unsafe static function queryInterface(self:Ptr, riid:Ptr, ppv:Ptr):Int {
		if (ppv.isNull()) return E_POINTER;
		Mem.setPtr(ppv, 0, Ptr.nil());
		if (riid.isNull()) return E_POINTER;
		var base = baseOf(self);
		var r = Ptr.nil();
		if (LibC.memcmp(riid, unknownIid(), 16) == 0) r = base.add(B_IFACES) else {
			var d = Mem.getPtr(base, B_DESC);
			var n = Mem.getI64(d, D_N).toInt();
			for (i in 0...n) {
				var e = d.add(D_IFACES + IFACE_BYTES * i);
				var ids = Mem.getPtr(e, 16);
				for (j in 0...Mem.getI64(e, 8).toInt())
					if (LibC.memcmp(riid, ids.add(16 * j), 16) == 0) {
						r = base.add(B_IFACES + 8 * i);
						break;
					}
				if (!r.isNull()) break;
			}
		}
		if (r.isNull()) return E_NOINTERFACE;
		Atomic.add32(base.add(B_COUNT), 1);
		Mem.setPtr(ppv, 0, r);
		return S_OK;
	}

	@:hxmc.callback @:hxmc.unsafe static function addRef(self:Ptr):Int
		return Atomic.add32(baseOf(self).add(B_COUNT), 1) + 1;

	// (zero: the pairing's reference was the last, released once the Haxe
	// object died: the block freed)
	@:hxmc.callback @:hxmc.unsafe static function releaseSelf(self:Ptr):Int {
		var base = baseOf(self);
		var n = Atomic.add32(base.add(B_COUNT), -1) - 1;
		if (n == 0) LibC.free(base);
		return n;
	}

	// ---- descriptors (the generated descriptor function of a class,
	// hxmc.ir.Com.descBody, called once per type by the first constructor
	// that runs: rt_com_known)

	// whether o's type has its descriptor
	@:hxmc.host("rt_com_known") static function typeKnown(o:Dynamic):Int
		return descOf(o).isNull() ? 0 : 1;

	// a descriptor of n interfaces
	@:hxmc.host("rt_com_desc") @:hxmc.unsafe static function desc(n:Int):Ptr {
		var d = LibC.malloc((D_IFACES + IFACE_BYTES * n : I64));
		LibC.memset(d, 0, (D_IFACES + IFACE_BYTES * n : I64));
		Mem.setI64(d, D_N, n);
		return d;
	}

	// interface i's vtable (nslots words after the offset word, IUnknown's
	// three filled), with its IID (w0..w3)
	@:hxmc.host("rt_com_vtable") @:hxmc.unsafe static function vtable(d:Ptr, i:Int, nslots:Int, w0:Int, w1:Int, w2:Int, w3:Int):Ptr {
		var w = LibC.malloc((8 * (nslots + 1) : I64));
		LibC.memset(w, 0, (8 * (nslots + 1) : I64));
		Mem.setI64(w, 0, B_IFACES + 8 * i);
		var vt = w.add(8);
		Mem.setPtr(vt, 0, Callback.addr(queryInterface));
		Mem.setPtr(vt, 8, Callback.addr(addRef));
		Mem.setPtr(vt, 16, Callback.addr(releaseSelf));
		var e = d.add(D_IFACES + IFACE_BYTES * i);
		Mem.setPtr(e, 0, vt);
		Mem.setPtr(e, 16, LibC.malloc(16 * MAX_IIDS));
		ifaceIid(d, i, w0, w1, w2, w3);
		return vt;
	}

	// one more IID interface i answers QueryInterface for (a base's)
	@:hxmc.host("rt_com_iface_iid") @:hxmc.unsafe static function ifaceIid(d:Ptr, i:Int, w0:Int, w1:Int, w2:Int, w3:Int):Void {
		var e = d.add(D_IFACES + IFACE_BYTES * i);
		var n = Mem.getI64(e, 8).toInt();
		if (n == MAX_IIDS) return;
		var g = Mem.getPtr(e, 16).add(16 * n);
		Mem.setI32(g, 0, w0);
		Mem.setI32(g, 4, w1);
		Mem.setI32(g, 8, w2);
		Mem.setI32(g, 12, w3);
		Mem.setI64(e, 8, n + 1);
	}

	// o's type gets descriptor d (once: another thread's wins), the block in
	// o's field at byte offset off
	@:hxmc.host("rt_com_register") static function register(o:Dynamic, d:Ptr, off:Int):Void {
		Mem.setI64(d, D_FIELD, off);
		var t = Types.tindex(o);
		Os.lock(Foreign.lock);
		var ts = types;
		if (ts.isNull()) {
			// (filled before it is published: known and descOf read it without the lock)
			ts = LibC.malloc(8 * 65536);
			LibC.memset(ts, 0, 8 * 65536);
			Atomic.store64(Mem.sym("rt_com_types"), ts.toI64());
		}
		if (Mem.getPtr(ts, 8 * t).isNull()) Atomic.store64(ts.add(8 * t), d.toI64());
		Os.unlock(Foreign.lock);
	}

	// the block of Haxe object o (descriptor d), made and paired at its first use
	static function blockOf(o:Dynamic, d:Ptr):Ptr {
		var off = Mem.getI64(d, D_FIELD).toInt();
		var b = Mem.getPtr(Mem.addr(o), off);
		if (!b.isNull()) return b;
		var k = k();
		// (one thread makes it, paired before any other sees it; no GC point
		// while the lock is held)
		Os.lock(blockLock);
		b = Mem.getPtr(Mem.addr(o), off);
		if (b.isNull()) {
			var n = Mem.getI64(d, D_N).toInt();
			b = LibC.malloc((B_IFACES + 8 * n : I64));
			Mem.setI32(b, B_COUNT, 1);
			Mem.setI32(b, B_COUNT + 4, 0);
			Mem.setPtr(b, B_DESC, d);
			for (i in 0...n)
				Mem.setPtr(b, B_IFACES + 8 * i, Mem.getPtr(d, D_IFACES + IFACE_BYTES * i));
			Mem.setI64(b, B_ENTRY, Foreign.pair(k, o, b.add(B_IFACES), false));
			Mem.setPtr(Mem.addr(o), off, b);
		}
		Os.unlock(blockLock);
		return b;
	}

	// the descriptor of Haxe object o's type, or null
	@:hxmc.unsafe static inline function descOf(o:Dynamic):Ptr {
		var ts = Ptr.ofI64(Atomic.load64(Mem.sym("rt_com_types")));
		return ts.isNull() ? Ptr.nil() : Ptr.ofI64(Atomic.load64(ts.add(8 * Types.tindex(o))));
	}

	// ---- values

	// the interface pointer of v for the interface of IID w0..w3 (borrowed:
	// valid while v lives): a box's reference, or the interface's in the
	// block of a Haxe object implementing it; null for null
	@:hxmc.host("rt_com_ptr") static function ptr(v:Dynamic, w0:Int, w1:Int, w2:Int, w3:Int):Ptr {
		if (v == null) return Ptr.nil();
		// (a box of this kind's, not any native handle: Foreign.isBox)
		if (isBox(v)) {
			var r = Mem.getPtr(Mem.addr(v), 0);
			if (r.isNull()) throw new hxmc.com.ComException(E_POINTER, "a COM object used after Com.detach");
			return r;
		}
		var d = Types.tindex(v) == Types.T_NATIVE ? Ptr.nil() : descOf(v);
		if (d.isNull()) throw new hxmc.com.ComException(E_NOINTERFACE, Std.string(v) + " is no COM object");
		var b = blockOf(v, d);
		var n = Mem.getI64(d, D_N).toInt();
		for (i in 0...n) {
			var e = d.add(D_IFACES + IFACE_BYTES * i);
			var ids = Mem.getPtr(e, 16);
			for (j in 0...Mem.getI64(e, 8).toInt()) {
				var g = ids.add(16 * j);
				if (Mem.getI32(g, 0) == w0 && Mem.getI32(g, 4) == w1 && Mem.getI32(g, 8) == w2 && Mem.getI32(g, 12) == w3)
					return b.add(B_IFACES + 8 * i);
			}
		}
		// (IUnknown: the first)
		if (w0 == 0 && w1 == 0 && w2 == 0xC0 && w3 == 0x46000000) return b.add(B_IFACES);
		throw new hxmc.com.ComException(E_NOINTERFACE, Std.string(v) + " does not implement the interface");
	}

	// the same, owned (+1): what a Haxe method returns to COM ([out, retval])
	@:hxmc.host("rt_com_out") static function out(v:Dynamic, w0:Int, w1:Int, w2:Int, w3:Int):Ptr {
		var p = ptr(v, w0, w1, w2, w3);
		if (!p.isNull()) addRefOf(p);
		return p;
	}

	// a borrowed interface pointer as a value: the Haxe object it is the
	// block of, else its box (which holds a reference of its own)
	@:hxmc.host("rt_com_wrap") static function wrap(p:Ptr):Dynamic
		return p.isNull() ? null : Foreign.box(k(), p);

	// an owned interface pointer (an [out] one) as a value: wrapped, and
	// the caller's reference released
	@:hxmc.host("rt_com_adopt") static function adopt(p:Ptr):Dynamic {
		if (p.isNull()) return null;
		var b = Foreign.box(k(), p);
		releaseOf(p);
		return b;
	}

	// whether v is a box of this kind (detached or not)
	static function isBox(v:Dynamic):Bool {
		var k = known();
		return k != 0 && Foreign.isBox(k, Mem.addr(v));
	}

	// any interface pointer of v (a box's, a Haxe object's first), borrowed
	static function anyPtr(v:Dynamic):Ptr
		return ptr(v, 0, 0, 0xC0, 0x46000000);

	// the same, or null when v is no COM value (another value, a detached box)
	static function anyPtrOrNull(v:Dynamic):Ptr {
		if (v == null) return Ptr.nil();
		if (isBox(v)) return Mem.getPtr(Mem.addr(v), 0);
		var d = Types.tindex(v) == Types.T_NATIVE ? Ptr.nil() : descOf(v);
		return d.isNull() ? Ptr.nil() : blockOf(v, d).add(B_IFACES);
	}

	// QueryInterface of v (IID w0..w3): the value, or null (E_NOINTERFACE,
	// and a value that is no COM object: Std.isOfType's false,
	// Std.downcast's null; Com.as and cast throw)
	@:hxmc.host("rt_com_query") static function query(v:Dynamic, w0:Int, w1:Int, w2:Int, w3:Int):Dynamic {
		var p = anyPtrOrNull(v);
		if (p.isNull()) return null;
		var g = Mem.stack(16);
		Mem.setI32(g, 0, w0);
		Mem.setI32(g, 4, w1);
		Mem.setI32(g, 8, w2);
		Mem.setI32(g, 12, w3);
		var out = Mem.stack(16);
		Mem.setPtr(out, 0, Ptr.nil());
		var hr = queryIn(p, g, out);
		if (hr == E_NOINTERFACE) return null;
		if (hr < 0) throw new hxmc.com.ComException(hr);
		return adopt(Mem.getPtr(out, 0));
	}

	// the same of an IID's address (Com.query)
	static function queryIid(v:Dynamic, g:Ptr):Dynamic
		return query(v, Mem.getI32(g, 0), Mem.getI32(g, 4), Mem.getI32(g, 8), Mem.getI32(g, 12));

	// (Com.as: E_NOINTERFACE thrown)
	static function asIid(v:Dynamic, g:Ptr):Dynamic {
		if (v == null) return null;
		var r = queryIid(v, g);
		if (r == null) throw new hxmc.com.ComException(E_NOINTERFACE);
		return r;
	}

	// (Com.ptr)
	static function ptrIid(v:Dynamic, g:Ptr):Ptr
		return ptr(v, Mem.getI32(g, 0), Mem.getI32(g, 4), Mem.getI32(g, 8), Mem.getI32(g, 12));

	// (Com.guid)
	static function guid(s:String):Ptr {
		var w = hxmc.com.Guids.parse(s);
		return iid(w[0], w[1], w[2], w[3]);
	}

	// an object of class clsid made, as the interface of IID riid (CoCreateInstance)
	static function create(clsid:Ptr, context:Int, riid:Ptr):Dynamic {
		if (fCoCreateInstance.isNull()) fCoCreateInstance = sys(0, Mem.cstr("CoCreateInstance"));
		var out = Mem.stack(16);
		Mem.setPtr(out, 0, Ptr.nil());
		var region = Leaf.rt_blocking_enter();
		var hr = Ind.call5(fCoCreateInstance, clsid, Ptr.nil(), Ptr.ofI64(context), riid, out).toI64().toInt();
		Regions.end(region);
		if (hr < 0) throw new hxmc.com.ComException(hr);
		return adopt(Mem.getPtr(out, 0));
	}

	// (a QueryInterface the object may answer by calling back into Haxe: a
	// Haxe object's is the runtime's, a foreign one's in a safe region)
	static function queryIn(p:Ptr, riid:Ptr, out:Ptr):Int {
		var region = Leaf.rt_blocking_enter();
		var hr = queryOf(p, riid, out);
		Regions.end(region);
		return hr;
	}

	// whether a and b are one COM object (their canonical IUnknowns)
	static function same2(a:Dynamic, b:Dynamic):Bool {
		if (a == null || b == null) return a == b;
		return identity(anyPtr(a)) == identity(anyPtr(b));
	}

	// the count of v's object after an AddRef and a Release (a diagnostic:
	// a Haxe object's includes its pairing's reference)
	static function refCount(v:Dynamic):Int {
		var p = anyPtr(v);
		addRefOf(p);
		return releaseOf(p);
	}

	// the interned GUID w0..w3 (16 bytes, never freed: one per GUID, in every chunk)
	static function iid(w0:Int, w1:Int, w2:Int, w3:Int):Ptr {
		Os.lock(Foreign.lock);
		var c = iids, n = niids;
		while (!c.isNull()) {
			for (i in 0...n) {
				var g = c.add(8 + 16 * i);
				if (Mem.getI32(g, 0) == w0 && Mem.getI32(g, 4) == w1 && Mem.getI32(g, 8) == w2 && Mem.getI32(g, 12) == w3) {
					Os.unlock(Foreign.lock);
					return g;
				}
			}
			// (the previous chunks are full)
			c = Mem.getPtr(c, 0);
			n = IIDS_PER_CHUNK;
		}
		if (iids.isNull() || niids == IIDS_PER_CHUNK) {
			// (a new chunk: interned GUIDs never move)
			var chunk = LibC.malloc(8 + 16 * IIDS_PER_CHUNK);
			Mem.setPtr(chunk, 0, iids);
			iids = chunk;
			niids = 0;
		}
		var g = iids.add(8 + 16 * niids++);
		Mem.setI32(g, 0, w0);
		Mem.setI32(g, 4, w1);
		Mem.setI32(g, 8, w2);
		Mem.setI32(g, 12, w3);
		Os.unlock(Foreign.lock);
		return g;
	}

	@:hxmc.unsafe static inline function unknownIid():Ptr
		return Mem.words("000000000000000046000000000000c0", 16);

	// ---- the Haxe side of a thunk (hxmc.ir.Com.thunk)

	// the Haxe object of a block's interface pointer (null: collected, which
	// COM holding the pointer prevents; a call after its last Release)
	@:hxmc.host("rt_com_self") static function self(p:Ptr):Dynamic
		return Foreign.peerGet(Mem.getI64(baseOf(p), B_ENTRY).toInt());

	// the HRESULT a Haxe method's exception returns to COM: a
	// ComException's, else E_FAIL
	@:hxmc.host("rt_com_hresult") static function hresultOf(e:Dynamic):Int {
		var x = Std.downcast(e, hxmc.com.ComException);
		return x != null ? x.hresult : E_FAIL;
	}

	// a failed HRESULT (< 0) of a call: thrown
	@:hxmc.host("rt_com_fail") static function fail(hr:Int):Void
		throw new hxmc.com.ComException(hr);

	// ---- strings: LPCWSTR (UTF-16, NUL-terminated), BSTR (length-prefixed)

	static function sys(lib:Int, name:Ptr):Ptr {
		if (ole32.isNull()) {
			ole32 = K.LoadLibraryA(Mem.cstr("ole32.dll"));
			oleaut32 = K.LoadLibraryA(Mem.cstr("oleaut32.dll"));
		}
		var f = K.GetProcAddress(lib == 0 ? ole32 : oleaut32, name);
		if (f.isNull()) Gc.dieC(Mem.cstr("hxmc: COM: a function of ole32 or oleaut32 is missing\n"));
		return f;
	}

	static function taskAlloc(n:I64):Ptr {
		if (fCoTaskMemAlloc.isNull()) fCoTaskMemAlloc = sys(0, Mem.cstr("CoTaskMemAlloc"));
		return Ind.call1(fCoTaskMemAlloc, Ptr.ofI64(n));
	}

	@:hxmc.host("rt_com_task_free") static function taskFree(p:Ptr):Void {
		if (p.isNull()) return;
		if (fCoTaskMemFree.isNull()) fCoTaskMemFree = sys(0, Mem.cstr("CoTaskMemFree"));
		Ind.call1(fCoTaskMemFree, p);
	}

	// s's units at p (n of them), and a NUL
	static function copyUnits(s:String, p:Ptr) {
		var n = Str.len(s);
		if (Str.isOne(s)) {
			var c:Ptr = Str.chars1(s);
			for (i in 0...n)
				Mem.setI16(p, 2 * i, Mem.getU8(c, i));
		} else if (n > 0) LibC.memcpy(p, Str.chars2(s), (2 * n : I64));
		Mem.setI16(p, 2 * n, 0);
	}

	// the string of n units at p
	static function ofUnits(p:Ptr, n:Int):String {
		var r = Str.make2(n);
		if (n > 0) LibC.memcpy(Str.chars2(r), p, (2 * n : I64));
		return Repr.fitsOne(Str.chars2(r), 0, n) ? Str.range(r, 0, n) : r;
	}

	// an LPCWSTR of s for the call (malloc'd: rt_com_wstr_free after it; null for null)
	@:hxmc.host("rt_com_wstr") static function wstr(s:String):Ptr {
		if (s == null) return Ptr.nil();
		var p = LibC.malloc((2 * Str.len(s) + 2 : I64));
		copyUnits(s, p);
		return p;
	}

	@:hxmc.host("rt_com_wstr_free") @:hxmc.unsafe static function wstrFree(p:Ptr):Void
		if (!p.isNull()) LibC.free(p);

	// the string of a NUL-terminated UTF-16 string (borrowed; null: null)
	@:hxmc.host("rt_com_wstr_string") static function wstrString(p:Ptr):String {
		if (p.isNull()) return null;
		var n = 0;
		while (Mem.getU16(p, 2 * n) != 0)
			n++;
		return ofUnits(p, n);
	}

	// an [out] LPWSTR (CoTaskMemAlloc's): its string, the memory freed
	@:hxmc.host("rt_com_wstr_take") static function wstrTake(p:Ptr):String {
		var s = wstrString(p);
		taskFree(p);
		return s;
	}

	// an [out] LPWSTR a Haxe method returns: CoTaskMemAlloc's, the caller's to free
	@:hxmc.host("rt_com_wstr_out") static function wstrOut(s:String):Ptr {
		if (s == null) return Ptr.nil();
		var p = taskAlloc((2 * Str.len(s) + 2 : I64));
		copyUnits(s, p);
		return p;
	}

	// a BSTR of s (SysAllocStringLen; null: null), the caller's to free
	@:hxmc.host("rt_com_bstr") static function bstr(s:String):Ptr {
		if (s == null) return Ptr.nil();
		if (fSysAllocStringLen.isNull()) fSysAllocStringLen = sys(1, Mem.cstr("SysAllocStringLen"));
		var n = Str.len(s);
		var p = Ind.call2(fSysAllocStringLen, Ptr.nil(), Ptr.ofI64(n));
		if (p.isNull()) throw new hxmc.com.ComException(0x8007000E);
		copyUnits(s, p);
		return p;
	}

	@:hxmc.host("rt_com_bstr_free") static function bstrFree(p:Ptr):Void {
		if (p.isNull()) return;
		if (fSysFreeString.isNull()) fSysFreeString = sys(1, Mem.cstr("SysFreeString"));
		Ind.call1(fSysFreeString, p);
	}

	// the string of a BSTR (borrowed; its length the prefix's: embedded NULs
	// kept; null: an empty string, as COM reads it)
	@:hxmc.host("rt_com_bstr_string") static function bstrString(p:Ptr):String {
		if (p.isNull()) return "";
		return ofUnits(p, Mem.getI32(p, -4) >>> 1);
	}

	// an [out] BSTR: its string, the BSTR freed
	@:hxmc.host("rt_com_bstr_take") static function bstrTake(p:Ptr):String {
		var s = bstrString(p);
		bstrFree(p);
		return s;
	}

	// ---- VARIANTs (hxmc.com.Variants)

	// v's IUnknown, +1 (a variant's punkVal)
	static function ownedUnknown(v:Dynamic):Ptr {
		var p = anyPtr(v);
		addRefOf(p);
		return p;
	}

	static function variantClear(v:Ptr):Void {
		if (fVariantClear.isNull()) fVariantClear = sys(1, Mem.cstr("VariantClear"));
		var region = Leaf.rt_blocking_enter();
		Ind.call1(fVariantClear, v);
		Regions.end(region);
	}

	// ---- apartments (hxmc.com.Com)

	// the calling thread's Win32 id noted for wake (Com.init)
	static function noteThread() {
		var t = Foreign.me();
		if (t <= 0) return;
		k();
		Os.lock(Foreign.lock);
		if (t >= tidsCap) {
			var cap = tidsCap == 0 ? 64 : tidsCap;
			while (cap <= t)
				cap *= 2;
			tids = LibC.realloc(tids, (4 * cap : I64));
			LibC.memset(tids.add(4 * tidsCap), 0, (4 * (cap - tidsCap) : I64));
			tidsCap = cap;
		}
		Mem.setI32(tids, 4 * t, K.GetCurrentThreadId());
		if (fPostThreadMessageW.isNull()) {
			var user32 = K.LoadLibraryA(Mem.cstr("user32.dll"));
			if (!user32.isNull()) fPostThreadMessageW = K.GetProcAddress(user32, Mem.cstr("PostThreadMessageW"));
		}
		Os.unlock(Foreign.lock);
	}

	// the calling thread no longer has an apartment (Com.uninit)
	static function forgetThread() {
		var t = Foreign.me();
		Os.lock(Foreign.lock);
		if (t > 0 && t < tidsCap) Mem.setI32(tids, 4 * t, 0);
		Os.unlock(Foreign.lock);
	}

	// v (a box) gives up its reference now (Foreign.detach)
	static function detach(v:Dynamic):Void {
		var k = known();
		if (k != 0 && v != null) Foreign.detach(k, v);
	}
}

// calls through C function pointers (vtables' slots, the system's functions)
@:hxmc.c @:hxmc.fast private extern class Ind {
	@:hxmc.indirect static function call1(f:Ptr, a:Ptr):Ptr;
	@:hxmc.indirect static function call2(f:Ptr, a:Ptr, b:Ptr):Ptr;
	@:hxmc.indirect static function call3(f:Ptr, a:Ptr, b:Ptr, c:Ptr):Ptr;
	@:hxmc.indirect static function call4(f:Ptr, a:Ptr, b:Ptr, c:Ptr, d:Ptr):Ptr;
	@:hxmc.indirect static function call5(f:Ptr, a:Ptr, b:Ptr, c:Ptr, d:Ptr, e:Ptr):Ptr;
}

@:hxmc.c @:hxmc.lib("kernel32") private extern class K {
	static function LoadLibraryA(name:Ptr):Ptr;
	@:hxmc.fast static function GetProcAddress(m:Ptr, name:Ptr):Ptr;
	@:hxmc.fast static function GetCurrentThreadId():Int;
}
