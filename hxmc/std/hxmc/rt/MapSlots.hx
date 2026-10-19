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
