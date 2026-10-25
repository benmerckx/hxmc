// GC code: a closure cannot capture a scoped value holding references (it may outlive the scope).
// expect: ScopedClosure.hx:9: ScopedClosure.main: s holds a scoped value with references: a closure cannot capture it (the GC heap)
import hxmc.scoped.*;

class ScopedClosure {
	static function main() {
		var s = Str.copyOf("text");
		var f = function() {
			return s.length;
		};
		trace(f());
	}
}
