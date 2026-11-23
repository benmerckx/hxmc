/*
 * Copyright (C)2005-2019 Haxe Foundation
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 */

package haxe.zip;

// hxmc: haxe/upstream/std/haxe/zip/InflateImpl.hx, and from a BytesInput the
// whole stream inflated at once (Fast: a 32-bit bit buffer, prefix codes up
// to 10 bits by table, matches copied in place, the Adler-32 checked as the
// streaming code checks it), the input left just past the stream's last
// byte as the streaming code leaves it; other inputs, which a reader may go
// on reading, inflated byte by byte as upstream does.

import haxe.crypto.Adler32;
import haxe.ds.Vector;
import haxe.zip.Huffman;

private class Window {
	public static inline var SIZE = 1 << 15;
	public static inline var BUFSIZE = 1 << 16;

	public var buffer:haxe.io.Bytes;
	public var pos:Int;

	var crc:Adler32;

	public function new(hasCrc) {
		buffer = haxe.io.Bytes.alloc(BUFSIZE);
		pos = 0;
		if (hasCrc)
			crc = new Adler32();
	}

	public function slide() {
		if (crc != null)
			crc.update(buffer, 0, SIZE);
		var b = haxe.io.Bytes.alloc(BUFSIZE);
		pos -= SIZE;
		b.blit(0, buffer, SIZE, pos);
		buffer = b;
	}

	public function addBytes(b, p, len) {
		if (pos + len > BUFSIZE)
			slide();
		buffer.blit(pos, b, p, len);
		pos += len;
	}

	public function addByte(c) {
		if (pos == BUFSIZE)
			slide();
		buffer.set(pos, c);
		pos++;
	}

	public function getLastChar() {
		return buffer.get(pos - 1);
	}

	public function available() {
		return pos;
	}

	public function checksum() {
		if (crc != null)
			crc.update(buffer, 0, pos);
		return crc;
	}
}

private enum State {
	Head;
	Block;
	CData;
	Flat;
	Crc;
	Dist;
	DistOne;
	Done;
}

