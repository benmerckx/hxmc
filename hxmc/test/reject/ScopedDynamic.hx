// GC code: a scoped value holding references cannot become Dynamic (a box in the GC heap): it is copied out instead.
// expect: ScopedDynamic.hx:8: ScopedDynamic.main: d: a scoped value holding references (hxmc.scoped.Str) cannot become Dynamic (the GC heap)
import hxmc.scoped.*;

class ScopedDynamic {
	static function main() {
		var s = Str.copyOf("text");
		var d:Dynamic = s;
		trace(d);
	}
}
