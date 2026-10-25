// Scoped code cannot throw (no-GC code): it aborts with a message.
// expect: ScopedThrow.hx:7: Code.bad: scoped code cannot throw
import hxmc.scoped.*;

@:hxmc.scoped class Code {
	public static function bad(n:Int):Int {
		if (n < 0) throw "negative";
		return n;
	}
}

class ScopedThrow {
	static function main()
		trace(Code.bad(1));
}
