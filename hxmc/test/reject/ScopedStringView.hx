// A Str views a string literal only: a String moves with the collector, Str.copyOf copies it.
// expect: ScopedStringView.hx:8: ScopedStringView.main: a Str views a string literal only (a String moves with the collector): Str.copyOf copies one
import hxmc.scoped.*;

class ScopedStringView {
	static function main() {
		var t = "text " + Std.random(10);
		var s:Str = t;
		trace(s.length);
	}
}
