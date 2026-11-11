package hxmc;

import hxmc.I64;
import hxmc.ReadOnlySpan;
import hxmc.Span;
import hxmc.rt.Bytes;
import hxmc.rt.C;
import hxmc.rt.Repr;
import hxmc.unsafe.BytesPtr;
import hxmc.unsafe.LibC;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Ptr;
import hxmc.unsafe.UInt8;

// DEFLATE (RFC 1951) decompression and CRC-32 in kernels over spans, for
// programs that inflate whole buffers (the compiler's ZIP reader):
// haxe.zip.InflateImpl and haxe.crypto.Crc32 are several times slower. A
// canonical-Huffman decoder of streams held whole in memory, the buffers lent
// for the call (Span.ofBytes), its state and tables in the frame
// (Span.stack). Errors (invalid codes, the input running out, the output
// overflowing) set the state's error flag, which every loop checks.
class NativeZip {
	// (a code's Ints: counts[16], then symbols[288])
	static inline var HUFF = 16 + 288;

	// (fail: the error flag, which every loop checks)
	static inline function err(s:Span<ZipState>):Bool
		return s[0].err != 0;

	static inline function fail(s:Span<ZipState>)
		s[0].err = 1;

	// (the tables of RFC 1951 3.2.5, values + 1 for the extra bits: ZipTab)
	static inline function lbase(i:Int):Int
		return ZipTab.lbase()[i].toInt();

	static inline function lext(i:Int):Int
		return ZipTab.lext()[i].toInt();

	static inline function dbase(i:Int):Int
		return ZipTab.dbase()[i].toInt();

	static inline function dext(i:Int):Int
		return ZipTab.dext()[i].toInt();

	static inline function order(i:Int):Int
		return ZipTab.order()[i].toInt();

	@:hxmc.kernel static function bits(s:Span<ZipState>, inp:ReadOnlySpan<UInt8>, need:Int):Int {
		var val:I64 = s[0].bitbuf;
		val = val & (((1 : I64) << 32) - 1);
		var cnt = s[0].bitcnt;
		while (cnt < need) {
			var pos = s[0].inpos;
			if (pos < 0 || pos >= inp.length) {
				fail(s);
				return 0;
			}
			val = val | (((inp[pos] : Int) : I64) << cnt);
			s[0].inpos = pos + 1;
			cnt += 8;
		}
		s[0].bitbuf = (val >>> need).toInt();
		s[0].bitcnt = cnt - need;
		return (val & (((1 : I64) << need) - 1)).toInt();
	}

	@:hxmc.kernel static function decode(s:Span<ZipState>, inp:ReadOnlySpan<UInt8>, h:ReadOnlySpan<Int>):Int {
		if (h.length < HUFF) return -1;
		var code = 0, first = 0, index = 0;
		for (len in 1...16) {
			code |= bits(s, inp, 1);
			if (err(s)) return -1;
			var count = h[len];
			if (code - count < first) return h[16 + index + (code - first)];
			index += count;
			first += count;
			first <<= 1;
			code <<= 1;
		}
		fail(s); // no code of 15 bits or less matches
		return -1;
	}

	// 0 for a complete code, > 0 for an incomplete one, < 0 for an oversubscribed one
	@:hxmc.kernel static function construct(h:Span<Int>, length:ReadOnlySpan<Int>, n:Int):Int {
		if (h.length < HUFF || n > length.length || n > 288) return -1;
		var offs:Span<Int> = Span.stack(16);
		for (len in 0...16)
			h[len] = 0;
		for (sym in 0...n) {
			var l = length[sym];
			h[l] = h[l] + 1;
		}
		if (h[0] == n) return 0;
		var left = 1;
		for (len in 1...16) {
			left <<= 1;
			left -= h[len];
			if (left < 0) return left;
		}
		offs[1] = 0;
		for (len in 1...15)
			offs[len + 1] = offs[len] + h[len];
		for (sym in 0...n) {
			var l = length[sym];
			if (l != 0) {
				var o = offs[l];
				h[16 + o] = sym;
				offs[l] = o + 1;
			}
		}
		return left;
	}

