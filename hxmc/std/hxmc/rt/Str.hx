package hxmc.rt;

import hxmc.I64;
import hxmc.rt.C;
import hxmc.rt.Repr;
import hxmc.unsafe.LibC;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Ptr;

// The runtime's strings (formerly rt_str.c): UTF-16 strings, number
// formatting, the String, StringBuf and Std natives, written over
// hxmc.rt.Repr for both runtimes (@:hxmc.anyHeap). In linear memory a
// string is an array without references (hxmc.rt.Types: its hash in its
// header, 0 until computed), its int32 length, then its UTF-16 units;
// StringBuf keeps the runtime's layout (T_STRINGBUF: slot 0 the length,
// slot 1 a K_RAW block of units), which generated code's
// inline addChar reads too (MirBuild.stringBufAddChar). Under -D
// hxmc.wasm-gc a string is an array of units (hxmc.rt.gc.GcRepr).
//
// @:hxmc.export functions are called by the runtime's C code too (by that
// symbol); @:hxmc.host ones only replace generated code's calls. Written
// with the intrinsics only: an operation of the language that the runtime
// implements here (string concatenation, Std.string...) would call itself.
// The functions over C strings (Ptr) are linear memory's.
@:keep @:allow(hxmc.rt) @:hxmc.anyHeap
class Str {
	public static inline var T_STRING = 16; // (Types.T_STRING, Types.T_ADATA_RAW)
	public static inline var T_ADATA_RAW = 17;
	public static inline var T_STRINGBUF = 10;
	public static inline var K_OBJ = 0;
	public static inline var K_RAW = 2;

	// ---- representation (hxmc.rt.Repr)

	public static inline function isNull(o:Dynamic):Bool
		return Repr.isNull(o);

	public static inline function len(s:String):Int
		return Repr.len(s);

	public static inline function unit(s:String, i:Int):Int
		return Repr.unit(s, i);

	// the units (in linear memory the address of unit 0: valid until the next GC point)
	public static inline function chars(s:String):Chars
		return Repr.chars(s);

	// linear memory's: the address of unit 0, after the length (valid until the next GC point)
	public static inline function unitsAddr(s:String):Ptr
		return Mem.addr(s).add(4);

	// a string of `n` units, not yet written
	public static inline function make(n:Int):String
		return Repr.make(n);

	// the units [pos, pos + n) of s as a new string
	static function range(s:String, pos:Int, n:Int):String {
		var r = make(n);
		Repr.copyFrom(chars(r), chars(s), pos, n);
		return r;
	}

	@:hxmc.host("hx_str_alloc") static function alloc(n:Int):String
		return make(n);

	// ---- C strings

	@:hxmc.host("hx_str_of_ascii") static function ofAscii(c:Ptr):String {
		var n = LibC.strlen(c).toInt();
		var s = make(n);
		var d = chars(s);
		for (i in 0...n)
			d.set(i, Mem.getU8At(c, 0, i));
		return s;
	}

	// ASCII bytes [p, p + n) (outside the heap) as a string
	static function ofBytes(p:Ptr, n:Int):String {
		var s = make(n);
		var d = chars(s);
		for (i in 0...n)
			d.set(i, Mem.getU8At(p, 0, i));
		return s;
	}

	@:hxmc.host("hx_str_of_utf8") public static function ofUtf8(c:Ptr, n:Int):String
		return decode(Repr.octetsAt(c, n), 0, n);

	// the UTF-8 bytes [from, end) of o as a string (TextCore.utf8Decode; not
	// allocating before it: in linear memory o may be the address of a heap
	// object's)
	public static inline function decode(o:Octets, from:Int, end:Int):String {
		var s = make(TextCore.utf8Units(Repr.byteView(o, end), from, end));
		TextCore.utf8Decode(Repr.byteView(o, end), from, end, view(s));
		return s;
	}

	// the units of s as a scoped Str, for TextCore (no GC point while it is used)
	static inline function view(s:String):hxmc.scoped.Str
		return hxmc.scoped.Str.view(s);

