// A string with interpolations expected as a Str takes scoped and scalar values.
// expect: a Str interpolates Str, Int, Float and Bool values, not String
import hxmc.scoped.*;

@:hxmc.scoped class Code {
	public static function bad(n:Int):Str
		return 'n=$n ${Std.string(n)}';
}

class ScopedInterpolation {
	static function main()
		trace(Code.bad(1).length);
}
