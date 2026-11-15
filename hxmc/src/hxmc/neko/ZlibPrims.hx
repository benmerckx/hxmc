package hxmc.neko;

import haxe.io.Bytes;
import hxmc.neko.Prims.Register;
import hxmc.neko.StdPrims.NBuf;
import hxmc.neko.Value;

using hxmc.neko.Builtins.Check;

// an inflate stream: the input it was given until the stream ends (each call
// inflates it again from the start: haxe.zip.InflateImpl inflates a whole
// stream), then the output, handed out as the destination has room
class Inflater {
	public var wbits:Int;
	public var pending = new NBuf();
	public var out:Null<Bytes>;
	public var outPos = 0;

	public function new(wbits)
		this.wbits = wbits;
}

// a deflate stream: stored blocks (no compression), zlib's framing unless the
// window bits are negative
class Deflater {
	public var wbits:Int;
	public var flush = "NO";
	public var input = new NBuf();
	public var out:Null<Bytes>;
	public var outPos = 0;

	public function new(wbits)
		this.wbits = wbits;
}

class ZlibPrims {
	static function result(done:Bool, read:Int, write:Int):NObj {
		var o = new NObj();
		o.set(Fields.id("done"), done);
		o.set(Fields.id("read"), read);
		o.set(Fields.id("write"), write);
		return o;
	}

	static function drain(out:Bytes, pos:Int, dst:Bytes, dpos:Int):Int {
		var n = out.length - pos;
		var room = dst.length - dpos;
		if (n > room) n = room;
		dst.blit(dpos, out, pos, n);
		return n;
	}

	public static function adler32(b:Bytes, pos:Int, len:Int, init:Int = 1):Int {
		var a = init & 0xFFFF, s = (init >>> 16) & 0xFFFF;
		for (i in pos...pos + len) {
			a = (a + b.get(i)) % 65521;
			s = (s + a) % 65521;
		}
		return (s << 16) | a;
	}

	static function stored(data:Bytes, zlib:Bool):Bytes {
		var b = new NBuf();
		if (zlib) {
			b.addByte(0x78);
			b.addByte(0x01);
		}
		var p = 0;
		do {
			var n = data.length - p;
			if (n > 65535) n = 65535;
			var last = p + n >= data.length;
			b.addByte(last ? 1 : 0);
			b.addByte(n & 0xFF);
			b.addByte(n >> 8);
			b.addByte(~n & 0xFF);
			b.addByte((~n >> 8) & 0xFF);
			b.addBytes(data, p, n);
			p += n;
		} while (p < data.length);
		if (zlib) {
			var a = adler32(data, 0, data.length);
			b.addByte((a >>> 24) & 0xFF);
			b.addByte((a >>> 16) & 0xFF);
			b.addByte((a >>> 8) & 0xFF);
			b.addByte(a & 0xFF);
		}
		return b.bytes();
	}

	static function inflate(input:haxe.io.Input, header:Bool):Bytes {
		var inf = new haxe.zip.InflateImpl(input, header, header);
		var out = new haxe.io.BytesBuffer();
		var buf = Bytes.alloc(65536);
		while (true) {
			var n = inf.readBytes(buf, 0, buf.length);
			out.addBytes(buf, 0, n);
			if (n < buf.length) break;
		}
		return out.getBytes();
	}

	public static function register(add:Register) {
		var r = (n:String, k:Int, f:Prim) -> add("zlib@" + n, k, f);
		r("inflate_init", 1, (vm, a) -> new NAbs("zlib_inflate", new Inflater(a[0] == null ? 15 : a[0].int())));
		r("inflate_end", 1, (vm, a) -> null);
		r("inflate_buffer", 5, (vm, a) -> {
			var z:Inflater = a[0].abs("zlib_inflate");
			var src = a[1].str().b, sp = a[2].int(), dst = a[3].str().b, dp = a[4].int();
			if (sp < 0 || dp < 0 || sp > src.length || dp > dst.length) throw Builtins.failure;
			var read = 0;
			if (z.out == null) {
				var before = z.pending.len;
				z.pending.addBytes(src, sp, src.length - sp);
				var input = new haxe.io.BytesInput(z.pending.bytes());
				var header = z.wbits > 0;
				var done = try {
					z.out = inflate(input, header);
					true;
				} catch (e:haxe.io.Eof) false catch (e:Dynamic) throw VM.error("inflate error: " + Std.string(e));
				if (!done) return result(false, src.length - sp, 0);
				read = input.position - before;
				if (read < 0) read = 0;
			}
			var n = drain(z.out, z.outPos, dst, dp);
			z.outPos += n;
			return result(z.outPos >= z.out.length, read, n);
		});
		r("deflate_init", 1, (vm, a) -> new NAbs("zlib_deflate", new Deflater(15)));
		r("deflate_end", 1, (vm, a) -> null);
		r("deflate_bound", 2, (vm, a) -> {
			var n = a[1].int();
			return n + 6 + 5 * (Std.int(n / 65535) + 1) + 4;
		});
		r("deflate_buffer", 5, (vm, a) -> {
			var z:Deflater = a[0].abs("zlib_deflate");
			var src = a[1].str().b, sp = a[2].int(), dst = a[3].str().b, dp = a[4].int();
			if (sp < 0 || dp < 0 || sp > src.length || dp > dst.length) throw Builtins.failure;
			var read = 0;
			if (z.out == null) {
				z.input.addBytes(src, sp, src.length - sp);
				read = src.length - sp;
				if (z.flush != "FINISH") return result(false, read, 0);
				z.out = stored(z.input.bytes(), z.wbits > 0);
			}
			var n = drain(z.out, z.outPos, dst, dp);
			z.outPos += n;
			return result(z.outPos >= z.out.length, read, n);
		});
		r("set_flush_mode", 2, (vm, a) -> {
			var mode = a[1].str().toString();
			if (["NO", "SYNC", "FULL", "FINISH", "BLOCK"].indexOf(mode) < 0) throw Builtins.failure;
			if (Tag.isAbstract(a[0]) && (a[0] : NAbs).kind == "zlib_deflate") ((a[0] : NAbs).data : Deflater).flush = mode else
				a[0].abs("zlib_inflate");
			return null;
		});
		r("get_adler32", 1, (vm, a) -> {
			var z:Deflater = a[0].abs("zlib_deflate");
			return adler32(z.input.b, 0, z.input.len);
		});
		r("update_adler32", 4, (vm, a) -> {
			var s = a[1].str().b, p = a[2].int(), l = a[3].int();
			if (p < 0 || l < 0 || p + l > s.length) throw Builtins.failure;
			return adler32(s, p, l, a[0].int());
		});
		r("update_crc32", 4, (vm, a) -> {
			var s = a[1].str().b, p = a[2].int(), l = a[3].int();
			if (p < 0 || l < 0 || p + l > s.length) throw Builtins.failure;
			var crc = new haxe.crypto.Crc32();
			// (the running value: zlib's crc32(crc, buf, len))
			var c = ~a[0].int();
			for (i in p...p + l) {
				c ^= s.get(i);
				for (_ in 0...8)
					c = (c >>> 1) ^ (0xEDB88320 & -(c & 1));
			}
			return ~c;
		});
	}
}
