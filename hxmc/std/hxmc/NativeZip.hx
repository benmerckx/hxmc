package hxmc;

import hxmc.I64;
import hxmc.rt.Bytes;
import hxmc.rt.C;
import hxmc.rt.Repr;
import hxmc.unsafe.BytesPtr;
import hxmc.unsafe.LibC;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Ptr;

// DEFLATE (RFC 1951) decompression and CRC-32 over raw memory, for programs
// that inflate whole buffers (the compiler's ZIP reader): haxe.zip.InflateImpl
// and haxe.crypto.Crc32 are several times slower. A canonical-Huffman
// decoder of streams held whole in memory, over raw addresses (nothing
// allocates while it runs, so the buffers stay in place). Errors (invalid
// codes, the input running out, the output overflowing) set the state's
// error flag, which every loop checks.
class NativeZip {
	// the decoder's state (a frame area): in, inlen, inpos, out, outlen,
	// outpos (8 bytes each), bitbuf, bitcnt, err (4 bytes each)
	static inline var IN = 0;
	static inline var INLEN = 8;
	static inline var INPOS = 16;
	static inline var OUT = 24;
	static inline var OUTLEN = 32;
	static inline var OUTPOS = 40;
	static inline var BITBUF = 48;
	static inline var BITCNT = 52;
	static inline var ERR = 56;
	// a Huffman code: count[16] then symbol[288] (16-bit)
	static inline var HUFF = 608;

	// the tables of RFC 1951 3.2.5 (values + 1 for the extra bits and the
	// code length order: no NUL in a literal)
	static inline var LBASE = "\u0003\u0004\u0005\u0006\u0007\u0008\u0009\u000a\u000b\u000d\u000f\u0011\u0013\u0017\u001b\u001f#+3;CScs\u0083£ÃãĂ";
	static inline var LEXT = "\u0001\u0001\u0001\u0001\u0001\u0001\u0001\u0001\u0002\u0002\u0002\u0002\u0003\u0003\u0003\u0003\u0004\u0004\u0004\u0004\u0005\u0005\u0005\u0005\u0006\u0006\u0006\u0006\u0001";
	static inline var DBASE = "\u0001\u0002\u0003\u0004\u0005\u0007\u0009\u000d\u0011\u0019!1Aa\u0081ÁāƁȁ́Ё؁ࠁఁခ᠁ 、䀁态";
	static inline var DEXT = "\u0001\u0001\u0001\u0001\u0002\u0002\u0003\u0003\u0004\u0004\u0005\u0005\u0006\u0006\u0007\u0007\u0008\u0008\u0009\u0009\u000a\u000a\u000b\u000b\u000c\u000c\u000d\u000d\u000e\u000e";
	static inline var ORDER = "\u0011\u0012\u0013\u0001\u0009\u0008\u000a\u0007\u000b\u0006\u000c\u0005\u000d\u0004\u000e\u0003\u000f\u0002\u0010";

	static inline function tab(t:String, i:Int):Int
		return Repr.unit(t, i);

	static inline function err(s:Ptr):Bool
		return Mem.getI32(s, ERR) != 0;

	static inline function fail(s:Ptr)
		Mem.setI32(s, ERR, 1);

	@:hxmc.noGc static function bits(s:Ptr, need:Int):Int {
		var val:I64 = Mem.getI32(s, BITBUF);
		val = val & (((1 : I64) << 32) - 1);
		var cnt = Mem.getI32(s, BITCNT);
		while (cnt < need) {
			var pos = Mem.getI64(s, INPOS);
			if (pos == Mem.getI64(s, INLEN)) {
				fail(s);
				return 0;
			}
			val = val | ((Mem.getU8(Mem.getPtr(s, IN).addL(pos), 0) : I64) << cnt);
			Mem.setI64(s, INPOS, pos + 1);
			cnt += 8;
		}
		Mem.setI32(s, BITBUF, (val >>> need).toInt());
		Mem.setI32(s, BITCNT, cnt - need);
		return (val & (((1 : I64) << need) - 1)).toInt();
	}

	@:hxmc.noGc static function decode(s:Ptr, h:Ptr):Int {
		var code = 0, first = 0, index = 0;
		for (len in 1...16) {
			code |= bits(s, 1);
			if (err(s)) return -1;
			var count = Mem.getI16(h, 2 * len);
			if (code - count < first) return Mem.getI16(h, 32 + 2 * (index + (code - first)));
			index += count;
			first += count;
			first <<= 1;
			code <<= 1;
		}
		fail(s); // no code of 15 bits or less matches
		return -1;
	}

