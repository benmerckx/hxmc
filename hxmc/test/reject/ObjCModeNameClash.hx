// Two classes this program registers under one Objective-C name.
// expect: Objective-C class name Twin: both
@:hxmc.lib("/usr/lib/libobjc.A.dylib") @:hxmc.objc extern class NSObject {
	static function alloc():NSObject;
	function init():NSObject;
}

@:hxmc.objc("Twin") class A extends NSObject {
	public extern static function alloc():A;
}

@:hxmc.objc("Twin") class B extends NSObject {
	public extern static function alloc():B;
}

class ObjCModeNameClash {
	static function main() {
		trace(A.alloc().init() != null);
		trace(B.alloc().init() != null);
	}
}
