// A scope-bound object never becomes Dynamic (the GC heap could keep it).
// expect: ScopedBoundDynamic.hx:13: ScopedBoundDynamic.main: d: a scoped value holding references (Node) cannot become Dynamic (the GC heap)
import hxmc.scoped.*;

@:hxmc.scopeBound class Node {
	public var key:Int;
	public function new(key:Int)
		this.key = key;
}

class ScopedBoundDynamic {
	static function main() {
		var d:Dynamic = new Node(Std.random(10));
		trace(d);
	}
}
