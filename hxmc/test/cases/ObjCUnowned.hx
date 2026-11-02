import hxmc.objc.AutoreleasePool;
import hxmc.rt.Gc;
import hxmc.unsafe.*;

@:hxmc.lib("/usr/lib/libobjc.A.dylib") @:hxmc.objc extern class NSObject {
	static function alloc():NSObject;
	function init():NSObject;
	function retainCount():Int64;
	function dealloc():Void;
}

@:hxmc.c @:hxmc.lib("/usr/lib/libobjc.A.dylib") extern class Rt {
	static function objc_retain(o:NSObject):NSObject;
	static function objc_autorelease(o:NSObject):NSObject;
}

// a field holding the id only: no reference, nothing at the holder's death
class Holder {
	@:hxmc.unowned public var o:NSObject;
	public var strong:Null<NSObject>;

	public function new(o) {
		this.o = o;
	}
}

// an instance variable holding the id only (__unsafe_unretained)
@:hxmc.objc class Node extends NSObject {
	public extern static function alloc():Node;

	@:hxmc.unowned public var other:Null<NSObject>;

	override function init():Node {
		super.init();
		return this;
	}
}

@:hxmc.objc class Child extends NSObject {
	public extern static function alloc():Child;

	public static var deallocs = 0;

	override function init():Child {
		super.init();
		return this;
	}

	override function dealloc() {
		deallocs++;
	}
}

// a dealloc that autoreleases: put off by the collector, it runs in a pool of its own
@:hxmc.objc class Parent extends NSObject {
	public extern static function alloc():Parent;

	public var child:Null<Child>;

	override function init():Parent {
		super.init();
		return this;
	}

	override function dealloc() {
		final c = child;
		if (c != null) Rt.objc_autorelease(Rt.objc_retain(c));
	}
}

class Keeper {
	public var parent:Null<Parent>;

	public function new() {}
}

class ObjCUnowned {
	static var kept:Null<NSObject>;
	static var keeper:Null<Keeper>;

	static function main() {
		AutoreleasePool.run(() -> kept = NSObject.alloc().init());
		final o = kept;
		final before = o.retainCount();
		var h = new Holder(o);
		trace("unowned field: retainCount +" + (o.retainCount() - before) + ", same id " + (h.o == o));
		h.strong = o;
		trace("strong field beside it: retainCount +" + (o.retainCount() - before));
		h.strong = null;
		for (i in 0...10000)
			new Holder(o);
		for (_ in 0...2) Gc.collect(true);
		trace("10000 holders collected: retainCount +" + (o.retainCount() - before));
		AutoreleasePool.run(() -> {
			final n:Node = cast Node.alloc().init();
			// (kept, not o: a closure capturing an id holds it until it is collected)
			n.other = kept;
			trace("unowned ivar: retainCount +" + (kept.retainCount() - before) + ", same id " + (n.other == kept));
		});
		trace("its object gone: retainCount +" + (o.retainCount() - before));
		AutoreleasePool.run(() -> {
			final p:Parent = cast Parent.alloc().init();
			p.child = cast Child.alloc().init();
			keeper = new Keeper();
			keeper.parent = p;
		});
		keeper = null;
		for (_ in 0...2) Gc.collect(true);
		// (no pool around: the child goes with the dealloc's own)
		trace("dealloc put off, autoreleasing: child deallocs " + Child.deallocs);
		trace("done");
	}
}