	// 0 for a complete code, > 0 for an incomplete one, < 0 for an oversubscribed one
	@:hxmc.noGc static function construct(h:Ptr, length:Ptr, n:Int):Int {
		var offs = Mem.stack(32);
		for (len in 0...16)
			Mem.setI16(h, 2 * len, 0);
		for (sym in 0...n) {
			var l = Mem.getI16(length, 2 * sym);
			Mem.setI16(h, 2 * l, Mem.getI16(h, 2 * l) + 1);
		}
		if (Mem.getI16(h, 0) == n) return 0;
		var left = 1;
		for (len in 1...16) {
			left <<= 1;
			left -= Mem.getI16(h, 2 * len);
			if (left < 0) return left;
		}
		Mem.setI16(offs, 2, 0);
		for (len in 1...15)
			Mem.setI16(offs, 2 * (len + 1), Mem.getI16(offs, 2 * len) + Mem.getI16(h, 2 * len));
		for (sym in 0...n) {
			var l = Mem.getI16(length, 2 * sym);
			if (l != 0) {
				var o = Mem.getI16(offs, 2 * l);
				Mem.setI16(h, 32 + 2 * o, sym);
				Mem.setI16(offs, 2 * l, o + 1);
			}
		}
		return left;
	}

	@:hxmc.noGc static function codes(s:Ptr, lencode:Ptr, distcode:Ptr) {
		while (true) {
			var symbol = decode(s, lencode);
			if (err(s)) return;
			if (symbol < 256) {
				var outpos = Mem.getI64(s, OUTPOS);
				if (outpos == Mem.getI64(s, OUTLEN)) {
					fail(s);
					return;
				}
				Mem.setI8(Mem.getPtr(s, OUT).addL(outpos), 0, symbol);
				Mem.setI64(s, OUTPOS, outpos + 1);
			} else if (symbol == 256) {
				return;
			} else {
				symbol -= 257;
				if (symbol >= 29) {
					fail(s);
					return;
				}
				var len = tab(LBASE, symbol) + bits(s, tab(LEXT, symbol) - 1);
				symbol = decode(s, distcode);
				if (err(s)) return;
				if (symbol < 0 || symbol >= 30) {
					fail(s);
					return;
				}
				var dist = tab(DBASE, symbol) + bits(s, tab(DEXT, symbol) - 1);
				var outpos = Mem.getI64(s, OUTPOS);
				if (err(s) || (dist : I64) > outpos || (len : I64) > Mem.getI64(s, OUTLEN) - outpos) {
					fail(s);
					return;
				}
				var p = Mem.getPtr(s, OUT).addL(outpos);
				var q = p.add(-dist);
				for (i in 0...len)
					Mem.setU8At(p, 0, i, Mem.getU8At(q, 0, i)); // overlapping copies repeat the pattern
				Mem.setI64(s, OUTPOS, outpos + len);
			}
		}
	}

	@:hxmc.noGc static function stored(s:Ptr) {
		Mem.setI32(s, BITBUF, 0); // skip to the next byte boundary
		Mem.setI32(s, BITCNT, 0);
		var inpos = Mem.getI64(s, INPOS), inlen = Mem.getI64(s, INLEN);
		if (inlen - inpos < 4) {
			fail(s);
			return;
		}
		var p = Mem.getPtr(s, IN).addL(inpos);
		var len = Mem.getU8(p, 0) | (Mem.getU8(p, 1) << 8);
		if (Mem.getU8(p, 2) != (~Mem.getU8(p, 0) & 0xFF) || Mem.getU8(p, 3) != (~Mem.getU8(p, 1) & 0xFF)) {
			fail(s);
			return;
		}
		inpos += 4;
		var outpos = Mem.getI64(s, OUTPOS);
		if ((len : I64) > inlen - inpos || (len : I64) > Mem.getI64(s, OUTLEN) - outpos) {
			fail(s);
			return;
		}
		LibC.memcpy(Mem.getPtr(s, OUT).addL(outpos), Mem.getPtr(s, IN).addL(inpos), len);
		Mem.setI64(s, INPOS, inpos + len);
		Mem.setI64(s, OUTPOS, outpos + len);
	}

	@:hxmc.noGc static function fixed(s:Ptr) {
		var lencode = Mem.stack(HUFF), distcode = Mem.stack(HUFF);
		var lengths = Mem.stack(640);
		for (sym in 0...288)
			Mem.setI16(lengths, 2 * sym, sym < 144 ? 8 : sym < 256 ? 9 : sym < 280 ? 7 : 8);
		construct(lencode, lengths, 288);
		for (sym in 0...30)
			Mem.setI16(lengths, 2 * sym, 5);
		construct(distcode, lengths, 30);
		codes(s, lencode, distcode);
	}

