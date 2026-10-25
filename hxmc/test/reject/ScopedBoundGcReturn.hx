// GC code returns no scope-bound object (its scope ends with the function): a @:hxmc.scoped function may.
// expect: ScopedBoundGcReturn.hx:13: ScopedBoundGcReturn.make: GC code returns no scoped value holding references
import hxmc.scoped.*;

@:hxmc.scopeBound class Node {
	public var key:Int;
	public function new(key:Int)
		this.key = key;
}

class ScopedBoundGcReturn {
	static function make():Node
		return new Node(Std.random(10));

	static function main()
		trace(make().key);
}
