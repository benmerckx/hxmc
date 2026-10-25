// Scoped code holds no GC references, parameters included.
// expect: ScopedGcParam.hx:6: Code.len: scoped code holds no GC references: the parameter s is a String
import hxmc.scoped.*;

@:hxmc.scoped class Code {
	public static function len(s:String):Int
		return s.length;
}

class ScopedGcParam {
	static function main()
		trace(Code.len("abc"));
}
