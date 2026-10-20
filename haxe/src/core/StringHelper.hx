package core;

import core.ds.Failure;
import core.ds.InvalidArgument;

// port: OCaml strings are byte strings. The functions below that work byte by byte on
// identifiers and paths only change ASCII bytes, so they work on characters here.
class StringHelper {
	public static function uppercase(s:String):String {
		var bytes = new StringBuf();
		for (idx in 0...s.length) {
			var code = StringTools.fastCodeAt(s, idx);
			bytes.addChar(97 <= code && code <= 122 ? code - 32 : code);
		}
		return bytes.toString();
	}

	public static function capitalize(s:String):String {
		if (s.length == 0) return "";
		else {
			var code = StringTools.fastCodeAt(s, 0);
			return if (97 <= code && code <= 122) String.fromCharCode(code - 32) + s.substr(1) else s;
		}
	}

	public static function startsUppercaseIdentifier(x:String):Bool {
		if (x.length == 0) throw new InvalidArgument("Identifier name must not be empty");
		else {
			function loop(p:Int):Bool {
				return switch StringTools.fastCodeAt(x, p) {
					case c if (c >= "A".code && c <= "Z".code): true;
					case "_".code: p + 1 < x.length && loop(p + 1);
					case _: false;
				}
			}
			return loop(0);
		}
	}

	public static function checkUppercase(x:String):Void {
		if (x.length == 0) throw new Failure("empty part");
		else if (!startsUppercaseIdentifier(x)) throw new Failure("Class name must start with an uppercase letter");
	}

	public static function sEscape(s:String, hex:Bool = true):String {
		var b = new StringBuf();
		for (i in 0...s.length) {
			switch StringTools.fastCodeAt(s, i) {
				case "\n".code:
					b.add("\\n");
				case "\t".code:
					b.add("\\t");
				case "\r".code:
					b.add("\\r");
				case "\"".code:
					b.add("\\\"");
				case "\\".code:
					b.add("\\\\");
				case c if (c < 32 && hex):
					b.add("\\x" + StringTools.hex(c, 2));
				case c:
					b.addChar(c);
			}
		}
		return b.toString();
	}

	public static function escapeResName(name:String, allowed:Array<String>):String {
		var result = new StringBuf();
		// port: ExtString.String.replace_chars goes through the bytes; a non-ASCII character
		// is escaped as its UTF-8 bytes.
		var bytes = haxe.io.Bytes.ofString(name);
		for (index in 0...bytes.length) {
			var chr = bytes.get(index);
			if ((chr >= "a".code && chr <= "z".code)
				|| (chr >= "A".code && chr <= "Z".code)
				|| (chr >= "0".code && chr <= "9".code)
				|| chr == "_".code
				|| chr == ".".code) result.add(charEscaped(chr));
			else if (allowed.indexOf(String.fromCharCode(chr)) >= 0) result.add(charEscaped(chr));
			else result.add("-x" + chr);
		}
		return result.toString();
	}

	// port: OCaml's Char.escaped
	static function charEscaped(c:Int):String {
		return switch c {
			case "'".code: "\\'";
			case "\\".code: "\\\\";
			case "\n".code: "\\n";
			case "\t".code: "\\t";
			case "\r".code: "\\r";
			case 8: "\\b";
			case c if (c >= 32 && c <= 126): String.fromCharCode(c);
			case c: "\\" + StringTools.lpad(Std.string(c), "0", 3);
		}
	}

	public static function removeExtension(file:String):String {
		var dot = file.lastIndexOf(".");
		return dot < 0 ? file : file.substr(0, dot);
	}

	public static function extension(file:String):String {
		var dotPos = file.lastIndexOf(".");
		return dotPos < 0 ? file : file.substr(dotPos);
	}

	/* UTF8 */

	// port: whether the host's strings index code points: a character past U+FFFF
	// is one character, and the strings are UTF-8 bytes underneath, which may be
	// malformed (Bytes.getString copies them), as OCaml's (Eval, hxmc with -D
	// hxmc.strings=utf8). Else (utf16) they index UTF-16 code units: such a
	// character is a surrogate pair, and bytes that are not UTF-8 are lone
	// surrogates, U+DC80 to U+DCFF for 0x80 to 0xFF, which become those bytes
	// again (Bytes.ofString, the outputs: hxmc.rt.Str's decode and utf8Into).
	// A constant: the other host's code is dropped.
	public static inline final codePointHost:Bool = #if utf16 false #else true #end;

