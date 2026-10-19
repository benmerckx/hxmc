package ml2hx.std;

import Array;
import String;
import StdTypes;
import ml2hx.rt.*;

// Stdlib.Buffer over a StringBuf (appends and contents are the hot path);
// nth and truncate, rare, read the contents.
class BufferT {
	public var sb:StringBuf;
	public final initial:Int;

	public function new(n:Int) {
		sb = new StringBuf();
		initial = n;
	}
}

class Buffer {
	public static function create(n:Int63):BufferT
		return new BufferT(n.toInt());

	public static inline function contents(b:BufferT):String
		return b.sb.toString();

	public static inline function toBytes(b:BufferT):haxe.io.Bytes
		return ByteString.toBytes(b.sb.toString());

	public static function sub(b:BufferT, ofs:Int63, len:Int63):String {
		var s = b.sb.toString();
		if (Int63.lt(ofs, Int63.zero) || Int63.lt(len, Int63.zero) || ofs.toInt() > s.length - len.toInt()) throw new InvalidArgument("Buffer.sub");
		return s.substr(ofs.toInt(), len.toInt());
	}

	public static function blit(b:BufferT, srcOfs:Int63, dst:haxe.io.Bytes, dstOfs:Int63, len:Int63):Unit {
		var s = b.sb.toString();
		if (Int63.lt(len, Int63.zero) || Int63.lt(srcOfs, Int63.zero) || srcOfs.toInt() > s.length - len.toInt() || Int63.lt(dstOfs, Int63.zero)
			|| dstOfs.toInt() > dst.length - len.toInt())
			throw new InvalidArgument("Buffer.blit");
		return ml2hx.std.String.blit(s, srcOfs, dst, dstOfs, len);
	}

	public static function nth(b:BufferT, i:Int63):Int {
		var s = b.sb.toString();
		if (Int63.lt(i, Int63.zero) || i.toInt() >= s.length) throw new InvalidArgument("Buffer.nth");
		return StringTools.fastCodeAt(s, i.toInt());
	}

	public static inline function length(b:BufferT):Int63
		return Int63.ofInt(b.sb.length);

	public static function clear(b:BufferT):Unit {
		b.sb = new StringBuf();
		return Unit.value;
	}

	public static function reset(b:BufferT):Unit {
		b.sb = new StringBuf();
		return Unit.value;
	}

	public static function truncate(b:BufferT, len:Int63):Unit {
		if (Int63.lt(len, Int63.zero) || len.toInt() > b.sb.length) throw new InvalidArgument("Buffer.truncate");
		var s = b.sb.toString().substr(0, len.toInt());
		b.sb = new StringBuf();
		b.sb.add(s);
		return Unit.value;
	}

	public static inline function addChar(b:BufferT, c:Int):Unit {
		b.sb.addChar(c);
		return Unit.value;
	}

	public static inline function addString(b:BufferT, s:String):Unit {
		b.sb.add(s);
		return Unit.value;
	}

	public static function addBytes(b:BufferT, s:haxe.io.Bytes):Unit {
		for (i in 0...s.length) b.sb.addChar(s.get(i));
		return Unit.value;
	}

	public static function addSubstring(b:BufferT, s:String, ofs:Int63, len:Int63):Unit {
		var o = ofs.toInt(), n = len.toInt();
		if (Int63.lt(ofs, Int63.zero) || Int63.lt(len, Int63.zero) || o > s.length - n) throw new InvalidArgument("Buffer.add_substring/add_subbytes");
		b.sb.addSub(s, o, n);
		return Unit.value;
	}

	public static function addSubbytes(b:BufferT, s:haxe.io.Bytes, ofs:Int63, len:Int63):Unit {
		var o = ofs.toInt(), n = len.toInt();
		if (Int63.lt(ofs, Int63.zero) || Int63.lt(len, Int63.zero) || o > s.length - n) throw new InvalidArgument("Buffer.add_substring/add_subbytes");
		for (i in o...o + n) b.sb.addChar(s.get(i));
		return Unit.value;
	}

	public static function addBuffer(b:BufferT, other:BufferT):Unit {
		b.sb.add(other.sb.toString());
		return Unit.value;
	}

	public static function addUtf_8Uchar(b:BufferT, u:Int63):Unit {
		var c = u.toInt();
		if (c <= 0x7F)
			b.sb.addChar(c);
		else if (c <= 0x7FF) {
			b.sb.addChar(0xC0 | (c >> 6));
			b.sb.addChar(0x80 | (c & 0x3F));
		} else if (c <= 0xFFFF) {
			b.sb.addChar(0xE0 | (c >> 12));
			b.sb.addChar(0x80 | ((c >> 6) & 0x3F));
			b.sb.addChar(0x80 | (c & 0x3F));
		} else {
			b.sb.addChar(0xF0 | (c >> 18));
			b.sb.addChar(0x80 | ((c >> 12) & 0x3F));
			b.sb.addChar(0x80 | ((c >> 6) & 0x3F));
			b.sb.addChar(0x80 | (c & 0x3F));
		}
		return Unit.value;
	}

	public static function outputBuffer(oc:Stdlib.StdlibOutChannel, b:BufferT):Unit
		return Stdlib.outputString(oc, b.sb.toString());

	public static function addChannel(b:BufferT, ic:Stdlib.StdlibInChannel, n:Int63):Unit {
		var k = n.toInt();
		for (_ in 0...k) {
			var c = ic.readByte();
			if (c < 0) throw EndOfFile.instance;
			b.sb.addChar(c);
		}
		return Unit.value;
	}
}
