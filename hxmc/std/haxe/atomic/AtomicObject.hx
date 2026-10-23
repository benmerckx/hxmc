// hxmc: haxe/upstream/std/hl/_std/haxe/atomic/AtomicObject.hx over a cell (a one-slot
// K_PARR object the collector scans) and the Atomic intrinsics (sequentially
// consistent; a reference stored into an old cell is remembered afterwards
// when it is young: rt_barrier_range of the slot), with the docs of
// haxe/upstream/std/haxe/atomic/AtomicObject.hx

package haxe.atomic;

import hxmc.rt.C.Leaf;
import hxmc.unsafe.Atomic;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Ptr;

/**
	Atomic object. Use with care, this does not magically make it thread-safe to mutate objects.
**/
abstract AtomicObject<T:{}>(Dynamic) {
	#if hxmc.wasm_gc
	// (-D hxmc.wasm-gc: the cell a NativeArray<Dynamic> of one element, there being no threads)
	static function cell(v:Dynamic):Dynamic {
		var a = new hxmc.NativeArray<Dynamic>(1);
		a[0] = v;
		return a;
	}

	static inline function arr(a:Dynamic):hxmc.NativeArray<Dynamic>
		return cast a;

	static function get(a:Dynamic):Dynamic
		return arr(a)[0];

	static function put(a:Dynamic, v:Dynamic)
		arr(a)[0] = v;

	static function swap(a:Dynamic, v:Dynamic):Dynamic {
		var o = arr(a)[0];
		arr(a)[0] = v;
		return o;
	}

	static function cas(a:Dynamic, e:Dynamic, r:Dynamic):Dynamic {
		var o = arr(a)[0];
		if (hxmc.rt.gc.W.same(o, e)) arr(a)[0] = r;
		return o;
	}
	#else
	static function cell(v:Dynamic):Dynamic {
		var a = Mem.alloc(1, hxmc.rt.Types.T_ADATA_P, 1); // K_PARR
		Mem.setRef(Mem.addr(a), 0, v); // (a is young)
		return a;
	}

	// (the cell's address is taken in functions that never reach a GC point:
	// inlined into the program, it could be taken before an allocation that
	// moves the cell)
	@:hxmc.noGc static function get(a:Dynamic):Dynamic
		return Mem.obj(Ptr.ofI64(Atomic.load64(Mem.addr(a))));

	@:hxmc.noGc static function put(a:Dynamic, v:Dynamic) {
		var p = Mem.addr(a);
		Atomic.store64(p, Mem.addr(v).toI64());
		Leaf.rt_barrier_range(a, p, 1);
	}

	@:hxmc.noGc static function swap(a:Dynamic, v:Dynamic):Dynamic {
		var p = Mem.addr(a);
		var o = Atomic.exchange64(p, Mem.addr(v).toI64());
		Leaf.rt_barrier_range(a, p, 1);
		return Mem.obj(Ptr.ofI64(o));
	}

	@:hxmc.noGc static function cas(a:Dynamic, e:Dynamic, r:Dynamic):Dynamic {
		var p = Mem.addr(a);
		var ei = Mem.addr(e).toI64();
		var o = Atomic.cas64(p, ei, Mem.addr(r).toI64());
		if (Ptr.ofI64(o) == Ptr.ofI64(ei)) Leaf.rt_barrier_range(a, p, 1);
		return Mem.obj(Ptr.ofI64(o));
	}
	#end

	public inline function new(value:T):Void {
		this = cell(value);
	}

	/**
		Atomically compares the value of `a` with `expected` and replaces `a` with `replacement` if they are equal..
		Returns the original value of `a`.

		Note that comparison is done by reference, and not by value.
		While this is expected for most objects, this might give unexpected behaviour for strings.
	**/
	public inline function compareExchange(expected:T, replacement:T):T {
		return cas(this, expected, replacement);
	}

	/**
		Atomically exchanges `a` with `value`.
		Returns the original value of `a`.
	**/
	public inline function exchange(value:T):T {
		return swap(this, value);
	}

	/**
		Atomically fetches the value of `a`.
	**/
	public inline function load():T {
		return get(this);
	}

	/**
		Atomically stores `value` into `a`.
		Returns the value that has been stored.
	**/
	public inline function store(value:T):T {
		put(this, value);
		return value;
	}
}
