import haxe.io.Bytes;
import hxmc.NativeGc;
import hxmc.ReadOnlySpan;
import hxmc.Span;
import hxmc.unsafe.Blocking;
import hxmc.unsafe.IoBuffer;
import hxmc.unsafe.UInt8;
import sys.thread.Lock;
import sys.thread.Thread;

// A realistic kernel on checked spans (docs/interop.md, "Spans"): zlib's
// inflate and Adler-32, as helder's off-heap PNG decoder does them
// (OffHeapPng: a 32-bit bit buffer, codes up to 10 bits by table, longer
// ones from their canonical counts), written without @:hxmc.unsafe: its
// state is a struct element of a span (written in place), its tables Ints
// of the scratch span. One kernel, three paths: on the main thread over
// Bytes (lent for the call, no copy) and over IoBuffers, and on a worker
// over IoBuffers, inside the region the worker entered (Blocking.enter, as
// a job pool does) while the main thread collects.
@:hxmc.struct @:publicFields class Bits {
	var buf:Int;
	var cnt:Int;
	var p:Int;
	var pos:Int;
	var bad:Int;

	function new() {}
}

@:hxmc.kernel class Inflate {
	public static inline var ERR = -1;
	static inline var FAST = 10;
	// (a code's Ints: the counts per length, the symbols, the table)
	static inline var CODE = 16 + 288 + 1024;
	// (the scratch's Ints: the state, five codes, the lengths)
	public static inline var SCRATCH = 4 * (8 + 5 * CODE + 320);

	// a zlib stream into out: the bytes produced, or ERR
	public static function inflate(src:ReadOnlySpan<UInt8>, out:Span<UInt8>, scratch:Span<UInt8>):Int {
		var words:Span<Int> = scratch.reinterpret();
		var st:Span<Bits> = scratch.sub(0, 32).reinterpret();
		var lit = words.sub(8, CODE), dist = words.sub(8 + CODE, CODE), cl = words.sub(8 + 2 * CODE, CODE);
		var flit = words.sub(8 + 3 * CODE, CODE), fdist = words.sub(8 + 4 * CODE, CODE), lens = words.sub(8 + 5 * CODE, 320);
		var n = src.length;
		if (n < 2) return ERR;
		var cmf:Int = src[0], flg:Int = src[1];
		if (cmf & 15 != 8 || ((cmf << 8) + flg) % 31 != 0 || flg & 32 != 0) return ERR;
		st[0] = new Bits();
		st[0].p = 2;
		for (i in 0...288)
			lens[i] = i < 144 ? 8 : i < 256 ? 9 : i < 280 ? 7 : 8;
		build(flit, lens, 288);
		for (i in 0...30)
			lens[i] = 5;
		build(fdist, lens, 30);
		var last = false;
		while (!last) {
			last = bits(st, src, 1) == 1;
			var type = bits(st, src, 2);
			if (type == 0) {
				giveBack(st);
				var p = st[0].p;
				if (p + 4 > n) return ERR;
				var len = src[p] | src[p + 1] << 8, nlen = src[p + 2] | src[p + 3] << 8;
				p += 4;
				var pos = st[0].pos;
				if (nlen != 0xFFFF - len || p + len > n || pos + len > out.length) return ERR;
				out.blit(pos, src.sub(p, len), 0, len);
				st[0].pos = pos + len;
				st[0].p = p + len;
			} else if (type == 1) {
				if (!block(st, src, out, flit, fdist)) return ERR;
			} else if (type == 2) {
				var hlit = bits(st, src, 5) + 257, hdist = bits(st, src, 5) + 1, hclen = bits(st, src, 4) + 4;
				lens.fill(0, 19, 0);
				for (i in 0...hclen)
					lens[order(i)] = bits(st, src, 3);
				build(cl, lens, 19);
				var i = 0, total = hlit + hdist;
				while (i < total) {
					var sym = symbol(st, src, cl);
					if (sym < 16) lens[i++] = sym else {
						var v = 0, r = 0;
						if (sym == 16) {
							if (i == 0) return ERR;
							v = lens[i - 1];
							r = 3 + bits(st, src, 2);
						} else r = sym == 17 ? 3 + bits(st, src, 3) : 11 + bits(st, src, 7);
						if (i + r > total) return ERR;
						lens.fill(i, r, v);
						i += r;
					}
					if (st[0].bad != 0) return ERR;
				}
				build(lit, lens, hlit);
				build(dist, lens.sub(hlit, hdist), hdist);
				if (!block(st, src, out, lit, dist)) return ERR;
			} else
				return ERR;
			if (st[0].bad != 0) return ERR;
		}
		giveBack(st);
		var p = st[0].p, pos = st[0].pos;
		if (p + 4 > n) return ERR;
		var want = src[p] << 24 | src[p + 1] << 16 | src[p + 2] << 8 | src[p + 3];
		return adler(out.sub(0, pos)) == want ? pos : ERR;
	}

	// one block's symbols: false when it does not decode
	static function block(st:Span<Bits>, src:ReadOnlySpan<UInt8>, out:Span<UInt8>, lit:ReadOnlySpan<Int>, dist:ReadOnlySpan<Int>):Bool {
		var pos = st[0].pos;
		while (true) {
			var sym = symbol(st, src, lit);
			if (sym < 256) {
				if (pos >= out.length) return false;
				out[pos++] = sym;
			} else if (sym == 256) {
				st[0].pos = pos;
				return st[0].bad == 0;
			} else {
				var k = sym - 257;
				if (k >= 29) return false;
				var len = lengthBase(k) + bits(st, src, lengthExtra(k));
				var d = symbol(st, src, dist);
				if (d >= 30) return false;
				var back = distBase(d) + bits(st, src, distExtra(d));
				if (back > pos || pos + len > out.length || st[0].bad != 0) return false;
				if (back >= len) out.blit(pos, out.sub(pos - back, len), 0, len) else
					for (i in 0...len)
						out[pos + i] = out[pos + i - back];
				pos += len;
			}
		}
	}

	// (past the input's end, zeros: no more than its reading ahead, else bad)
	static inline function need(st:Span<Bits>, src:ReadOnlySpan<UInt8>, n:Int)
		while (st[0].cnt < n) {
			var p = st[0].p;
			if (p < src.length) st[0].buf |= src[p] << st[0].cnt else if (p >= src.length + 4) st[0].bad = 1;
			st[0].p = p + 1;
			st[0].cnt += 8;
		}

	static inline function bits(st:Span<Bits>, src:ReadOnlySpan<UInt8>, n:Int):Int {
		need(st, src, n);
		var buf = st[0].buf;
		st[0].buf = buf >>> n;
		st[0].cnt -= n;
		return buf & ((1 << n) - 1);
	}

	static function giveBack(st:Span<Bits>) {
		st[0].p -= st[0].cnt >> 3;
		st[0].buf = 0;
		st[0].cnt = 0;
	}

	// a symbol: by table up to FAST bits, else bit by bit from the counts
	static function symbol(st:Span<Bits>, src:ReadOnlySpan<UInt8>, h:ReadOnlySpan<Int>):Int {
		need(st, src, 15);
		var buf = st[0].buf;
		var e = h[16 + 288 + (buf & ((1 << FAST) - 1))];
		if (e != 0) {
			var len = e >> 9;
			st[0].buf = buf >>> len;
			st[0].cnt -= len;
			return e & 511;
		}
		var code = 0, first = 0, index = 0;
		for (len in 1...16) {
			code |= bits(st, src, 1);
			var count = h[len];
			if (code - count < first) return h[16 + index + (code - first)];
			index += count;
			first += count;
			first <<= 1;
			code <<= 1;
		}
		st[0].bad = 1;
		return 999;
	}

	// a canonical code from n lengths: counts, symbols, the table of the codes
	// up to FAST bits (by their bits as read: reversed), each (length << 9) | symbol
	static function build(h:Span<Int>, l:ReadOnlySpan<Int>, n:Int) {
		h.fill(0, CODE, 0);
		for (i in 0...n)
			if (l[i] > 0) h[l[i]] += 1;
		// (the symbols by length, then by value; offsets in the table's room until it is filled)
		var at = h.sub(16 + 288, 1024), total = 0;
		for (len in 1...16) {
			at[len] = total;
			total += h[len];
		}
		for (sym in 0...n) {
			var len = l[sym];
			if (len > 0) {
				var k = at[len];
				h[16 + k] = sym;
				at[len] = k + 1;
			}
		}
		at.fill(0, 16, 0);
		var code = 0, k = 0;
		for (len in 1...16) {
			for (i in 0...h[len]) {
				if (len <= FAST) {
					var r = 0, c = code;
					for (b in 0...len) {
						r = (r << 1) | (c & 1);
						c >>= 1;
					}
					var step = 1 << len, e = (len << 9) | h[16 + k];
					var j = r;
					while (j < (1 << FAST)) {
						at[j] = e;
						j += step;
					}
				}
				code++;
				k++;
			}
			code <<= 1;
		}
	}

	public static function adler(s:ReadOnlySpan<UInt8>):Int {
		var a = 1, b = 0, i = 0, n = s.length;
		while (i < n) {
			// (3800 bytes at most between the reductions: the sums stay under 2^31)
			var stop = i + 3800 < n ? i + 3800 : n;
			while (i < stop) {
				a += s[i++];
				b += a;
			}
			a %= 65521;
			b %= 65521;
		}
		return (b << 16) | a;
	}

	static inline function lengthBase(k:Int):Int
		return k < 8 ? 3 + k : k == 28 ? 258 : ((4 + (k & 3)) << ((k >> 2) - 1)) + 3;

	static inline function lengthExtra(k:Int):Int
		return k < 8 || k == 28 ? 0 : (k >> 2) - 1;

	static inline function distBase(d:Int):Int
		return d < 4 ? 1 + d : ((2 + (d & 1)) << ((d >> 1) - 1)) + 1;

	static inline function distExtra(d:Int):Int
		return d < 4 ? 0 : (d >> 1) - 1;

	static inline function order(i:Int):Int
		return switch i {
			case 0: 16;
			case 1: 17;
			case 2: 18;
			case 3: 0;
			case _: (i & 1) == 0 ? 8 + ((i - 4) >> 1) : 7 - ((i - 5) >> 1);
		}
}

