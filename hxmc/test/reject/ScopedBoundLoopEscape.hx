// A scope-bound object made in a loop body is freed at the end of each iteration: no variable outside the loop keeps it.
// expect: ScopedBoundLoopEscape.hx:19: ScopedBoundLoopEscape.main: storing a reference rooted at n (made at line 18, memory of that scope) into head, which outlives it
import hxmc.scoped.*;

@:hxmc.scopeBound class Node {
	public var key:Int;
	public var next:Node;
	public function new(key:Int, next:Node) {
		this.key = key;
		this.next = next;
	}
}

class ScopedBoundLoopEscape {
	static function main() {
		var head:Node = null;
		for (i in 0...3) {
			var n = new Node(i, head);
			head = n;
		}
		trace(head.key);
	}
}
