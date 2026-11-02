// define: debug
import hxmc.objc.AutoreleasePool;

// -debug checks unowned fields (docs/interop.md, "Unowned fields"): each is
// held weakly, and a nil read of one that is not Null<...> ends the program,
// its object gone (in a release build, a dangling pointer)
@:hxmc.lib("/usr/lib/libobjc.A.dylib") @:hxmc.objc extern class NSObject {
	static function alloc():NSObject;
	function init():NSObject;
	function retainCount():Int;
}

class Holder {
	@:hxmc.unowned public var o:NSObject;
	@:hxmc.unowned public var maybe:Null<NSObject>;

	public function new(o) {
		this.o = o;
		maybe = o;
	}
}

@:hxmc.objc class Node extends NSObject {
	@:hxmc.unowned public var other:Null<NSObject>;
}

class ObjCUnownedCheck {
	static var kept:Null<NSObject>;

	static function main() {
		AutoreleasePool.run(() -> kept = NSObject.alloc().init());
		var h = new Holder(kept);
		AutoreleasePool.run(() -> trace("while kept: same " + (h.o == kept) + ", retainCount " + kept.retainCount()));
		AutoreleasePool.run(() -> {
			final n = Node.alloc().init();
			n.other = kept;
			trace("ivar while kept: same " + (n.other == kept));
		});
		AutoreleasePool.run(() -> kept = null);
		// (a Null<...> one reads nil, as a weak field)
		AutoreleasePool.run(() -> trace("nullable after: " + (h.maybe == null)));
		AutoreleasePool.run(() -> trace("read after: " + (h.o != null)));
		trace("not reached");
	}
}