	// port: extlib's UTF8.validate, on the UTF-8 bytes of `s`.
	public static function validUtf8(s:String):Bool {
		var b = haxe.io.Bytes.ofString(s);
		var len = b.length;
		function trail(c:Int, i:Int, a:Int):Int {
			while (c > 0) {
				if (i >= len) return -1;
				var n = b.get(i);
				if (n < 0x80 || n >= 0xc0) return -1;
				a = (a << 6) | (n - 0x80);
				c--;
				i++;
			}
			return a;
		}
		var i = 0;
		while (i < len) {
			var n = b.get(i);
			if (n < 0x80) i += 1 else if (n < 0xc2) return false else if (n <= 0xdf) {
				if (trail(1, i + 1, n - 0xc0) < 0x80) return false;
				i += 2;
			} else if (n <= 0xef) {
				if (trail(2, i + 1, n - 0xe0) < 0x800) return false;
				i += 3;
			} else if (n <= 0xf7) {
				if (trail(3, i + 1, n - 0xf0) < 0x10000) return false;
				i += 4;
			} else if (n <= 0xfb) {
				if (trail(4, i + 1, n - 0xf8) < 0x200000) return false;
				i += 5;
			} else if (n <= 0xfd) {
				var t = trail(5, i + 1, n - 0xfc);
				if (t < 0 || (t >>> 16) < 0x400) return false;
				i += 6;
			} else
				return false;
		}
		return true;
	}

	// port: whether extlib's UTF8.validate fails on the UTF-8 bytes of `s`
	// (to_utf8's Malformed_code); on a UTF-16 host only a string with a
	// surrogate can fail (codePointHost).
	public static function malformedUtf8(s:String):Bool {
		if (!codePointHost) {
			var i = 0, n = s.length;
			while (i < n && (StringTools.fastCodeAt(s, i) & 0xF800) != 0xD800) i++;
			if (i == n) return false;
		}
		return !validUtf8(s);
	}

	// port: the string of `bytes`, as OCaml's strings take any bytes: getString,
	// which on Eval (a code point host) does not check them as toString does
	// ("Invalid string"); on a UTF-16 host bytes that are not UTF-8 become lone
	// surrogates (codePointHost).
	public static inline function ofBytes(bytes:haxe.io.Bytes):String return bytes.getString(0, bytes.length);

	// port: `s` as a UTF-8 decoder (sedlex's) reads its bytes: on a UTF-16 host
	// bytes that are not UTF-8 are lone surrogates (codePointHost), which their
	// neighbours can make UTF-8 again (pieces joined): the bytes decoded again.
	// Where they are not UTF-8, utf8Error says.
	public static function decodedUtf8(s:String):String {
		if (codePointHost || loneSurrogate(s) < 0) return s;
		return haxe.io.Bytes.ofString(s).toString();
	}

	// port: the index of the first character of `s` (decodedUtf8's) that is not
	// UTF-8, where sedlex's decoding raises MalFormed (-1: none): a lone
	// surrogate on a UTF-16 host, on a code point host the first byte that
	// does not decode (Unicode's table 3-7, as OCaml's String.get_utf_8_uchar).
	public static function utf8Error(s:String):Int {
		if (!codePointHost) return loneSurrogate(s);
		var bytes = haxe.io.Bytes.ofString(s);
		var i = 0, chars = 0;
		while (i < bytes.length) {
			var c = bytes.get(i++);
			if (c >= 0x80) {
				var n = c >= 0xc2 && c <= 0xdf ? 1 : c >= 0xe0 && c <= 0xef ? 2 : c >= 0xf0 && c <= 0xf4 ? 3 : -1;
				if (n < 0 || i + n > bytes.length) return chars;
				var first = bytes.get(i);
				if ((c == 0xe0 && first < 0xa0)
					|| (c == 0xed && first >= 0xa0)
					|| (c == 0xf0 && first < 0x90)
					|| (c == 0xf4 && first >= 0x90))
					return chars;
				for (_ in 0...n) {
					var next = bytes.get(i++);
					if (next < 0x80 || next > 0xbf) return chars;
				}
			}
			chars++;
		}
		return -1;
	}

