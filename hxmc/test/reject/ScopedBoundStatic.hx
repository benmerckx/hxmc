// A scope-bound object is never stored in a static, which outlives every scope.
// expect: ScopedBoundStatic.hx:15: ScopedBoundStatic.main: storing a reference rooted at a temporary (made at line 15, memory of the function) into the static last, which outlives it
import hxmc.scoped.*;

@:hxmc.scopeBound class Node {
	public var key:Int;
	public function new(key:Int)
		this.key = key;
}

class ScopedBoundStatic {
	static var last:Node;

	static function main() {
		last = new Node(Std.random(10));
		trace(last.key);
	}
}