	// UTF-8 bytes of s into buf (3 * length + 1 bytes), NUL-terminated; the byte count
	@:hxmc.host("hx_str_utf8_into") @:hxmc.unsafe public static function utf8Into(s:String, buf:Octets):Int
		return TextCore.utf8Encode(view(s), Repr.byteView(buf, 3 * len(s) + 1));

	// a malloc'ed UTF-8 copy ("null" for null)
	@:hxmc.host("hx_str_to_utf8") @:hxmc.unsafe static function toUtf8(s:String):Ptr {
		if (isNull(s)) {
			var p = LibC.malloc(5);
			Mem.setI32(p, 0, 0x6c6c756e); // "null"
			Mem.setI8(p, 4, 0);
			return p;
		}
		var buf = LibC.malloc((3 * len(s) + 1 : I64));
		Repr.utf8To(s, buf);
		return buf;
	}

	// ---- comparison, hashing

	@:hxmc.export("hx_str_eq_slow") @:hxmc.unsafe static function eqSlow(a:String, b:String):Bool
		return MemOps.compare(unitsAddr(a), unitsAddr(b), (2 * len(a) : I64)) == 0;

	@:hxmc.host("hx_str_cmp") @:hxmc.unsafe static function cmp(a:String, b:String):Int {
		if (Repr.same(a, b)) return 0;
		if (isNull(a)) return -1;
		if (isNull(b)) return 1;
		return TextCore.compare(view(a), view(b));
	}

	// FNV-1a over the units, never 0, kept in the string's header where it
	// has room (a benign race between threads: they store the same value).
	// FnLower.strHash computes the same at compile time (DataGen stores it in
	// the literals).
	@:hxmc.host("hx_str_hash") @:hxmc.unsafe static function hash(s:String):Int {
		var h = Repr.storedHash(s);
		return h != 0 ? h : hashSlow(s);
	}

	@:hxmc.unsafe static function hashSlow(s:String):Int {
		var x = TextCore.hash(view(s));
		Repr.storeHash(s, x);
		return x;
	}

	// StringMap's hash: null is a key like any other (inline: the cached one
	// read where the map looks it up)
	public static inline function strHash(s:String):Int {
		if (isNull(s)) return 0;
		var h = Repr.storedHash(s);
		return h != 0 ? h : hashSlow(s);
	}

	// ---- concatenation and conversions

	@:hxmc.host("hx_str_or_null") @:hxmc.unsafe static function orNull(s:String):String
		return isNull(s) ? "null" : s;

	@:hxmc.host("hx_str_concat") static function concat(a:String, b:String):String {
		if (isNull(a)) a = "null";
		if (isNull(b)) b = "null";
		var na = len(a), nb = len(b);
		if (na == 0) return b;
		if (nb == 0) return a;
		var s = make(na + nb);
		var d = chars(s);
		Repr.copy(d, chars(a), na);
		Repr.copyTo(d, na, chars(b), nb);
		return s;
	}

	@:hxmc.host("hx_str_of_int") static function ofInt(v:Int):String {
		var s = make(TextCore.intLength(v));
		TextCore.intWrite(v, view(s));
		return s;
	}

	@:hxmc.host("hx_str_of_i64") static function ofI64(v:I64):String {
		var s = make(TextCore.i64Length(v));
		TextCore.i64Write(v, view(s));
		return s;
	}

	@:hxmc.host("hx_str_of_float") static function ofFloat(v:Float):String {
		var buf:hxmc.scoped.Fixed<hxmc.unsafe.UInt8, 32> = hxmc.scoped.Fixed.scratch();
		var n = FloatText.format(v, buf.view());
		var s = make(n);
		for (i in 0...n)
			Repr.setUnit(s, i, buf[i]);
		return s;
	}

	@:hxmc.host("hx_str_of_bool") @:hxmc.unsafe static function ofBool(v:Bool):String
		return v ? "true" : "false";

	// ---- String

	@:hxmc.host("String_charAt") static function charAt(s:String, i:Int):String {
		if (Repr.ult(i, len(s))) {
			var r = make(1);
			Repr.setUnit(r, 0, unit(s, i));
			return r;
		}
		return "";
	}

