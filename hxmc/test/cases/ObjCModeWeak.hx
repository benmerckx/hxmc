import hxmc.objc.AutoreleasePool;
import hxmc.rt.Gc;

@:hxmc.lib("/usr/lib/libobjc.A.dylib") @:hxmc.objc extern class NSObject {
	static function alloc():NSObject;
	function init():NSObject;
	function dealloc():Void;
}

class Attrs {
	public var label:String;
	public var n:Int;

	public function new(label, n) {
		this.label = label;
		this.n = n;
	}
}

@:hxmc.objc class Node extends NSObject {
	public extern static function alloc():Node;

	@:hxmc.weak public var props:Null<Attrs>;
	@:hxmc.weak public var buddy:Null<NSObject>;
	@:hxmc.weak public var f:Null<() -> String>;

	public static var deallocs = 0;

	override function init():Node {
		super.init();
		return this;
	}

	override function dealloc() {
		deallocs++;
	}
}

class ObjCModeWeak {
	static var kept:Null<Attrs>;
	static var keptObj:Null<NSObject>;

	static function churn() {
		var keep = [];
		for (i in 0...200000) {
			var a = [i, i + 1];
			if (i % 1000 == 0) keep.push(a);
		}
		return keep.length;
	}

	static var keptFn:Null<() -> String>;

	// (in a frame of its own: no slot of main's holds it)
	static function storeOld(n:Node) {
		var old = new Attrs("old", 4);
		Gc.collect(true);
		n.props = old;
	}

	static function show(n:Node, what:String) {
		var p = n.props;
		trace(what + ": " + (p == null ? "null" : p.label + " " + p.n + " " + (p == kept)));
	}

	static function main() {
		var n = Node.alloc().init();
		show(n, "never stored");
		// kept alive by a static: moved by a minor collection, then a major one
		kept = new Attrs("kept", 1);
		n.props = kept;
		show(n, "stored");
		churn();
		Gc.collect(false);
		show(n, "after a minor collection");
		Gc.collect(true);
		show(n, "after a major collection");
		kept.n = 2;
		show(n, "changed through the static");
		// unreachable but for the weak field: null after a collection
		n.props = new Attrs("only weak", 3);
		Gc.collect(false);
		show(n, "only weak, after a minor collection");
		// a closure (any Haxe value)
		var s = "captured";
		keptFn = () -> s;
		n.f = keptFn;
		Gc.collect(true);
		trace("closure: " + (n.f == null ? "null" : n.f()));
		keptFn = null;
		Gc.collect(true);
		trace("closure after: " + (n.f == null ? "null" : "alive"));
		// stored null: the slot keeps nothing
		n.props = kept;
		n.props = null;
		show(n, "stored null");
		n.props = kept;
		// an old object, dead in a major collection
		storeOld(n);
		Gc.collect(false);
		show(n, "old, after a minor collection");
		Gc.collect(true);
		show(n, "old, after a major collection");
		// Objective-C weak: nil once its object is gone
		AutoreleasePool.run(() -> {
			keptObj = NSObject.alloc().init();
			n.buddy = keptObj;
		});
		AutoreleasePool.run(() -> trace("buddy while kept: " + (n.buddy == keptObj)));
		AutoreleasePool.run(() -> keptObj = null);
		AutoreleasePool.run(() -> trace("buddy after release: " + (n.buddy == null)));
		// many objects with weak fields, freed: their slots reused
		var before = @:privateAccess Gc.nweak;
		for (round in 0...5)
			AutoreleasePool.run(() -> for (i in 0...1000) {
				var m = Node.alloc().init();
				m.props = kept;
				m.buddy = n;
			});
		trace("deallocs: " + Node.deallocs + ", slots made: " + (@:privateAccess Gc.nweak - before <= 1001));
		show(n, "at the end");
	}
}
