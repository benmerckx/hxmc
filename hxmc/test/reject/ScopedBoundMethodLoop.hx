// A method keeps what it allocates into its object in its own scope only: a loop body's memory is freed each iteration.
// expect: ScopedBoundMethodLoop.hx:10: Names.addAll: storing a reference rooted at a temporary (made at line 10, memory of that scope) into memory of the caller (this), which outlives it
import hxmc.scoped.*;

@:hxmc.scopeBound class Names {
	public var last:Str;
	public function new() {}
	public function addAll(n:Int)
		for (i in 0...n) {
			last = Str.copyOf("n" + i);
		}
}

class ScopedBoundMethodLoop {
	static function main() {
		var s = new Names();
		s.addAll(3);
		trace(s.last.toString());
	}
}