	@:hxmc.host("String_charCodeAt") static function charCodeAt(s:String, i:Int):Null<Int> {
		if (!Repr.ult(i, len(s))) return null;
		return unit(s, i);
	}

	@:hxmc.host("String_fromCharCode") static function fromCharCode(code:Int):String {
		if (code >= 0x10000) {
			var r = make(2);
			code -= 0x10000;
			Repr.setUnit(r, 0, 0xD800 | (code >> 10));
			Repr.setUnit(r, 1, 0xDC00 | (code & 0x3FF));
			return r;
		}
		var r = make(1);
		Repr.setUnit(r, 0, code);
		return r;
	}

	// ("" past the end: the length, as String.indexOf says; upstream's TestString)
	@:hxmc.host("String_indexOf") @:hxmc.unsafe static function indexOf(s:String, sub:String, start:Null<Int>):Int
		return TextCore.indexOf(view(s), view(sub), start == null ? 0 : start);

	// ("" before the start: 0, as Eval and ECMAScript; upstream's Issue5271)
	@:hxmc.host("String_lastIndexOf") @:hxmc.unsafe static function lastIndexOf(s:String, sub:String, start:Null<Int>):Int {
		var n = len(s);
		return TextCore.lastIndexOf(view(s), view(sub), start == null ? n : start);
	}

	@:hxmc.host("String_substr") static function substr(s:String, pos:Int, lenp:Null<Int>):String {
		var n = len(s);
		var l:Int = lenp == null ? n : lenp;
		if (pos < 0) {
			pos += n;
			if (pos < 0) pos = 0;
		}
		if (pos > n) return "";
		if (l < 0) {
			l += n - pos;
			if (l < 0) return "";
		}
		if (pos + l > n) l = n - pos;
		if (pos == 0 && l == n) return s;
		return range(s, pos, l);
	}

	@:hxmc.host("String_substring") static function substring(s:String, start:Int, endp:Null<Int>):String {
		var n = len(s);
		var end:Int = endp == null ? n : endp;
		if (start < 0) start = 0;
		if (end < 0) end = 0;
		if (start > n) start = n;
		if (end > n) end = n;
		if (start > end) {
			var t = start;
			start = end;
			end = t;
		}
		if (start == 0 && end == n) return s;
		return range(s, start, end - start);
	}

	// (beyond ASCII: Eval's simple mappings of the BMP, CaseMap; upstream's TestUnicode)
	@:hxmc.host("String_toLowerCase") static function toLowerCase(s:String):String {
		var n = len(s);
		var r = make(n);
		var c = chars(s), d = chars(r);
		for (i in 0...n) {
			var u = c.get(i);
			d.set(i, u < 128 ? (u >= 65 && u <= 90 ? u + 32 : u) : CaseMap.map(u, false));
		}
		return r;
	}

	@:hxmc.host("String_toUpperCase") static function toUpperCase(s:String):String {
		var n = len(s);
		var r = make(n);
		var c = chars(s), d = chars(r);
		for (i in 0...n) {
			var u = c.get(i);
			d.set(i, u < 128 ? (u >= 97 && u <= 122 ? u - 32 : u) : CaseMap.map(u, true));
		}
		return r;
	}

	@:hxmc.host("String_toString") @:hxmc.unsafe static function toString(s:String):String
		return s;

	// new String(s): strings do not change, s itself
	@:hxmc.host("String_new") @:hxmc.unsafe static function ofString(s:String):String
		return s;

	@:hxmc.host("String_split") static function split(s:String, delim:String):Array<String> {
		var arr:Array<String> = [];
		var m = len(delim);
		var start = 0;
		while (true) {
			var n = len(s);
			var at = -1;
			if (m == 0) {
				// split("") gives the code units
				if (start >= n) break;
				at = start + 1;
			} else
				// (the views taken again after each piece: an allocation)
				at = TextCore.indexOf(view(s), view(delim), start);
			var end = at < 0 ? n : at;
			arr.push(range(s, start, end - start));
			if (at < 0) break;
			start = m == 0 ? at : at + m;
		}
		return arr;
	}

