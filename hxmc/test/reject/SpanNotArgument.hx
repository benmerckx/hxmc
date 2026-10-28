// GC code makes a span only as a direct argument of a call of a kernel: the call is its scope.
// expect: SpanNotArgument.main: a span made outside a call's arguments (kernel: spans exist only in kernels; pass ReadOnlySpan.ofBytes(...) as an argument of a @:hxmc.kernel function)
import hxmc.ReadOnlySpan;
import hxmc.unsafe.UInt8;

class SpanNotArgument {
	@:hxmc.kernel static function first(s:ReadOnlySpan<UInt8>):Int
		return s[0];

	static function main() {
		var b = haxe.io.Bytes.ofString("abc");
		trace(first(ReadOnlySpan.ofBytes(b).sub(1, 2)));
	}
}
