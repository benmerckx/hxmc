import hxmc.unsafe.*;

@:hxmc.objc extern class NSObject {
	static function alloc():NSObject;
	function init():NSObject;
	var description(default, null):NSString;
}

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSString extends NSObject {
	static function alloc():NSString;
	function initWithUTF8String(s:CString):NSString;
	var UTF8String(default, null):CString;
	var length(default, null):Int;
	@:getter("isAbsolutePath") var absolutePath(default, null):Bool;
}

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSNumber extends NSObject {
	static function alloc():NSNumber;
	function initWithInt(i:Int):NSNumber;
	function initWithDouble(d:Float):NSNumber;
	var doubleValue(default, null):Float;
}

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSURLComponents extends NSObject {
	static function alloc():NSURLComponents;
	override function init():NSURLComponents;
	var scheme:Null<NSString>;
	var host:Null<NSString>;
	var path:Null<NSString>;
	var port:Null<NSNumber>;
	var string(default, null):Null<NSString>;
}

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSProcessInfo extends NSObject {
	static var processInfo(default, null):NSProcessInfo;
	var processIdentifier(default, null):Int;
	var processName(default, null):NSString;
}

class ObjCDeclarations {
	static inline function ns(s:String):NSString
		return NSString.alloc().initWithUTF8String(cast Mem.cstr(s));

	static function str(s:Null<NSString>):String
		return s == null ? "nil" : s.UTF8String.toString();

	static function main() {
		var s = ns("/usr/bin");
		trace(str(s), s.length, s.absolutePath, ns("relative").absolutePath);
		trace(NSNumber.alloc().initWithInt(42).doubleValue, NSNumber.alloc().initWithDouble(2.5).doubleValue);
		var c = NSURLComponents.alloc().init();
		trace(str(c.string));
		c.scheme = ns("https");
		c.host = ns("haxe.org");
		c.path = ns("/manual");
		c.port = NSNumber.alloc().initWithInt(8443);
		trace(str(c.string));
		c.port = null;
		trace(str(c.string), str(c.host));
		var p = NSProcessInfo.processInfo;
		trace(p.processName != null, p.processIdentifier > 0);
		trace(str(NSObject.alloc().init().description).substr(0, 10));
	}
}
