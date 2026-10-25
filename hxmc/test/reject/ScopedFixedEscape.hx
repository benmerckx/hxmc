// The root checker: a Fixed's view is its frame area, which ends with the function.
// expect: ScopedFixedEscape.hx:8: Code.bad: returning a reference rooted at the Fixed f (a frame area), which ends with the function
import hxmc.scoped.*;

@:hxmc.scoped class Code {
	public static function bad():Slice<Int> {
		var f = new Fixed<Int, 4>();
		return f.view();
	}
}

class ScopedFixedEscape {
	static function main()
		trace(Code.bad().length);
}
