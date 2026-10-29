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

class Holder {
	@:hxmc.weak public var weak:Null<NSObject>;
	public var strong:Null<NSObject>;
	public function new() {}
}

class ObjCWeak {
	static var kept:Null<NSObject>;
	static final slot = LibC.malloc(8);

	static function alive():Bool {
		var o = Rt.objc_loadWeakRetained(slot);
		if (o == null) return false;
		Rt.objc_release(o);
		return true;
	}

	static function main() {
		var h = new Holder();
		trace("never stored: " + (h.weak == null));
		AutoreleasePool.run(() -> {
			kept = NSObject.alloc().init();
			h.weak = kept;
		});
		// (a read returns an autoreleased id, as every value: read in a pool)
		AutoreleasePool.run(() -> trace("weak while kept: " + (h.weak == kept) + ", retainCount " + kept.retainCount()));
		AutoreleasePool.run(() -> kept = null);
		AutoreleasePool.run(() -> trace("weak after release: " + (h.weak == null)));
		// only weakly held: gone with its pool
		AutoreleasePool.run(() -> {
			h.weak = NSObject.alloc().init();
			Mem.setPtr(slot, 0, Ptr.nil());
			Rt.objc_storeWeak(slot, h.weak);
		});
		trace("only weak: alive " + alive() + ", field " + (h.weak == null));
		// holders dying with weak fields set (their cells destroyed, freed)
		AutoreleasePool.run(() -> {
			var o = NSObject.alloc().init();
			kept = o;
			for (i in 0...10000) {
				var x = new Holder();
				x.weak = o;
				x.strong = o;
			}
		});
		trace("10000 holders: retainCount " + kept.retainCount());
		for (_ in 0...2) hxmc.rt.Gc.collect(true);
		trace("collected: retainCount " + kept.retainCount());
		// a pool that throws still pops
		try AutoreleasePool.run(() -> throw "inside") catch (e) trace("caught " + e);
		trace("done");
	}
}
