package hxmc.rt;

import hxmc.I64;
import hxmc.scoped.Slice;
import hxmc.scoped.Str;
import hxmc.unsafe.UInt8;

// String's algorithms, written once as scoped code over the scoped
// abstractions only (docs/plans/lowlevel.md, "Two representations, one
// core"): code units as a Str, bytes as a Slice of UInt8, whatever the
// target makes of them (linear memory's addresses, WasmGC's arrays). The GC
// face is String's (hxmc.rt.Str: its natives view a String's units right
// before calling, Str.view, no GC point in between); the scoped face is
// hxmc.scoped.Str's. The units and bytes are read and written unchecked
// (Str.unit, Slice.unsafeGet: in range by construction, the ranges checked
// on entry). Strings are UTF-16 on both faces; UTF-8 crosses the system
// boundaries, a byte that begins no well-formed sequence as one unit U+DC80
// to U+DCFF (surrogateescape), so any bytes decoded and encoded again are
// the same bytes.
@:hxmc.scoped
class TextCore {
	// the first i >= from where the units of d start in c; -1 (d empty: from,
	// at most c's length)
	public static inline function indexOf(c:Str, d:Str, from:Int):Int {
		var n = c.length, m = d.length;
		if (from < 0) from = 0;
		var r = -1;
		if (m == 0) r = from <= n ? from : n else {
			var i = from;
			while (i + m <= n) {
				if (c.matchAt(i, d)) {
					r = i;
					break;
				}
				i++;
			}
		}
		return r;
	}

	// the last i <= from where they start; -1 (d empty: from, at least 0)
	public static inline function lastIndexOf(c:Str, d:Str, from:Int):Int {
		var n = c.length, m = d.length;
		if (from > n - m) from = n - m;
		var r = -1;
		if (m == 0) r = from >= 0 ? from : 0 else {
			var i = from;
			while (i >= 0) {
				if (c.matchAt(i, d)) {
					r = i;
					break;
				}
				i--;
			}
		}
		return r;
	}

	// -1, 0 or 1: the units of a against b's, by unit, then by length
	public static inline function compare(a:Str, b:Str):Int {
		var na = a.length, nb = b.length;
		var n = na < nb ? na : nb;
		var r = na < nb ? -1 : na > nb ? 1 : 0;
		for (i in 0...n) {
			var x = a.unit(i), y = b.unit(i);
			if (x != y) {
				r = x < y ? -1 : 1;
				break;
			}
		}
		return r;
	}

	// FNV-1a over the units, never 0
	public static inline function hash(c:Str):Int {
		var x = 0x811C9DC5;
		for (i in 0...c.length)
			x = (x ^ c.unit(i)) * 16777619;
		return x == 0 ? 1 : x;
	}

	// UTF-8 of the units c into buf (3 * length + 1 bytes, checked),
	// NUL-terminated: the byte count
	public static inline function utf8Encode(c:Str, buf:Slice<UInt8>):Int {
		var n = c.length;
		if (buf.length < 3 * n + 1) Abort.outOfRange();
		var j = 0, i = 0;
		while (i < n) {
			var cp = c.unit(i);
			if (cp < 0x80) {
				put(buf, j++, cp);
				i++;
				continue;
			}
			if (cp >= 0xD800 && cp < 0xDC00 && i + 1 < n) {
				var lo = c.unit(i + 1);
				if (lo >= 0xDC00 && lo < 0xE000) {
					cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
					i++;
				}
			} else if (cp >= 0xDC80 && cp < 0xDD00) {
				put(buf, j++, cp & 0xFF);
				i++;
				continue;
			}
			if (cp < 0x800) {
				put(buf, j++, 0xC0 | (cp >> 6));
				put(buf, j++, 0x80 | (cp & 0x3F));
			} else if (cp < 0x10000) {
				put(buf, j++, 0xE0 | (cp >> 12));
				put(buf, j++, 0x80 | ((cp >> 6) & 0x3F));
				put(buf, j++, 0x80 | (cp & 0x3F));
			} else {
				put(buf, j++, 0xF0 | (cp >> 18));
				put(buf, j++, 0x80 | ((cp >> 12) & 0x3F));
				put(buf, j++, 0x80 | ((cp >> 6) & 0x3F));
				put(buf, j++, 0x80 | (cp & 0x3F));
			}
			i++;
		}
		buf.unsafeSet(j, 0);
		return j;
	}

