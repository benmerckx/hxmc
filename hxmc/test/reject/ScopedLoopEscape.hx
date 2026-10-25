// The root checker: memory a loop body allocates ends with the body; a variable declared before the loop outlives it.
// expect: ScopedLoopEscape.hx:10: Code.bad: storing a reference rooted at tmp (made at line 9, memory of that scope) into w, which outlives it
import hxmc.scoped.*;

@:hxmc.scoped class Code {
	public static function bad():Int {
		var w:Str = "";
		for (i in 0...3) {
			var tmp = Str.copy("abc");
			w = tmp;
		}
		return w.length;
	}
}

class ScopedLoopEscape {
	static function main()
		trace(Code.bad());
}
