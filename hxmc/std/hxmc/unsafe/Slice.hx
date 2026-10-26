package hxmc.unsafe;

// A run of T in memory outside the GC heap (an Arena's, C's): a Ptr and a
// length, bounds-checked (docs/interop.md, "Struct values"). A struct value
// itself: passing one copies its two words, not the elements. T is a C
// scalar, a Ptr or a @:hxmc.struct class, whose elements are stored inline
// and reached in place (`s[i].x = 1`); reading one into a variable copies it.
@:forward(length)
abstract Slice<T>(SliceData) {
	public inline function new(p:Ptr<T>, length:Int)
		this = new SliceData(p, length);

	public inline function ptr():Ptr<T>
		return this.ptr;

	@:arrayAccess inline function get(i:Int):T {
		check(i);
		return (this.ptr : Ptr<T>)[i];
	}

	@:arrayAccess inline function set(i:Int, v:T):T {
		check(i);
		return (this.ptr : Ptr<T>)[i] = v;
	}

	// the elements pos .. pos + len - 1, the same memory
	public inline function sub(pos:Int, len:Int):Slice<T> {
		if (pos < 0 || len < 0 || pos + len > this.length) throw "Slice.sub out of range";
		return new Slice((this.ptr : Ptr<T>).offset(pos), len);
	}

	inline function check(i:Int)
		if ((i : UInt) >= (this.length : UInt)) throw "Slice index out of range";
}

@:hxmc.struct @:noCompletion class SliceData {
	public var ptr:Ptr;
	public var length:Int;

	public inline function new(p:Ptr, length:Int) {
		ptr = p;
		this.length = length;
	}
}
