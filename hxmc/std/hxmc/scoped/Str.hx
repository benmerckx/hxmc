package hxmc.scoped;

#if !hxmc.wasm_gc
import hxmc.rt.DataStacks;
#end
import hxmc.rt.Abort;
import hxmc.rt.TextCore;
import hxmc.unsafe.*;
import hxmc.scoped.Slice;
#if hxmc.wasm_gc
import hxmc.rt.gc.W;
import hxmc.rt.gc.GcRepr.GcChars;
#end

// Text in scoped memory (docs/plans/lowlevel.md, "Scoped memory"): a view of
// UTF-16 code units (as String's, on both faces). A string literal converts
// to one (its units are static data: the global root); `Str.copy` and
// `Str.copyOf` (a String, from GC code) copy units (fresh memory of the
// scope); `toString` makes a String (GC code). Linear memory: an address and
// a length, copies on the data stack. WasmGC ("Two representations, one
// core"): a String's own array of units, an offset and a length; no Str
// changes units once made, so the copies are the units themselves.
#if hxmc.wasm_gc
abstract Str(StrData) {
	@:noCompletion public inline function new(s:GcChars, off:Int, length:Int)
		this = new StrData(s, off, length);

	@:from static inline function ofLiteral(s:String):Str
		return new Str(s, 0, W.strLen(s));

	// (fresh to the checker, as a linear copy is)
	public static inline function copy(s:Str):Str
		return cast StrData.fresh(s.chars(), s.start(), s.length);

	public static inline function copyOf(s:String):Str
		return cast StrData.fresh(s, 0, W.strLen(s));

	@:noCompletion public inline function chars():GcChars
		return this.s;

	@:noCompletion public inline function start():Int
		return this.off;

	public var length(get, never):Int;

	inline function get_length():Int
		return this.length;

	// the units from 0 (TextCore's view: the String itself, or a copy of a
	// Str that starts further in)
	inline function units():GcChars {
		var s = this.s;
		if (this.off != 0) {
			s = W.strNew(this.length);
			W.strCopy(s, 0, this.s, this.off, this.length);
		}
		return s;
	}

	@:arrayAccess public inline function at(i:Int):Int {
		if ((i : UInt) >= (this.length : UInt)) Abort.outOfRange();
		return W.strGet(this.s, this.off + i);
	}

	public inline function sub(pos:Int, len:Int):Str {
		if (pos < 0 || len < 0 || pos + len > this.length) Abort.outOfRange();
		return new Str(this.s, this.off + pos, len);
	}

	public inline function eq(o:Str):Bool {
		var r = this.length == o.length;
		var i = 0;
		while (r && i < this.length) {
			r = W.strGet(this.s, this.off + i) == o.at(i);
			i++;
		}
		return r;
	}

	public inline function indexOf(c:Int, from:Int = 0):Int {
		var r = -1;
		var i = from < 0 ? 0 : from;
		while (i < this.length) {
			if (W.strGet(this.s, this.off + i) == c) {
				r = i;
				break;
			}
			i++;
		}
		return r;
	}

	public inline function find(s:Str, from:Int = 0):Int
		return TextCore.indexOf(units(), this.length, s.units(), s.length, from);

	public inline function findLast(s:Str, from:Int):Int
		return TextCore.lastIndexOf(units(), this.length, s.units(), s.length, from);

	public inline function compare(o:Str):Int
		return TextCore.compare(units(), this.length, o.units(), o.length);

	public inline function hash():Int
		return TextCore.hash(units(), this.length);

	public static inline function ofInt(v:Int):Str {
		var n = TextCore.intLength(v);
		var s:GcChars = W.strNew(n);
		TextCore.intWrite(v, s, n);
		return cast StrData.fresh(s, 0, n);
	}

	public inline function toInt(none:Int):Int {
		var r = TextCore.parseInt(units(), this.length);
		return r == 0 ? none : r.toInt();
	}

	public inline function utf8(buf:Slice<UInt8>):Int {
		if (buf.length < 3 * this.length + 1) Abort.outOfRange();
		return TextCore.utf8Encode(units(), this.length, cast buf.array(), buf.offset());
	}

	public static inline function ofUtf8(b:Slice<UInt8>, n:Int):Str {
		if ((n : UInt) > (b.length : UInt)) Abort.outOfRange();
		var o:hxmc.rt.gc.GcRepr.GcOctets = cast b.array();
		var from = b.offset();
		var s:GcChars = W.strNew(TextCore.utf8Units(o, from, from + n));
		TextCore.utf8Decode(o, from, from + n, s);
		return cast StrData.fresh(s, 0, W.strLen(s));
	}

	public inline function toCase(toUpper:Bool):Str {
		var n = this.length;
		var s:GcChars = W.strNew(n);
		for (i in 0...n)
			W.strSet(s, i, hxmc.rt.CaseMap.map(W.strGet(this.s, this.off + i), toUpper));
		return cast StrData.fresh(s, 0, n);
	}

	public static inline function ofFloat(v:Float):Str {
		var buf:Slice<UInt8> = Scope.slice(32);
		var n = hxmc.rt.FloatText.format(v, buf);
		var s:GcChars = W.strNew(n);
		for (i in 0...n)
			W.strSet(s, i, buf[i]);
		return cast StrData.fresh(s, 0, n);
	}

	public inline function toFloat():Float {
		var n = this.length;
		var buf:Slice<UInt8> = Scope.slice(n);
		for (i in 0...n) {
			var u = W.strGet(this.s, this.off + i);
			buf[i] = u < 0x80 ? u : 0x80;
		}
		var r = hxmc.rt.FloatText.parse(buf);
		return r.end == 0 ? Math.NaN : r.value;
	}

	public inline function toString():String {
		var s:String = this.s;
		if (this.off != 0 || this.length != W.strLen(s)) {
			s = W.strNew(this.length);
			W.strCopy(s, 0, this.s, this.off, this.length);
		}
		return s;
	}
}

