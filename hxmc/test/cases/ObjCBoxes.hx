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
}

@:hxmc.c @:hxmc.lib("/usr/lib/libobjc.A.dylib") extern class Rt {
	static function objc_storeWeak(loc:Ptr, o:Null<NSObject>):Null<NSObject>;
	static function objc_loadWeakRetained(loc:Ptr):Null<NSObject>;
	static function objc_release(o:NSObject):Void;
	static function objc_autoreleasePoolPush():Ptr;
	static function objc_autoreleasePoolPop(pool:Ptr):Void;
}


class ObjCBoxes {
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

	static function gc()
		for (_ in 0...2) hxmc.rt.Gc.collect(true);

	static var map = new Map<String, NSObject>();
	static var arr:Array<NSObject> = [];
	static var dyn:Dynamic;

	static function main() {
		pool(() -> {
			map["a"] = NSObject.alloc().init();
			watch(0, map["a"]);
			arr.push(NSObject.alloc().init());
			watch(1, arr[0]);
			dyn = NSObject.alloc().init();
			watch(2, dyn);
		});
		gc();
		trace("kept by map, array, Dynamic: " + [alive(0), alive(1), alive(2)]);
		trace("equal through the map: " + (map["a"] == map["a"]) + ", null: " + (map["b"] == null) + ", not null: " + (map["a"] != null));
		var o:NSObject = dyn;
		trace("Dynamic back: " + (o == (dyn : NSObject)) + ", retainCount " + o.retainCount());
		map.remove("a");
		arr.pop();
		dyn = null;
		o = null;
		gc();
		trace("removed: " + [alive(0), alive(1), alive(2)]);
	}
}
