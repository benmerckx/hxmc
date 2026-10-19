package ml2hx.std;

import String;
import StdTypes;
import ml2hx.rt.*;
import ml2hx.std.Ipaddr;

typedef IpaddrV4T = haxe.Int32;

@:allow(ml2hx.std.Ipaddr)
@:allow(ml2hx.std.Ipaddr_V6)
class Ipaddr_V4 {
	static function rejectOctal(s:String, i:Ref<Int>) {
		if (i.value + 1 < s.length && StringTools.fastCodeAt(s, i.value) == "0".code && Ipaddr.digit(StringTools.fastCodeAt(s, i.value + 1)) >= 0 && Ipaddr.digit(StringTools.fastCodeAt(s, i.value + 1)) < 10)
			throw new IpaddrParseError("octal notation disallowed", s);
	}
	static function ofStringRaw(s:String, i:Ref<Int>):IpaddrV4T {
		var parts = [];
		for (k in 0...4) {
			if (k > 0) Ipaddr.expectChar(s, i, ".".code);
			rejectOctal(s, i);
			parts.push(Ipaddr.parseInt(10, s, i));
		}
		var names = ["first", "second", "third", "fourth"];
		for (k in 0...4) if (parts[k] & 0xff != parts[k]) throw new IpaddrParseError(names[k] + " octet out of bounds", s);
		return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3];
	}
	public static function ofStringExn(s:String):IpaddrV4T {
		var o = new Ref(0);
		var x = ofStringRaw(s, o);
		Ipaddr.expectEnd(s, o);
		return x;
	}
	public static function toString(i:IpaddrV4T):String return '${(i >>> 24) & 255}.${(i >>> 16) & 255}.${(i >>> 8) & 255}.${i & 255}';
}
