package hxmc.rt;

import hxmc.rt.Repr.Chars;
import hxmc.rt.Repr.Octets;
import hxmc.I64;
import hxmc.unsafe.*;

// String's algorithms, written once as scoped code (docs/plans/lowlevel.md,
// "One core, two faces") over code units (Chars) and bytes (Octets), the
// representation the runtime chose (Repr: linear memory, or WasmGC's
// arrays, where no code is scoped). The GC face is String's (hxmc.rt.Str:
// its natives take a String's units right before calling, no GC point in
// between); the scoped face is hxmc.scoped.Str's. Strings are UTF-16 on
// both; UTF-8 crosses the system boundaries, a byte that begins no
// well-formed sequence as one unit U+DC80 to U+DCFF (surrogateescape), so
// any bytes decoded and encoded again are the same bytes.
#if !hxmc.wasm_gc @:hxmc.scoped #end
class TextCore {
	// the first i >= from where the m units d start in the n units c; -1
	// (m = 0: from, at most n)
	public static inline function indexOf(c:Chars, n:Int, d:Chars, m:Int, from:Int):Int {
		if (from < 0) from = 0;
		var r = -1;
		if (m == 0) r = from <= n ? from : n else {
			var i = from;
			while (i + m <= n) {
				if (Repr.matchAt(c, d, i, m)) {
					r = i;
					break;
				}
				i++;
			}
		}
		return r;
	}

	// the last i <= from where they start; -1 (m = 0: from, at least 0)
	public static inline function lastIndexOf(c:Chars, n:Int, d:Chars, m:Int, from:Int):Int {
		if (from > n - m) from = n - m;
		var r = -1;
		if (m == 0) r = from >= 0 ? from : 0 else {
			var i = from;
			while (i >= 0) {
				if (Repr.matchAt(c, d, i, m)) {
					r = i;
					break;
				}
				i--;
			}
		}
		return r;
	}

	// -1, 0 or 1: the units of a against b's, by unit, then by length
	public static inline function compare(ca:Chars, na:Int, cb:Chars, nb:Int):Int {
		var n = na < nb ? na : nb;
		var r = na < nb ? -1 : na > nb ? 1 : 0;
		for (i in 0...n) {
			var x = ca.get(i), y = cb.get(i);
			if (x != y) {
				r = x < y ? -1 : 1;
				break;
			}
		}
		return r;
	}

	// FNV-1a over the units, never 0
	public static inline function hash(c:Chars, n:Int):Int {
		var x = 0x811C9DC5;
		for (i in 0...n)
			x = (x ^ c.get(i)) * 16777619;
		return x == 0 ? 1 : x;
	}

	// UTF-8 of the n units c into buf from byte `to` (3 * n + 1 bytes),
	// NUL-terminated: the byte count
	public static inline function utf8Encode(c:Chars, n:Int, buf:Octets, to:Int = 0):Int {
		var j = to, i = 0;
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
		return j - to;
	}

	// the units the UTF-8 bytes [from, end) of o decode to
	public static inline function utf8Units(o:Octets, from:Int, end:Int):Int {
		var units = 0, i = from;
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
				} else {
					units += k == 4 ? 2 : 1;
					i += k;
				}
			}
		}
		return units;
	}

	// the UTF-8 bytes [from, end) of o decoded into d (utf8Units of them)
	public static inline function utf8Decode(o:Octets, from:Int, end:Int, d:Chars) {
		var j = 0;
		var i = from;
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
	}

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

	// v in decimal into the n (intLength) units d
	public static inline function intWrite(v:Int, d:Chars, n:Int) {
		var u:I64 = v;
		if (u < 0) u = -u;
		var k = n;
		do {
			var q = (u * m10()) >>> 35;
			d.set(--k, 48 + (u - q * 10).toInt());
			u = q;
		} while (u > 0);
		if (v < 0) d.set(0, 45);
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

	public static inline function i64Write(v:I64, d:Chars, n:Int) {
		var m = v < 0 ? v : -v;
		var k = n;
		do {
			var q = m / 10;
			d.set(--k, 48 + (q * 10 - m).toInt());
			m = q;
		} while (m < 0);
		if (v < 0) d.set(0, 45);
	}

	// the integer the n units c start with, as Std.parseInt reads it (blanks,
	// a sign, decimal digits kept to 32 bits, or 0x and hexadecimal ones), with
	// 1 << 32 set; 0: none
	public static inline function parseInt(c:Chars, n:Int):I64 {
		var i = 0;
		// (space, \t, \n, \v, \f, \r: upstream's TestStd)
		while (i < n && (c.get(i) == 32 || (c.get(i) >= 9 && c.get(i) <= 13)))
			i++;
		var neg = false;
		if (i < n && (c.get(i) == 45 || c.get(i) == 43)) {
			neg = c.get(i) == 45;
			i++;
		}
		var v:I64 = 0;
		var any = false;
		if (i + 1 < n && c.get(i) == 48 && (c.get(i + 1) == 120 || c.get(i + 1) == 88)) {
			i += 2;
			while (i < n) {
				var u = c.get(i);
				var d = u >= 48 && u <= 57 ? u - 48 : u >= 97 && u <= 102 ? u - 87 : u >= 65 && u <= 70 ? u - 55 : -1;
				if (d < 0) break;
				v = ((v << 4) + d) & low32();
				any = true;
				i++;
			}
		} else {
			while (i < n && c.get(i) >= 48 && c.get(i) <= 57) {
				v = (v * 10 + (c.get(i) - 48)) & low32();
				any = true;
				i++;
			}
		}
		return any ? (((neg ? -v : v) & low32()) | ((1 : I64) << 32)) : 0;
	}

	static inline function low32():I64
		return ((1 : I64) << 32) - 1;

	// the length of the well-formed UTF-8 sequence at i, whose first byte b is
	// not ASCII (Unicode's table 3-7); 0 when there is none
	static inline function seqLen(o:Octets, i:Int, end:Int, b:Int):Int {
		return if (b < 0xC2) 0 else if (b < 0xE0) (inByte(o, i + 1, end, 0x80, 0xBF) ? 2 : 0) else if (b < 0xF0)
			(inByte(o, i + 1, end, b == 0xE0 ? 0xA0 : 0x80, b == 0xED ? 0x9F : 0xBF) && inByte(o, i + 2, end, 0x80, 0xBF) ? 3 : 0) else if (b < 0xF5)
			(inByte(o, i + 1, end, b == 0xF0 ? 0x90 : 0x80, b == 0xF4 ? 0x8F : 0xBF)
				&& inByte(o, i + 2, end, 0x80, 0xBF)
				&& inByte(o, i + 3, end, 0x80, 0xBF) ? 4 : 0) else 0;
	}

	static inline function inByte(o:Octets, p:Int, end:Int, lo:Int, hi:Int):Bool
		return p < end && o.get(p) >= lo && o.get(p) <= hi;
}
