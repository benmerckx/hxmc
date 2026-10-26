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
// header, 0 until computed), its int32 length, then its units: a byte each
// (T_STRING1, where every unit is below 0x100) or two (T_STRING), as V8's
// one-byte and two-byte strings. Every operation takes either width (and a
// two-byte string whose units would fit in bytes: no result depends on the
// width); what this makes is one-byte wherever every unit fits, but for the
// concatenations of a two-byte string. StringBuf keeps the runtime's layout
// (T_STRINGBUF: slot 0 the length, slot 1 its units, a string as long as
// its capacity, one-byte until a unit above 0xFF comes), which generated
// code's inline addChar reads too (MirBuild.stringBufAddChar). Under -D
// hxmc.wasm-gc a string is an array of UTF-16 units (hxmc.rt.gc.GcRepr).
//
// @:hxmc.export functions are called by the runtime's C code too (by that
// symbol); @:hxmc.host ones only replace generated code's calls. Written
// with the intrinsics only: an operation of the language that the runtime
// implements here (string concatenation, Std.string...) would call itself.
// The functions over C strings (Ptr) are linear memory's.
@:keep @:allow(hxmc.rt) @:hxmc.anyHeap
class Str {
	public static inline var T_STRING = 16; // (Types.T_STRING, Types.T_STRING1)
	public static inline var T_STRING1 = 17;
	public static inline var T_STRINGBUF = 10;
	public static inline var K_OBJ = 0;
	public static inline var K_RAW = 2;

	// ---- representation (hxmc.rt.Repr)

	public static inline function isNull(o:Dynamic):Bool
		return Repr.isNull(o);

	public static inline function len(s:String):Int
		return Repr.len(s);

	// whether s has a byte per unit (never under -D hxmc.wasm-gc)
	public static inline function isOne(s:String):Bool
		return Repr.isOne(s);

	public static inline function unit(s:String, i:Int):Int
		return Repr.unit(s, i);

	// the units of a one-byte string (chars1), a two-byte one (chars2) (in
	// linear memory the address of unit 0: valid until the next GC point)
	public static inline function chars1(s:String):Chars1
		return Repr.chars1(s);

	public static inline function chars2(s:String):Chars
		return Repr.chars2(s);

	// linear memory's: the address of unit 0, after the length (valid until the next GC point)
	public static inline function unitsAddr(s:String):Ptr
		return Mem.addr(s).add(4);

	// a string of `n` units, not yet written: one-byte (make1: each unit
	// written below 0x100), two-byte (make2)
	public static inline function make1(n:Int):String
		return Repr.make1(n);

	public static inline function make2(n:Int):String
		return Repr.make2(n);

	// the units [pos, pos + n) of s as a new string (one-byte where they fit)
	static function range(s:String, pos:Int, n:Int):String {
		if (isOne(s)) {
			var r = make1(n);
			Repr.copyFrom1(chars1(r), chars1(s), pos, n);
			return r;
		}
		if (Repr.fitsOne(chars2(s), pos, n)) {
			var r = make1(n);
			Repr.narrow(chars1(r), 0, chars2(s), pos, n);
			return r;
		}
		var r = make2(n);
		Repr.copyFrom(chars2(r), chars2(s), pos, n);
		return r;
	}

	@:hxmc.host("hx_str_alloc") static function alloc(n:Int):String
		return make2(n);

	// ---- C strings

	@:hxmc.host("hx_str_of_ascii") static function ofAscii(c:Ptr):String
		return ofBytes(c, LibC.strlen(c).toInt());

	// bytes [p, p + n) (outside the heap) as a string, a unit each
	static function ofBytes(p:Ptr, n:Int):String {
		var s = make1(n);
		#if (hxmc.wasm_gc)
		var d = chars1(s);
		for (i in 0...n)
			d.set(i, Mem.getU8At(p, 0, i));
		#else
		if (n > 0) LibC.memcpy(chars1(s), p, (n : I64));
		#end
		return s;
	}

	@:hxmc.host("hx_str_of_utf8") public static function ofUtf8(c:Ptr, n:Int):String
		return decode(Repr.octetsAt(c, n), 0, n);