class SpanInflate {
	static function text():String {
		var t = new StringBuf();
		for (i in 0...120)
			t.add("line " + i + ": the quick brown fox jumps over the lazy dog " + (i * i) % 97 + "\n");
		return t.toString();
	}

	static final DYNAMIC = ""
			+ "78da9d98499614310c44f79c228f6059d6c46d180a6828baa0a1994ecf83946b1fb1ce17cf72ea4b96e2faf07839c6cbe3fb"
			+ "87cbf1f5f9e1cda7e3f5d3ede7e3f1eef6ebf8f8fcf9cbb7e3f6e3f2f4fff3f5d59fdfc7dbdbfb63bcb8fe5309a692533531"
			+ "d53a558aa9ea542d30423f6586c9a69d32c764daa705f843fa6e89c9bc7f6461b2ecac098888b60c64647694825212ad0339"
			+ "89d93a90942d0349d1fd3741547c9f07b2524da680b0e84e1f484b746798202dd2f79b202ed6714e1097ead29b202eabf19c"
			+ "202eb57b1fc8cbdaf70379a91d27c88bedfc81bc64cb405cbcf1541097d9d5ae202ed9712a888bed4708c46536d60ae292dd"
			+ "e215c4c51b33455fa29d071017d9e7a1b874f929ca4beb16c8cbeabc2f9017edfc2d9017d9e781bceceba1dda5bbc40271c9"
			+ "4efb0271893d5d81b8c43e0fc425f6fd8ad3d9e0e234e1fe8b4d2e0fa65cde6d51989971549b735564c155ad25d725acb8ae"
			+ "e483eb822e5cd7f5c9757957ee55f1c5bd626edcabe9cebdd21edc54e0c94d215ed4d013839bb142b8992e2637438672336b"
			+ "2c6e460ee366f2706e0788e0768e486ec789e276aa1cdc0e97c2ed8c39b91d35955a8973711b781ab7f1a7730e4306656864"
			+ "72fe491669d70cce1d2ae1cca89a9cf755ca596db52863af8c7211cb29cbb282f2472bb9d38aba9b8c41fd4a19c2a54e06c9"
			+ "8a0ce5e094b1b86a90615cf9c970d62fe5fa8b8c241dd351a4658a5abb77cf143677b78e7c91047577efb6296aefde7d53d8"
			+ "e0bdfbdece4d1522e41823a8c76bf7500b1ed4fe02aa43f0aa";
	static final FIXED = "7801cb48cdc9c957c84090003a2e067d";
	static final STORED = "7801010700f8ff73746f726564210bef02b3";

