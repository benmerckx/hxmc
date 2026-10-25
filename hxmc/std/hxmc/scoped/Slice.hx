package hxmc.scoped;

import hxmc.rt.Abort;
import hxmc.unsafe.*;

// A view of a run of T (docs/plans/lowlevel.md, "Scoped memory"): an address
// and a length, a struct value (copying one copies the two words, not the
// elements), rooted at what it views. Indexes are checked: out of range
// aborts (scoped code cannot throw). T is a scalar, a scoped class or enum,
// or another scoped type; a struct element is reached in place (`s[i].x = 1`).
// Scope.slice makes one on the data stack; it brings in no data stacks itself
// (the maps' index views GC memory with it: hxmc.rt.MapIndex).
@:forward(length)
abstract Slice<T>(SliceData) {
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
}

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
