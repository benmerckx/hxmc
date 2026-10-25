package hxmc;

import hxmc.rt.Repr;
import hxmc.scoped.Fixed;
import hxmc.scoped.Ref;
import hxmc.scoped.Scope;
import hxmc.scoped.Slice;
import hxmc.scoped.Str;
import hxmc.unsafe.UInt8;

// DEFLATE (RFC 1951) decompression and CRC-32, for programs that inflate
// whole buffers (the compiler's ZIP reader): haxe.zip.InflateImpl and
// haxe.crypto.Crc32 are several times slower. A canonical-Huffman decoder
// of streams held whole in memory, scoped code over views of the Bytes
// (docs/plans/lowlevel.md, "One core, two faces": the same code on WasmGC,
// over the engine's arrays). Errors (invalid codes, the input running out,
// the output overflowing) set the state's error flag, which every loop
// checks.
class NativeZip {
	// inflates the raw DEFLATE stream in src[srcPos, srcPos + srcLen) into
	// dst[dstPos, dstPos + dstLen): the number of bytes written, or -1 when the
	// stream is invalid, truncated or does not fit
	public static function inflateRaw(src:haxe.io.Bytes, srcPos:Int, srcLen:Int, dst:haxe.io.Bytes, dstPos:Int, dstLen:Int):Int {
		if (srcPos < 0 || srcLen < 0 || srcPos + srcLen > src.length || dstPos < 0 || dstLen < 0 || dstPos + dstLen > dst.length)
			outside();
		// (views of the Bytes: nothing collects while the core runs)
		return Inflate.run(view(src).sub(srcPos, srcLen), view(dst).sub(dstPos, dstLen));
	}

	// the CRC-32 (ISO-HDLC, as zlib's crc32) of b[pos, pos + len)
	public static function crc32(b:haxe.io.Bytes, pos:Int, len:Int):Int {
		if (pos < 0 || len < 0 || pos + len > b.length) outside();
		return Inflate.crc32(view(b).sub(pos, len));
	}

	static inline function view(b:haxe.io.Bytes):Slice<UInt8>
		return Repr.byteView(Repr.octets(b.getData()), b.length);

	static function outside()
		throw haxe.io.Error.OutsideBounds;
}

// the decoder's state
@:hxmc.scoped class InflateState {
	public var inp:Slice<UInt8>;
	public var inpos:Int;
	public var out:Slice<UInt8>;
	public var outpos:Int;
	public var bitbuf:Int;
	public var bitcnt:Int;
	public var err:Bool;
}

