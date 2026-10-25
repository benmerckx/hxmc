package hxmc.scoped;

import hxmc.rt.DataStacks;
import hxmc.unsafe.*;
import hxmc.scoped.Slice;
import hxmc.scoped.Slice.SliceIterator;

// A grow-only array in scoped memory (docs/plans/lowlevel.md, "Scoped
// memory"): its elements on a data stack it claims for itself, so `push` is
// a test and a pointer bump and nothing ever moves: a reference to an
// element (`push`'s result, `ref(i)`) stays valid as long as the Grow. The
// value is the address of its header (on the fixed stack: base, end,
// length, stack), so passing a Grow passes it by reference. Freed with the
// scope that made it, at once.
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
	public inline function push(v:T):Ref<T> {
		var n = Mem.getI32(this, LEN);
		var p:Ptr<T> = (Mem.getPtr(this, BASE) : Ptr<T>).offset(n);
		if (Mem.ult(Mem.getPtr(this, END).toI64(), p.offset(1).toI64())) DataStacks.overflow();
		p.value = v;
		Mem.setI32(this, LEN, n + 1);
		return new Ref(p);
	}

	@:arrayAccess inline function get(i:Int):T {
		if ((i : UInt) >= (Mem.getI32(this, LEN) : UInt)) DataStacks.outOfRange();
		return (Mem.getPtr(this, BASE) : Ptr<T>)[i];
	}

	@:arrayAccess inline function set(i:Int, v:T):T {
		if ((i : UInt) >= (Mem.getI32(this, LEN) : UInt)) DataStacks.outOfRange();
		return (Mem.getPtr(this, BASE) : Ptr<T>)[i] = v;
	}

	// a reference to element i
	public inline function ref(i:Int):Ref<T> {
		if ((i : UInt) >= (Mem.getI32(this, LEN) : UInt)) DataStacks.outOfRange();
		return new Ref((Mem.getPtr(this, BASE) : Ptr<T>).offset(i));
	}

	// the elements so far, as a view (the Grow's root)
	public inline function slice():Slice<T>
		return new Slice((Mem.getPtr(this, BASE) : Ptr<T>), Mem.getI32(this, LEN));

	public inline function iterator():SliceIterator<T>
		return new SliceIterator((Mem.getPtr(this, BASE) : Ptr<T>), Mem.getI32(this, LEN));
}
