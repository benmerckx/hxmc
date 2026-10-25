// A closure (a GC object) captures no scope-bound object.
// expect: ScopedBoundClosure.hx:14: ScopedBoundClosure.main: n holds a scoped value with references: a closure cannot capture it (the GC heap)
import hxmc.scoped.*;

@:hxmc.scopeBound class Node {
	public var key:Int;
	public function new(key:Int)
		this.key = key;
}

class ScopedBoundClosure {
	static function main() {
		var n = new Node(Std.random(10));
		var f = () -> n.key;
		trace(f());
	}
}
