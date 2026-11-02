// An Objective-C class implements protocols, not Haxe interfaces.
// expect: implements the Haxe interface Named
// target: macos-arm64
@:hxmc.lib("/usr/lib/libobjc.A.dylib") @:hxmc.objc extern class NSObject {
	static function alloc():NSObject;
	function init():NSObject;
	function dealloc():Void;
}

interface Named {
	function name():Int;
}

@:hxmc.objc class C extends NSObject implements Named {
	public extern static function alloc():C;

	public function name():Int
		return 1;
}

class ObjCModeInterface {
	static function main()
		trace(C.alloc().init() != null);
}
