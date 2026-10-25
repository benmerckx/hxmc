package hxmc.rt;

import hxmc.I64;
#if hxmc.wasm_gc
import hxmc.rt.gc.W;
#else
import hxmc.unsafe.Mem;
import hxmc.unsafe.Ptr;
#end

// An Array's elements as ArrayCore reads and moves them (docs/plans/lowlevel.md,
// "GC references in the core"), taken by the face (hxmc.rt.Arr) right before
// the call: the core has no GC point, so nothing moves under it. Linear
// memory: the storage's address and the length (references are addresses,
// compared as words); WasmGC: the Array object, read through the engine's
// accessors. The element kind is the face's to know (Repr.AK_*). Moves of
// references need the write barrier: the face runs it over what moved
// (Repr.arrBarrier), the core only moves.
abstract ArrayView(ArrayViewData) {
	#if hxmc.wasm_gc
	public static inline function of(a:Dynamic, n:Int):ArrayView
		return cast new ArrayViewData(a, n);
	#else
	public static inline function of(a:Dynamic, n:Int):ArrayView
		return cast new ArrayViewData(MemRepr.arrData(a), n);
	#end

	public var length(get, never):Int;

	inline function get_length():Int
		return this.length;

	#if hxmc.wasm_gc
	public inline function int(i:Int):Int
		return W.arrGetI(this.a, i);

	public inline function float(i:Int):Float
		return W.arrGetF(this.a, i);

	public inline function bool(i:Int):Int
		return W.arrGetB(this.a, i);

	public inline function long(i:Int):I64
		return W.arrGetL(this.a, i);

	// element i is the reference k
	public inline function isRef(i:Int, k:RefKey):Bool
		return W.same(W.arrGetP(this.a, i), k.o());

	// elements i and j swapped (es: the linear element size)
	public inline function swap(i:Int, j:Int, es:Int) {
		var t = W.arrGet(this.a, i);
		W.arrSet(this.a, i, W.arrGet(this.a, j));
		W.arrSet(this.a, j, t);
	}
	#else
	public inline function int(i:Int):Int
		return Mem.getI32At(this.p, 0, i);

	public inline function float(i:Int):Float
		return Mem.getF64At(this.p, 0, i);

	public inline function bool(i:Int):Int
		return Mem.getU8At(this.p, 0, i);

	public inline function long(i:Int):I64
		return Mem.getI64At(this.p, 0, i);

	public inline function isRef(i:Int, k:RefKey):Bool
		return Mem.getI64At(this.p, 0, i) == k.word();

	// elements i and j (of es bytes: 1, 4 or 8) swapped
	public inline function swap(i:Int, j:Int, es:Int) {
		if (es == 1) {
			var t = Mem.getU8At(this.p, 0, i);
			Mem.setU8At(this.p, 0, i, Mem.getU8At(this.p, 0, j));
			Mem.setU8At(this.p, 0, j, t);
		} else if (es == 4) {
			var t = Mem.getI32At(this.p, 0, i);
			Mem.setI32At(this.p, 0, i, Mem.getI32At(this.p, 0, j));
			Mem.setI32At(this.p, 0, j, t);
		} else {
			var t = Mem.getI64At(this.p, 0, i);
			Mem.setI64At(this.p, 0, i, Mem.getI64At(this.p, 0, j));
			Mem.setI64At(this.p, 0, j, t);
		}
	}
	#end
}

// a reference to look for by identity: its address linearly (no GC point
// while it is in use: the face makes it right before the call), the
// reference itself on WasmGC
abstract RefKey(#if hxmc.wasm_gc RefKeyData #else I64 #end) {
	#if hxmc.wasm_gc
	public static inline function of(x:Dynamic):RefKey
		return cast new RefKeyData(x);

	public inline function o():Dynamic
		return this.o;
	#else
	public static inline function of(x:Dynamic):RefKey
		return cast Mem.addr(x).toI64();

	public inline function word():I64
		return this;
	#end
}

#if hxmc.wasm_gc
@:hxmc.struct @:hxmc.repr @:noCompletion class ArrayViewData {
	public final a:Dynamic;
	public final length:Int;

	public inline function new(a:Dynamic, length:Int) {
		this.a = a;
		this.length = length;
	}
}

@:hxmc.struct @:hxmc.repr @:noCompletion class RefKeyData {
	public final o:Dynamic;

	public inline function new(o:Dynamic)
		this.o = o;
}
#else
@:hxmc.struct @:noCompletion class ArrayViewData {
	public final p:Ptr;
	public final length:Int;

	public inline function new(p:Ptr, length:Int) {
		this.p = p;
		this.length = length;
	}
}
#end
