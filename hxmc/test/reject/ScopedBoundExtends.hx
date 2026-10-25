// A scope-bound class has no subclasses: its methods are called directly.
// expect: ScopedBoundExtends.hx:11: Derived: a scope-bound class has no subclasses
import hxmc.scoped.*;

@:hxmc.scopeBound class Base {
	public var key:Int;
	public function new(key:Int)
		this.key = key;
}

class Derived extends Base {}

class ScopedBoundExtends {
	static function main()
		trace(new Derived(1).key);
}