	@:hxmc.kernel static function codes(s:Span<ZipState>, inp:ReadOnlySpan<UInt8>, out:Span<UInt8>, lencode:ReadOnlySpan<Int>, distcode:ReadOnlySpan<Int>) {
		while (true) {
			var symbol = decode(s, inp, lencode);
			if (err(s)) return;
			if (symbol < 256) {
				var outpos = s[0].outpos;
				if (outpos >= out.length) {
					fail(s);
					return;
				}
				out[outpos] = symbol;
				s[0].outpos = outpos + 1;
			} else if (symbol == 256) {
				return;
			} else {
				symbol -= 257;
				if (symbol >= 29) {
					fail(s);
					return;
				}
				var len = lbase(symbol) + bits(s, inp, lext(symbol) - 1);
				symbol = decode(s, inp, distcode);
				if (err(s)) return;
				if (symbol < 0 || symbol >= 30) {
					fail(s);
					return;
				}
				var dist = dbase(symbol) + bits(s, inp, dext(symbol) - 1);
				var outpos = s[0].outpos;
				if (err(s) || dist > outpos || len > out.length - outpos) {
					fail(s);
					return;
				}
				// (overlapping copies repeat the pattern: a byte at a time)
				var q = outpos - dist;
				for (i in 0...len)
					out[outpos + i] = out[q + i];
				s[0].outpos = outpos + len;
			}
		}
	}

	@:hxmc.kernel static function stored(s:Span<ZipState>, inp:ReadOnlySpan<UInt8>, out:Span<UInt8>) {
		s[0].bitbuf = 0; // skip to the next byte boundary
		s[0].bitcnt = 0;
		var inpos = s[0].inpos, inlen = inp.length;
		if (inpos < 0 || inlen - inpos < 4) {
			fail(s);
			return;
		}
		var b0:Int = inp[inpos], b1:Int = inp[inpos + 1], b2:Int = inp[inpos + 2], b3:Int = inp[inpos + 3];
		var len = b0 | (b1 << 8);
		if (b2 != (~b0 & 0xFF) || b3 != (~b1 & 0xFF)) {
			fail(s);
			return;
		}
		inpos += 4;
		var outpos = s[0].outpos;
		if (len > inlen - inpos || len > out.length - outpos) {
			fail(s);
			return;
		}
		out.blit(outpos, inp.sub(inpos, len), 0, len);
		s[0].inpos = inpos + len;
		s[0].outpos = outpos + len;
	}

	@:hxmc.kernel static function fixed(s:Span<ZipState>, inp:ReadOnlySpan<UInt8>, out:Span<UInt8>) {
		var lencode:Span<Int> = Span.stack(HUFF), distcode:Span<Int> = Span.stack(HUFF);
		var lengths:Span<Int> = Span.stack(320);
		for (sym in 0...288)
			lengths[sym] = sym < 144 ? 8 : sym < 256 ? 9 : sym < 280 ? 7 : 8;
		construct(lencode, lengths, 288);
		for (sym in 0...30)
			lengths[sym] = 5;
		construct(distcode, lengths, 30);
		codes(s, inp, out, lencode, distcode);
	}

