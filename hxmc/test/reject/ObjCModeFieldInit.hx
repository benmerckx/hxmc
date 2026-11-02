// An Objective-C class's instance variables start zeroed: no constructor runs initializers.
// expect: has an initializer, which nothing runs
// target: macos-arm64
@:hxmc.lib("/usr/lib/libobjc.A.dylib") @:hxmc.objc extern class NSObject {
	static function alloc():NSObject;
	function init():NSObject;
	function dealloc():Void;
}

@:hxmc.objc class C extends NSObject {
	public extern static function alloc():C;

	public var n:Int = 3;
}

class ObjCModeFieldInit {
	static function main()
		trace(C.alloc().init() != null);
}
