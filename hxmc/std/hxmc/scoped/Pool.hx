package hxmc.scoped;

import hxmc.rt.DataStacks;
import hxmc.unsafe.*;
import hxmc.scoped.Slice;

// A bump region in scoped memory (docs/plans/lowlevel.md, "Scoped memory"):
// a Grow of bytes for values whose lifetime is a caller's, passed in, as
// Goose passes pools to recursive functions: what it makes is rooted at the
// pool. The address of its header, as a Grow's.
abstract Pool(Ptr) {
	static inline var BASE = 0;
	static inline var END = 8;
	static inline var USED = 16;
	static inline var HEADER = 24;

	public inline function new() {
		var h = DataStacks.alloc(HEADER);
		var i = DataStacks.claim();
		Mem.setPtr(h, BASE, DataStacks.base(i));
		Mem.setPtr(h, END, DataStacks.end(i));
		Mem.setI32(h, USED, 0);
		this = h;
	}

	// `bytes` bytes of the pool, 8-byte aligned, not zeroed
	public inline function bytes(n:Int):Ptr {
		var used = Mem.getI32(this, USED);
		var p = Mem.getPtr(this, BASE).add(used);
		var next = used + ((n + 7) & ~7);
		if (Mem.ult(Mem.getPtr(this, END).toI64(), Mem.getPtr(this, BASE).add(next).toI64())) DataStacks.overflow();
		Mem.setI32(this, USED, next);
		return p;
	}

	// a copy of s in the pool
	public inline function str(s:Str):Str {
		var n = s.length;
		var p = bytes(2 * n);
		LibC.memcpy(p, s.ptr(), (2 * n : I64));
		return new Str(p, n);
	}

	// n zeroed elements in the pool
	public inline function slice<T>(n:Int):Slice<T> {
		var size = (Ptr.nil() : Ptr<T>).offset(n).toI64().toInt();
		var p = bytes(size);
		LibC.memset(p, 0, (size : I64));
		return new Slice((p : Ptr<T>), n);
	}

	// the bytes used
	public var used(get, never):Int;

	inline function get_used():Int
		return Mem.getI32(this, USED);
}