	@:hxmc.kernel static function dynamicBlock(s:Span<ZipState>, inp:ReadOnlySpan<UInt8>, out:Span<UInt8>) {
		var lengths:Span<Int> = Span.stack(320);
		var lencode:Span<Int> = Span.stack(HUFF), distcode:Span<Int> = Span.stack(HUFF);
		var nlen = bits(s, inp, 5) + 257;
		var ndist = bits(s, inp, 5) + 1;
		var ncode = bits(s, inp, 4) + 4;
		if (err(s) || nlen > 286 || ndist > 30) {
			fail(s);
			return;
		}
		var index = 0;
		while (index < ncode) {
			lengths[order(index) - 1] = bits(s, inp, 3);
			index++;
		}
		while (index < 19) {
			lengths[order(index) - 1] = 0;
			index++;
		}
		if (err(s) || construct(lencode, lengths, 19) != 0) { // the code length code must be complete
			fail(s);
			return;
		}
		index = 0;
		while (index < nlen + ndist) {
			var symbol = decode(s, inp, lencode);
			if (err(s)) return;
			if (symbol < 16) {
				lengths[index++] = symbol;
			} else {
				var len = 0;
				if (symbol == 16) {
					if (index == 0) {
						fail(s);
						return;
					}
					len = lengths[index - 1];
					symbol = 3 + bits(s, inp, 2);
				} else if (symbol == 17) {
					symbol = 3 + bits(s, inp, 3);
				} else {
					symbol = 11 + bits(s, inp, 7);
				}
				if (err(s) || index + symbol > nlen + ndist) {
					fail(s);
					return;
				}
				while (symbol-- > 0)
					lengths[index++] = len;
			}
		}
		if (lengths[256] == 0) { // no end-of-block code
			fail(s);
			return;
		}
		// an incomplete code is only allowed for a single length
		var left = construct(lencode, lengths, nlen);
		if (left < 0 || (left > 0 && nlen - lencode[0] != 1)) {
			fail(s);
			return;
		}
		left = construct(distcode, lengths.sub(nlen, ndist), ndist);
		if (left < 0 || (left > 0 && ndist - distcode[0] != 1)) {
			fail(s);
			return;
		}
		codes(s, inp, out, lencode, distcode);
	}

	// inflates the raw DEFLATE stream in src[srcPos, srcPos + srcLen) into
	// dst[dstPos, dstPos + dstLen): the number of bytes written, or -1 when the
	// stream is invalid, truncated or does not fit
	public static function inflateRaw(src:haxe.io.Bytes, srcPos:Int, srcLen:Int, dst:haxe.io.Bytes, dstPos:Int, dstLen:Int):Int {
		if (srcPos < 0 || srcLen < 0 || srcPos > src.length - srcLen || dstPos < 0 || dstLen < 0 || dstPos > dst.length - dstLen)
			outside();
		return inflate(ReadOnlySpan.ofBytes(src, srcPos, srcLen), Span.ofBytes(dst, dstPos, dstLen));
	}

	// the raw DEFLATE stream inp inflated into out (inflateRaw's result)
	@:hxmc.kernel static function inflate(inp:ReadOnlySpan<UInt8>, out:Span<UInt8>):Int {
		var s:Span<ZipState> = Span.stack(1);
		var last = 0;
		do {
			last = bits(s, inp, 1);
			var type = bits(s, inp, 2);
			if (err(s)) return -1;
			if (type == 0) stored(s, inp, out) else if (type == 1) fixed(s, inp, out) else if (type == 2) dynamicBlock(s, inp, out) else return -1;
			if (err(s)) return -1;
		} while (last == 0);
		return s[0].outpos;
	}

	// the CRC-32 table of the reflected polynomial 0xEDB88320 (zlib's
	// crc32), computed once outside the heap (two threads computing it
	// write the same values)
	static var crcTable:Ptr;

	@:hxmc.unsafe static function table():Ptr {
		var t = crcTable;
		if (!t.isNull()) return t;
		t = LibC.malloc(1024);
		for (n in 0...256) {
			var c = n;
			for (k in 0...8)
				c = (c & 1) != 0 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
			Mem.setI32At(t, 0, n, c);
		}
		crcTable = t;
		return t;
	}

	// the CRC-32 (ISO-HDLC, as zlib's crc32) of b[pos, pos + len): the
	// range checked here (OutsideBounds), the bytes lent to the kernel
	// for its call, and the table, which lives for good
	public static function crc32(b:haxe.io.Bytes, pos:Int, len:Int):Int
		return crcOf(ReadOnlySpan.ofBytes(b, pos, len), ReadOnlySpan.unsafeOf((table() : Ptr<Int>), 256));

