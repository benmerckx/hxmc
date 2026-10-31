// abstracts over Objective-C classes (as hxmc-objc-extern-gen's NSStringArg):
// an id as the abstract is, and as Null<> of it (not boxed), from Haxe values
// by @:from, passed to messages and C functions, stored, read back
import hxmc.objc.Strings;

@:hxmc.lib("/usr/lib/libobjc.A.dylib") @:hxmc.objc extern class NSObject {}

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSString extends NSObject {
	function stringByAppendingString(s:StringArg):NSString;
}

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSNumber extends NSObject {
	static function numberWithInt(v:Int):NSNumber;
	static function numberWithDouble(v:Float):NSNumber;
	var doubleValue(default, null):Float;
	function isEqualToNumber(n:Null<NumberArg>):Bool;
}

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSMutableArray extends NSObject {
	static function array():NSMutableArray;
	function addObject(o:NSObject):Void;
	var count(default, null):hxmc.I64;
	function objectAtIndex(i:hxmc.I64):NSObject;
}

@:forward abstract StringArg(NSString) from NSString to NSString {
	@:from static inline function ofString(s:String):StringArg
		return cast Strings.toNSString(s);
}

@:forward abstract NumberArg(NSNumber) from NSNumber to NSNumber {
	@:from static inline function ofInt(v:Int):NumberArg
		return NSNumber.numberWithInt(v);

	@:from static inline function ofFloat(v:Float):NumberArg
		return NSNumber.numberWithDouble(v);
}

@:hxmc.c @:hxmc.framework("CoreFoundation") extern class CF {
	static function CFStringGetLength(s:Null<StringArg>):hxmc.I64;
}

class ObjCAbstracts {
	static var kept:Null<NumberArg>;

	static function str(s:NSString):String
		return Strings.ofNSString(cast s);

	static function main() {
		var s:NSString = cast Strings.toNSString("ab");
		trace(str(s.stringByAppendingString("cd")));
		trace((CF.CFStringGetLength("héllo") : Int), (CF.CFStringGetLength(s) : Int));
		var three = NSNumber.numberWithInt(3);
		trace(three.isEqualToNumber(3), three.isEqualToNumber(3.5));
		var n:Null<NumberArg> = 2.5;
		trace(n.doubleValue);
		kept = 7;
		hxmc.rt.Gc.collect(true);
		trace(kept.doubleValue);
		var a = NSMutableArray.array();
		var arg:NumberArg = 4;
		a.addObject(arg);
		trace((a.count : Int), (cast a.objectAtIndex(0) : NSNumber).doubleValue);
	}
}
