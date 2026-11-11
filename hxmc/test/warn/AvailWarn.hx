// A use of a declaration newer than the deployment target is a warning
// (-D hxmc.strict: an error) unless guarded: a C function, an Objective-C
// class, a property, an inlined enum constant, an enum's constructor, a Haxe
// class's `new`, a class extending a newer one; a guard of an older version
// and a function's own @:hxmc.available allow only up to theirs
// (docs/interop.md, "Availability").
// target: macos-arm64
// warns: Lib.newer: macOS 14.0 and later, the deployment target is 11.0 (guard it with Platform.available("macos 14.0"))
// warns: Future.alloc: macOS 13.0 and later, the deployment target is 11.0
// warns: Future.rate: macOS 14.2 and later, the deployment target is 11.0
// warns: Mode.Fast: macOS 14.0 and later
// warns: Shape.Ring: macOS 15.0 and later
// warns: new Box: macOS 12.0 and later
// warns: Sub extends Future: macOS 13.0 and later
// warns: Lib.newest: macOS 15.0 and later, this code is for 14.0 and later (guard it with Platform.available("macos 15.0"))
// warns: Lib.newer: macOS 14.0 and later, this code is for 12.0 and later
import hxmc.Platform;

@:hxmc.lib("/usr/lib/libobjc.A.dylib") @:hxmc.objc extern class NSObject {}

@:hxmc.framework("Foundation") @:hxmc.objc @:hxmc.available("macos 13.0", "ios 16.0")
extern class Future extends NSObject {
	static function alloc():Future;
	@:hxmc.available("macos 14.2") var rate(get, never):Float;
	function get_rate():Float;
}

class Sub extends Future {}

@:hxmc.c @:hxmc.lib("/usr/lib/libSystem.B.dylib") extern class Lib {
	@:hxmc.available("macos 14.0", "ios 17.0") static function newer():Int;
	@:hxmc.available("macos 15.0") static function newest():Int;
}

enum abstract Mode(Int) to Int {
	var Slow = 0;
	@:hxmc.available("macos 14.0") var Fast = 1;
}

enum Shape {
	Dot;
	@:hxmc.available("macos 15.0") Ring;
}

@:hxmc.available("macos 12.0") class Box {
	public function new() {}
}

class AvailWarn {
	@:hxmc.available("macos 12.0") static function twelve():Int
		return Lib.newer();

	static function main() {
		trace(Lib.newer());
		var f = Future.alloc();
		trace(f.rate);
		trace((Mode.Fast : Int), Shape.Ring, new Box());
		if (Platform.available("macos 14.0")) trace(Lib.newer() + Lib.newest());
		trace(Platform.available("macos 12.0") ? twelve() : 0);
	}
}