	// the UTF-8 bytes [from, end) of o as a string (not allocating
	// before it: in linear memory o may be the address of a heap object's).
	// A byte that does not begin a well-formed sequence (a stray continuation
	// byte; a sequence cut short, overlong, of a surrogate or past U+10FFFF)
	// becomes one unit, U+DC80 to U+DCFF for 0x80 to 0xFF (as Python's
	// surrogateescape), which utf8Into writes back as that byte: any bytes
	// decoded and encoded again are the same bytes.
	public static inline function decode(o:Octets, from:Int, end:Int):String {
		// UTF-16 units first, and whether one is above 0xFF (a sequence led by
		// 0xC4 or more, a byte of none)
		var units = 0, i = from, wide = false;
		while (i < end) {
			#if !hxmc.wasm_gc
			// (four ASCII bytes at a time)
			if (i + 4 <= end && Mem.getI32(o.at(i), 0) & 0x80808080 == 0) {
				units += 4;
				i += 4;
				continue;
			}
			#end
			var b = o.get(i);
			if (b < 0x80) {
				units++;
				i++;
			} else {
				var k = seqLen(o, i, end, b);
				if (k == 0) {
					units++;
					i++;
					wide = true;
				} else {
					units += k == 4 ? 2 : 1;
					i += k;
					if (b >= 0xC4) wide = true;
				}
			}
		}
		if (!wide) return decodeOne(o, from, end, units);
		var s = make2(units);
		var d = chars2(s);
		var j = 0;
		i = from;
		while (i < end) {
			#if !hxmc.wasm_gc
			// (four ASCII bytes at a time: two units per store)
			if (i + 4 <= end) {
				var x = Mem.getI32(o.at(i), 0);
				if (x & 0x80808080 == 0) {
					Mem.setI32(d.at(j), 0, (x & 0xFF) | ((x & 0xFF00) << 8));
					Mem.setI32(d.at(j + 2), 0, ((x >>> 16) & 0xFF) | ((x >>> 8) & 0xFF0000));
					i += 4;
					j += 4;
					continue;
				}
			}
			#end
			var b = o.get(i);
			if (b < 0x80) {
				d.set(j++, b);
				i++;
				continue;
			}
			var k = seqLen(o, i, end, b);
			if (k == 0) {
				d.set(j++, 0xDC00 | b);
				i++;
				continue;
			}
			var cp = if (k == 2) ((b & 0x1F) << 6) | (o.get(i + 1) & 0x3F) else if (k == 3)
				((b & 0x0F) << 12) | ((o.get(i + 1) & 0x3F) << 6) | (o.get(i + 2) & 0x3F) else
				((b & 0x07) << 18) | ((o.get(i + 1) & 0x3F) << 12) | ((o.get(i + 2) & 0x3F) << 6) | (o.get(i + 3) & 0x3F);
			i += k;
			if (cp >= 0x10000) {
				cp -= 0x10000;
				d.set(j++, 0xD800 | (cp >> 10));
				d.set(j++, 0xDC00 | (cp & 0x3FF));
			} else d.set(j++, cp);
		}
		return s;
	}

	// decode's one-byte string: the bytes are ASCII and well-formed two-byte
	// sequences of U+0080 to U+00FF, `units` of them
	static function decodeOne(o:Octets, from:Int, end:Int, units:Int):String {
		var s = make1(units);
		var d = chars1(s);
		#if !hxmc.wasm_gc
		// (ASCII: the bytes themselves)
		if (units == end - from) {
			if (units > 0) LibC.memcpy(d, o.at(from), (units : I64));
			return s;
		}
		#end
		var j = 0, i = from;
		while (i < end) {
			#if !hxmc.wasm_gc
			// (four ASCII bytes at a time)
			if (i + 4 <= end) {
				var x = Mem.getI32(o.at(i), 0);
				if (x & 0x80808080 == 0) {
					Mem.setI32(d.at(j), 0, x);
					i += 4;
					j += 4;
					continue;
				}
			}
			#end
			var b = o.get(i);
			if (b < 0x80) {
				d.set(j++, b);
				i++;
			} else {
				d.set(j++, ((b & 0x1F) << 6) | (o.get(i + 1) & 0x3F));
				i += 2;
			}
		}
		return s;
	}

	// the length of the well-formed UTF-8 sequence at i, whose first byte b is
	// not ASCII (Unicode's table 3-7); 0 when there is none
	static inline function seqLen(o:Octets, i:Int, end:Int, b:Int):Int {
		return if (b < 0xC2) 0 else if (b < 0xE0) (inByte(o, i + 1, end, 0x80, 0xBF) ? 2 : 0) else if (b < 0xF0)
			(inByte(o, i + 1, end, b == 0xE0 ? 0xA0 : 0x80, b == 0xED ? 0x9F : 0xBF) && inByte(o, i + 2, end, 0x80, 0xBF) ? 3 : 0) else if (b < 0xF5)
			(inByte(o, i + 1, end, b == 0xF0 ? 0x90 : 0x80, b == 0xF4 ? 0x8F : 0xBF)
				&& inByte(o, i + 2, end, 0x80, 0xBF)
				&& inByte(o, i + 3, end, 0x80, 0xBF) ? 4 : 0) else 0;
	}

