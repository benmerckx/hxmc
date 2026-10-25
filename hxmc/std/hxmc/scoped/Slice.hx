package hxmc.scoped;

import hxmc.rt.Abort;
import hxmc.unsafe.*;

// A view of a run of T (docs/plans/lowlevel.md, "Scoped memory"): rooted at
// what it views, a struct value (copying one copies the view, not the
// elements). Indexes are checked: out of range aborts (scoped code cannot
// throw). T is a scalar, a scoped class or enum, or another scoped type; a
// struct element is reached in place (`s[i].x = 1`). Scope.slice makes one;
// it brings in no data stacks itself (the maps' index views GC memory with
// it: hxmc.rt.MapIndex). Linear memory: an address and a length; WasmGC
// ("Two representations, one core"): the engine's array, an offset and a
// length (an object of final fields: Haxe's inline constructors keep one
// that does not escape in locals).
@:forward(length)
abstract Slice<T>(#if hxmc.wasm_gc SliceData<T> #else SliceData #end) {
	#if hxmc.wasm_gc
	public inline function new(a:NativeArray<T>, off:Int, length:Int)
		this = new SliceData(a, off, length);

	// (memory at an address: linear memory only; typed here, never run)
	@:noCompletion public static inline function raw<T>(p:Ptr, length:Int):Slice<T>
		return new Slice(new NativeArray<T>(0), 0, 0);

	@:noCompletion public inline function array():NativeArray<T>
		return this.a;

	@:noCompletion public inline function offset():Int
		return this.off;

	inline function at(i:Int):Int {
		if ((i : UInt) >= (this.length : UInt)) Abort.outOfRange();
		return this.off + i;
	}

	@:arrayAccess inline function get(i:Int):T
		return this.a.unsafeGet(at(i));

	@:hxmc.noScope @:arrayAccess inline function set(i:Int, v:T):T {
		this.a.unsafeSet(at(i), v);
		return v;
	}

	// a reference to element i
	public inline function ref(i:Int):Ref<T>
		return new Ref(new Ref.Holder(this.a), at(i));

	// the elements pos .. pos + len - 1, the same memory
	public inline function sub(pos:Int, len:Int):Slice<T> {
		if (pos < 0 || len < 0 || pos + len > this.length) Abort.outOfRange();
		return new Slice(this.a, this.off + pos, len);
	}

	public inline function iterator():SliceIterator<T>
		return new SliceIterator(this.a, this.off, this.off + this.length);

	// element i, unchecked: for the std's cores, whose views keep their
	// indexes in range by construction (hxmc.rt.MapIndex's masks)
	@:noCompletion public inline function unsafeGet(i:Int):T
		return this.a.unsafeGet(this.off + i);

	@:noCompletion public inline function unsafeSet(i:Int, v:T)
		this.a.unsafeSet(this.off + i, v);

	// the first n Ints of src into dst, unchecked (the cores')
	@:noCompletion public static inline function copyInts(dst:Slice<Int>, src:Slice<Int>, n:Int)
		NativeArray.blit(src.array(), src.offset(), dst.array(), dst.offset(), n);

	// the bytes i .. i + 3 of s as an Int, little-endian, unchecked (the cores')
	@:noCompletion public static inline function word(s:Slice<UInt8>, i:Int):Int {
		var a:NativeArray<UInt8> = s.array(), k = s.offset() + i;
		return (a.unsafeGet(k) : Int) | ((a.unsafeGet(k + 1) : Int) << 8) | ((a.unsafeGet(k + 2) : Int) << 16) | ((a.unsafeGet(k + 3) : Int) << 24);
	}
	#else
	public inline function new(p:Ptr<T>, length:Int)
		this = new SliceData(p, length);

	// the n Ts at an address (the trusted layer's: a C call's argument)
	@:noCompletion public static inline function raw<T>(p:Ptr, length:Int):Slice<T>
		return new Slice<T>(cast p, length);

	public inline function ptr():Ptr<T>
		return this.ptr;

	@:arrayAccess inline function get(i:Int):T {
		if ((i : UInt) >= (this.length : UInt)) Abort.outOfRange();
		return (this.ptr : Ptr<T>)[i];
	}

	@:hxmc.noScope @:arrayAccess inline function set(i:Int, v:T):T {
		if ((i : UInt) >= (this.length : UInt)) Abort.outOfRange();
		return (this.ptr : Ptr<T>)[i] = v;
	}

	// a reference to element i
	public inline function ref(i:Int):Ref<T> {
		if ((i : UInt) >= (this.length : UInt)) Abort.outOfRange();
		return new Ref((this.ptr : Ptr<T>).offset(i));
	}

	// the elements pos .. pos + len - 1, the same memory
	public inline function sub(pos:Int, len:Int):Slice<T> {
		if (pos < 0 || len < 0 || pos + len > this.length) Abort.outOfRange();
		return new Slice((this.ptr : Ptr<T>).offset(pos), len);
	}

	public inline function iterator():SliceIterator<T>
		return new SliceIterator((this.ptr : Ptr<T>), this.length);

	// element i, unchecked: for the std's cores, whose views keep their
	// indexes in range by construction (hxmc.rt.MapIndex's masks)
	@:noCompletion public inline function unsafeGet(i:Int):T
		return (this.ptr : Ptr<T>)[i];

	@:noCompletion public inline function unsafeSet(i:Int, v:T)
		(this.ptr : Ptr<T>)[i] = v;

	// the first n Ints of src into dst, unchecked (the cores')
	@:noCompletion public static inline function copyInts(dst:Slice<Int>, src:Slice<Int>, n:Int)
		LibC.memmove(dst.ptr(), src.ptr(), (4 * n : I64));

	// the bytes i .. i + 3 of s as an Int, little-endian, unchecked (the cores')
	@:noCompletion public static inline function word(s:Slice<UInt8>, i:Int):Int
		return Mem.getI32(s.ptr(), i);
	#end
}

