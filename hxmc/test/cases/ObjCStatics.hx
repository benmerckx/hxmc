import hxmc.objc.Block;
import hxmc.unsafe.*;

// Objective-C objects and blocks made by statics' initializers, which run
// before the runtime's own: an instance of a Haxe subclass (paired with its
// object) and a block of a capturing closure, both used from main.
@:hxmc.objc extern class NSObject {
	static function alloc():NSObject;
	function init():NSObject;
	function description():NSObject;
}

class Counter extends NSObject {
	public var n = 40;

	public function new() {}

	public function bump():Int
		return ++n;
}

@:hxmc.c extern class Dispatch {
	static function dispatch_block_create(flags:Int64, block:Block<() -> Void>):Block<() -> Void>;
}

class ObjCStatics {
	static final counter = new Counter();
	static var hits = 0;
	static final block = {
		var by = 2;
		Dispatch.dispatch_block_create(0, () -> hits += by);
	};

	static function main() {
		Sys.println("counter " + counter.bump() + " " + counter.bump());
		var f:() -> Void = block;
		f();
		f();
		Sys.println("hits " + hits);
		Sys.println("fresh " + new Counter().bump());
	}
}
