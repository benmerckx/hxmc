// An Objective-C object cannot own a Haxe value (yet): only weakly.
// expect: declare it @:hxmc.weak
// target: macos-arm64
@:hxmc.lib("/usr/lib/libobjc.A.dylib") @:hxmc.objc extern class NSObject {
	static function alloc():NSObject;
	function init():NSObject;
	function dealloc():Void;
}

@:hxmc.objc class C extends NSObject {
	public extern static function alloc():C;

	public var name:String;
}

class ObjCModeHaxeField {
	static function main()
		trace(C.alloc().init() != null);
}