	// ---- StringBuf: in linear memory slot 0 the length, slot 1 the units
	// (K_RAW, capacity 4 units per slot); its storage is Repr's

	static inline function sbLen(b:Dynamic):Int
		return Repr.sbLen(b);

	@:hxmc.host("StringBuf_new") static function sbNew():Dynamic
		return Repr.sbNew();

	#if !hxmc.wasm_gc
	// super() of a class extending StringBuf (Lower.stringBufCtor)
	@:hxmc.host("StringBuf_init") static function sbInit(b:Dynamic):Void
		Repr.sbInit(b);
	#end

	// room for `extra` more units
	static function reserve(b:Dynamic, extra:Int) {
		var n = sbLen(b);
		var cap = Repr.sbCapacity(b);
		if (n + extra > cap) {
			var ncap = cap * 2;
			if (ncap < n + extra) ncap = n + extra;
			Repr.sbGrow(b, ncap, n);
		}
	}

	static function sbAddStr(b:Dynamic, s:String) {
		var n = len(s);
		reserve(b, n);
		var at = sbLen(b);
		Repr.copyTo(Repr.sbChars(b), at, chars(s), n);
		Repr.sbSetLen(b, at + n);
	}

	@:hxmc.host("StringBuf_add") static function sbAdd(b:Dynamic, x:Dynamic):Void
		sbAddStr(b, Repr.stdString(x));

	@:hxmc.export("StringBuf_addChar_slow") static function sbAddCharSlow(b:Dynamic, c:Int):Void {
		reserve(b, 2);
		var n = sbLen(b);
		var d = Repr.sbChars(b);
		if (c >= 0x10000) {
			c -= 0x10000;
			d.set(n, 0xD800 | (c >> 10));
			d.set(n + 1, 0xDC00 | (c & 0x3FF));
			Repr.sbSetLen(b, n + 2);
		} else {
			d.set(n, c);
			Repr.sbSetLen(b, n + 1);
		}
	}

	@:hxmc.host("StringBuf_addSub") static function sbAddSub(b:Dynamic, s:String, pos:Int, lenp:Null<Int>):Void
		sbAddStr(b, substr(s, pos, lenp));

	@:hxmc.host("StringBuf_clear") @:hxmc.unsafe static function sbClear(b:Dynamic):Void
		Repr.sbSetLen(b, 0);

	@:hxmc.host("StringBuf_get_length") @:hxmc.unsafe static function sbGetLength(b:Dynamic):Int
		return sbLen(b);

	@:hxmc.host("StringBuf_toString") static function sbToString(b:Dynamic):String {
		var n = sbLen(b);
		var s = make(n);
		Repr.copy(chars(s), Repr.sbChars(b), n);
		return s;
	}

	// ---- Std

	@:hxmc.host("Std_parseInt") static function parseInt(s:String):Null<Int> {
		if (isNull(s)) return null;
		var r = TextCore.parseInt(view(s));
		return r == 0 ? null : r.toInt();
	}

	@:hxmc.host("Std_parseFloat") static function parseFloat(s:String):Float {
		if (isNull(s)) return Math.NaN;
		// (any unit past ASCII ends the number, as its UTF-8 would)
		var r = FloatText.parse(view(s));
		return r.end == 0 ? Math.NaN : r.value;
	}

	@:hxmc.host("Std_random") @:hxmc.unsafe static function random(max:Int):Int {
		if (max <= 0) return 0;
		#if (hxmc.wasm_gc)
		return Std.int(hxmc.rt.gc.W.random() * max);
		#else
		if (Mem.os() == 2) {
			// the C runtime's rand() has 15 bits: two make 30
			var r:I64 = (LibC.rand() << 15) ^ LibC.rand();
			return ((r * max) >> 30).toInt();
		}
		var r:I64 = LibC.rand();
		return ((r * max) >> 31).toInt();
		#end
	}
}
