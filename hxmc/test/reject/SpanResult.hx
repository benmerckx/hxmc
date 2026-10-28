// A GC-free function may return a span (one of its arguments', or a sub-view), but only to GC-free code.
// expect: SpanResult.main: the result of SpanResult.tail has a span type (gcfree: spans exist only in GC-free code: only a @:hxmc.gcfree function holds one)
import hxmc.ReadOnlySpan;
import hxmc.unsafe.UInt8;

class SpanResult {
	@:hxmc.gcfree static function tail(s:ReadOnlySpan<UInt8>):ReadOnlySpan<UInt8>
		return s.sub(1, s.length - 1);

	static function main() {
		var b = haxe.io.Bytes.ofString("abc");
		trace(tail(ReadOnlySpan.ofBytes(b)).length);
	}
}
