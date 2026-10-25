package hxmc.scoped;

#if !hxmc.wasm_gc
import hxmc.rt.DataStacks;
#end
import hxmc.rt.Abort;
import hxmc.unsafe.*;
import hxmc.scoped.Slice;
import hxmc.scoped.Slice.SliceIterator;

// A grow-only array in scoped memory (docs/plans/lowlevel.md, "Scoped
// memory"): a reference to an element (`push`'s result, `ref(i)`) stays
// valid as long as the Grow; passing a Grow passes it by reference. Linear
// memory: its elements on a data stack it claims for itself, so `push` is a
// test and a pointer bump and nothing ever moves; the value is the address of
// its header (on the fixed stack: base, end, length, stack); freed with the
// scope that made it, at once. WasmGC ("Two representations, one core"): a
// header object over the engine's array, reallocated as it grows (a Ref is
// the header and an index).
#if hxmc.wasm_gc
abstract Grow<T>(GrowData<T>) {
	public inline function new()
		this = new GrowData(new NativeArray<T>(8));

	public var length(get, never):Int;

	inline function get_length():Int
		return this.len;

	// appends v (a copy); a reference to the new element
	@:hxmc.noScope public inline function push(v:T):Ref<T> {
		var n = this.len;
		// (the array reallocated: the Grow's own memory, moved)
		if (n == this.a.length) {
			var b = new NativeArray<T>(2 * n);
			for (k in 0...n)
				b.unsafeSet(k, this.a.unsafeGet(k));
			this.a = b;
		}
		this.a.unsafeSet(n, v);
		this.len = n + 1;
		return new Ref(this, n);
	}

	inline function at(i:Int):Int {
		if ((i : UInt) >= (this.len : UInt)) Abort.outOfRange();
		return i;
	}

	@:arrayAccess inline function get(i:Int):T
		return this.a.unsafeGet(at(i));

	@:hxmc.noScope @:arrayAccess inline function set(i:Int, v:T):T {
		this.a.unsafeSet(at(i), v);
		return v;
	}

	// a reference to element i
	public inline function ref(i:Int):Ref<T>
		return new Ref(this, at(i));

	// the elements so far, as a view (the Grow's root)
	public inline function slice():Slice<T>
		return new Slice(this.a, 0, this.len);

	public inline function iterator():SliceIterator<T>
		return new SliceIterator(this.a, 0, this.len);
}

// (@:hxmc.fresh: what makes one allocates scoped memory, to the root checker)
@:hxmc.repr @:hxmc.fresh @:noCompletion class GrowData<T> extends Ref.Holder<T> {
	public var len:Int;

	public function new(a:NativeArray<T>) {
		super(a);
		len = 0;
	}
}
#else
abstract Grow<T>(Ptr) {
	static inline var BASE = 0;
	static inline var END = 8;
	static inline var LEN = 16;
	static inline var HEADER = 24;

	public inline function new() {
		var h = DataStacks.alloc(HEADER);
		var i = DataStacks.claim();
		Mem.setPtr(h, BASE, DataStacks.base(i));
		Mem.setPtr(h, END, DataStacks.end(i));
		Mem.setI32(h, LEN, 0);
		this = h;
	}

	public var length(get, never):Int;

	inline function get_length():Int
		return Mem.getI32(this, LEN);

	// appends v (a copy); a reference to the new element
	@:hxmc.noScope public inline function push(v:T):Ref<T> {
		var n = Mem.getI32(this, LEN);
		var p:Ptr<T> = (Mem.getPtr(this, BASE) : Ptr<T>).offset(n);
		if (Mem.ult(Mem.getPtr(this, END).toI64(), p.offset(1).toI64())) DataStacks.overflow();
		p.value = v;
		Mem.setI32(this, LEN, n + 1);
		return new Ref(p);
	}

	@:arrayAccess inline function get(i:Int):T {
		if ((i : UInt) >= (Mem.getI32(this, LEN) : UInt)) Abort.outOfRange();
		return (Mem.getPtr(this, BASE) : Ptr<T>)[i];
	}

	@:hxmc.noScope @:arrayAccess inline function set(i:Int, v:T):T {
		if ((i : UInt) >= (Mem.getI32(this, LEN) : UInt)) Abort.outOfRange();
		return (Mem.getPtr(this, BASE) : Ptr<T>)[i] = v;
	}

	// a reference to element i
	public inline function ref(i:Int):Ref<T> {
		if ((i : UInt) >= (Mem.getI32(this, LEN) : UInt)) Abort.outOfRange();
		return new Ref((Mem.getPtr(this, BASE) : Ptr<T>).offset(i));
	}

	// the elements so far, as a view (the Grow's root)
	public inline function slice():Slice<T>
		return new Slice((Mem.getPtr(this, BASE) : Ptr<T>), Mem.getI32(this, LEN));

	public inline function iterator():SliceIterator<T>
		return new SliceIterator((Mem.getPtr(this, BASE) : Ptr<T>), Mem.getI32(this, LEN));
}
#end