	@:hxmc.noGc static function dynamicBlock(s:Ptr) {
		var lengths = Mem.stack(640);
		var lencode = Mem.stack(HUFF), distcode = Mem.stack(HUFF);
		var nlen = bits(s, 5) + 257;
		var ndist = bits(s, 5) + 1;
		var ncode = bits(s, 4) + 4;
		if (err(s) || nlen > 286 || ndist > 30) {
			fail(s);
			return;
		}
		var index = 0;
		while (index < ncode) {
			Mem.setI16(lengths, 2 * (tab(ORDER, index) - 1), bits(s, 3));
			index++;
		}
		while (index < 19) {
			Mem.setI16(lengths, 2 * (tab(ORDER, index) - 1), 0);
			index++;
		}
		if (err(s) || construct(lencode, lengths, 19) != 0) { // the code length code must be complete
			fail(s);
			return;
		}
		index = 0;
		while (index < nlen + ndist) {
			var symbol = decode(s, lencode);
			if (err(s)) return;
			if (symbol < 16) {
				Mem.setI16(lengths, 2 * index++, symbol);
			} else {
				var len = 0;
				if (symbol == 16) {
					if (index == 0) {
						fail(s);
						return;
					}
					len = Mem.getI16(lengths, 2 * (index - 1));
					symbol = 3 + bits(s, 2);
				} else if (symbol == 17) {
					symbol = 3 + bits(s, 3);
				} else {
					symbol = 11 + bits(s, 7);
				}
				if (err(s) || index + symbol > nlen + ndist) {
					fail(s);
					return;
				}
				while (symbol-- > 0)
					Mem.setI16(lengths, 2 * index++, len);
			}
		}
		if (Mem.getI16(lengths, 2 * 256) == 0) { // no end-of-block code
			fail(s);
			return;
		}
		// an incomplete code is only allowed for a single length
		var left = construct(lencode, lengths, nlen);
		if (left < 0 || (left > 0 && nlen - Mem.getI16(lencode, 0) != 1)) {
			fail(s);
			return;
		}
		left = construct(distcode, lengths.add(2 * nlen), ndist);
		if (left < 0 || (left > 0 && ndist - Mem.getI16(distcode, 0) != 1)) {
			fail(s);
			return;
		}
		codes(s, lencode, distcode);
	}

	// inflates the raw DEFLATE stream in src[srcPos, srcPos + srcLen) into
	// dst[dstPos, dstPos + dstLen): the number of bytes written, or -1 when the
	// stream is invalid, truncated or does not fit
	public static function inflateRaw(src:haxe.io.Bytes, srcPos:Int, srcLen:Int, dst:haxe.io.Bytes, dstPos:Int, dstLen:Int):Int {
		if (srcPos < 0 || srcLen < 0 || srcPos + srcLen > Bytes.len(src) || dstPos < 0 || dstLen < 0 || dstPos + dstLen > Bytes.len(dst))
			outside();
		#if (hxmc.wasm_gc)
		// (-D hxmc.wasm-gc: a Bytes is the collector's, without an address: the
		// stream inflated from a copy in the module's linear memory into a buffer
		// there, copied out)
		var out = LibC.malloc(dstLen > 0 ? dstLen : 1);
		var n = inflate(BytesPtr.of(src, srcPos, srcLen), srcLen, out, dstLen);
		if (n > 0) BytesPtr.copyIn(dst, dstPos, out, n);
		LibC.free(out);
		return n;
		#else
		// (no GC point from here: the buffers' addresses stay valid)
		return inflate(Bytes.bytes(src).add(srcPos), srcLen, Bytes.bytes(dst).add(dstPos), dstLen);
		#end
	}

	// the raw DEFLATE stream of inLen bytes at inp inflated into the outLen
	// bytes at out (inflateRaw's result)
	@:hxmc.noGc static function inflate(inp:Ptr, inLen:Int, out:Ptr, outLen:Int):Int {
		var s = Mem.stack(64);
		Mem.setPtr(s, IN, inp);
		Mem.setI64(s, INLEN, inLen);
		Mem.setI64(s, INPOS, 0);
		Mem.setPtr(s, OUT, out);
		Mem.setI64(s, OUTLEN, outLen);
		Mem.setI64(s, OUTPOS, 0);
		Mem.setI32(s, BITBUF, 0);
		Mem.setI32(s, BITCNT, 0);
		Mem.setI32(s, ERR, 0);
		var last = 0;
		do {
			last = bits(s, 1);
			var type = bits(s, 2);
			if (err(s)) return -1;
			if (type == 0) stored(s) else if (type == 1) fixed(s) else if (type == 2) dynamicBlock(s) else return -1;
			if (err(s)) return -1;
		} while (last == 0);
		return Mem.getI64(s, OUTPOS).toInt();
	}

	// the CRC-32 table of the reflected polynomial 0xEDB88320 (zlib's
	// crc32), computed once outside the heap (two threads computing it
	// write the same values)
	static var crcTable:Ptr;

	@:hxmc.noGc static function table():Ptr {
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

	// the CRC-32 (ISO-HDLC, as zlib's crc32) of b[pos, pos + len)
	public static function crc32(b:haxe.io.Bytes, pos:Int, len:Int):Int {
		if (pos < 0 || len < 0 || pos + len > Bytes.len(b)) outside();
		var t = table();
		// (-D hxmc.wasm-gc: a copy in the module's linear memory, as inflateRaw)
		var p = #if (hxmc.wasm_gc) BytesPtr.of(b, pos, len) #else Bytes.bytes(b).add(pos) #end;
		var c = 0xFFFFFFFF;
		for (i in 0...len)
			c = Mem.getI32At(t, 0, (c ^ Mem.getU8At(p, 0, i)) & 0xFF) ^ (c >>> 8);
		return c ^ 0xFFFFFFFF;
	}

	static function outside()
		Rt.rt_throw("OutsideBounds");
}
