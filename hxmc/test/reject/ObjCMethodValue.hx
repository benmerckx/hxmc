// An Objective-C method as a value is not a closure yet: an error that says
// what to write instead (not a symbol missing at load time).
// expect: Objective-C method description as a value: wrap the message in a function
@:hxmc.lib("/usr/lib/libobjc.A.dylib") @:hxmc.objc extern class NSObject {
	static function alloc():NSObject;
	function init():NSObject;
	function description():NSObject;
}

class ObjCMethodValue {
	static function main() {
		var o = NSObject.alloc().init();
		var f = o.description;
		trace(f() != null);
	}
}
