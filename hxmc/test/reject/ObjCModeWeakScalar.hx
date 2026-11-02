// Only an object can be held weakly.
// expect: only a field holding an object
// target: macos-arm64
@:hxmc.lib("/usr/lib/libobjc.A.dylib") @:hxmc.objc extern class NSObject {
	static function alloc():NSObject;
	function init():NSObject;
	function dealloc():Void;
}

@:hxmc.objc class C extends NSObject {
	public extern static function alloc():C;

	@:hxmc.weak public var n:Null<Int>;
}

class ObjCModeWeakScalar {
	static function main()
		trace(C.alloc().init() != null);
}
