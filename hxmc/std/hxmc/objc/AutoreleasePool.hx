package hxmc.objc;

import hxmc.unsafe.Ptr;

// An autorelease pool (docs/interop.md, "Objective-C"): the objects
// autoreleased while `f` runs (every id a message returns that nothing keeps)
// are released when it returns, or throws. The run loop drains a pool per
// event; code outside it (a loop of many messages, a thread hxmc started)
// drains its own with run.
class AutoreleasePool {
	public static function run(f:() -> Void) {
		var pool = Libobjc.objc_autoreleasePoolPush();
		try {
			f();
		} catch (e) {
			Libobjc.objc_autoreleasePoolPop(pool);
			throw e;
		}
		Libobjc.objc_autoreleasePoolPop(pool);
	}
}

@:hxmc.c @:hxmc.lib("/usr/lib/libobjc.A.dylib") private extern class Libobjc {
	static function objc_autoreleasePoolPush():Ptr;
	static function objc_autoreleasePoolPop(pool:Ptr):Void;
}