	// (an Int argument: typed against UInt8, `cp >> 12` would be UInt8's >>,
	// of the low byte, as Haxe chooses an abstract's operator by the expected type)
	static inline function put(buf:Slice<UInt8>, j:Int, v:Int)
		buf.unsafeSet(j, v);

	// the units the UTF-8 bytes [from, end) of o decode to (the range checked)
	public static inline function utf8Units(o:Slice<UInt8>, from:Int, end:Int):Int {
		if (from < 0 || end > o.length) Abort.outOfRange();
		var units = 0, i = from;
		while (i < end) {
			// (four ASCII bytes at a time)
			if (i + 4 <= end && Slice.word(o, i) & 0x80808080 == 0) {
				units += 4;
				i += 4;
				continue;
			}
			var b:Int = o.unsafeGet(i);
			if (b < 0x80) {
				units++;
				i++;
			} else {
				var k = seqLen(o, i, end, b);
				if (k == 0) {
					units++;
					i++;
				} else {
					units += k == 4 ? 2 : 1;
					i += k;
				}
			}
		}
		return units;
	}

	// the UTF-8 bytes [from, end) of o decoded into d, which holds their
	// utf8Units units (the range checked, and d's room as it fills)
	public static inline function utf8Decode(o:Slice<UInt8>, from:Int, end:Int, d:Str) {
		if (from < 0 || end > o.length) Abort.outOfRange();
		var j = 0, len = d.length;
		var i = from;
		while (i < end) {
			// (four ASCII bytes at a time, room for them)
			if (i + 4 <= end && j + 4 <= len) {
				var x = Slice.word(o, i);
				if (x & 0x80808080 == 0) {
					d.setAscii4(j, x);
					i += 4;
					j += 4;
					continue;
				}
			}
			if (j >= len) Abort.outOfRange();
			var b:Int = o.unsafeGet(i);
			if (b < 0x80) {
				d.setUnit(j++, b);
				i++;
				continue;
			}
			var k = seqLen(o, i, end, b);
			if (k == 0) {
				d.setUnit(j++, 0xDC00 | b);
				i++;
				continue;
			}
			var b1:Int = o.unsafeGet(i + 1);
			var cp = if (k == 2) ((b & 0x1F) << 6) | (b1 & 0x3F) else if (k == 3) {
				var b2:Int = o.unsafeGet(i + 2);
				((b & 0x0F) << 12) | ((b1 & 0x3F) << 6) | (b2 & 0x3F);
			} else {
				var b2:Int = o.unsafeGet(i + 2), b3:Int = o.unsafeGet(i + 3);
				((b & 0x07) << 18) | ((b1 & 0x3F) << 12) | ((b2 & 0x3F) << 6) | (b3 & 0x3F);
			}
			i += k;
			if (cp >= 0x10000) {
				if (j + 2 > len) Abort.outOfRange();
				cp -= 0x10000;
				d.setUnit(j++, 0xD800 | (cp >> 10));
				d.setUnit(j++, 0xDC00 | (cp & 0x3FF));
			} else d.setUnit(j++, cp);
		}
	}

	// the length of the well-formed UTF-8 sequence at i, whose first byte b is
	// not ASCII (Unicode's table 3-7); 0 when there is none
	static inline function seqLen(o:Slice<UInt8>, i:Int, end:Int, b:Int):Int {
		return if (b < 0xC2) 0 else if (b < 0xE0) (inByte(o, i + 1, end, 0x80, 0xBF) ? 2 : 0) else if (b < 0xF0)
			(inByte(o, i + 1, end, b == 0xE0 ? 0xA0 : 0x80, b == 0xED ? 0x9F : 0xBF) && inByte(o, i + 2, end, 0x80, 0xBF) ? 3 : 0) else if (b < 0xF5)
			(inByte(o, i + 1, end, b == 0xF0 ? 0x90 : 0x80, b == 0xF4 ? 0x8F : 0xBF)
				&& inByte(o, i + 2, end, 0x80, 0xBF)
				&& inByte(o, i + 3, end, 0x80, 0xBF) ? 4 : 0) else 0;
	}

	static inline function inByte(o:Slice<UInt8>, p:Int, end:Int, lo:Int, hi:Int):Bool {
		var x:Int = p < end ? o.unsafeGet(p) : -1;
		return x >= lo && x <= hi;
	}

	// ---- hexadecimal

