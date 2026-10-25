// GC code holds scoped values in locals only: a field of an object is the GC heap, which outlives every scope.
// expect: ScopedGcField.hx:13: ScopedGcField.main: storing a reference rooted at a temporary (made at line 13, memory of the function) into h.s (the GC heap), which outlives it
import hxmc.scoped.*;

class Holder {
	public var s:Str = "";
	public function new() {}
}

class ScopedGcField {
	static function main() {
		var h = new Holder();
		h.s = Str.copyOf("text " + Std.random(10));
		trace(h.s.length);
	}
}
