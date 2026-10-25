package hxmc.scoped;

#if !hxmc.wasm_gc
import hxmc.rt.DataStacks;
#end
import hxmc.rt.MapIndex;
import hxmc.rt.MapIndex.IndexView;
import hxmc.unsafe.*;
import hxmc.scoped.Slice;

// A table of Int keys in scoped memory (docs/plans/lowlevel.md, "One core,
// two faces"): the maps' index (hxmc.rt.MapIndex, which haxe.ds.IntMap uses
// too) over slots in a Pool, the keys and values in Grows, in insertion
// order; a reference to a value stays valid as the table grows. It only
// grows (no removal): a growth makes the slots anew in the pool, the old
// ones stay there until the scope ends (at most as much again). Linear
// memory: the address of its header (on the fixed stack), as a Grow's;
// WasmGC: a header object ("Two representations, one core").
#if hxmc.wasm_gc
abstract IntTable<V>(IntTableData<V>) {
	public inline function new()
		this = new IntTableData(new Pool(), new Grow<Int>(), new Grow<V>());

	static inline function hashOf(k:Int):Int
		return MapIndex.intHome(k);


	inline function index():IndexView
		return new IndexView(this.slots, this.mask);

	public var length(get, never):Int;

	inline function get_length():Int
		return this.keys.length;

	inline function find(k:Int):Int
		return this.keys.length == 0 ? -1 : MapIndex.first(index(), hashOf(k), k);

	public inline function exists(k:Int):Bool
		return find(k) >= 0;

	public inline function get(k:Int, def:V):V {
		var e = find(k);
		return e < 0 ? def : this.vals[e];
	}

	public inline function ref(k:Int):Ref<V> {
		var e = find(k);
		return e < 0 ? Ref.nil() : this.vals.ref(e);
	}

	@:hxmc.noScope public inline function set(k:Int, v:V) {
		var e = find(k);
		if (e >= 0) this.vals[e] = v else {
			var n = this.keys.length;
			if (2 * (n + 1) > this.mask + 1) grow(n);
			this.keys.push(k);
			this.vals.push(v);
			MapIndex.insert(index(), hashOf(k), k, n);
		}
	}

	inline function grow(n:Int) {
		var cap = 16;
		while (cap < 4 * (n + 1))
			cap *= 2;
		this.slots = this.pool.slice(2 * cap);
		this.mask = cap - 1;
		var idx = index(), ks = this.keys;
		for (e in 0...n)
			MapIndex.insert(idx, hashOf(ks[e]), ks[e], e);
	}

	public inline function keySlice():Slice<Int>
		return this.keys.slice();

	public inline function valueSlice():Slice<V>
		return this.vals.slice();
}

@:hxmc.repr @:hxmc.fresh @:noCompletion class IntTableData<V> {
	public var slots:Slice<Int>;
	public var mask:Int;
	public final pool:Pool;
	public final keys:Grow<Int>;
	public final vals:Grow<V>;

	public function new(pool:Pool, keys:Grow<Int>, vals:Grow<V>) {
		this.pool = pool;
		this.keys = keys;
		this.vals = vals;
		slots = pool.slice(0);
		mask = -1;
	}
}
#else
abstract IntTable<V>(Ptr) {
	static inline var SLOTS = 0;
	static inline var MASK = 8;
	static inline var POOL = 16;
	static inline var KEYS = 24;
	static inline var VALS = 32;
	static inline var HEADER = 40;

	public inline function new() {
		var h = DataStacks.alloc(HEADER);
		Mem.setPtr(h, POOL, cast new Pool());
		Mem.setPtr(h, KEYS, cast new Grow<Int>());
		Mem.setPtr(h, VALS, cast new Grow<V>());
		Mem.setI32(h, MASK, -1);
		Mem.setPtr(h, SLOTS, Ptr.nil());
		this = h;
	}

	static inline function hashOf(k:Int):Int
		return MapIndex.intHome(k);


	inline function keys():Grow<Int>
		return cast Mem.getPtr(this, KEYS);

	inline function vals():Grow<V>
		return cast Mem.getPtr(this, VALS);

	inline function index():IndexView {
		var mask = Mem.getI32(this, MASK);
		return new IndexView(new Slice((Mem.getPtr(this, SLOTS) : Ptr<Int>), 2 * (mask + 1)), mask);
	}

	public var length(get, never):Int;

	inline function get_length():Int
		return keys().length;

	// the entry of k, or -1
	inline function find(k:Int):Int
		return keys().length == 0 ? -1 : MapIndex.first(index(), hashOf(k), k);

	public inline function exists(k:Int):Bool
		return find(k) >= 0;

	// the value of k, or def
	public inline function get(k:Int, def:V):V {
		var e = find(k);
		return e < 0 ? def : vals()[e];
	}

	// a reference to the value of k (null: no such key)
	public inline function ref(k:Int):Ref<V> {
		var e = find(k);
		return e < 0 ? Ref.nil() : vals().ref(e);
	}

	// k's value set to v (a copy)
	@:hxmc.noScope public inline function set(k:Int, v:V) {
		var e = find(k);
		if (e >= 0) vals()[e] = v else {
			var n = keys().length;
			if (2 * (n + 1) > Mem.getI32(this, MASK) + 1) grow(n);
			keys().push(k);
			vals().push(v);
			MapIndex.insert(index(), hashOf(k), k, n);
		}
	}

	// slots for twice the entries (at least 16), the n entries indexed again
	inline function grow(n:Int) {
		var cap = 16;
		while (cap < 4 * (n + 1))
			cap *= 2;
		var pool:Pool = cast Mem.getPtr(this, POOL);
		var p = pool.bytes(8 * cap);
		LibC.memset(p, 0, (8 * cap : I64));
		Mem.setPtr(this, SLOTS, p);
		Mem.setI32(this, MASK, cap - 1);
		var idx = index(), ks = keys();
		for (e in 0...n)
			MapIndex.insert(idx, hashOf(ks[e]), ks[e], e);
	}

	// the keys and the values in insertion order
	public inline function keySlice():Slice<Int>
		return keys().slice();

	public inline function valueSlice():Slice<V>
		return vals().slice();
}
#end
