package hxmc.rt;

// The storage of haxe.ds.IntMap, StringMap and ObjectMap: fixed-size arrays
// of zeros, false or nulls, read and written without the test of the index
// (the maps keep theirs in bounds). A NativeArray (one allocation, Int and
// Bool elements packed). The element type must be a concrete one (Int, Bool,
// Dynamic): made for an erased type parameter, a NativeArray is a wrapper
// (rt/NArray).
abstract MapSlots<T>(hxmc.NativeArray<T>) {
	public inline function new(n:Int) {
		this = new hxmc.NativeArray<T>(n);
	}

	@:op([]) inline function get(i:Int):T
		return this.unsafeGet(i);

	@:op([]) inline function set(i:Int, v:T):T {
		this.unsafeSet(i, v);
		return v;
	}
}

#if hxmc.wasm_gc
typedef RefSlots = MapSlots<Dynamic>;
#else
// The maps' keys and values: storage of references, as MapSlots<Dynamic>,
// but typed with a class (never instantiated), so that its accesses are a
// load or a store (with the write barrier): a Dynamic element's test the
// storage's kind first, and their slow path (another kind: a conversion)
// would be a GC point in every lookup. WasmGC keeps MapSlots<Dynamic> (a cast
// to the class would be checked there).
abstract RefSlots(hxmc.NativeArray<RefSlot>) {
	public inline function new(n:Int) {
		this = new hxmc.NativeArray<RefSlot>(n);
	}

	@:op([]) inline function get(i:Int):Dynamic
		return cast this.unsafeGet(i);

	@:op([]) inline function set(i:Int, v:Dynamic):Dynamic {
		this.unsafeSet(i, cast v);
		return v;
	}
}

private class RefSlot {}
#end
