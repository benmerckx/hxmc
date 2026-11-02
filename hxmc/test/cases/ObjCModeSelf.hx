import hxmc.objc.AutoreleasePool;

// an Objective-C mode class's own `alloc` (declared by the compiler when the
// class does not), and Objective-C's related result type: a message of the
// init family gives an object of the receiver's class (docs/interop.md,
// "Objective-C classes in Haxe"), as clang types `[[C alloc] initX]`
@:hxmc.lib("/usr/lib/libobjc.A.dylib") @:hxmc.objc extern class NSObject {
	static function alloc():NSObject;
	function init():NSObject;
	function retainCount():Int;
}

@:hxmc.objc class Counter extends NSObject {
	public var n:Int;

	override function init():Counter {
		super.init();
		n = 10;
		return this;
	}

	public function bump():Int
		return ++n;
}

@:hxmc.objc class Doubler extends Counter {
	public function twice():Int
		return 2 * bump();
}

// declaring its own alloc still works
@:hxmc.objc class Declared extends NSObject {
	public extern static function alloc():Declared;
	public var tag:Int;
}

// an initializer named like the family but not of it (`initialize...`)
@:hxmc.objc class Plain extends NSObject {
	public function initialized():NSObject
		return this;
}

class ObjCModeSelf {
	static function main() AutoreleasePool.run(() -> {
		// (no cast: Counter.alloc() is a Counter, init() on it a Counter)
		final c = Counter.alloc().init();
		trace("counter", c.bump(), c.bump());
		final d:Doubler = Doubler.alloc().init();
		trace("doubler", d.twice(), d.n);
		final e = Declared.alloc().init();
		e.tag = 7;
		trace("declared", e.tag);
		final p = Plain.alloc().init();
		final o:NSObject = p.initialized();
		trace("plain", o == p);
	});
}
