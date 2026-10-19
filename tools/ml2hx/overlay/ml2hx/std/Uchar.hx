package ml2hx.std;

import Array;
import ml2hx.rt.*;

// Stdlib.Uchar (a Unicode scalar value as an Int63) and its utf_decode values
class Uchar {
	public static var min(get, never):Int63;
	public static var max(get, never):Int63;
	public static var rep(get, never):Int63;

	static inline function get_min():Int63
		return Int63.zero;

	static inline function get_max():Int63
		return Int63.ofInt(0x10FFFF);

	static inline function get_rep():Int63
		return Int63.ofInt(0xFFFD);

	public static inline function toInt(u:Int63):Int63
		return u;

	public static inline function unsafeOfInt(n:Int63):Int63
		return n;

	public static final bom:Int63 = Int63.ofInt(0xFEFF);

	public static inline function isChar(u:Int63):Bool
		return Int63.lt(u, Int63.ofInt(256));

	public static inline function unsafeToChar(u:Int63):Int
		return u.toInt() & 255;

	public static function isValid(n:Int63):Bool {
		var i = n.toInt();
		return n.isInt() && ((i >= 0 && i <= 0xD7FF) || (i >= 0xE000 && i <= 0x10FFFF));
	}

	public static function ofInt(n:Int63):Int63 {
		if (!isValid(n)) throw new InvalidArgument(Printf.sprintf(Fmt.of("%X is not an Unicode scalar value"), [n]));
		return n;
	}

	public static function toChar(u:Int63):Int {
		var i = u.toInt();
		if (i > 255) throw new InvalidArgument(Printf.sprintf(Fmt.of("U+%04X is not a latin1 character"), [u]));
		return i;
	}

	public static inline function ofChar(c:Int):Int63
		return Int63.ofInt(c);

	public static inline function equal(a:Int63, b:Int63):Bool
		return Int63.eq(a, b);

	public static inline function compare(a:Int63, b:Int63):Int63
		return Int63.ofInt(Int63.compare(a, b));

	public static inline function utfDecodeIsValid(d:Int63):Bool
		return (d.toInt() >>> 27) == 1;

	public static inline function utfDecodeLength(d:Int63):Int63
		return Int63.ofInt((d.toInt() >>> 24) & 7);

	public static inline function utfDecodeUchar(d:Int63):Int63
		return Int63.ofInt(d.toInt() & 0xFFFFFF);

	public static inline function utfDecode(n:Int63, u:Int63):Int63
		return Int63.ofInt(((8 | n.toInt()) << 24) | u.toInt());

	public static inline function utfDecodeInvalid(n:Int63):Int63
		return Int63.ofInt((n.toInt() << 24) | 0xFFFD);

	public static function utf8ByteLength(u:Int63):Int63 {
		var i = u.toInt();
		return Int63.ofInt(i <= 0x7F ? 1 : (i <= 0x7FF ? 2 : (i <= 0xFFFF ? 3 : 4)));
	}
}
