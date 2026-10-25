package hxmc.scoped;

import hxmc.rt.DataStacks;
import hxmc.rt.Abort;
import hxmc.rt.TextCore;
import hxmc.unsafe.*;
import hxmc.scoped.Slice;

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

	// a copy of the String s on the data stack, a 0 unit after it (not in the
	// length: a wide C string for the system), GC code
	public static inline function copyOf(s:String):Str
		return new Str(DataStacks.copyString(s), s.length);

	public var length(get, never):Int;

	inline function get_length():Int
		return this.length;

	public inline function ptr():Ptr<UInt16>
		return this.ptr;

	// the code unit at i
	@:arrayAccess public inline function at(i:Int):Int {
		if ((i : UInt) >= (this.length : UInt)) Abort.outOfRange();
		return Mem.getU16(this.ptr, 2 * i);
	}

	// the units pos .. pos + len - 1, the same memory
	public inline function sub(pos:Int, len:Int):Str {
		if (pos < 0 || len < 0 || pos + len > this.length) Abort.outOfRange();
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

	#if !hxmc.wasm_gc // (TextCore over linear memory's units)
	// the first index from `from` where the units of s start, or -1 (String's
	// indexOf: hxmc.rt.TextCore)
	public inline function find(s:Str, from:Int = 0):Int
		return TextCore.indexOf(this.ptr, this.length, (s.ptr() : Ptr), s.length, from);

	// the last index at most `from` where they start, or -1 (lastIndexOf)
	public inline function findLast(s:Str, from:Int):Int
		return TextCore.lastIndexOf(this.ptr, this.length, (s.ptr() : Ptr), s.length, from);

	// -1, 0 or 1, as Reflect.compare orders Strings
	public inline function compare(o:Str):Int
		return TextCore.compare(this.ptr, this.length, (o.ptr() : Ptr), o.length);

	// String's hash (FNV-1a over the units, never 0)
	public inline function hash():Int
		return TextCore.hash(this.ptr, this.length);

	// the n UTF-8 bytes at p decoded (as String's: a byte that begins no
	// well-formed sequence is one unit U+DC80 to U+DCFF), fresh memory of the scope
	public static inline function ofUtf8(p:Ptr<UInt8>, n:Int):Str {
		var units = TextCore.utf8Units((p : Ptr), 0, n);
		var d = DataStacks.alloc(2 * units);
		TextCore.utf8Decode((p : Ptr), 0, n, d);
		return new Str(d, units);
	}

	// the UTF-8 bytes into buf (3 * length + 1 bytes), NUL-terminated: the byte count
	public inline function utf8(buf:Ptr<UInt8>):Int
		return TextCore.utf8Encode(this.ptr, this.length, (buf : Ptr));


	// the UTF-8 of the String s ("null" for null), NUL-terminated (not counted
	// in the length), fresh memory of the scope: a C string for the system (GC code)
	public static inline function utf8Of(s:String):Slice<UInt8> {
		if (s == null) s = "null";
		var p = DataStacks.alloc(3 * s.length + 1);
		return new Slice((p : Ptr<UInt8>), hxmc.rt.Str.utf8Into(s, p));
	}
	#end

	// a copy in upper case (toUpper) or lower case, as String's
	// (hxmc.rt.CaseMap: the simple mappings of the BMP), fresh memory of the scope
	public inline function toCase(toUpper:Bool):Str {
		var n = this.length;
		var p = DataStacks.alloc(2 * n);
		for (i in 0...n)
			Mem.setI16(p, 2 * i, hxmc.rt.CaseMap.map(Mem.getU16(this.ptr, 2 * i), toUpper));
		return new Str(p, n);
	}

	// v as Std.string writes it (hxmc.rt.FloatText: the shortest decimal that
	// reads back as v), fresh memory of the scope
	public static inline function ofFloat(v:Float):Str {
		var buf = Mem.stack(48);
		hxmc.rt.FloatText.format(v, buf);
		var n = LibC.strlen(buf).toInt();
		var p = DataStacks.alloc(2 * n);
		for (i in 0...n)
			Mem.setI16(p, 2 * i, Mem.getU8(buf, i));
		return new Str(p, n);
	}

	// the number the text starts with (after blanks), as Std.parseFloat reads
	// it; NaN: none
	public inline function toFloat():Float {
		var n = this.length;
		var buf = DataStacks.alloc(n + 1);
		var k = 0;
		while (k < n && (Mem.getU16(this.ptr, 2 * k) == 32 || Mem.getU16(this.ptr, 2 * k) == 9 || Mem.getU16(this.ptr, 2 * k) == 10 || Mem.getU16(this.ptr, 2 * k) == 13))
			k++;
		for (i in k...n) {
			var u = Mem.getU16(this.ptr, 2 * i);
			Mem.setI8(buf, i - k, u < 0x80 ? u : 0x80);
		}
		Mem.setI8(buf, n - k, 0);
		var end = Mem.stack(8);
		var d = hxmc.rt.FloatText.parse(buf, end);
		return Mem.getPtr(end, 0) == buf ? Math.NaN : d;
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