#if hxmc.wasm_gc
@:hxmc.repr @:noCompletion class SliceData<T> {
	public final a:NativeArray<T>;
	public final off:Int;
	public final length:Int;

	public inline function new(a:NativeArray<T>, off:Int, length:Int) {
		this.a = a;
		this.off = off;
		this.length = length;
	}

	// the view of scoped memory just made (to the root checker: fresh, as a
	// data stack's; a call it sees)
	public static function fresh<T>(a:NativeArray<T>, length:Int):SliceData<T>
		return new SliceData(a, 0, length);

	// memory of the pool (to the root checker: rooted at it, as linearly)
	public static function of<T>(pool:Dynamic, a:NativeArray<T>, length:Int):SliceData<T>
		return new SliceData(a, 0, length);

	// a with its struct elements made, zero (the lowering's: CInterop.valueCopies)
	public static function zeroed<T>(a:NativeArray<T>):NativeArray<T>
		return a;
}

// (an inline constructor: Haxe's inliner makes its fields locals)
@:hxmc.repr @:noCompletion class SliceIterator<T> {
	var a:NativeArray<T>;
	var i:Int;
	var end:Int;

	public inline function new(a:NativeArray<T>, i:Int, end:Int) {
		this.a = a;
		this.i = i;
		this.end = end;
	}

	public inline function hasNext():Bool
		return i < end;

	public inline function next():T
		return a.unsafeGet(i++);
}
#else
@:hxmc.struct @:noCompletion class SliceData {
	public var ptr:Ptr;
	public var length:Int;

	public inline function new(p:Ptr, length:Int) {
		ptr = p;
		this.length = length;
	}
}

// (an inline constructor: Haxe's inliner makes its fields locals)
@:noCompletion class SliceIterator<T> {
	var p:Ptr<T>;
	var i:Int;
	var n:Int;

	public inline function new(p:Ptr<T>, n:Int) {
		this.p = p;
		this.n = n;
		i = 0;
	}

	public inline function hasNext():Bool
		return i < n;

	public inline function next():T
		return p[i++];
}
#end