/**
	A pure Haxe implementation of the ZLIB Inflate algorithm which allows reading compressed data without any platform-specific support.
**/
class InflateImpl {
	static var LEN_EXTRA_BITS_TBL = [
		0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0, -1, -1
	];
	static var LEN_BASE_VAL_TBL = [
		3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258
	];
	static var DIST_EXTRA_BITS_TBL = [
		0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13, -1, -1
	];
	static var DIST_BASE_VAL_TBL = [
		1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577
	];
	static var CODE_LENGTHS_POS = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];

	var nbits:Int;
	var bits:Int;
	var state:State;
	var isFinal:Bool;
	var huffman:Huffman;
	var huffdist:Null<Huffman>;
	var htools:HuffTools;
	var len:Int;
	var dist:Int;
	var needed:Int;
	var output:haxe.io.Bytes;
	var outpos:Int;
	var input:haxe.io.Input;
	var lengths:Vector<Int>;
	var window:Window;
	// (hxmc: from a BytesInput: the whole output and how much of it was read)
	var header:Bool;
	var crc:Bool;
	var fast:Null<haxe.io.Bytes> = null;
	var fastPos = 0;

	static var FIXED_HUFFMAN:Null<Huffman> = null;

	public function new(i, header = true, crc = true) {
		isFinal = false;
		htools = new HuffTools();
		huffman = buildFixedHuffman();
		huffdist = null;
		len = 0;
		dist = 0;
		state = header ? Head : Block;
		input = i;
		bits = 0;
		nbits = 0;
		needed = 0;
		output = null;
		outpos = 0;
		lengths = new Vector(19, -1);
		window = new Window(crc);
		this.header = header;
		this.crc = crc;
	}

	function buildFixedHuffman() {
		if (FIXED_HUFFMAN != null)
			return FIXED_HUFFMAN;
		var a = new Vector(288);
		for (n in 0...288)
			a[n] = (if (n <= 143) 8 else if (n <= 255) 9 else if (n <= 279) 7 else 8);
		FIXED_HUFFMAN = htools.make(a, 0, 288, 10);
		return FIXED_HUFFMAN;
	}

	public function readBytes(b, pos, len) {
		// (hxmc: a BytesInput, untouched: inflated whole, then given out)
		if (fast == null && state == (header ? Head : Block) && outpos == 0 && nbits == 0 && Std.isOfType(input, haxe.io.BytesInput))
			fast = Fast.from(cast input, header, crc, len);
		if (fast != null) {
			var n = fast.length - fastPos < len ? fast.length - fastPos : len;
			if (n > 0) b.blit(pos, fast, fastPos, n);
			fastPos += n;
			state = Done;
			return n;
		}
		needed = len;
		outpos = pos;
		output = b;
		if (len > 0)
			while (inflateLoop()) {}
		return len - needed;
	}

	function getBits(n) {
		while (nbits < n) {
			bits |= input.readByte() << nbits;
			nbits += 8;
		}
		var b = bits & ((1 << n) - 1);
		nbits -= n;
		bits >>= n;
		return b;
	}

	function getBit() {
		if (nbits == 0) {
			nbits = 8;
			bits = input.readByte();
		}
		var b = bits & 1 == 1;
		nbits--;
		bits >>= 1;
		return b;
	}

	function getRevBits(n) {
		return if (n == 0)
			0
		else if (getBit())
			(1 << (n - 1)) | getRevBits(n - 1)
		else
			getRevBits(n - 1);
	}

	function resetBits() {
		bits = 0;
		nbits = 0;
	}

	function addBytes(b, p, len) {
		window.addBytes(b, p, len);
		output.blit(outpos, b, p, len);
		needed -= len;
		outpos += len;
	}

	function addByte(b) {
		window.addByte(b);
		output.set(outpos, b);
		needed--;
		outpos++;
	}

	function addDistOne(n) {
		var c = window.getLastChar();
		for (i in 0...n)
			addByte(c);
	}

	function addDist(d, len) {
		addBytes(window.buffer, window.pos - d, len);
	}

	function applyHuffman(h) {
		return switch (h) {
			case Found(n): n;
			case NeedBit(a, b): applyHuffman(getBit() ? b : a);
			case NeedBits(n, tbl): applyHuffman(tbl[getBits(n)]);
		}
	}

	function inflateLengths(a:Vector<Int>, max) {
		var i = 0;
		var prev = 0;
		while (i < max) {
			var n = applyHuffman(huffman);
			switch (n) {
				case 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15:
					prev = n;
					a[i] = n;
					i++;
				case 16:
					var end = i + 3 + getBits(2);
					if (end > max)
						throw "Invalid data";
					while (i < end) {
						a[i] = prev;
						i++;
					}
				case 17:
					i += 3 + getBits(3);
					if (i > max)
						throw "Invalid data";
				case 18:
					i += 11 + getBits(7);
					if (i > max)
						throw "Invalid data";
				default:
					throw "Invalid data";
			}
		}
	}

	function inflateLoop() {
		switch (state) {
			case Head:
				var cmf = input.readByte();
				var cm = cmf & 15;
				var cinfo = cmf >> 4;
				if (cm != 8)
					throw "Invalid data";
				var flg = input.readByte();
				// var fcheck = flg & 31;
				var fdict = flg & 32 != 0;
				// var flevel = flg >> 6;
				if (((cmf << 8) + flg) % 31 != 0)
					throw "Invalid data";
				if (fdict)
					throw "Unsupported dictionary";
				state = Block;
				return true;
			case Crc:
				var calc = window.checksum();
				if (calc == null) {
					state = Done;
					return true;
				}
				var crc = Adler32.read(input);
				if (!calc.equals(crc))
					throw "Invalid CRC";
				state = Done;
				return true;
			case Done:
				// nothing
				return false;
			case Block:
				isFinal = getBit();
				switch (getBits(2)) {
					case 0: // no compression
						len = input.readUInt16();
						var nlen = input.readUInt16();
						if (nlen != 0xFFFF - len) throw "Invalid data";
						state = Flat;
						var r = inflateLoop();
						resetBits();
						return r;
					case 1: // fixed Huffman
						huffman = buildFixedHuffman();
						huffdist = null;
						state = CData;
						return true;
					case 2: // dynamic Huffman
						var hlit = getBits(5) + 257;
						var hdist = getBits(5) + 1;
						var hclen = getBits(4) + 4;
						for (i in 0...hclen)
							lengths[CODE_LENGTHS_POS[i]] = getBits(3);
						for (i in hclen...19)
							lengths[CODE_LENGTHS_POS[i]] = 0;
						huffman = htools.make(lengths, 0, 19, 8);
						var lengths = new Vector(hlit + hdist, 0);
						inflateLengths(lengths, hlit + hdist);
						huffdist = htools.make(lengths, hlit, hdist, 16);
						huffman = htools.make(lengths, 0, hlit, 16);
						state = CData;
						return true;
					default:
						throw "Invalid data";
				}
			case Flat:
				var rlen = (len < needed) ? len : needed;
				var bytes = input.read(rlen);
				len -= rlen;
				addBytes(bytes, 0, rlen);
				if (len == 0)
					state = isFinal ? Crc : Block;
				return needed > 0;
			case DistOne:
				var rlen = (len < needed) ? len : needed;
				addDistOne(rlen);
				len -= rlen;
				if (len == 0)
					state = CData;
				return needed > 0;
			case Dist:
				while (len > 0 && needed > 0) {
					var rdist = (len < dist) ? len : dist;
					var rlen = (needed < rdist) ? needed : rdist;
					addDist(dist, rlen);
					len -= rlen;
				}
				if (len == 0)
					state = CData;
				return needed > 0;
			case CData:
				var n = applyHuffman(huffman);
				if (n < 256) {
					addByte(n);
					return needed > 0;
				} else if (n == 256) {
					state = isFinal ? Crc : Block;
					return true;
				} else {
					n -= 257;
					var extra_bits = LEN_EXTRA_BITS_TBL[n];
					if (extra_bits == -1)
						throw "Invalid data";
					len = LEN_BASE_VAL_TBL[n] + getBits(extra_bits);
					var dist_code = if (huffdist == null) getRevBits(5) else applyHuffman(huffdist);
					extra_bits = DIST_EXTRA_BITS_TBL[dist_code];
					if (extra_bits == -1)
						throw "Invalid data";
					dist = DIST_BASE_VAL_TBL[dist_code] + getBits(extra_bits);
					if (dist > window.available())
						throw "Invalid data";
					state = (dist == 1) ? DistOne : Dist;
					return true;
				}
		}
	}

	public static function run(i:haxe.io.Input, bufsize = 65536) {
		// (hxmc: a BytesInput: its output as it is, no copies)
		if (Std.isOfType(i, haxe.io.BytesInput)) return Fast.from(cast i, true, true, bufsize);
		var buf = haxe.io.Bytes.alloc(bufsize);
		var output = new haxe.io.BytesBuffer();
		var inflate = new InflateImpl(i);
		while (true) {
			var len = inflate.readBytes(buf, 0, bufsize);
			output.addBytes(buf, 0, len);
			if (len < bufsize)
				break;
		}
		return output.getBytes();
	}
}

