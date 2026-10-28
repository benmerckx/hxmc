// A GC function (a closure too) takes no span: it may collect while holding it.
// expect: SpanParameter.count: the parameter s has a span type (gcfree: spans exist only in GC-free code: only a @:hxmc.gcfree function holds one)
import hxmc.ReadOnlySpan;
import hxmc.unsafe.UInt8;

class SpanParameter {
	static function count(s:ReadOnlySpan<UInt8>):Int
		return s.length;

	static function main() {
		var f = count;
		trace(f != null);
	}
}
