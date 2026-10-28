// A kernel may return a span (one of its arguments', or a sub-view), but only to a kernel.
// expect: SpanResult.main: the result of SpanResult.tail has a span type (kernel: spans exist only in kernels: only a @:hxmc.kernel function holds one)
import hxmc.ReadOnlySpan;
import hxmc.unsafe.UInt8;

class SpanResult {
	@:hxmc.kernel static function tail(s:ReadOnlySpan<UInt8>):ReadOnlySpan<UInt8>
		return s.sub(1, s.length - 1);

	static function main() {
		var b = haxe.io.Bytes.ofString("abc");
		trace(tail(ReadOnlySpan.ofBytes(b)).length);
	}
}
