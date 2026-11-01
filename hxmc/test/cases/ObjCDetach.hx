import hxmc.objc.AutoreleasePool;
import hxmc.objc.Peers;
import hxmc.unsafe.*;

// hxmc.objc.Peers.detach (docs/interop.md, "Ownership"): the Haxe object
// gives up its Objective-C object at once. Held by Objective-C, the object
// lives and its calls into the Haxe class reach the Haxe object; let go, it
// is deallocated then, before any collection (given as an id: once its
// box is collected). Messages through the detached
// Haxe object go to nil. Without detach, the object waits for a collection.
@:hxmc.lib("/usr/lib/libobjc.A.dylib") @:hxmc.objc extern class NSObject implements hxmc.objc.Id {
	function hash():Int64;
}

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSMutableArray extends NSObject {
	static function array():NSMutableArray;
	function addObject(o:NSObject):Void;
	function removeAllObjects():Void;
	function makeObjectsPerformSelector(sel:hxmc.objc.Selector):Void;
}

class Thing extends NSObject {
	public static var bumps = 0;

	public function new() {}

	public function bump():Void
		bumps++;
}

class Watch {
	@:hxmc.weak public var o:Null<NSObject>;

	public function new(o:NSObject)
		this.o = o;
}

class ObjCDetach {
	static function alive(w:Watch):Bool {
		var r = false;
		AutoreleasePool.run(() -> r = w.o != null);
		return r;
	}

	static function main() {
		// (each object made in a pool of its own: what a message returns is
		// autoreleased, and main's own pool drains only when main returns)
		var kept:NSMutableArray = null;
		var t:Thing = null;
		var w:Watch = null;
		AutoreleasePool.run(() -> {
			kept = NSMutableArray.array();
			t = new Thing();
			w = new Watch(t);
			kept.addObject(t);
		});
		Peers.detach(t);
		trace("detached, held by an array: alive " + alive(w) + ", hash through it " + t.hash());
		AutoreleasePool.run(() -> kept.makeObjectsPerformSelector(hxmc.objc.Selector.of("bump")));
		hxmc.rt.Gc.collect(true);
		AutoreleasePool.run(() -> kept.makeObjectsPerformSelector(hxmc.objc.Selector.of("bump")));
		trace("calls into it, across a collection: " + Thing.bumps);
		AutoreleasePool.run(() -> kept.removeAllObjects());
		trace("let go: alive " + alive(w));
		Peers.detach(t);
		trace("detached twice: fine");

		var wu:Watch = null;
		AutoreleasePool.run(() -> {
			var u = new Thing();
			wu = new Watch(u);
			Peers.detach(u);
		});
		trace("detached, held by nothing: alive " + alive(wu));

		var wx:Watch = null;
		AutoreleasePool.run(() -> {
			var plain:NSObject = new Thing(); // (as its Objective-C type: an id)
			wx = new Watch(plain);
			Peers.detach(plain);
		});
		AutoreleasePool.run(() -> hxmc.rt.Gc.collect(false));
		trace("detached as an id, held by nothing: alive " + alive(wx));

		var wv:Watch = null;
		AutoreleasePool.run(() -> wv = new Watch(new Thing()));
		trace("not detached: alive " + alive(wv));
		for (_ in 0...2) AutoreleasePool.run(() -> hxmc.rt.Gc.collect(true));
		trace("not detached, after collections: alive " + alive(wv));
		Peers.detach(null);
		trace("done");
	}
}