	// over Bytes, on this thread: n bytes out, or ERR
	static function viaBytes(z:Bytes, n:Int):String {
		var out = Bytes.alloc(n), scratch = Bytes.alloc(Inflate.SCRATCH);
		var r = Inflate.inflate(ReadOnlySpan.ofBytes(z), Span.ofBytes(out), Span.ofBytes(scratch));
		return r < 0 ? "error" : out.getString(0, r);
	}

	static function main() {
		var want = text();
		var d = viaBytes(Bytes.ofHex(DYNAMIC), want.length);
		trace("dynamic", d.length, d == want, StringTools.hex(Inflate.adler(ReadOnlySpan.ofBytes(Bytes.ofString(want))), 8),
			StringTools.hex(haxe.crypto.Adler32.make(Bytes.ofString(want)), 8));
		trace("fixed", viaBytes(Bytes.ofHex(FIXED), 64));
		trace("stored", viaBytes(Bytes.ofHex(STORED), 64));
		var bad = Bytes.ofHex(DYNAMIC);
		bad.set(40, bad.get(40) ^ 0x55);
		trace("corrupt", viaBytes(bad, want.length));
		trace("short output", viaBytes(Bytes.ofHex(DYNAMIC), 100));

		// IoBuffers, on a worker in a region it entered, while this thread collects
		var z = IoBuffer.ofBytes(Bytes.ofHex(DYNAMIC)), out = IoBuffer.alloc(want.length), scratch = IoBuffer.alloc(Inflate.SCRATCH);
		var done = new Lock(), r = 0;
		Thread.create(() -> {
			var region = Blocking.enter();
			var n = 0;
			for (k in 0...20)
				n = Inflate.inflate(ReadOnlySpan.ofIoBuffer(z), Span.ofIoBuffer(out), Span.ofIoBuffer(scratch));
			Blocking.leave(region);
			r = n;
			done.release();
		});
		var junk = [];
		for (k in 0...200) {
			junk.push([for (i in 0...100) "x" + i]);
			if (k % 50 == 0) NativeGc.collect(k % 100 == 0);
		}
		done.wait();
		trace("worker", r, out.getBytes(0, r).toString() == want, junk.length);
		z.free();
		out.free();
		scratch.free();
	}
}
