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

	@:arrayAccess inline function set(i:Int, v:T):T {
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
	#else
	public inline function new(p:Ptr<T>, length:Int)
		this = new SliceData(p, length);

	public inline function ptr():Ptr<T>
		return this.ptr;

	@:arrayAccess inline function get(i:Int):T {
		if ((i : UInt) >= (this.length : UInt)) Abort.outOfRange();
		return (this.ptr : Ptr<T>)[i];
	}

	@:arrayAccess inline function set(i:Int, v:T):T {
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
