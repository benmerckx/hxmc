import hxmc.unsafe.*;

@:hxmc.struct class Rect {
	public var x:Float;
	public var y:Float;
	public var w:Float;
	public var h:Float;
	public function new(x, y, w, h) {
		this.x = x; this.y = y; this.w = w; this.h = h;
	}
}

@:hxmc.objc extern class NSObject {
	static function alloc():NSObject;
	function init():NSObject;
	function description():NSString;
	function retainCount():Int;
	function isKindOfClass(cls:Ptr):Bool;
}

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSString extends NSObject {
	static function stringWithUTF8String(s:CString):NSString;
	function UTF8String():CString;
	function length():Int;
	function stringByAppendingString(other:NSString):NSString;
	function rangeOfString(s:NSString):Range;
}

@:hxmc.struct class Range {
	public var location:Int64;
	public var length:Int64;
}

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSMutableDictionary extends NSObject {
	static function dictionary():NSMutableDictionary;
	function setObject(o:NSObject, forKey:NSObject):Void;
	function objectForKey(k:NSObject):Null<NSObject>;
	function count():Int;
}

@:hxmc.framework("Foundation") @:hxmc.objc("NSValue") extern class Value extends NSObject {
	static function valueWithRect(r:Rect):Value;
	function rectValue():Rect;
}

@:hxmc.c @:hxmc.lib("/System/Library/Frameworks/Foundation.framework/Foundation") extern class Foundation {
	static function NSLog(fmt:Ptr):Void;
}

class ObjCMessages {
	static inline function ns(s:String):NSString
		return NSString.stringWithUTF8String(cast Mem.cstr(s));

	static function main() {
		var hello = ns("Hello, ");
		var s = hello.stringByAppendingString(ns("Objective-C"));
		trace(s.UTF8String().toString(), s.length());
		var r = s.rangeOfString(ns("Objective"));
		trace(r.location, r.length);
		var d = NSMutableDictionary.dictionary();
		d.setObject(ns("value"), ns("key"));
		trace(d.count(), (cast d.objectForKey(ns("key")) : NSString).UTF8String().toString());
		trace(d.objectForKey(ns("missing")) == null);
		var v = Value.valueWithRect(new Rect(1, 2, 3, 4));
		var back = v.rectValue();
		trace(back.x, back.y, back.w, back.h);
		trace(d.description().UTF8String().toString());
	}
}
