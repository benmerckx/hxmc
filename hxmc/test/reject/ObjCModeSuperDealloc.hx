// An Objective-C class's dealloc sends super's itself, after releasing its instance variables.
// expect: super.dealloc()
// target: macos-arm64
@:hxmc.lib("/usr/lib/libobjc.A.dylib") @:hxmc.objc extern class NSObject {
	static function alloc():NSObject;
	function init():NSObject;
	function dealloc():Void;
}

@:hxmc.objc class C extends NSObject {
	public extern static function alloc():C;

	override function dealloc() {
		super.dealloc();
	}
}

class ObjCModeSuperDealloc {
	static function main()
		trace(C.alloc().init() != null);
}
