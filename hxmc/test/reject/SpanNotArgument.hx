// GC code makes a span only as a direct argument of a call of a GC-free function: the call is its scope.
// expect: SpanNotArgument.main: a span made outside a call's arguments (gcfree: spans exist only in GC-free code; pass ReadOnlySpan.ofBytes(...) as an argument of a @:hxmc.gcfree function)
import hxmc.ReadOnlySpan;
import hxmc.unsafe.UInt8;

class SpanNotArgument {
	@:hxmc.gcfree static function first(s:ReadOnlySpan<UInt8>):Int
		return s[0];

	static function main() {
		var b = haxe.io.Bytes.ofString("abc");
		trace(first(ReadOnlySpan.ofBytes(b).sub(1, 2)));
	}
}
