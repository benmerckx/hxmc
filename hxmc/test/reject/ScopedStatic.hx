// The root checker: a static outlives every scope.
// expect: ScopedStatic.hx:9: Code.bad: storing a reference rooted at a temporary (made at line 9, memory of the function) into the static last, which outlives it
import hxmc.scoped.*;

@:hxmc.scoped class Code {
	static var last:Str = "";

	public static function bad():Int {
		last = Str.copy("abc");
		return last.length;
	}
}

class ScopedStatic {
	static function main()
		trace(Code.bad());
}
