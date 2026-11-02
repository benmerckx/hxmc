import hxmc.unsafe.*;

@:hxmc.lib("/usr/lib/libobjc.A.dylib") @:hxmc.objc extern class NSObject {
	static function alloc():NSObject;
	function init():NSObject;
	function retainCount():Int64;
	function copy():NSObject;
}

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSMutableString extends NSObject {
	static function alloc():NSMutableString;
	override function init():NSMutableString;
}

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSMutableArray extends NSObject {
	static function alloc():NSMutableArray;
	override function init():NSMutableArray;
	function addObject(o:NSObject):Void;
	function removeAllObjects():Void;
}

@:hxmc.c @:hxmc.lib("/usr/lib/libobjc.A.dylib") extern class Rt {
	static function objc_storeWeak(loc:Ptr, o:Null<NSObject>):Null<NSObject>;
	static function objc_loadWeakRetained(loc:Ptr):Null<NSObject>;
	static function objc_release(o:NSObject):Void;
	static function objc_autoreleasePoolPush():Ptr;
	static function objc_autoreleasePoolPop(pool:Ptr):Void;
}

class Holder {
	public var o:Null<NSObject>;
	public var label = "holder";
	public function new(o) this.o = o;
}

class ObjCOwnership {
	static var kept:Null<NSObject>;
	static final slots = LibC.malloc(8 * 16);

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

	static function pool(f:() -> Void) {
		var p = Rt.objc_autoreleasePoolPush();
		f();
		Rt.objc_autoreleasePoolPop(p);
	}

	static var h:Holder;

	static function makeHolders() {
		var p = Rt.objc_autoreleasePoolPush();
		var hs = [for (i in 0...10000) new Holder(NSObject.alloc().init())];
		watch(5, hs[1234].o);
		Rt.objc_autoreleasePoolPop(p);
		trace("10000 holders, before collecting: " + alive(5));
	}

	static function main() {
		// a new object nobody keeps: gone with its pool
		pool(() -> watch(0, NSObject.alloc().init()));
		trace("unkept new: " + alive(0));
		// kept in a static: survives the pool; replaced: released
		pool(() -> {
			kept = NSObject.alloc().init();
			watch(1, kept);
		});
		trace("static: " + alive(1) + ", retainCount " + kept.retainCount());
		pool(() -> kept = NSMutableString.alloc().init());
		trace("static replaced: old alive " + alive(1));
		// a field: survives the pool, and the holder's death
		pool(() -> {
			h = new Holder(NSObject.alloc().init());
			watch(2, h.o);
			watch(3, kept);
		});
		trace("field: " + alive(2));
		h = null;
		hxmc.rt.Gc.collect(true);
		hxmc.rt.Gc.collect(true);
		trace("holder collected: field's id alive " + alive(2));
		// copy is +1: autoreleased like new
		var a = NSMutableArray.alloc().init();
		a.addObject(kept);
		pool(() -> watch(4, a.copy()));
		trace("unkept copy: " + alive(4));
		a.removeAllObjects(); // (the array held it too)
		kept = null;
		trace("static cleared: " + alive(3));
		// many holders, many collections
		makeHolders();
		for (i in 0...3) hxmc.rt.Gc.collect(true);
		trace("10000 holders collected: " + alive(5));
	}
}
