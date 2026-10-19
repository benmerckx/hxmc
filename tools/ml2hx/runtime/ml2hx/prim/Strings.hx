package ml2hx.prim;

import haxe.io.Bytes;
import ml2hx.rt.*;

// OCaml's str.c: strings are Haxe strings of byte units (immutable), bytes
// are haxe.io.Bytes.
class Strings {
	static inline function i(n:Int63):Int return n.toInt();

	public static function camlCreateBytes(n:Int63):Bytes {
		if (Int63.lt(n, Int63.zero) || Int63.gt(n, Int63.ofInt(0x7FFFFFFF))) throw new InvalidArgument("Bytes.create");
		return Bytes.alloc(i(n));
	}
	public static function camlBlitBytes(src:Bytes, so:Int63, dst:Bytes, d:Int63, n:Int63):Unit {
		dst.blit(i(d), src, i(so), i(n));
		return Unit.value;
	}
	public static function camlBlitString(src:String, so:Int63, dst:Bytes, d:Int63, n:Int63):Unit {
		var s = i(so), o = i(d);
		for (k in 0...i(n)) dst.set(o + k, StringTools.fastCodeAt(src, s + k));
		return Unit.value;
	}
	public static function camlFillBytes(b:Bytes, ofs:Int63, n:Int63, c:Int):Unit {
		b.fill(i(ofs), i(n), c);
		return Unit.value;
	}
	public static function camlBytesEqual(a:Bytes, b:Bytes):Bool return a.length == b.length && a.compare(b) == 0;
	public static function camlStringEqual(a:String, b:String):Bool return a == b;
	public static function camlStringNotequal(a:String, b:String):Bool return a != b;
	public static function camlStringCompare(a:String, b:String):Int63 return Int63.ofInt(Poly.compareStrings(a, b));
	public static function camlBytesCompare(a:Bytes, b:Bytes):Int63 {
		var c = a.compare(b);
		return Int63.ofInt(c < 0 ? -1 : c > 0 ? 1 : 0);
	}
	public static function camlStringHash(seed:Int63, s:String):Int63 return Int63.ofInt(Poly.finalMix(Poly.mixString(seed.toInt(), s)) & 0x3FFFFFFF);
}
