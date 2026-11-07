package hxmc;

import haxe.io.Bytes;

// A growable little-endian byte buffer (machine code, object files).
class Buf {
	public var b:Bytes;
	public var len:Int = 0;

	public function new(cap = 256) {
		b = Bytes.alloc(cap < 16 ? 16 : cap);
	}

	inline function need(n:Int) {
		if (len + n > b.length) grow(len + n);
	}

	function grow(min:Int) {
		var cap = b.length * 2;
		while (cap < min)
			cap *= 2;
		var nb = Bytes.alloc(cap);
		nb.blit(0, b, 0, len);
		b = nb;
	}

	public inline function u8(v:Int) {
		need(1);
		b.set(len++, v);
	}

	public inline function u16(v:Int) {
		need(2);
		b.setUInt16(len, v);
		len += 2;
	}

	public inline function u32(v:Int) {
		need(4);
		b.setInt32(len, v);
		len += 4;
	}

	// a 64-bit value from its halves
	public inline function u64(lo:Int, hi:Int) {
		u32(lo);
		u32(hi);
	}

	// a non-negative Int as 64 bits, or a negative one sign-extended
	public inline function i64(v:Int)
		u64(v, v < 0 ? -1 : 0);

	public function bytes(src:Bytes, pos = 0, n = -1) {
		if (n < 0) n = src.length - pos;
		need(n);
		b.blit(len, src, pos, n);
		len += n;
	}

	public function buf(src:Buf) {
		need(src.len);
		b.blit(len, src.b, 0, src.len);
		len += src.len;
	}

	public function str(s:String) {
		bytes(Bytes.ofString(s));
	}

	// LEB128 (DWARF, the objects' function records): unsigned, signed
	public function uleb(v:Int) {
		while (true) {
			var c = v & 0x7f;
			v >>>= 7;
			if (v == 0) {
				u8(c);
				return;
			}
			u8(c | 0x80);
		}
	}

	public function sleb(v:Int) {
		while (true) {
			var c = v & 0x7f;
			v >>= 7;
			if ((v == 0 && (c & 0x40) == 0) || (v == -1 && (c & 0x40) != 0)) {
				u8(c);
				return;
			}
			u8(c | 0x80);
		}
	}

	public function zeros(n:Int) {
		need(n);
		b.fill(len, n, 0);
		len += n;
	}

	public function align(a:Int, fill = 0) {
		while (len % a != 0)
			u8(fill);
	}

	public inline function get8(at:Int):Int
		return b.get(at);

	public inline function set8(at:Int, v:Int)
		b.set(at, v);

	public inline function get32(at:Int):Int
		return b.getInt32(at);

	public inline function set32(at:Int, v:Int) {
		b.setInt32(at, v);
	}

	public inline function set16(at:Int, v:Int) {
		b.setUInt16(at, v);
	}

	public inline function set64(at:Int, lo:Int, hi:Int) {
		set32(at, lo);
		set32(at + 4, hi);
	}

	public function toBytes():Bytes
		return b.sub(0, len);
}
