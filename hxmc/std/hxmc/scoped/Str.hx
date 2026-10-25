package hxmc.scoped;

import hxmc.rt.DataStacks;
import hxmc.unsafe.*;

// Text in scoped memory (docs/plans/lowlevel.md, "Scoped memory"): a view of
// UTF-16 code units (as String's, on both faces), an address and a length.
// A string literal converts to one (its units are static data: the global
// root); `Str.copy` and `Str.copyOf` (a String, from GC code) copy units
// onto the data stack (fresh memory of the scope); `toString` makes a String
// (GC code).
abstract Str(StrData) {
	public inline function new(p:Ptr<UInt16>, length:Int)
		this = new StrData(p, length);

	// a string literal's units (the root checker accepts literals only)
	@:from static inline function ofLiteral(s:String):Str
		return new Str(Mem.addr(s).add(4), s.length);

	// a copy of s on the data stack
	public static inline function copy(s:Str):Str {
		var n = s.length;
		var p = DataStacks.alloc(2 * n);
		LibC.memcpy(p, s.ptr(), (2 * n : I64));
		return new Str(p, n);
	}

	// a copy of the String s on the data stack (GC code)
	public static inline function copyOf(s:String):Str
		return new Str(DataStacks.copyString(s), s.length);

	public var length(get, never):Int;

	inline function get_length():Int
		return this.length;

	public inline function ptr():Ptr<UInt16>
		return this.ptr;

	// the code unit at i
	@:arrayAccess public inline function at(i:Int):Int {
		if ((i : UInt) >= (this.length : UInt)) DataStacks.outOfRange();
		return Mem.getU16(this.ptr, 2 * i);
	}

	// the units pos .. pos + len - 1, the same memory
	public inline function sub(pos:Int, len:Int):Str {
		if (pos < 0 || len < 0 || pos + len > this.length) DataStacks.outOfRange();
		return new Str((this.ptr : Ptr<UInt16>).offset(pos), len);
	}

	public inline function eq(o:Str):Bool
		return this.length == o.length && LibC.memcmp(this.ptr, o.ptr(), (2 * this.length : I64)) == 0;

	// the first index of unit c from `from`, or -1
	public inline function indexOf(c:Int, from:Int = 0):Int {
		var r = -1;
		var i = from < 0 ? 0 : from;
		while (i < this.length) {
			if (Mem.getU16(this.ptr, 2 * i) == c) {
				r = i;
				break;
			}
			i++;
		}
		return r;
	}

	// FNV-1a over the units (String's hash)
	public inline function hash():Int {
		var h = 0x811C9DC5;
		for (i in 0...this.length)
			h = (h ^ Mem.getU16(this.ptr, 2 * i)) * 0x01000193;
		return h;
	}

	// a String of the units (GC code)
	public inline function toString():String
		return DataStacks.stringOf(this.ptr, this.length);
}

@:hxmc.struct @:noCompletion class StrData {
	public var ptr:Ptr;
	public var length:Int;

	public inline function new(p:Ptr, length:Int) {
		ptr = p;
		this.length = length;
	}
}
