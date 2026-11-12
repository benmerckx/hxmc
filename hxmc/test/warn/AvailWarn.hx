// A use of a declaration newer than the deployment target is a warning
// (-D hxmc.strict: an error) unless guarded: a C function, an Objective-C
// class, a property, an inlined enum constant, an enum's constructor, a Haxe
// class's `new`, a class extending a newer one; a guard of an older version
// and a function's own @:hxmc.available allow only up to theirs: a
// Platform.supports guard allows what the declaration it names needs (its
// own and its class's version), not more, in its then-branch, after `&&`,
// in the else-branch of its `!`, after `||` and after an early return; a
// version is its literal's text (11.10 is newer than 11.9); `#if (macos >= 11.0)` tests the deployment
// target (docs/interop.md, "Availability").
// target: macos-arm64
// warns: Lib.newer: macOS 14.0 and later, the deployment target is 11.0 (guard it with Platform.supports(...))
// warns: Future.alloc: macOS 13.0 and later, the deployment target is 11.0
// warns: Future.rate: macOS 14.2 and later, the deployment target is 11.0
// warns: Mode.Fast: macOS 14.0 and later
// warns: Shape.Ring: macOS 15.0 and later
// warns: new Box: macOS 12.0 and later
// warns: Sub extends Future: macOS 13.0 and later
// warns: Lib.newest: macOS 15.0 and later, this code is for 14.0 and later (guard it with Platform.supports(...))
// warns: Lib.newer: macOS 14.0 and later, this code is for 12.0 and later
// warns: Lib.patch: macOS 12.0.1 and later, the deployment target is 11.0 (guard it with Platform.supports(...))
// warns: Lib.tenth: macOS 11.10 and later, this code is for 11.9 and later
// warns: Future.rate: macOS 14.2 and later, this code is for 13.0 and later
// warns: Old.frame: macOS 14.0 and later, this code is for 13.0 and later
// warns: Platform.supports: no @:hxmc.available, every version has it (the test is true)
import hxmc.Platform;

@:hxmc.lib("/usr/lib/libobjc.A.dylib") @:hxmc.objc extern class NSObject {}

@:hxmc.framework("Foundation") @:hxmc.objc @:hxmc.available(macos >= 13.0, ios >= 16.0)
extern class Future extends NSObject {
	static function alloc():Future;
	@:hxmc.available(macos >= 14.2) var rate(get, never):Float;
	function get_rate():Float;
}

@:hxmc.framework("Foundation") @:hxmc.objc extern class Old extends NSObject {
	static function alloc():Old;
	@:hxmc.available(macos >= 14.0) function frame():Void;
}

class Sub extends Future {}

@:hxmc.c @:hxmc.lib("/usr/lib/libSystem.B.dylib") extern class Lib {
	@:hxmc.available(macos >= 14.0, ios >= 17.0) static function newer():Int;
	@:hxmc.available(macos >= 15.0) static function newest():Int;
	@:hxmc.available(macos >= version("12.0.1") || ios >= 15.0) static function patch():Int;
	@:hxmc.available(macos >= 11.10) static function tenth():Int;
	@:hxmc.available(macos >= 11.9) static function ninth():Int;
	static function old():Int;
}

enum abstract Mode(Int) to Int {
	var Slow = 0;
	@:hxmc.available(macos >= 14.0) var Fast = 1;
}

enum Shape {
	Dot;
	@:hxmc.available(macos >= 15.0) Ring;
}

@:hxmc.available(macos >= 12.0) class Box {
	public function new() {}
}

#if !(macos >= 11.0) #error "macos: the deployment target, 11.0" #end
#if (macos >= 11.1 || ios || maccatalyst) #error "macos: only the deployment target" #end

class AvailWarn {
	@:hxmc.available(macos >= 12.0) static function twelve():Int
		return Lib.newer();

	static function supports(o:Old) {
		// (a method, a class, a method that has its class's version, an enum constant)
		if (Platform.supports(o.frame)) o.frame();
		if (Platform.supports(Future)) trace(Future.alloc());
		if (Platform.supports(Future.alloc)) trace(Future.alloc().rate);
		if (Platform.supports(Future.alloc)) o.frame();
		if (Platform.supports(Mode.Fast)) trace((Mode.Fast : Int));
		if (Platform.supports(Lib.old)) trace(Lib.old());
		if (!Platform.supports(Lib.newer)) return;
		trace(Lib.newer());
	}

	// (several declarations, and the other shapes of a guard)
	static function shapes() {
		if (Platform.supports(Lib.newer) && Platform.supports(Lib.newest)) trace(Lib.newer() + Lib.newest());
		trace(Platform.supports(Lib.newest) && Lib.newest() > 0);
		trace(!Platform.supports(Lib.newer) || Lib.newer() > 0);
		if (!Platform.supports(Lib.newest)) trace("not yet") else trace(Lib.newest());
		while (true) {
			if (!Platform.supports(Lib.newest)) break;
			trace(Lib.newest());
			break;
		}
	}

	static function main() {
		trace(Lib.newer());
		var f = Future.alloc();
		trace(f.rate);
		trace((Mode.Fast : Int), Shape.Ring, new Box());
		if (Platform.supports(Lib.newer)) trace(Lib.newer() + Lib.newest());
		trace(Platform.supports(twelve) ? twelve() : 0);
		trace(Lib.patch());
		if (Platform.supports(Lib.ninth)) trace(Lib.tenth());
		if (Platform.supports(Lib.tenth)) trace(Lib.ninth() + Lib.tenth());
		supports(Old.alloc());
		shapes();
	}
}
