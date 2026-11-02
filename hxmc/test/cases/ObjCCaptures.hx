import hxmc.objc.AutoreleasePool;
import hxmc.unsafe.*;

@:hxmc.lib("/usr/lib/libobjc.A.dylib") @:hxmc.objc extern class NSObject {
	static function alloc():NSObject;
	function init():NSObject;
	function retainCount():Int64;
}

@:hxmc.c @:hxmc.lib("/usr/lib/libobjc.A.dylib") extern class Rt {
	static function objc_storeWeak(loc:Ptr, o:Null<NSObject>):Null<NSObject>;
	static function objc_loadWeakRetained(loc:Ptr):Null<NSObject>;
	static function objc_release(o:NSObject):Void;
}

class ObjCCaptures {
	static final slots = LibC.malloc(8 * 16);
	static var get:Null<() -> Null<NSObject>>;
	static var set:Null<NSObject->Void>;
	static var many:Array<() -> NSObject> = [];
	static var shared:Null<NSObject>;

	static function watch(i:Int, o:NSObject) {
		Mem.setPtr(slots, 8 * i, Ptr.nil());
		Rt.objc_storeWeak(slots.add(8 * i), o);
	}

	static function alive(i:Int):Bool {
		var o = Rt.objc_loadWeakRetained(slots.add(8 * i));
		if (o == null) return false;
		Rt.objc_release(o);
		return true;
	}

	static function collect() {
		hxmc.rt.Gc.collect(true);
		hxmc.rt.Gc.collect(true);
	}

	// a closure over an argument it assigns (the argument's box)
	static function cell(o:Null<NSObject>) {
		get = () -> o;
		set = x -> o = x;
	}

	static function main() {
		// captured: kept past its pool by the closure, released when it dies
		AutoreleasePool.run(() -> {
			var o = NSObject.alloc().init();
			watch(0, o);
			get = () -> o;
		});
		AutoreleasePool.run(() -> trace("captured, past its pool: " + alive(0) + ", get " + (get() != null)));
		get = null;
		collect();
		trace("closure collected: " + alive(0));
		// captured by a closure inside a closure: both hold it
		AutoreleasePool.run(() -> {
			var o = NSObject.alloc().init();
			watch(1, o);
			get = (() -> () -> o)();
		});
		collect();
		trace("nested, outer collected: " + alive(1));
		get = null;
		collect();
		trace("nested collected: " + alive(1));
		// a captured variable assigned: its box holds the value; the
		// overwritten one is released
		AutoreleasePool.run(() -> {
			var o:Null<NSObject> = NSObject.alloc().init();
			watch(2, o);
			get = () -> o;
			set = x -> o = x;
		});
		trace("assigned, past its pool: " + alive(2));
		AutoreleasePool.run(() -> {
			var n = NSObject.alloc().init();
			watch(3, n);
			set(n);
		});
		trace("overwritten: " + alive(2) + ", new " + alive(3));
		AutoreleasePool.run(() -> set(null));
		trace("set to null: " + alive(3) + ", get " + (get() == null));
		// an argument captured and assigned
		AutoreleasePool.run(() -> {
			var o = NSObject.alloc().init();
			watch(4, o);
			cell(o);
		});
		trace("argument, past its pool: " + alive(4));
		get = null;
		set = null;
		collect();
		trace("argument's closures collected: " + alive(4));
		// many closures over one object: each holds a reference, all given back
		AutoreleasePool.run(() -> {
			shared = NSObject.alloc().init();
			var o = shared;
			for (i in 0...10000) many.push(() -> o);
		});
		trace("10000 closures, retainCount " + shared.retainCount());
		many = [];
		collect();
		trace("collected, retainCount " + shared.retainCount());
		// many closures over their own objects
		AutoreleasePool.run(() -> {
			for (i in 0...10000) {
				var o = NSObject.alloc().init();
				if (i == 1234) watch(5, o);
				many.push(() -> o);
			}
		});
		trace("10000 objects, before collecting: " + alive(5));
		many = [];
		collect();
		trace("collected: " + alive(5));
	}
}