// (hxmc) a zlib or raw deflate stream held whole in a BytesInput, inflated
// in one go: the bits from a 32-bit buffer, prefix codes up to FAST bits by
// table and longer ones from their canonical counts, matches copied in
// place; the output grown from the size the caller expects. The input then
// stands just past the stream (its checksum's last byte), the bytes the bit
// buffer read ahead given back. Errors as the streaming code's: "Invalid
// data", "Unsupported dictionary", "Invalid CRC"; Eof when the input ends
// before the stream does.
private class Fast {
	static inline var FAST = 10;
	static final LENGTH_BASE = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258];
	static final LENGTH_EXTRA = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0];
	static final DIST_BASE = [
		1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577
	];
	static final DIST_EXTRA = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13];
	static final ORDER = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];

	// the stream at the input's position: inflated, the input moved past it
	public static function from(i:haxe.io.BytesInput, header:Bool, crc:Bool, expected:Int):haxe.io.Bytes {
		var src = haxe.io.Bytes.ofData(@:privateAccess i.b), start:Int = @:privateAccess i.pos, end = start + @:privateAccess i.len;
		var f = new Fast(src, start, end, expected);
		var out = f.run(header, crc);
		@:privateAccess i.pos = f.p;
		@:privateAccess i.len = end - f.p;
		return out;
	}

	final src:haxe.io.Bytes;
	var p:Int;
	final end:Int;
	var buf = 0;
	var cnt = 0;
	var out:haxe.io.Bytes;
	var pos = 0;

	function new(src:haxe.io.Bytes, at:Int, end:Int, expected:Int) {
		this.src = src;
		this.p = at;
		this.end = end;
		out = haxe.io.Bytes.alloc(expected > 0 ? expected : 1024);
	}

	// (past the input's end, zeros: no more than its reading ahead, else
	// the stream was cut and garbage would decode on: Eof)
	inline function need(n:Int)
		while (cnt < n) {
			if (p < end) buf |= src.get(p) << cnt else if (p >= end + 4) throw new haxe.io.Eof();
			p++;
			cnt += 8;
		}

	inline function bits(n:Int):Int {
		need(n);
		var v = buf & ((1 << n) - 1);
		buf >>>= n;
		cnt -= n;
		return v;
	}

	// (the whole bytes the bit buffer holds unread: given back to the input)
	function giveBack() {
		p -= cnt >> 3;
		buf = cnt = 0;
	}

	// (a byte the stream must have: past the input's end, Eof)
	function byte():Int {
		if (p >= end) throw new haxe.io.Eof();
		return src.get(p++);
	}

	// (data that does not decode: Eof when it ran past the input, as the streaming code would have)
	function invalid():Dynamic {
		giveBack();
		if (p > end) throw new haxe.io.Eof();
		throw "Invalid data";
	}

	inline function room(n:Int)
		if (pos + n > out.length) {
			var size = out.length * 2;
			while (size < pos + n)
				size *= 2;
			var b = haxe.io.Bytes.alloc(size);
			b.blit(0, out, 0, pos);
			out = b;
		}

	function run(header:Bool, crc:Bool):haxe.io.Bytes {
		if (header) {
			var cmf = byte(), flg = byte();
			if (cmf & 15 != 8 || ((cmf << 8) + flg) % 31 != 0) throw "Invalid data";
			if (flg & 32 != 0) throw "Unsupported dictionary";
		}
		var last = false;
		while (!last) {
			last = bits(1) == 1;
			switch bits(2) {
				case 0:
					// (stored: from the next byte)
					giveBack();
					var len = byte() | (byte() << 8), nlen = byte() | (byte() << 8);
					if (nlen != 0xFFFF - len) throw "Invalid data";
					if (p + len > end) {
						p = end;
						throw new haxe.io.Eof();
					}
					room(len);
					out.blit(pos, src, p, len);
					pos += len;
					p += len;
				case 1:
					block(fixedLit, fixedDist);
				case 2:
					var hlit = bits(5) + 257, hdist = bits(5) + 1, hclen = bits(4) + 4;
					var cl = [for (i in 0...19) 0];
					for (i in 0...hclen)
						cl[ORDER[i]] = bits(3);
					var clCode = new FastHuffman(cl);
					var lengths = [for (i in 0...hlit + hdist) 0], i = 0;
					while (i < hlit + hdist) {
						var s = decode(clCode);
						if (s < 16) lengths[i++] = s else {
							var v = 0, r = 0;
							if (s == 16) {
								if (i == 0) invalid();
								v = lengths[i - 1];
								r = 3 + bits(2);
							} else r = s == 17 ? 3 + bits(3) : 11 + bits(7);
							if (i + r > hlit + hdist) invalid();
							for (k in 0...r)
								lengths[i++] = v;
						}
					}
					block(new FastHuffman(lengths.slice(0, hlit)), new FastHuffman(lengths.slice(hlit)));
				case _:
					invalid();
			}
		}
		giveBack();
		if (p > end) throw new haxe.io.Eof();
		var result = pos == out.length ? out : out.sub(0, pos);
		// (zlib's Adler-32 of the output, big-endian, after the stream)
		if (crc) {
			var want = (byte() << 24) | (byte() << 16) | (byte() << 8) | byte();
			if (adler(result) != want) throw "Invalid CRC";
		}
		return result;
	}

	static function adler(b:haxe.io.Bytes):Int {
		var a = 1, c = 0, i = 0, n = b.length;
		while (i < n) {
			// (3800 bytes at most between the reductions: the sums stay under 2^31, signed)
			var stop = i + 3800 < n ? i + 3800 : n;
			while (i < stop) {
				a += b.get(i++);
				c += a;
			}
			a %= 65521;
			c %= 65521;
		}
		return (c << 16) | a;
	}

	@:isVar static var fixedLit(get, null):FastHuffman;
	@:isVar static var fixedDist(get, null):FastHuffman;

	static function get_fixedLit():FastHuffman {
		if (fixedLit == null) fixedLit = new FastHuffman([for (i in 0...288) i < 144 ? 8 : i < 256 ? 9 : i < 280 ? 7 : 8]);
		return fixedLit;
	}

	static function get_fixedDist():FastHuffman {
		if (fixedDist == null) fixedDist = new FastHuffman([for (i in 0...30) 5]);
		return fixedDist;
	}

	function block(lit:FastHuffman, dist:FastHuffman) {
		while (true) {
			var s = decode(lit);
			if (s < 256) {
				room(1);
				out.set(pos++, s);
			} else if (s == 256) return else {
				var k = s - 257;
				if (k >= 29) invalid();
				var len = LENGTH_BASE[k] + bits(LENGTH_EXTRA[k]);
				var d = decode(dist);
				if (d >= 30) invalid();
				var back = DIST_BASE[d] + bits(DIST_EXTRA[d]);
				if (back > pos) invalid();
				room(len);
				if (back >= len) {
					out.blit(pos, out, pos - back, len);
					pos += len;
				} else
					for (i in 0...len) {
						out.set(pos, out.get(pos - back));
						pos++;
					}
			}
		}
	}

	// a symbol: the table for codes up to FAST bits (inline: once a byte), else
	// bit by bit from the canonical counts (the code's first bit its most significant)
	inline function decode(h:FastHuffman):Int {
		need(15);
		var e = h.fast[buf & ((1 << FAST) - 1)];
		return if (e != 0) {
			var len = e >> 9;
			buf >>>= len;
			cnt -= len;
			e & 511;
		} else slow(h);
	}

	// (a code longer than FAST bits)
	function slow(h:FastHuffman):Int {
		var code = 0, first = 0, index = 0;
		for (len in 1...16) {
			code |= bits(1);
			var count = h.counts[len];
			if (code - count < first) return h.symbols[index + (code - first)];
			index += count;
			first += count;
			first <<= 1;
			code <<= 1;
		}
		return invalid();
	}
}

