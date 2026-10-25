// A scope-bound object is never stored in the GC heap: a field of a GC object outlives every scope.
// expect: ScopedBoundGcField.hx:19: ScopedBoundGcField.main: storing a reference rooted at a temporary (made at line 19, memory of the function) into h.node (the GC heap), which outlives it
import hxmc.scoped.*;

@:hxmc.scopeBound class Node {
	public var key:Int;
	public function new(key:Int)
		this.key = key;
}

class Holder {
	public var node:Node;
	public function new() {}
}

class ScopedBoundGcField {
	static function main() {
		var h = new Holder();
		h.node = new Node(Std.random(10));
		trace(h.node.key);
	}
}
