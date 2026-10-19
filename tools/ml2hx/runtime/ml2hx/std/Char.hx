package ml2hx.std;

import Array;
import ml2hx.rt.*;

// Stdlib.Char (a char is its code, an Int)
class Char {
	public static inline function code(c:Int):Int63
		return Int63.ofInt(c);

	public static function chr(n:Int63):Int {
		if (Int63.lt(n, Int63.zero) || Int63.gt(n, Int63.ofInt(255))) throw new InvalidArgument("Char.chr");
		return n.toInt();
	}

	public static inline function unsafeChr(n:Int63):Int
		return n.toInt();

	public static function escaped(c:Int):std.String {
		return switch c {
			case "'".code: "\\'";
			case "\\".code: "\\\\";
			case "\n".code: "\\n";
			case "\t".code: "\\t";
			case "\r".code: "\\r";
			case 8: "\\b";
			case c if (c >= 32 && c <= 126): std.String.fromCharCode(c);
			case c:
				"\\" + std.String.fromCharCode(48 + Std.int(c / 100)) + std.String.fromCharCode(48 + Std.int(c / 10) % 10)
					+ std.String.fromCharCode(48 + c % 10);
		}
	}

	public static inline function lowercaseAscii(c:Int):Int
		return c >= "A".code && c <= "Z".code ? c + 32 : c;

	public static inline function uppercaseAscii(c:Int):Int
		return c >= "a".code && c <= "z".code ? c - 32 : c;

	public static inline function compare(a:Int, b:Int):Int63
		return Int63.ofInt(a - b);

	public static inline function equal(a:Int, b:Int):Bool
		return a == b;

	// Char.hash: Hashtbl.hash on the char
	public static inline function hash(c:Int):Int63
		return Int63.ofInt(Poly.hash(c));
}
