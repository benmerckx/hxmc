package ml2hx.std;

import String;
import ml2hx.rt.*;

// Stdlib.Digest (MD5): a digest is a 16-byte string.
typedef DigestT = String;

class Digest {
	public static function string(s:String):DigestT return ByteString.ofBytes(haxe.crypto.Md5.make(ByteString.toBytes(s)), 0, 16);
	public static function bytes(b:haxe.io.Bytes):DigestT return ByteString.ofBytes(haxe.crypto.Md5.make(b), 0, 16);
	public static function substring(s:String, ofs:Int63, len:Int63):DigestT return string(s.substr(ofs.toInt(), len.toInt()));
	public static function toHex(d:DigestT):String {
		if (d.length != 16) throw new InvalidArgument("Digest.to_hex");
		var hex = "0123456789abcdef", b = new StringBuf();
		for (i in 0...16) { var c = StringTools.fastCodeAt(d, i); b.addChar(StringTools.fastCodeAt(hex, c >> 4)); b.addChar(StringTools.fastCodeAt(hex, c & 15)); }
		return b.toString();
	}
	public static function fromHex(s:String):DigestT {
		if (s.length != 32) throw new InvalidArgument("Digest.from_hex");
		var b = new StringBuf();
		for (i in 0...16) {
			var v = Std.parseInt("0x" + s.substr(2 * i, 2));
			if (v == null) throw new InvalidArgument("Digest.from_hex");
			b.addChar(v);
		}
		return b.toString();
	}
	public static inline function equal(a:DigestT, b:DigestT):Bool return a == b;
	public static inline function compare(a:DigestT, b:DigestT):Int63 return Int63.ofInt(Poly.compareStrings(a, b));
	public static function file(name:String):DigestT {
		#if sys
		return bytes(sys.io.File.getBytes(ByteString.toNative(name)));
		#else
		throw new SysError(name + ": no file system");
		#end
	}
}
