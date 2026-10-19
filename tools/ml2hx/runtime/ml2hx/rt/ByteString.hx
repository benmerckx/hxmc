package ml2hx.rt;

// OCaml strings are byte strings: in Haxe a String of one unit (0-255) per
// byte, whatever the target's own encoding (on hxmc UTF-16 units). Text that
// leaves the program (paths, the environment, messages to the host's APIs)
// is converted at that boundary: the bytes are taken as UTF-8.
class ByteString {
	// the bytes of a Haxe string's UTF-8 encoding, as a byte string
	public static function ofNative(s:String):String {
		for (i in 0...s.length)
			if (StringTools.fastCodeAt(s, i) > 127) return ofBytes(haxe.io.Bytes.ofString(s), 0, -1);
		return s;
	}

	// the Haxe string a byte string's UTF-8 bytes encode
	public static function toNative(s:String):String {
		for (i in 0...s.length)
			if (StringTools.fastCodeAt(s, i) > 127) return toBytes(s).toString();
		return s;
	}

	public static function ofBytes(b:haxe.io.Bytes, pos:Int, len:Int):String {
		if (len < 0) len = b.length - pos;
		var buf = new StringBuf();
		for (i in pos...pos + len) buf.addChar(b.get(i));
		return buf.toString();
	}

	public static function toBytes(s:String):haxe.io.Bytes {
		var b = haxe.io.Bytes.alloc(s.length);
		for (i in 0...s.length) b.set(i, StringTools.fastCodeAt(s, i));
		return b;
	}
}
