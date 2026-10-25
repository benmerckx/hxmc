// An array literal expected as a Fixed has its N elements.
// expect: a literal of 2 elements for a Fixed of 3
import hxmc.scoped.*;

@:hxmc.scoped class Code {
	public static function bad():Int {
		var f:Fixed<Int, 3> = [1, 2];
		return f[0];
	}
}

class ScopedLiteralCount {
	static function main()
		trace(Code.bad());
}
