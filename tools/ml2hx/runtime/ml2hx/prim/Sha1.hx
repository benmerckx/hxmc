package ml2hx.prim;

import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import ml2hx.rt.*;

// The sha library's SHA-1 (sha1_stubs.c): a context gathers the bytes,
// finalize hashes them (haxe.crypto.Sha1); a digest is its 20 bytes.
class Sha1Ctx {
	public var data:BytesBuffer;
	public function new() data = new BytesBuffer();
}

class Sha1Digest {
	public final bytes:Bytes;
	public function new(bytes:Bytes) this.bytes = bytes;
}

class Sha1 {
	public static function stubSha1Init(_:Unit):Sha1Ctx return new Sha1Ctx();
	public static function stubSha1Update(ctx:Sha1Ctx, s:String, ofs:Int63, len:Int63):Unit {
		var o = ofs.toInt();
		for (i in 0...len.toInt()) ctx.data.addByte(StringTools.fastCodeAt(s, o + i));
		return Unit.value;
	}
	public static function stubSha1UpdateBigarray<A, B, C>(ctx:Sha1Ctx, buf:BigarrayData<A, B, C>):Unit {
		for (i in 0...buf.dims[0]) ctx.data.addByte((buf.data[buf.offset + i] : Int) & 0xff);
		return Unit.value;
	}
	public static function stubSha1Finalize(ctx:Sha1Ctx):Sha1Digest {
		var b = ctx.data.getBytes();
		// (the context is spent, as sha1_finalize leaves it)
		ctx.data = new BytesBuffer();
		return new Sha1Digest(haxe.crypto.Sha1.make(b));
	}
	public static function stubSha1Copy(ctx:Sha1Ctx):Sha1Ctx {
		var c = new Sha1Ctx();
		var b = ctx.data.getBytes();
		ctx.data = new BytesBuffer();
		ctx.data.add(b);
		c.data.add(b);
		return c;
	}
	public static function stubSha1ToBin(d:Sha1Digest):String {
		var s = new StringBuf();
		for (i in 0...20) s.addChar(d.bytes.get(i));
		return s.toString();
	}
	public static function stubSha1ToHex(d:Sha1Digest):String return d.bytes.toHex();
	public static function stubSha1OfBin(b:Bytes):Sha1Digest return new Sha1Digest(b.sub(0, 20));
	public static function stubSha1OfHex(h:String):Sha1Digest {
		var b = Bytes.alloc(20);
		b.fill(0, 20, 0);
		if (h.length != 40) return new Sha1Digest(b);
		function digit(c:Int) return c >= "0".code && c <= "9".code ? c - "0".code : c >= "a".code && c <= "f".code ? c - "a".code + 10 : c >= "A".code && c <= "F".code ? c - "A".code + 10 : -1;
		for (i in 0...20) {
			var a = digit(StringTools.fastCodeAt(h, 2 * i)), c = digit(StringTools.fastCodeAt(h, 2 * i + 1));
			if (a < 0 || c < 0) break;
			b.set(i, a * 16 + c);
		}
		return new Sha1Digest(b);
	}
	public static function stubSha1File(name:String):Sha1Digest {
		var b = try sys.io.File.getBytes(ByteString.toNative(name)) catch (e:Dynamic) throw new Failure("file error");
		return new Sha1Digest(haxe.crypto.Sha1.make(b));
	}
	public static function stubSha1Equal(a:Sha1Digest, b:Sha1Digest):Bool return a.bytes.compare(b.bytes) == 0;
}
