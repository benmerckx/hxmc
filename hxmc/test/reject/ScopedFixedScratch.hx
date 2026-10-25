// Fixed.scratch leaves its elements as they were: numbers only.
// expect: Fixed.scratch: its elements are numbers (others start zeroed: new Fixed)
import hxmc.scoped.*;

@:hxmc.scoped class V {
	public var x:Int;
}

@:hxmc.scoped class Code {
	public static function bad():Int {
		var f:Fixed<V, 4> = Fixed.scratch();
		return f[0].x;
	}
}

class ScopedFixedScratch {
	static function main()
		trace(Code.bad());
}