	// port: the index of the first lone surrogate of `s` (-1: none).
	static function loneSurrogate(s:String):Int {
		var i = 0, n = s.length;
		while (i < n) {
			var c = StringTools.fastCodeAt(s, i);
			if ((c & 0xF800) == 0xD800) {
				if (c >= 0xDC00 || i + 1 == n || (StringTools.fastCodeAt(s, i + 1) & 0xFC00) != 0xDC00) return i;
				i++;
			}
			i++;
		}
		return -1;
	}

	// port: to_utf8's Malformed_code branch: the bytes of `s` as ISO-8859-1 characters.
	public static function isoToUtf8(s:String):String {
		var b = haxe.io.Bytes.ofString(s);
		var buf = new StringBuf();
		for (i in 0...b.length) buf.addChar(b.get(i));
		return buf.toString();
	}

	// port: returns (u8, ccount).
	public static function toUtf8(str:String, p:core.Globals.Pos):{value:String, utf16Length:Int} {
		var u8 = malformedUtf8(str) ? isoToUtf8(str) : str;
		var ccount = 0;
		for (c in new haxe.iterators.StringIteratorUnicode(u8)) {
			if ((c >= 0xD800 && c <= 0xDFFF) || c >= 0x110000) throw new Failure("Invalid unicode char");
			ccount++;
			if (c > 0x10000) ccount++;
		}
		return {value: u8, utf16Length: ccount};
	}

	// port: the buffer holds bytes, one character (0-255) each.
	public static function utf16Add(buf:StringBuf, c:Int):Void {
		function add(c:Int) {
			buf.addChar(c & 0xFF);
			buf.addChar(c >>> 8);
		}
		if (c >= 0 && c < 0x10000) {
			if (c >= 0xD800 && c <= 0xDFFF) throw new Failure("Invalid unicode char " + c);
			add(c);
		} else if (c < 0x110000) {
			var c = c - 0x10000;
			add((c >> 10) + 0xD800);
			add((c & 1023) + 0xDC00);
		} else
			throw new Failure("Invalid unicode char " + c);
	}

	// port: the result is a byte string, one character (0-255) per byte.
	public static function utf8ToUtf16(str:String, zt:Bool):String {
		var b = new StringBuf();
		for (c in new haxe.iterators.StringIteratorUnicode(str)) utf16Add(b, c);
		if (zt) utf16Add(b, 0);
		return b.toString();
	}

	// port: `str` is a byte string, one character (0-255) per byte.
	public static function utf16ToUtf8(str:String):String {
		var b = new StringBuf();
		function add(c:Int) b.addChar(c & 0xFF);
		function get(i:Int) return StringTools.fastCodeAt(str, i) & 0xFF;
		function loop(i:Int) {
			while (true) {
				if (i >= str.length) return;
				else {
					var c = get(i);
					if (c < 0x80) {
						add(c);
						i += 2;
					} else if (c < 0x800) {
						var c = c | (get(i + 1) << 8);
						add(c);
						add(c >> 8);
						i += 2;
					} else
						core.Globals.die("", "stringHelper.ml");
				}
			}
		}
		loop(0);
		return b.toString();
	}

	public static function urlEncode(s:String, addChar:String->Void):Void {
		var hex = "0123456789ABCDEF";
		// port: OCaml iterates the bytes
		var bytes = haxe.io.Bytes.ofString(s);
		for (i in 0...bytes.length) {
			var c = bytes.get(i);
			if ((c >= "A".code && c <= "Z".code)
				|| (c >= "a".code && c <= "z".code)
				|| (c >= "0".code && c <= "9".code)
				|| c == "_".code
				|| c == "-".code
				|| c == ".".code) addChar(String.fromCharCode(c));
			else {
				addChar("%");
				addChar(hex.charAt(c >> 4));
				addChar(hex.charAt(c & 0xF));
			}
		}
	}

	public static function urlEncodeString(s:String):String {
		var b = new StringBuf();
		urlEncode(s, b.add);
		return b.toString();
	}
}
