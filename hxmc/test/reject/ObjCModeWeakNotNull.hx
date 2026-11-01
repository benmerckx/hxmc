// A weak field becomes null once its object is gone: its type says so.
// expect: declare it Null<...>
// target: macos-arm64
@:hxmc.lib("/usr/lib/libobjc.A.dylib") @:hxmc.objc extern class NSObject {
	static function alloc():NSObject;
	function init():NSObject;
	function dealloc():Void;
}

class Attrs {
	public function new() {}
}

@:hxmc.objc class C extends NSObject {
	public extern static function alloc():C;

	@:hxmc.weak public var attrs:Attrs;
}

class ObjCModeWeakNotNull {
	static function main()
		trace(C.alloc().init() != null);
}
