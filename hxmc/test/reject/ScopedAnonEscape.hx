// The root checker: a structure's fields keep the roots of what they hold.
// expect: ScopedAnonEscape.hx:8: Code.bad: returning a reference rooted at the Fixed f (a frame area), which ends with the function
import hxmc.scoped.*;

@:hxmc.scoped class Code {
	public static function bad():{v:Slice<Int>, n:Int} {
		var f = new Fixed<Int, 4>();
		return {v: f.view(), n: 4};
	}
}

class ScopedAnonEscape {
	static function main()
		trace(Code.bad().n);
}
