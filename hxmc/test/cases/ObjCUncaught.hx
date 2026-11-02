// A Haxe exception leaving a method Objective-C called, in a program without
// Foundation (no NSException to raise it as, ObjCExceptions), ends the
// program as an uncaught one: the try around the message never sees it.
@:hxmc.lib("/usr/lib/libobjc.A.dylib") @:hxmc.objc extern class NSObject {
	static function alloc():NSObject;
	function init():NSObject;
	@:selector("performSelector:") function perform(sel:hxmc.objc.Selector):Null<NSObject>;
}

class Thrower extends NSObject {
	public function new() {}

	public function fail():Null<NSObject>
		throw "from a method Objective-C called";
}

class ObjCUncaught {
	static function main() {
		var t:NSObject = new Thrower();
		try {
			t.perform(hxmc.objc.Selector.of("fail"));
		} catch (e) {
			trace("caught past Objective-C: " + e);
		}
		trace("not reached");
	}
}
