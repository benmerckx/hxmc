// GC code never holds a span: not even in a local (it would outlive the buffer's free, or a collection moving a Bytes).
// expect: SpanLocal.main: the local s has a span type (kernel: spans exist only in kernels: only a @:hxmc.kernel function holds one)
import hxmc.ReadOnlySpan;
import hxmc.unsafe.IoBuffer;
import hxmc.unsafe.UInt8;

class SpanLocal {
	@:hxmc.kernel static function first(s:ReadOnlySpan<UInt8>):Int
		return s[0];

	static function main() {
		var buf = IoBuffer.alloc(4);
		var s = ReadOnlySpan.ofIoBuffer(buf);
		buf.free();
		trace(first(s));
	}
}
