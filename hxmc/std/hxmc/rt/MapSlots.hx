package hxmc.rt;

// The storage of haxe.ds.IntMap, StringMap and ObjectMap: fixed-size arrays
// of zeros, false or nulls. A NativeArray (one allocation, Int and Bool
// elements packed). The element type must be a concrete one (Int, Bool,
// Dynamic): made for an erased type parameter, a NativeArray is a wrapper
// (rt/NArray).
//
// An index is tested against the array's own length. A map keeps its indexes
// in bounds while one thread uses it at a time; threads that use one map
// together, one of them writing, can see its arrays and its counts of
// different sizes (a growth between the reads), and the test turns what would
// be a load or a store outside the array into a throw (MapRace.TORN), where
// the race is, instead of a heap damaged where it shows later. Code without a
// GC point (@:hxmc.unsafe: no throw) tests the sizes it relies on first, then
// reads and writes without the test (`length`, `at`, `put`).
abstract MapSlots<T>(hxmc.NativeArray<T>) {
	public inline function new(n:Int) {
		this = new hxmc.NativeArray<T>(n);
	}

	public var length(get, never):Int;

	inline function get_length():Int return this.length;

	// (untested: the caller has tested the length)
	public inline function at(i:Int):T return this.unsafeGet(i);

	public inline function put(i:Int, v:T):Void this.unsafeSet(i, v);

	@:op([]) inline function get(i:Int):T {
		if (i < 0 || i >= this.length) throw MapRace.TORN;
		return this.unsafeGet(i);
	}

	@:op([]) inline function set(i:Int, v:T):T {
		if (i < 0 || i >= this.length) throw MapRace.TORN;
		this.unsafeSet(i, v);
		return v;
	}
}

// The maps' keys and values: storage of references, as MapSlots<Dynamic>,
// but typed with a class (never instantiated), so that its accesses are a
// load or a store (with the write barrier): a Dynamic element's test the
// storage's kind first, and their slow path (another kind: a conversion)
// would be a GC point in every lookup.
abstract RefSlots(hxmc.NativeArray<RefSlot>) {
	public inline function new(n:Int) {
		this = new hxmc.NativeArray<RefSlot>(n);
	}

	public var length(get, never):Int;

	inline function get_length():Int return this.length;

	// (untested: the caller has tested the length)
	public inline function at(i:Int):Dynamic return cast this.unsafeGet(i);

	public inline function put(i:Int, v:Dynamic):Void this.unsafeSet(i, cast v);

	@:op([]) inline function get(i:Int):Dynamic {
		if (i < 0 || i >= this.length) throw MapRace.TORN;
		return cast this.unsafeGet(i);
	}

	@:op([]) inline function set(i:Int, v:Dynamic):Dynamic {
		if (i < 0 || i >= this.length) throw MapRace.TORN;
		this.unsafeSet(i, cast v);
		return v;
	}
}

private class RefSlot {}

// A map used by threads together without a lock, one of them writing: what
// the maps throw, as Go's maps fail (`concurrent map writes`). A map is
// marked while a write is under way (its `writing`): a write that finds the
// mark, or a read or an iterator's step that does, throws (a throw where it
// is found, not a call: the fast path keeps no value live across a call). The mark is a
// plain field, not an atomic: it catches most such races, not all; the
// indexes' tests (MapSlots) keep the others from reaching outside the arrays.
class MapRace {
	// a write found another under way
	public static inline final WRITES = "concurrent map writes";
	// a read or an iterator's step found a write under way
	public static inline final READ_WRITE = "concurrent map read and map write";
	// an index outside the map's arrays: their sizes and its counts read during a write
	public static inline final TORN = "concurrent map access";
}
