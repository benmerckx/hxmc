// The root checker: a block in statement position is a scope (reset where it ends).
// expect: ScopedBlockEscape.hx:10: Code.bad: storing a reference rooted at t (made at line 9, memory of that scope) into w, which outlives it
import hxmc.scoped.*;

@:hxmc.scoped class Code {
	public static function bad(c:Bool):Int {
		var w:Str = "";
		if (c) {
			var t = Str.copy("abc");
			w = t;
		}
		return w.length;
	}
}

class ScopedBlockEscape {
	static function main()
		trace(Code.bad(true));
}
