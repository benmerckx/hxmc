// A GC function (a closure too) takes no span: it may collect while holding it.
// expect: SpanParameter.count: the parameter s has a span type (kernel: spans exist only in kernels: only a @:hxmc.kernel function holds one)
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
