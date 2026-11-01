// A method of an Objective-C class is an Objective-C method: its types are C's.
// expect: takes and returns what C has
// target: macos-arm64
@:hxmc.lib("/usr/lib/libobjc.A.dylib") @:hxmc.objc extern class NSObject {
	static function alloc():NSObject;
	function init():NSObject;
	function dealloc():Void;
}

@:hxmc.objc class C extends NSObject {
	public extern static function alloc():C;

	public function greet(who:String):Int
		return who.length;
}

class ObjCModeMethodTypes {
	static function main()
		trace(C.alloc().init() != null);
}
