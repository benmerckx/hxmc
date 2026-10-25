// A scope-bound object holds no GC reference (the collector never scans it): an index into a table instead.
// expect: ScopedBoundGcReference.hx:6: Named.name: a scope-bound object holds no GC reference (the collector never scans it), and this is a String: an index into a table instead
import hxmc.scoped.*;

@:hxmc.scopeBound class Named {
	public var name:String;
	public function new(name:String)
		this.name = name;
}

class ScopedBoundGcReference {
	static function main()
		trace(new Named("a").name);
}
