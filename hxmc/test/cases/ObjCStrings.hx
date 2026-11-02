// hxmc.objc.Strings: Haxe strings to NSStrings and back, unit for unit
// (one-byte, two-byte, a lone surrogate, nil)
import hxmc.objc.Strings;
import hxmc.unsafe.*;

@:hxmc.lib("/usr/lib/libobjc.A.dylib") @:hxmc.objc extern class NSObject {}

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSString extends NSObject {
	var length(default, null):Int64;
	function characterAtIndex(i:Int64):Int;
	function stringByAppendingString(s:NSString):NSString;
	var UTF8String(default, null):CString;
	static function stringWithUTF8String(s:CString):NSString;
}

class ObjCStrings {
	static function ns(s:String):NSString
		return cast Strings.toNSString(s);

	static function main() {
		var cases = ["", "plain", "café", "€uro", "😀 emoji", "lone " + String.fromCharCode(0xDC80) + " surrogate", [for (i in 0...300) String.fromCharCode(i)].join("")];
		for (s in cases) {
			var n = ns(s);
			var back = Strings.ofNSString(cast n);
			trace(s.length + " " + (n.length : Int) + " " + (back == s) + " " + (back.length));
		}
		var both = Strings.ofNSString(cast ns("ab").stringByAppendingString(ns("€")));
		trace(both + " " + (both == "ab€"));
		trace(Strings.ofNSString(Ptr.nil()) == null, Strings.toNSString(null).isNull());
	}
}