	static inline function inByte(o:Octets, p:Int, end:Int, lo:Int, hi:Int):Bool {
		return p < end && o.get(p) >= lo && o.get(p) <= hi;
	}

	// UTF-8 bytes of s into buf (3 * length + 1 bytes), NUL-terminated; the byte count.
	// A lone U+DC80 to U+DCFF is the byte decode read it from (0x80 to 0xFF).
	@:hxmc.host("hx_str_utf8_into") @:hxmc.noGc public static function utf8Into(s:String, buf:Octets):Int {
		var n = len(s), j = 0, i = 0;
		if (isOne(s)) {
			var c = chars1(s);
			while (i < n) {
				#if !hxmc.wasm_gc
				// (four ASCII units at a time)
				if (i + 4 <= n) {
					var x = Mem.getI32(c.at(i), 0);
					if (x & 0x80808080 == 0) {
						Mem.setI32(buf.at(j), 0, x);
						i += 4;
						j += 4;
						continue;
					}
				}
				#end
				var cp = c.get(i++);
				if (cp < 0x80)
					buf.set(j++, cp);
				else {
					buf.set(j++, 0xC0 | (cp >> 6));
					buf.set(j++, 0x80 | (cp & 0x3F));
				}
			}
			buf.set(j, 0);
			return j;
		}
		var c = chars2(s);
		while (i < n) {
			var cp = c.get(i);
			if (cp < 0x80) {
				buf.set(j++, cp);
				i++;
				continue;
			}
			if (cp >= 0xD800 && cp < 0xDC00 && i + 1 < n) {
				var lo = c.get(i + 1);
				if (lo >= 0xDC00 && lo < 0xE000) {
					cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
					i++;
				}
			} else if (cp >= 0xDC80 && cp < 0xDD00) {
				buf.set(j++, cp & 0xFF);
				i++;
				continue;
			}
			if (cp < 0x800) {
				buf.set(j++, 0xC0 | (cp >> 6));
				buf.set(j++, 0x80 | (cp & 0x3F));
			} else if (cp < 0x10000) {
				buf.set(j++, 0xE0 | (cp >> 12));
				buf.set(j++, 0x80 | ((cp >> 6) & 0x3F));
				buf.set(j++, 0x80 | (cp & 0x3F));
			} else {
				buf.set(j++, 0xF0 | (cp >> 18));
				buf.set(j++, 0x80 | ((cp >> 12) & 0x3F));
				buf.set(j++, 0x80 | ((cp >> 6) & 0x3F));
				buf.set(j++, 0x80 | (cp & 0x3F));
			}
			i++;
		}
		buf.set(j, 0);
		return j;
	}

