// Scoped code holds no GC references.
// expect: ScopedGcReference.hx:7: Code.bad: scoped code holds no GC references: an array literal
import hxmc.scoped.*;

@:hxmc.scoped class Code {
	public static function bad(n:Int):Int {
		var a = [n];
		a.push(n);
		return a.length;
	}
}

class ScopedGcReference {
	static function main()
		trace(Code.bad(1));
}
