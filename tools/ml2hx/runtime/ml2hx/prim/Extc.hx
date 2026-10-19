package ml2hx.prim;

import ml2hx.rt.*;
import upstream.libs.extc.ExtcModule;

// The C primitives of libs/extc (extc_stubs.c): zlib streams over haxe.zip,
// paths and times over the host. Glue for the converted unit: it names the
// unit's generated types.
class Extc {
	static final deflaters = new haxe.ds.ObjectMap<ExtcZstream, haxe.zip.Compress>();
	static final inflaters = new haxe.ds.ObjectMap<ExtcZstream, haxe.zip.Uncompress>();
	static function mode(f:ExtcZflush):haxe.zip.FlushMode {
		return switch f {
			case Z_NO_FLUSH: NO;
			case Z_PARTIAL_FLUSH | Z_SYNC_FLUSH: SYNC;
			case Z_FULL_FLUSH: FULL;
			case Z_FINISH: FINISH;
		}
	}
	public static function zlibDeflateInit2(level:Int63, windowBits:Int63):ExtcZstream {
		var z = new ExtcZstream();
		deflaters.set(z, new haxe.zip.Compress(level.toInt()));
		return z;
	}
	public static function zlibDeflateBytecode(z:ExtcZstream, src:String, spos:Int63, slen:Int63, dst:haxe.io.Bytes, dpos:Int63, dlen:Int63, flush:ExtcZflush):ExtcZresult {
		var c = deflaters.get(z);
		c.setFlushMode(mode(flush));
		var input = ByteString.toBytes(src.substr(spos.toInt(), slen.toInt()));
		var out = haxe.io.Bytes.alloc(dlen.toInt());
		var r = c.execute(input, 0, out, 0);
		dst.blit(dpos.toInt(), out, 0, r.write);
		return new ExtcZresult(r.done, Int63.ofInt(r.read), Int63.ofInt(r.write));
	}
	public static function zlibDeflateEnd(z:ExtcZstream):Unit {
		var c = deflaters.get(z);
		if (c != null) c.close();
		deflaters.remove(z);
		return Unit.value;
	}
	public static function zlibInflateInit(windowBits:Int63):ExtcZstream {
		var z = new ExtcZstream();
		inflaters.set(z, new haxe.zip.Uncompress(windowBits.toInt()));
		return z;
	}
	public static function zlibInflateBytecode(z:ExtcZstream, src:String, spos:Int63, slen:Int63, dst:haxe.io.Bytes, dpos:Int63, dlen:Int63, flush:ExtcZflush):ExtcZresult {
		var u = inflaters.get(z);
		u.setFlushMode(mode(flush));
		var input = ByteString.toBytes(src.substr(spos.toInt(), slen.toInt()));
		var out = haxe.io.Bytes.alloc(dlen.toInt());
		var r = u.execute(input, 0, out, 0);
		dst.blit(dpos.toInt(), out, 0, r.write);
		return new ExtcZresult(r.done, Int63.ofInt(r.read), Int63.ofInt(r.write));
	}
	public static function zlibInflateEnd(z:ExtcZstream):Unit {
		var u = inflaters.get(z);
		if (u != null) u.close();
		inflaters.remove(z);
		return Unit.value;
	}
	// zlib's compressBound
	public static function zlibDeflateBound(z:ExtcZstream, n:Int63):Int63 {
		var len = n.toInt();
		return Int63.ofInt(len + (len >> 12) + (len >> 14) + (len >> 25) + 13);
	}
	public static function zlibCrc32(b:haxe.io.Bytes, len:Int63):haxe.Int32 return haxe.crypto.Crc32.make(b.sub(0, len.toInt()));
	public static function executablePath(argv0:String):String {
		#if sys
		return ByteString.ofNative(std.Sys.programPath() ?? ByteString.toNative(argv0));
		#else
		return argv0;
		#end
	}
	public static function getFullPath(p:String):String {
		#if sys
		return ByteString.ofNative(sys.FileSystem.fullPath(ByteString.toNative(p)));
		#else
		return p;
		#end
	}
	public static function getRealPath(p:String):String return getFullPath(p);
	public static function sysTime(_:Unit):Float return Date.now().getTime() / 1000;
	public static function sysTimestampMs(_:Unit):haxe.Int64 return haxe.Int64.fromFloat(Date.now().getTime());
	public static function sysFiletime(p:String):Float {
		#if sys
		return try sys.FileSystem.stat(ByteString.toNative(p)).mtime.getTime() / 1000 catch (e:Dynamic) 0.0;
		#else
		return 0.0;
		#end
	}
	public static function sysGetch(echo:Bool):Int63 {
		#if sys
		return Int63.ofInt(std.Sys.getChar(echo));
		#else
		return Int63.zero;
		#end
	}
}
