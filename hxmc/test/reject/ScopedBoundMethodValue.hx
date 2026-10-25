// A method of a scope-bound object is no function value: the closure would keep the object.
// expect: ScopedBoundMethodValue.hx:16: ScopedBoundMethodValue.main: a method of a scope-bound object as a function value: a closure (the GC heap) would keep the object
import hxmc.scoped.*;

@:hxmc.scopeBound class Node {
	public var key:Int;
	public function new(key:Int)
		this.key = key;
	public function get():Int
		return key;
}

class ScopedBoundMethodValue {
	static function main() {
		var n = new Node(Std.random(10));
		var f = n.get;
		trace(f());
	}
}