// (hxmc) a canonical prefix code from code lengths: a table of the codes up
// to 10 bits (by their bits as read: reversed), each (length << 9) | symbol
private class FastHuffman {
	public final counts = [for (i in 0...16) 0];
	public final symbols:Array<Int> = [];
	public final fast = new Vector<Int>(1 << 10);

	public function new(lengths:Array<Int>) {
		for (i in 0...fast.length)
			fast[i] = 0;
		for (l in lengths)
			if (l > 0) counts[l]++;
		// (the symbols by length, then by value: each length's first place, then each in turn)
		var at = [for (i in 0...16) 0], total = 0;
		for (len in 1...16) {
			at[len] = total;
			total += counts[len];
		}
		symbols.resize(total);
		for (s in 0...lengths.length) {
			var l = lengths[s];
			if (l > 0) symbols[at[l]++] = s;
		}
		var code = 0, k = 0;
		for (len in 1...16) {
			for (i in 0...counts[len]) {
				if (len <= 10) {
					// (the code's bits reversed, filled in for every longer index)
					var r = 0, c = code;
					for (b in 0...len) {
						r = (r << 1) | (c & 1);
						c >>= 1;
					}
					var step = 1 << len, e = (len << 9) | symbols[k];
					var j = r;
					while (j < (1 << 10)) {
						fast[j] = e;
						j += step;
					}
				}
				code++;
				k++;
			}
			code <<= 1;
		}
	}
}