	// a malloc'ed UTF-8 copy ("null" for null)
	@:hxmc.host("hx_str_to_utf8") @:hxmc.noGc static function toUtf8(s:String):Ptr {
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

	// a and b of the same length (MirBuild.strEq)
	@:hxmc.export("hx_str_eq_slow") @:hxmc.noGc static function eqSlow(a:String, b:String):Bool {
		var n = len(a);
		var one = isOne(a);
		if (one == isOne(b)) return MemOps.compare(unitsAddr(a), unitsAddr(b), one ? (n : I64) : (2 * n : I64)) == 0;
		return one ? eqMixed(a, b, n) : eqMixed(b, a, n);
	}

	// the n units of a one-byte string and of a two-byte one
	@:hxmc.noGc static function eqMixed(one:String, two:String, n:Int):Bool {
		var c = chars1(one), d = chars2(two);
		for (i in 0...n)
			if (c.get(i) != d.get(i)) return false;
		return true;
	}

	@:hxmc.host("hx_str_cmp") @:hxmc.noGc static function cmp(a:String, b:String):Int {
		if (Repr.same(a, b)) return 0;
		if (isNull(a)) return -1;
		if (isNull(b)) return 1;
		var na = len(a), nb = len(b);
		var n = na < nb ? na : nb;
		var oa = isOne(a), ob = isOne(b);
		if (oa && ob) {
			var ca = chars1(a), cb = chars1(b);
			for (i in 0...n) {
				var x = ca.get(i), y = cb.get(i);
				if (x != y) return x < y ? -1 : 1;
			}
		} else if (!oa && !ob) {
			var ca = chars2(a), cb = chars2(b);
			for (i in 0...n) {
				var x = ca.get(i), y = cb.get(i);
				if (x != y) return x < y ? -1 : 1;
			}
		} else
			for (i in 0...n) {
				var x = unit(a, i), y = unit(b, i);
				if (x != y) return x < y ? -1 : 1;
			}
		return na < nb ? -1 : na > nb ? 1 : 0;
	}

	// FNV-1a over the units, never 0, kept in the string's header where it
	// has room (a benign race between threads: they store the same value).
	// FnLower.strHash computes the same at compile time (DataGen stores it in
	// the literals).
	@:hxmc.host("hx_str_hash") @:hxmc.noGc static function hash(s:String):Int {
		var h = Repr.storedHash(s);
		return h != 0 ? h : hashSlow(s);
	}

	@:hxmc.noGc static function hashSlow(s:String):Int {
		var x = 0x811C9DC5;
		if (isOne(s)) {
			var c = chars1(s);
			for (i in 0...len(s))
				x = (x ^ c.get(i)) * 16777619;
		} else {
			var c = chars2(s);
			for (i in 0...len(s))
				x = (x ^ c.get(i)) * 16777619;
		}
		if (x == 0) x = 1;
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

	@:hxmc.host("hx_str_or_null") @:hxmc.noGc static function orNull(s:String):String
		return isNull(s) ? "null" : s;

	@:hxmc.host("hx_str_concat") static function concat(a:String, b:String):String {
		if (isNull(a)) a = "null";
		if (isNull(b)) b = "null";
		var na = len(a), nb = len(b);
		if (na == 0) return b;
		if (nb == 0) return a;
		if (isOne(a) && isOne(b)) {
			var s = make1(na + nb);
			var d = chars1(s);
			Repr.copy1(d, chars1(a), na);
			Repr.copyTo1(d, na, chars1(b), nb);
			return s;
		}
		var s = make2(na + nb);
		var d = chars2(s);
		if (isOne(a)) Repr.widen(d, 0, chars1(a), 0, na) else Repr.copy(d, chars2(a), na);
		if (isOne(b)) Repr.widen(d, na, chars1(b), 0, nb) else Repr.copyTo(d, na, chars2(b), nb);
		return s;
	}

	// a + b + c (+ d) in one string: no intermediate ones (FnLower: a chain
	// of +); one-byte when every operand is
	@:hxmc.host("hx_str_concat3") static function concat3(a:String, b:String, c:String):String
		return concat4(a, b, c, "");

	@:hxmc.host("hx_str_concat4") static function concat4(a:String, b:String, c:String, d:String):String {
		if (isNull(a)) a = "null";
		if (isNull(b)) b = "null";
		if (isNull(c)) c = "null";
		if (isNull(d)) d = "null";
		var na = len(a), nb = len(b), nc = len(c), nd = len(d);
		if ((na == 0 || isOne(a)) && (nb == 0 || isOne(b)) && (nc == 0 || isOne(c)) && (nd == 0 || isOne(d))) {
			var s = make1(na + nb + nc + nd);
			var u = chars1(s);
			if (na > 0) Repr.copy1(u, chars1(a), na);
			if (nb > 0) Repr.copyTo1(u, na, chars1(b), nb);
			if (nc > 0) Repr.copyTo1(u, na + nb, chars1(c), nc);
			if (nd > 0) Repr.copyTo1(u, na + nb + nc, chars1(d), nd);
			return s;
		}
		var s = make2(na + nb + nc + nd);
		var u = chars2(s);
		put2(u, 0, a, na);
		put2(u, na, b, nb);
		put2(u, na + nb, c, nc);
		put2(u, na + nb + nc, d, nd);
		return s;
	}

	// s's n units into the two-byte units u from ui (widened if one-byte)
	static inline function put2(u:Chars, ui:Int, s:String, n:Int) {
		if (n == 0) return;
		if (isOne(s)) Repr.widen(u, ui, chars1(s), 0, n) else Repr.copyTo(u, ui, chars2(s), n);
	}

	@:hxmc.host("hx_str_of_int") static function ofInt(v:Int):String {
		// |v| <= 2^31 as an I64; u / 10 as (u * 0xCCCCCCCD) >>> 35
		var m10 = ((0xCCCC : I64) << 16) | (0xCCCD : I64);
		var neg = v < 0;
		var u:I64 = v;
		if (neg) u = -u;
		var n = 1;
		var t = u;
		while (t >= 10) {
			t = (t * m10) >>> 35;
			n++;
		}
		if (neg) n++;
		var s = make1(n);
		var d = chars1(s);
		var k = n;
		do {
			var q = (u * m10) >>> 35;
			d.set(--k, 48 + (u - q * 10).toInt());
			u = q;
		} while (u > 0);
		if (neg) d.set(0, 45);
		return s;
	}

	@:hxmc.host("hx_str_of_i64") static function ofI64(v:I64):String {
		// digits of the negative value (no overflow at the minimum)
		var neg = v < 0;
		var m = neg ? v : -v;
		var n = 1;
		var t = m;
		while (t <= -10) {
			t = t / 10;
			n++;
		}
		if (neg) n++;
		var s = make1(n);
		var d = chars1(s);
		var k = n;
		do {
			var q = m / 10;
			d.set(--k, 48 + (q * 10 - m).toInt());
			m = q;
		} while (m < 0);
		if (neg) d.set(0, 45);
		return s;
	}

	@:hxmc.host("hx_str_of_float") static function ofFloat(v:Float):String {
		#if (hxmc.wasm_gc)
		// the host's shortest form (JavaScript's, as FloatText formats); integral values as Ints
		if (v == Std.int(v) && (v != 0 || 1 / v > 0)) return ofInt(Std.int(v));
		return hxmc.rt.gc.W.fmt(v);
		#else
		var buf = Mem.stack(48);
		FloatText.format(v, buf);
		return ofBytes(buf, LibC.strlen(buf).toInt());
		#end
	}

	@:hxmc.host("hx_str_of_bool") @:hxmc.noGc static function ofBool(v:Bool):String
		return v ? "true" : "false";

	// ---- String

	@:hxmc.host("String_charAt") static function charAt(s:String, i:Int):String {
		if (Repr.ult(i, len(s))) return ofUnit(unit(s, i));
		return "";
	}

	// the string of one unit u (0 to 0xFFFF)
	static function ofUnit(u:Int):String {
		if (u < 0x100) {
			var r = make1(1);
			Repr.setUnit1(r, 0, u);
			return r;
		}
		var r = make2(1);
		Repr.setUnit2(r, 0, u);
		return r;
	}

	@:hxmc.host("String_charCodeAt") static function charCodeAt(s:String, i:Int):Null<Int> {
		if (!Repr.ult(i, len(s))) return null;
		return unit(s, i);
	}

	@:hxmc.host("String_fromCharCode") static function fromCharCode(code:Int):String {
		if (code >= 0x10000) {
			var r = make2(2);
			code -= 0x10000;
			Repr.setUnit2(r, 0, 0xD800 | (code >> 10));
			Repr.setUnit2(r, 1, 0xDC00 | (code & 0x3FF));
			return r;
		}
		return ofUnit(code & 0xFFFF);
	}

	@:hxmc.host("String_indexOf") @:hxmc.noGc static function indexOf(s:String, sub:String, start:Null<Int>):Int {
		var n = len(s), m = len(sub);
		var from:Int = start == null ? 0 : start;
		if (from < 0) from = 0;
		// ("" past the end: the length, as String.indexOf says; upstream's TestString)
		if (m == 0) return from <= n ? from : n;
		return find(s, sub, from);
	}

	// the first i >= from where sub (not empty) is in s; -1 if none
	@:hxmc.noGc static function find(s:String, sub:String, from:Int):Int {
		var n = len(s), m = len(sub);
		var i = from;
		var one = isOne(s);
		if (one == isOne(sub)) {
			if (one) {
				var c = chars1(s), d = chars1(sub);
				while (i + m <= n) {
					if (Repr.matchAt1(c, d, i, m)) return i;
					i++;
				}
			} else {
				var c = chars2(s), d = chars2(sub);
				while (i + m <= n) {
					if (Repr.matchAt(c, d, i, m)) return i;
					i++;
				}
			}
		} else
			while (i + m <= n) {
				if (unitsAt(s, i, sub, m)) return i;
				i++;
			}
		return -1;
	}

	// s[i, i + m) == sub[0, m), of any widths
	@:hxmc.noGc static inline function unitsAt(s:String, i:Int, sub:String, m:Int):Bool {
		var k = 0;
		while (k < m && unit(s, i + k) == unit(sub, k))
			k++;
		return k == m;
	}

	@:hxmc.host("String_lastIndexOf") @:hxmc.noGc static function lastIndexOf(s:String, sub:String, start:Null<Int>):Int {
		var n = len(s), m = len(sub);
		var from:Int = start == null ? n : start;
		if (from > n - m) from = n - m;
		// ("" before the start: 0, as Eval and ECMAScript; upstream's Issue5271)
		if (m == 0) return from >= 0 ? from : 0;
		var i = from;
		var one = isOne(s);
		if (one == isOne(sub)) {
			if (one) {
				var c = chars1(s), d = chars1(sub);
				while (i >= 0) {
					if (Repr.matchAt1(c, d, i, m)) return i;
					i--;
				}
			} else {
				var c = chars2(s), d = chars2(sub);
				while (i >= 0) {
					if (Repr.matchAt(c, d, i, m)) return i;
					i--;
				}
			}
		} else
			while (i >= 0) {
				if (unitsAt(s, i, sub, m)) return i;
				i--;
			}
		return -1;
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
	@:hxmc.host("String_toLowerCase") static function toLowerCase(s:String):String
		return mapCase(s, false);

	@:hxmc.host("String_toUpperCase") static function toUpperCase(s:String):String
		return mapCase(s, true);

	static inline function caseOf(t:Array<Int>, upper:Bool, u:Int):Int
		return if (u >= 128) CaseMap.map(t, u) else if (upper) (u >= 97 && u <= 122 ? u - 32 : u) else (u >= 65 && u <= 90 ? u + 32 : u);

	// s in upper or lower case: one-byte from a one-byte string, unless a
	// unit's case is above 0xFF (the upper cases of U+00B5 and U+00FF)
	static function mapCase(s:String, upper:Bool):String {
		var n = len(s);
		var t = CaseMap.table(upper);
		if (isOne(s)) {
			var r = make1(n);
			var c = chars1(s), d = chars1(r);
			var i = 0;
			while (i < n) {
				var u = caseOf(t, upper, c.get(i));
				if (u > 0xFF) break;
				d.set(i++, u);
			}
			if (i == n) return r;
			var w = make2(n);
			var c1 = chars1(s), d2 = chars2(w);
			for (k in 0...n)
				d2.set(k, caseOf(t, upper, c1.get(k)));
			return w;
		}
		var r = make2(n);
		var c = chars2(s), d = chars2(r);
		for (i in 0...n)
			d.set(i, caseOf(t, upper, c.get(i)));
		return r;
	}

	@:hxmc.host("String_toString") @:hxmc.noGc static function toString(s:String):String
		return s;

	// new String(s): strings do not change, s itself
	@:hxmc.host("String_new") @:hxmc.noGc static function ofString(s:String):String
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
				at = find(s, delim, start);
			var end = at < 0 ? n : at;
			arr.push(range(s, start, end - start));
			if (at < 0) break;
			start = m == 0 ? at : at + m;
		}
		return arr;
	}

	// ---- StringBuf: in linear memory slot 0 the length, slot 1 the units
	// (a string as long as the capacity, one-byte until a unit above 0xFF is
	// added); its storage is Repr's

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

	static inline function sbAddStr(b:Dynamic, s:String)
		sbAddRange(b, s, 0, len(s));

	// s's units [pos, pos + n) appended (the buffer widened first if one of
	// them is above 0xFF)
	static function sbAddRange(b:Dynamic, s:String, pos:Int, n:Int) {
		reserve(b, n);
		var at = sbLen(b);
		if (Repr.sbIsOne(b) && !isOne(s) && !Repr.fitsOne(chars2(s), pos, n)) Repr.sbWiden(b, Repr.sbCapacity(b), at);
		sbPut(b, at, s, pos, n);
		Repr.sbSetLen(b, at + n);
	}

	// s's units [pos, pos + n) written at `at` (room made; a two-byte
	// buffer if any is above 0xFF; no GC point)
	static inline function sbPut(b:Dynamic, at:Int, s:String, pos:Int, n:Int) {
		if (Repr.sbIsOne(b)) {
			if (isOne(s))
				Repr.copyAt1(Repr.sbChars1(b), at, chars1(s), pos, n);
			else
				Repr.narrow(Repr.sbChars1(b), at, chars2(s), pos, n);
		} else if (isOne(s))
			Repr.widen(Repr.sbChars2(b), at, chars1(s), pos, n);
		else
			Repr.copyAt(Repr.sbChars2(b), at, chars2(s), pos, n);
	}

	@:hxmc.host("StringBuf_add") static function sbAdd(b:Dynamic, x:Dynamic):Void
		sbAddStr(b, Repr.stdString(x));

	// (the inline fast path's misses: a unit above 0xFF, a two-byte buffer, a full one)
	@:hxmc.export("StringBuf_addChar_slow") static function sbAddCharSlow(b:Dynamic, c:Int):Void {
		reserve(b, 2);
		var n = sbLen(b);
		if (Repr.sbIsOne(b)) {
			if (Repr.ult(c, 0x100)) {
				Repr.sbChars1(b).set(n, c);
				Repr.sbSetLen(b, n + 1);
				return;
			}
			Repr.sbWiden(b, Repr.sbCapacity(b), n);
		}
		var d = Repr.sbChars2(b);
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

	// (substr's range, copied without the substring)
	@:hxmc.host("StringBuf_addSub") static function sbAddSub(b:Dynamic, s:String, pos:Int, lenp:Null<Int>):Void {
		if (isNull(s)) {
			sbAddStr(b, substr(s, pos, lenp));
			return;
		}
		var n = len(s);
		var l:Int = lenp == null ? n : lenp;
		if (pos < 0) {
			pos += n;
			if (pos < 0) pos = 0;
		}
		if (pos > n) return;
		if (l < 0) {
			l += n - pos;
			if (l < 0) return;
		}
		if (pos + l > n) l = n - pos;
		if (l > 0) sbAddRange(b, s, pos, l);
	}

	// unit u (below 0x100) written at `at` (room made)
	static inline function sbUnit(b:Dynamic, at:Int, u:Int)
		if (Repr.sbIsOne(b)) Repr.sbChars1(b).set(at, u) else Repr.sbChars2(b).set(at, u);

	#if !hxmc.wasm_gc
	// eight one-byte units (lanes1) or four two-byte ones (lanes2) of a 64-bit
	// word at a time: whether a lane of x is zero, or below 0x20
	static inline function lanes1(n:Int):I64
		return ((n * 0x1010101 : I64) << 32) | (((n * 0x1010101 : I64) << 32) >>> 32);

	static inline function lanes2(n:Int):I64
		return ((n * 0x10001 : I64) << 32) | (((n * 0x10001 : I64) << 32) >>> 32);

	static inline function zero1(x:I64):Bool
		return (x - lanes1(1)) & ~x & lanes1(0x80) != (0 : I64);

	static inline function low1(x:I64):Bool
		return (x - lanes1(0x20)) & ~x & lanes1(0x80) != (0 : I64);

	static inline function zero2(x:I64):Bool
		return (x - lanes2(1)) & ~x & lanes2(0x8000) != (0 : I64);

	static inline function low2(x:I64):Bool
		return (x - lanes2(0x20)) & ~x & lanes2(0x8000) != (0 : I64);
	#end

	// the index of the first quote, backslash or 0 unit of s from pos (its
	// length if none): haxe.format.JsonParser.parseString's units to skip
	// (hxmc's)
	@:hxmc.noGc public static function jsonRun(s:String, pos:Int):Int {
		var n = len(s);
		var i = pos < 0 ? 0 : pos;
		if (isOne(s)) {
			var c = chars1(s);
			#if !hxmc.wasm_gc
			while (i + 8 <= n) {
				var w = Mem.getI64(c.at(i), 0);
				if (zero1(w) || zero1(w ^ lanes1('"'.code)) || zero1(w ^ lanes1('\\'.code))) break;
				i += 8;
			}
			#end
			while (i < n) {
				var u = c.get(i);
				if (u == '"'.code || u == '\\'.code || u == 0) break;
				i++;
			}
			return i;
		}
		var c = chars2(s);
		#if !hxmc.wasm_gc
		while (i + 4 <= n) {
			var w = Mem.getI64(c.at(i), 0);
			if (zero2(w) || zero2(w ^ lanes2('"'.code)) || zero2(w ^ lanes2('\\'.code))) break;
			i += 4;
		}
		#end
		while (i < n) {
			var u = c.get(i);
			if (u == '"'.code || u == '\\'.code || u == 0) break;
			i++;
		}
		return i;
	}

	static inline function jsonEscaped(u:Int):Bool
		return u == '"'.code || u == '\\'.code || u <= 13 && (u == 10 || u == 13 || u == 9 || u == 8 || u == 12);

	// the index of the first unit of s from i, before n, that JsonPrinter
	// escapes (n if none); the words skipped stop at any unit below 0x20
	@:hxmc.noGc static function jsonPlain(s:String, i:Int, n:Int):Int {
		if (isOne(s)) {
			var c = chars1(s);
			#if !hxmc.wasm_gc
			while (i + 8 <= n) {
				var w = Mem.getI64(c.at(i), 0);
				if (low1(w) || zero1(w ^ lanes1('"'.code)) || zero1(w ^ lanes1('\\'.code))) break;
				i += 8;
			}
			#end
			while (i < n && !jsonEscaped(c.get(i)))
				i++;
			return i;
		}
		var c = chars2(s);
		#if !hxmc.wasm_gc
		while (i + 4 <= n) {
			var w = Mem.getI64(c.at(i), 0);
			if (low2(w) || zero2(w ^ lanes2('"'.code)) || zero2(w ^ lanes2('\\'.code))) break;
			i += 4;
		}
		#end
		while (i < n && !jsonEscaped(c.get(i)))
			i++;
		return i;
	}

	// s as haxe.format.JsonPrinter quotes a string (its seven escapes, the
	// other units as they are), appended in one go: the runs without an
	// escape copied whole (JsonPrinter.quote, hxmc's)
	@:hxmc.host("StringBuf_addJsonString") static function sbAddJson(b:Dynamic, s:String):Void {
		// (room for s and the quotes; an escape makes room for itself and
		// the rest: it may collect)
		var n = len(s);
		reserve(b, n + 2);
		var at = sbLen(b);
		if (Repr.sbIsOne(b) && !isOne(s) && !Repr.fitsOne(chars2(s), 0, n)) Repr.sbWiden(b, Repr.sbCapacity(b), at);
		sbUnit(b, at++, '"'.code);
		var i = 0;
		while (i < n) {
			var j = jsonPlain(s, i, n);
			if (j > i) {
				sbPut(b, at, s, i, j - i);
				at += j - i;
			}
			if (j == n) break;
			var u = unit(s, j);
			if (at + 2 + (n - j - 1) + 1 > Repr.sbCapacity(b)) {
				Repr.sbSetLen(b, at);
				reserve(b, 2 + (n - j - 1) + 1);
			}
			sbUnit(b, at++, '\\'.code);
			sbUnit(b, at++, switch u {
				case 10: 'n'.code;
				case 13: 'r'.code;
				case 9: 't'.code;
				case 8: 'b'.code;
				case 12: 'f'.code;
				case _: u;
			});
			i = j + 1;
		}
		sbUnit(b, at++, '"'.code);
		Repr.sbSetLen(b, at);
	}

	@:hxmc.host("StringBuf_clear") @:hxmc.noGc static function sbClear(b:Dynamic):Void
		Repr.sbSetLen(b, 0);

	@:hxmc.host("StringBuf_get_length") @:hxmc.noGc static function sbGetLength(b:Dynamic):Int
		return sbLen(b);

	// (one-byte where every unit fits: a buffer widened, then cleared, may hold none above 0xFF)
	@:hxmc.host("StringBuf_toString") static function sbToString(b:Dynamic):String {
		var n = sbLen(b);
		if (Repr.sbIsOne(b)) {
			var s = make1(n);
			Repr.copy1(chars1(s), Repr.sbChars1(b), n);
			return s;
		}
		if (Repr.fitsOne(Repr.sbChars2(b), 0, n)) {
			var s = make1(n);
			Repr.narrow(chars1(s), 0, Repr.sbChars2(b), 0, n);
			return s;
		}
		var s = make2(n);
		Repr.copy(chars2(s), Repr.sbChars2(b), n);
		return s;
	}

	// ---- Std

	@:hxmc.host("Std_parseInt") static function parseInt(s:String):Null<Int> {
		if (isNull(s)) return null;
		var n = len(s), i = 0;
		inline function at(k:Int):Int
			return unit(s, k);
		// (space, \t, \n, \v, \f, \r: upstream's TestStd)
		while (i < n && (at(i) == 32 || (at(i) >= 9 && at(i) <= 13)))
			i++;
		var neg = false;
		if (i < n && (at(i) == 45 || at(i) == 43)) {
			neg = at(i) == 45;
			i++;
		}
		if (i + 1 < n && at(i) == 48 && (at(i + 1) == 120 || at(i + 1) == 88)) {
			i += 2;
			var v = 0, any = false;
			while (i < n) {
				var c = at(i);
				var d = c >= 48 && c <= 57 ? c - 48 : c >= 97 && c <= 102 ? c - 87 : c >= 65 && c <= 70 ? c - 55 : -1;
				if (d < 0) break;
				v = (v << 4) + d;
				any = true;
				i++;
			}
			if (!any) return null;
			return neg ? -v : v;
		}
		var v:I64 = 0;
		var any = false;
		var low32 = ((1 : I64) << 32) - 1;
		while (i < n && at(i) >= 48 && at(i) <= 57) {
			v = v * 10 + (at(i) - 48);
			if (v > low32) v = v & low32;
			any = true;
			i++;
		}
		if (!any) return null;
		return (neg ? -v : v).toInt();
	}

	@:hxmc.host("Std_parseFloat") static function parseFloat(s:String):Float {
		if (isNull(s)) return Math.NaN;
		#if (hxmc.wasm_gc)
		// the host's (JavaScript's parseFloat, as strtod reads)
		return hxmc.rt.gc.W.parseFloat(s);
		#else
		// ASCII bytes for strtod (any other unit ends the number, as its UTF-8 would)
		var n = len(s);
		var small = Mem.stack(128);
		var buf = n < 128 ? small : LibC.malloc((n + 1 : I64));
		for (i in 0...n) {
			var u = unit(s, i);
			Mem.setU8At(buf, 0, i, u < 0x80 ? u : 0x80);
		}
		Mem.setU8At(buf, 0, n, 0);
		var p = buf;
		while (Mem.getU8(p, 0) == 32 || Mem.getU8(p, 0) == 9 || Mem.getU8(p, 0) == 10 || Mem.getU8(p, 0) == 13)
			p = p.add(1);
		var end = Mem.stack(8);
		var d = LibC.strtod(p, end);
		if (Mem.getPtr(end, 0) == p) d = Math.NaN;
		if (buf != small) LibC.free(buf);
		return d;
		#end
	}

	@:hxmc.host("Std_random") @:hxmc.noGc static function random(max:Int):Int {
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
