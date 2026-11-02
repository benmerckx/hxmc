// An Objective-C class (@:hxmc.objc) has no Haxe constructor: Objective-C makes its objects.
// expect: has no Haxe constructor
// target: macos-arm64
@:hxmc.lib("/usr/lib/libobjc.A.dylib") @:hxmc.objc extern class NSObject {
	static function alloc():NSObject;
	function init():NSObject;
	function dealloc():Void;
}

@:hxmc.objc class C extends NSObject {
	public extern static function alloc():C;

	public function new() {}
}

class ObjCModeNew {
	static function main()
		trace(C.alloc().init() != null);
}