@:hxmc.repr @:noCompletion class StrData {
	public final s:GcChars;
	public final off:Int;
	public final length:Int;

	public inline function new(s:GcChars, off:Int, length:Int) {
		this.s = s;
		this.off = off;
		this.length = length;
	}

	// units of scoped memory just made, or of the pool (to the root checker:
	// fresh, as a data stack's; rooted at the pool), as Slice's
	public static function fresh(s:GcChars, off:Int, length:Int):StrData
		return new StrData(s, off, length);

	public static function of(pool:Dynamic, s:GcChars, off:Int, length:Int):StrData
		return new StrData(s, off, length);

}
#else
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

	// the first n bytes of b decoded from UTF-8 (as String's: a byte that
	// begins no well-formed sequence is one unit U+DC80 to U+DCFF), fresh
	// memory of the scope
	public static inline function ofUtf8(b:Slice<UInt8>, n:Int):Str {
		if ((n : UInt) > (b.length : UInt)) Abort.outOfRange();
		var p = b.ptr();
		var units = TextCore.utf8Units((p : Ptr), 0, n);
		var d = DataStacks.alloc(2 * units);
		TextCore.utf8Decode((p : Ptr), 0, n, d);
		return new Str(d, units);
	}

	// the UTF-8 bytes into buf (3 * length + 1 bytes), NUL-terminated: the byte count
	public inline function utf8(buf:Slice<UInt8>):Int {
		if (buf.length < 3 * this.length + 1) Abort.outOfRange();
		return TextCore.utf8Encode(this.ptr, this.length, (buf.ptr() : Ptr));
	}


	// v in decimal (Std.string's), fresh memory of the scope
	public static inline function ofInt(v:Int):Str {
		var n = TextCore.intLength(v);
		var p = DataStacks.alloc(2 * n);
		TextCore.intWrite(v, p, n);
		return new Str(p, n);
	}

	// the integer the text starts with, as Std.parseInt reads it; `none` when
	// there is none
	public inline function toInt(none:Int):Int {
		var r = TextCore.parseInt(this.ptr, this.length);
		return r == 0 ? none : r.toInt();
	}

	// the UTF-8 of the String s ("null" for null), NUL-terminated (not counted
	// in the length), fresh memory of the scope: a C string for the system (GC code)
	public static inline function utf8Of(s:String):Slice<UInt8> {
		if (s == null) s = "null";
		var p = DataStacks.alloc(3 * s.length + 1);
		return new Slice((p : Ptr<UInt8>), hxmc.rt.Str.utf8Into(s, p));
	}

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
		var buf:Slice<UInt8> = Scope.slice(32);
		var n = hxmc.rt.FloatText.format(v, buf);
		var p = DataStacks.alloc(2 * n);
		for (i in 0...n)
			Mem.setI16(p, 2 * i, buf[i]);
		return new Str(p, n);
	}

	// the number the text starts with (after blanks), as Std.parseFloat reads
	// it; NaN: none
	public inline function toFloat():Float {
		var n = this.length;
		var buf:Slice<UInt8> = Scope.slice(n);
		for (i in 0...n) {
			var u = Mem.getU16(this.ptr, 2 * i);
			buf[i] = u < 0x80 ? u : 0x80;
		}
		var r = hxmc.rt.FloatText.parse(buf);
		return r.end == 0 ? Math.NaN : r.value;
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
#end