	// the bytes of b as lower-case hexadecimal into d (2 units a byte, checked)
	public static inline function hexEncode(b:Slice<UInt8>, d:Str) {
		var n = b.length;
		if (d.length < 2 * n) Abort.outOfRange();
		for (i in 0...n) {
			var v:Int = b.unsafeGet(i);
			d.setUnit(2 * i, hexDigit(v >> 4));
			d.setUnit(2 * i + 1, hexDigit(v & 15));
		}
	}

	static inline function hexDigit(v:Int):Int
		return v < 10 ? 48 + v : 87 + v;

	// the bytes the pairs of hexadecimal digits of c give into b (length(c) / 2
	// of them, checked; a unit that is no digit counts as 0)
	public static inline function hexDecode(c:Str, b:Slice<UInt8>) {
		var n = c.length >> 1;
		if (b.length < n) Abort.outOfRange();
		for (i in 0...n)
			put(b, i, (hexValue(c.unit(2 * i)) << 4) | hexValue(c.unit(2 * i + 1)));
	}

	static inline function hexValue(u:Int):Int
		return u >= 48 && u <= 57 ? u - 48 : u >= 97 && u <= 102 ? u - 87 : u >= 65 && u <= 70 ? u - 55 : 0;

	// ---- numbers

	// the units of v in decimal
	public static inline function intLength(v:Int):Int {
		var n = v < 0 ? 2 : 1;
		var t:I64 = v;
		if (t < 0) t = -t;
		while (t >= 10) {
			t = (t * m10()) >>> 35;
			n++;
		}
		return n;
	}

	// v in decimal as the units of d, of which there are intLength(v)
	// (checked: a digit with no unit for it aborts)
	public static inline function intWrite(v:Int, d:Str) {
		var u:I64 = v;
		if (u < 0) u = -u;
		var k = d.length, low = v < 0 ? 1 : 0;
		do {
			if (k <= low) Abort.outOfRange();
			var q = (u * m10()) >>> 35;
			d.setUnit(--k, 48 + (u - q * 10).toInt());
			u = q;
		} while (u > 0);
		if (v < 0) d.setUnit(0, 45);
	}

	// (|v| <= 2^31 as an I64: u / 10 is (u * 0xCCCCCCCD) >>> 35)
	static inline function m10():I64
		return ((0xCCCC : I64) << 16) | (0xCCCD : I64);

	// the units of v in decimal (digits of the negative value: no overflow at
	// the minimum)
	public static inline function i64Length(v:I64):Int {
		var n = v < 0 ? 2 : 1;
		var t = v < 0 ? v : -v;
		while (t <= -10) {
			t = t / 10;
			n++;
		}
		return n;
	}

	// (as intWrite)
	public static inline function i64Write(v:I64, d:Str) {
		var m = v < 0 ? v : -v;
		var k = d.length, low = v < 0 ? 1 : 0;
		do {
			if (k <= low) Abort.outOfRange();
			var q = m / 10;
			d.setUnit(--k, 48 + (q * 10 - m).toInt());
			m = q;
		} while (m < 0);
		if (v < 0) d.setUnit(0, 45);
	}

	// the integer c starts with, as Std.parseInt reads it (blanks, a sign,
	// decimal digits kept to 32 bits, or 0x and hexadecimal ones), with 1 << 32
	// set; 0: none
	public static inline function parseInt(c:Str):I64 {
		var n = c.length, i = 0;
		// (space, \t, \n, \v, \f, \r: upstream's TestStd)
		while (i < n && (c.unit(i) == 32 || (c.unit(i) >= 9 && c.unit(i) <= 13)))
			i++;
		var neg = false;
		if (i < n && (c.unit(i) == 45 || c.unit(i) == 43)) {
			neg = c.unit(i) == 45;
			i++;
		}
		var v:I64 = 0;
		var any = false;
		if (i + 1 < n && c.unit(i) == 48 && (c.unit(i + 1) == 120 || c.unit(i + 1) == 88)) {
			i += 2;
			while (i < n) {
				var u = c.unit(i);
				var d = u >= 48 && u <= 57 ? u - 48 : u >= 97 && u <= 102 ? u - 87 : u >= 65 && u <= 70 ? u - 55 : -1;
				if (d < 0) break;
				v = ((v << 4) + d) & low32();
				any = true;
				i++;
			}
		} else {
			while (i < n && c.unit(i) >= 48 && c.unit(i) <= 57) {
				v = (v * 10 + (c.unit(i) - 48)) & low32();
				any = true;
				i++;
			}
		}
		return any ? (((neg ? -v : v) & low32()) | ((1 : I64) << 32)) : 0;
	}

	static inline function low32():I64
		return ((1 : I64) << 32) - 1;
}
