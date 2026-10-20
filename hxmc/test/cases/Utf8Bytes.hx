// Bytes that are not UTF-8 decode to one unit each, U+DC80 to U+DCFF for 0x80
// to 0xFF, which encode back to those bytes (hxmc.rt.Str's decode and
// utf8Into): bytes decoded and encoded again are the same bytes.
class Utf8Bytes {
	static function units(s:String):String
		return [for (i in 0...s.length) StringTools.hex(s.charCodeAt(i), 4)].join(" ");

	static function main() {
		// well-formed; a lone lead byte, cut short, a stray continuation byte,
		// 0xFF, a surrogate's, an overlong and a past-U+10FFFF encoding
		for (hex in ["61c3a9e68080f09f9880efbfbd", "61e662", "e6", "e680", "c328", "80", "ff", "eda080", "c080", "f4908080", "f88080808080"]) {
			var s = haxe.io.Bytes.ofHex(hex).toString();
			var back = haxe.io.Bytes.ofString(s).toHex();
			Sys.println(hex + ": " + units(s) + (back == hex ? "" : " -> " + back));
		}
		// a lone surrogate the program made: its three bytes, but U+DC80 to U+DCFF
		Sys.println(haxe.io.Bytes.ofString(String.fromCharCode(0xD800)).toHex() + " " + haxe.io.Bytes.ofString(String.fromCharCode(0xDC7F)).toHex() + " "
			+ haxe.io.Bytes.ofString(String.fromCharCode(0xDCE6)).toHex() + " " + haxe.io.Bytes.ofString(String.fromCharCode(0xDD00)).toHex());
		// pieces that join into UTF-8: decoded again, one character
		var s = haxe.io.Bytes.ofHex("c3").toString() + haxe.io.Bytes.ofHex("a9").toString();
		var b = haxe.io.Bytes.ofString(s);
		Sys.println(units(s) + " -> " + b.toHex() + " -> " + units(b.toString()));
		// through a buffer and a substring
		var bb = new haxe.io.BytesBuffer();
		bb.addString("x" + s.substr(1) + "y");
		Sys.println(bb.getBytes().toHex());
	}
}
