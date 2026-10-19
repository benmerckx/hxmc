package ml2hx.prim;

import haxe.Int64;
import haxe.io.Bytes;
import ml2hx.rt.*;

// BLAKE2b (RFC 7693) with a key and an output length of 1 to 64 bytes.
class Blake2State {
	static final IV = [
		Int64.make(0x6a09e667, 0xf3bcc908), Int64.make(0xbb67ae85, 0x84caa73b), Int64.make(0x3c6ef372, 0xfe94f82b), Int64.make(0xa54ff53a, 0x5f1d36f1),
		Int64.make(0x510e527f, 0xade682d1), Int64.make(0x9b05688c, 0x2b3e6c1f), Int64.make(0x1f83d9ab, 0xfb41bd6b), Int64.make(0x5be0cd19, 0x137e2179)
	];
	static final SIGMA = [
		[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15], [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
		[11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4], [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
		[9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13], [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
		[12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11], [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
		[6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5], [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0]
	];
	final h:Array<Int64>;
	final buf = Bytes.alloc(128);
	var len = 0;
	var t0:Int64 = 0;
	var t1:Int64 = 0;
	public final outlen:Int;

	public function new(outlen:Int, key:String) {
		this.outlen = outlen;
		h = IV.copy();
		h[0] = h[0] ^ Int64.ofInt(0x01010000 ^ (key.length << 8) ^ outlen);
		if (key.length > 0) {
			for (i in 0...key.length) buf.set(i, StringTools.fastCodeAt(key, i));
			len = 128;
		}
	}

	static inline function rotr(x:Int64, n:Int):Int64 return (x >>> n) | (x << (64 - n));

	function compress(last:Bool) {
		var v = h.concat(IV);
		v[12] = v[12] ^ t0;
		v[13] = v[13] ^ t1;
		if (last) v[14] = ~v[14];
		var m = [for (i in 0...16) buf.getInt64(i * 8)];
		inline function g(a:Int, b:Int, c:Int, d:Int, x:Int64, y:Int64) {
			v[a] = v[a] + v[b] + x;
			v[d] = rotr(v[d] ^ v[a], 32);
			v[c] = v[c] + v[d];
			v[b] = rotr(v[b] ^ v[c], 24);
			v[a] = v[a] + v[b] + y;
			v[d] = rotr(v[d] ^ v[a], 16);
			v[c] = v[c] + v[d];
			v[b] = rotr(v[b] ^ v[c], 63);
		}
		for (r in 0...12) {
			var s = SIGMA[r % 10];
			g(0, 4, 8, 12, m[s[0]], m[s[1]]);
			g(1, 5, 9, 13, m[s[2]], m[s[3]]);
			g(2, 6, 10, 14, m[s[4]], m[s[5]]);
			g(3, 7, 11, 15, m[s[6]], m[s[7]]);
			g(0, 5, 10, 15, m[s[8]], m[s[9]]);
			g(1, 6, 11, 12, m[s[10]], m[s[11]]);
			g(2, 7, 8, 13, m[s[12]], m[s[13]]);
			g(3, 4, 9, 14, m[s[14]], m[s[15]]);
		}
		for (i in 0...8) h[i] = h[i] ^ v[i] ^ v[i + 8];
	}

	function counter(n:Int) {
		var old = t0;
		t0 = t0 + n;
		if (Int64.ucompare(t0, old) < 0) t1 = t1 + 1;
	}

	public function update(get:Int->Int, n:Int) {
		for (i in 0...n) {
			if (len == 128) {
				counter(128);
				compress(false);
				len = 0;
			}
			buf.set(len++, get(i));
		}
	}

	public function final_():String {
		counter(len);
		while (len < 128) buf.set(len++, 0);
		compress(true);
		var out = new StringBuf();
		for (i in 0...outlen) out.addChar((h[i >> 3] >>> (8 * (i & 7))).low & 0xFF);
		return out.toString();
	}
}

// OCaml's md5.c and blake2.c: digests are byte strings.
class Digest {
	static function md5(b:Bytes, ofs:Int, len:Int):String {
		var d = haxe.crypto.Md5.make(b.sub(ofs, len));
		return ByteString.ofBytes(d, 0, d.length);
	}
	public static function camlMd5String(s:String, ofs:Int63, len:Int63):String return md5(ByteString.toBytes(s), ofs.toInt(), len.toInt());
	public static function camlMd5Bytes(b:Bytes, ofs:Int63, len:Int63):String return md5(b, ofs.toInt(), len.toInt());
	public static function camlMd5Chan(ic:Io.InChannel, len:Int63):String {
		var n = len.toInt();
		var out = new haxe.io.BytesBuffer();
		var chunk = Bytes.alloc(4096);
		while (n != 0) {
			var k = ic.read(chunk, 0, n < 0 || n > 4096 ? 4096 : n);
			if (k == 0) {
				if (n > 0) throw EndOfFile.instance;
				break;
			}
			out.addBytes(chunk, 0, k);
			if (n > 0) n -= k;
		}
		var b = out.getBytes();
		return md5(b, 0, b.length);
	}

	public static function camlBlake2Create(outlen:Int63, key:String):Blake2State return new Blake2State(outlen.toInt(), key);
	public static function camlBlake2Update(st:Blake2State, b:Bytes, ofs:Int63, len:Int63):Unit {
		var o = ofs.toInt();
		st.update(i -> b.get(o + i), len.toInt());
		return Unit.value;
	}
	public static function camlBlake2Final(st:Blake2State, outlen:Int63):String return st.final_();
	public static function camlBlake2String(outlen:Int63, key:String, s:String, ofs:Int63, len:Int63):String {
		var st = new Blake2State(outlen.toInt(), key);
		var o = ofs.toInt();
		st.update(i -> StringTools.fastCodeAt(s, o + i), len.toInt());
		return st.final_();
	}
	public static function camlBlake2Bytes(outlen:Int63, key:String, b:Bytes, ofs:Int63, len:Int63):String {
		var st = new Blake2State(outlen.toInt(), key);
		var o = ofs.toInt();
		st.update(i -> b.get(o + i), len.toInt());
		return st.final_();
	}
}