	// (in the safe subset of kernels: docs/interop.md, "Spans"; the loop
	// proves both element checks away, the table's index by the test of
	// its length, which never fails)
	@:hxmc.kernel static function crcOf(s:ReadOnlySpan<UInt8>, t:ReadOnlySpan<Int>):Int {
		if (t.length < 256) return 0;
		var c = 0xFFFFFFFF;
		for (i in 0...s.length)
			c = t[(c ^ s[i]) & 0xFF] ^ (c >>> 8);
		return c ^ 0xFFFFFFFF;
	}

	static function outside()
		throw haxe.io.Error.OutsideBounds;
}

// the inflater's state, in place in a span of one
@:hxmc.struct @:publicFields private class ZipState {
	var inpos:Int;
	var outpos:Int;
	var bitbuf:Int;
	var bitcnt:Int;
	var err:Int;

	function new() {}
}

// RFC 1951's tables (values + 1 for the extra bits), the program's read-only
// data as spans for the inflater: a view
@:hxmc.kernel @:hxmc.unsafe private class ZipTab {
	public static function lbase():ReadOnlySpan<I64>
		return ReadOnlySpan.unsafeOf((cast Mem.words("0000000000000003000000000000000400000000000000050000000000000006000000000000000700000000000000080000000000000009000000000000000a000000000000000b000000000000000d000000000000000f000000000000001100000000000000130000000000000017000000000000001b000000000000001f0000000000000023000000000000002b0000000000000033000000000000003b0000000000000043000000000000005300000000000000630000000000000073000000000000008300000000000000a300000000000000c300000000000000e30000000000000102", 16) : Ptr<I64>), 29);

	public static function lext():ReadOnlySpan<I64>
		return ReadOnlySpan.unsafeOf((cast Mem.words("00000000000000010000000000000001000000000000000100000000000000010000000000000001000000000000000100000000000000010000000000000001000000000000000200000000000000020000000000000002000000000000000200000000000000030000000000000003000000000000000300000000000000030000000000000004000000000000000400000000000000040000000000000004000000000000000500000000000000050000000000000005000000000000000500000000000000060000000000000006000000000000000600000000000000060000000000000001", 16) : Ptr<I64>), 29);

	public static function dbase():ReadOnlySpan<I64>
		return ReadOnlySpan.unsafeOf((cast Mem.words("0000000000000001000000000000000200000000000000030000000000000004000000000000000500000000000000070000000000000009000000000000000d000000000000001100000000000000190000000000000021000000000000003100000000000000410000000000000061000000000000008100000000000000c100000000000001010000000000000181000000000000020100000000000003010000000000000401000000000000060100000000000008010000000000000c01000000000000100100000000000018010000000000002001000000000000300100000000000040010000000000006001", 16) : Ptr<I64>), 30);

	public static function dext():ReadOnlySpan<I64>
		return ReadOnlySpan.unsafeOf((cast Mem.words("00000000000000010000000000000001000000000000000100000000000000010000000000000002000000000000000200000000000000030000000000000003000000000000000400000000000000040000000000000005000000000000000500000000000000060000000000000006000000000000000700000000000000070000000000000008000000000000000800000000000000090000000000000009000000000000000a000000000000000a000000000000000b000000000000000b000000000000000c000000000000000c000000000000000d000000000000000d000000000000000e000000000000000e", 16) : Ptr<I64>), 30);

	public static function order():ReadOnlySpan<I64>
		return ReadOnlySpan.unsafeOf((cast Mem.words("000000000000001100000000000000120000000000000013000000000000000100000000000000090000000000000008000000000000000a0000000000000007000000000000000b0000000000000006000000000000000c0000000000000005000000000000000d0000000000000004000000000000000e0000000000000003000000000000000f00000000000000020000000000000010", 16) : Ptr<I64>), 19);
}
