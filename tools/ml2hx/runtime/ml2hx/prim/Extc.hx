package ml2hx.prim;

import ml2hx.rt.*;
import upstream.libs.extc.ExtcModule;

// The C primitives of libs/extc (extc_stubs.c): deflate streams over the
// port's translation of zlib (ml2hx.zlib.Zlib, which generate.mjs copies from
// haxe/src/libs/extc: the reference's bytes), inflate over haxe.zip, paths
// and times over the host. Glue for the converted unit: it names the
// unit's generated types.
class Extc {
	static final deflaters = new haxe.ds.ObjectMap<ExtcZstream, ml2hx.zlib.Zlib>();
	// the last source string as bytes (zlib_op passes the same string with
	// growing offsets)
	static var lastSrc:String;
	static var lastBytes:haxe.io.Bytes;
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
		deflaters.set(z, ml2hx.zlib.Zlib.deflateInit2(level.toInt(), windowBits.toInt()));
		return z;
	}
	// zlib_deflate of extc_stubs.c, with its error messages
	public static function zlibDeflateBytecode(z:ExtcZstream, src:String, spos:Int63, slen:Int63, dst:haxe.io.Bytes, dpos:Int63, dlen:Int63, flush:ExtcZflush):ExtcZresult {
		var zl = deflaters.get(z);
		if (src != lastSrc || lastBytes == null) {
			lastSrc = src;
			lastBytes = ByteString.toBytes(src);
		}
		var f = switch flush {
			case Z_NO_FLUSH: ml2hx.zlib.Zlib.Z_NO_FLUSH;
			case Z_PARTIAL_FLUSH: ml2hx.zlib.Zlib.Z_PARTIAL_FLUSH;
			case Z_SYNC_FLUSH: ml2hx.zlib.Zlib.Z_SYNC_FLUSH;
			case Z_FULL_FLUSH: ml2hx.zlib.Zlib.Z_FULL_FLUSH;
			case Z_FINISH: ml2hx.zlib.Zlib.Z_FINISH;
		}
		var r = zl.deflate(lastBytes, spos.toInt(), slen.toInt(), dst, dpos.toInt(), dlen.toInt(), f);
		if (r == ml2hx.zlib.Zlib.Z_OK || r == ml2hx.zlib.Zlib.Z_STREAM_END)
			return new ExtcZresult(r == ml2hx.zlib.Zlib.Z_STREAM_END, Int63.ofInt(slen.toInt() - zl.getAvailIn()), Int63.ofInt(dlen.toInt() - zl.getAvailOut()));
		throw new Failure(switch r {
			case ml2hx.zlib.Zlib.Z_STREAM_ERROR: "Error in `zlib_deflate` (extc_stubs.c): call to `deflate` failed: Z_STREAM_ERROR";
			case ml2hx.zlib.Zlib.Z_BUF_ERROR: "Error in `zlib_deflate` (extc_stubs.c): call to `deflate` failed: Z_BUF_ERROR";
			case _: "Error in `zlib_deflate` (extc_stubs.c): unknown return code from `deflate`";
		});
	}
	public static function zlibDeflateEnd(z:ExtcZstream):Unit {
		var zl = deflaters.get(z);
		deflaters.remove(z);
		lastSrc = null;
		lastBytes = null;
		if (zl != null && zl.deflateEnd() != 0) throw new Failure("zlib_deflate_end");
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
	public static function zlibDeflateBound(z:ExtcZstream, n:Int63):Int63 {
		var zl = deflaters.get(z);
		if (zl != null) return Int63.ofInt(zl.deflateBound(n.toInt()));
		// (an inflate stream: zlib's compressBound)
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