// A Huffman code: count[16] (codes per length), then symbol[288]
@:hxmc.scoped class Inflate {
	// the tables of RFC 1951 3.2.5 (values + 1 for the extra bits and the
	// code length order: no NUL in a literal)
	static inline var LBASE = "\u0003\u0004\u0005\u0006\u0007\u0008\u0009\u000a\u000b\u000d\u000f\u0011\u0013\u0017\u001b\u001f#+3;CScs\u0083£ÃãĂ";
	static inline var LEXT = "\u0001\u0001\u0001\u0001\u0001\u0001\u0001\u0001\u0002\u0002\u0002\u0002\u0003\u0003\u0003\u0003\u0004\u0004\u0004\u0004\u0005\u0005\u0005\u0005\u0006\u0006\u0006\u0006\u0001";
	static inline var DBASE = "\u0001\u0002\u0003\u0004\u0005\u0007\u0009\u000d\u0011\u0019!1Aa\u0081ÁāƁȁ́Ё؁ࠁఁခ᠁ 、䀁态";
	static inline var DEXT = "\u0001\u0001\u0001\u0001\u0002\u0002\u0003\u0003\u0004\u0004\u0005\u0005\u0006\u0006\u0007\u0007\u0008\u0008\u0009\u0009\u000a\u000a\u000b\u000b\u000c\u000c\u000d\u000d\u000e\u000e";
	static inline var ORDER = "\u0011\u0012\u0013\u0001\u0009\u0008\u000a\u0007\u000b\u0006\u000c\u0005\u000d\u0004\u000e\u0003\u000f\u0002\u0010";

	// the raw DEFLATE stream inp inflated into out: the bytes written, or -1
	public static function run(inp:Slice<UInt8>, out:Slice<UInt8>):Int {
		var states:Slice<InflateState> = Scope.slice(1);
		var s = states.ref(0);
		s.value.inp = inp;
		s.value.inpos = 0;
		s.value.out = out;
		s.value.outpos = 0;
		s.value.bitbuf = 0;
		s.value.bitcnt = 0;
		s.value.err = false;
		var last = 0;
		do {
			last = bits(s, 1);
			var type = bits(s, 2);
			if (s.value.err) return -1;
			if (type == 0) stored(s) else if (type == 1) fixed(s) else if (type == 2) dynamicBlock(s) else return -1;
			if (s.value.err) return -1;
		} while (last == 0);
		return s.value.outpos;
	}

	static function bits(s:Ref<InflateState>, need:Int):Int {
		var val = s.value.bitbuf;
		var cnt = s.value.bitcnt;
		while (cnt < need) {
			var pos = s.value.inpos;
			if (pos == s.value.inp.length) {
				s.value.err = true;
				return 0;
			}
			val |= s.value.inp[pos] << cnt;
			s.value.inpos = pos + 1;
			cnt += 8;
		}
		s.value.bitbuf = val >>> need;
		s.value.bitcnt = cnt - need;
		return val & ((1 << need) - 1);
	}

	// (bit by bit, in locals: the state written back once a code matches)
	static function decode(s:Ref<InflateState>, h:Slice<Int>):Int {
		var inp = s.value.inp, pos = s.value.inpos;
		var buf = s.value.bitbuf, cnt = s.value.bitcnt;
		var code = 0, first = 0, index = 0;
		for (len in 1...16) {
			if (cnt == 0) {
				if (pos == inp.length) break;
				buf = inp[pos++];
				cnt = 8;
			}
			code |= buf & 1;
			buf >>>= 1;
			cnt--;
			var count = h[len];
			if (code - count < first) {
				s.value.inpos = pos;
				s.value.bitbuf = buf;
				s.value.bitcnt = cnt;
				return h[16 + index + (code - first)];
			}
			index += count;
			first += count;
			first <<= 1;
			code <<= 1;
		}
		s.value.err = true; // the input ran out, or no code of 15 bits or less matches
		return -1;
	}

	// 0 for a complete code, > 0 for an incomplete one, < 0 for an oversubscribed one
	static function construct(h:Slice<Int>, length:Slice<Int>, n:Int):Int {
		var offs = new Fixed<Int, 16>();
		for (len in 0...16)
			h[len] = 0;
		for (sym in 0...n)
			h[length[sym]]++;
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

	// a block's codes, the stream's state in locals (written back at its end)
	static function codes(s:Ref<InflateState>, lencode:Slice<Int>, distcode:Slice<Int>) {
		var lbase:Str = LBASE, lext:Str = LEXT, dbase:Str = DBASE, dext:Str = DEXT;
		var inp = s.value.inp, pos = s.value.inpos, buf = s.value.bitbuf, cnt = s.value.bitcnt;
		var out = s.value.out, outpos = s.value.outpos;
		var err = false, done = false;
		// n more bits (n <= 13)
		inline function need(n:Int):Int {
			while (cnt < n && pos < inp.length) {
				buf |= inp[pos++] << cnt;
				cnt += 8;
			}
			var v = 0;
			if (cnt < n) err = true else {
				v = buf & ((1 << n) - 1);
				buf >>>= n;
				cnt -= n;
			}
			return v;
		}
		// a symbol of the code h (decode's)
		inline function symbolOf(h:Slice<Int>):Int {
			var code = 0, first = 0, index = 0, r = -1, len = 1;
			while (r < 0 && len < 16 && !err) {
				if (cnt == 0) {
					if (pos == inp.length) err = true else {
						buf = inp[pos++];
						cnt = 8;
					}
				}
				if (!err) {
					code |= buf & 1;
					buf >>>= 1;
					cnt--;
					var count = h[len];
					if (code - count < first) r = h[16 + index + (code - first)] else {
						index += count;
						first += count;
						first <<= 1;
						code <<= 1;
						len++;
					}
				}
			}
			if (r < 0) err = true;
			return r;
		}
		while (!err && !done) {
			var symbol = symbolOf(lencode);
			if (err) break;
			if (symbol < 256) {
				if (outpos == out.length) err = true else out[outpos++] = symbol;
			} else if (symbol == 256) {
				done = true;
			} else {
				symbol -= 257;
				if (symbol >= 29) {
					err = true;
					break;
				}
				var len = lbase[symbol] + need(lext[symbol] - 1);
				symbol = symbolOf(distcode);
				if (err || symbol >= 30) {
					err = true;
					break;
				}
				var dist = dbase[symbol] + need(dext[symbol] - 1);
				if (err || dist > outpos || len > out.length - outpos) {
					err = true;
					break;
				}
				if (dist >= len) Slice.copyBytes(out, outpos, out, outpos - dist, len) else
					for (i in 0...len)
						out[outpos + i] = out[outpos - dist + i]; // overlapping copies repeat the pattern
				outpos += len;
			}
		}
		s.value.inpos = pos;
		s.value.bitbuf = buf;
		s.value.bitcnt = cnt;
		s.value.outpos = outpos;
		if (err) s.value.err = true;
	}

	static function stored(s:Ref<InflateState>) {
		s.value.bitbuf = 0; // skip to the next byte boundary
		s.value.bitcnt = 0;
		var inp = s.value.inp, inpos = s.value.inpos;
		if (inp.length - inpos < 4) {
			s.value.err = true;
			return;
		}
		var len = inp[inpos] | (inp[inpos + 1] << 8);
		if (inp[inpos + 2] != (~inp[inpos] & 0xFF) || inp[inpos + 3] != (~inp[inpos + 1] & 0xFF)) {
			s.value.err = true;
			return;
		}
		inpos += 4;
		var out = s.value.out, outpos = s.value.outpos;
		if (len > inp.length - inpos || len > out.length - outpos) {
			s.value.err = true;
			return;
		}
		Slice.copyBytes(out, outpos, inp, inpos, len);
		s.value.inpos = inpos + len;
		s.value.outpos = outpos + len;
	}

	static function fixed(s:Ref<InflateState>) {
		var lencode = new Fixed<Int, 304>(), distcode = new Fixed<Int, 304>();
		var lengths = new Fixed<Int, 320>();
		for (sym in 0...288)
			lengths[sym] = sym < 144 ? 8 : sym < 256 ? 9 : sym < 280 ? 7 : 8;
		construct(lencode.view(), lengths.view(), 288);
		for (sym in 0...30)
			lengths[sym] = 5;
		construct(distcode.view(), lengths.view(), 30);
		codes(s, lencode.view(), distcode.view());
	}

	static function dynamicBlock(s:Ref<InflateState>) {
		var lengths = new Fixed<Int, 320>();
		var lencode = new Fixed<Int, 304>(), distcode = new Fixed<Int, 304>();
		var order:Str = ORDER;
		var nlen = bits(s, 5) + 257;
		var ndist = bits(s, 5) + 1;
		var ncode = bits(s, 4) + 4;
		if (s.value.err || nlen > 286 || ndist > 30) {
			s.value.err = true;
			return;
		}
		var index = 0;
		while (index < ncode) {
			lengths[order[index] - 1] = bits(s, 3);
			index++;
		}
		while (index < 19) {
			lengths[order[index] - 1] = 0;
			index++;
		}
		if (s.value.err || construct(lencode.view(), lengths.view(), 19) != 0) { // the code length code must be complete
			s.value.err = true;
			return;
		}
		index = 0;
		while (index < nlen + ndist) {
			var symbol = decode(s, lencode.view());
			if (s.value.err) return;
			if (symbol < 16) {
				lengths[index++] = symbol;
			} else {
				var len = 0;
				if (symbol == 16) {
					if (index == 0) {
						s.value.err = true;
						return;
					}
					len = lengths[index - 1];
					symbol = 3 + bits(s, 2);
				} else if (symbol == 17) {
					symbol = 3 + bits(s, 3);
				} else {
					symbol = 11 + bits(s, 7);
				}
				if (s.value.err || index + symbol > nlen + ndist) {
					s.value.err = true;
					return;
				}
				while (symbol-- > 0)
					lengths[index++] = len;
			}
		}
		if (lengths[256] == 0) { // no end-of-block code
			s.value.err = true;
			return;
		}
		// an incomplete code is only allowed for a single length
		var left = construct(lencode.view(), lengths.view(), nlen);
		if (left < 0 || (left > 0 && nlen - lencode[0] != 1)) {
			s.value.err = true;
			return;
		}
		left = construct(distcode.view(), lengths.view().sub(nlen, 320 - nlen), ndist);
		if (left < 0 || (left > 0 && ndist - distcode[0] != 1)) {
			s.value.err = true;
			return;
		}
		codes(s, lencode.view(), distcode.view());
	}

	// the CRC-32 of b (zlib's crc32: the reflected polynomial 0xEDB88320)
	public static function crc32(b:Slice<UInt8>):Int {
		var t = new Fixed<Int, 256>();
		for (n in 0...256) {
			var c = n;
			for (k in 0...8)
				c = (c & 1) != 0 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
			t[n] = c;
		}
		var c = 0xFFFFFFFF;
		for (i in 0...b.length)
			c = t[(c ^ b[i]) & 0xFF] ^ (c >>> 8);
		return c ^ 0xFFFFFFFF;
	}
}
