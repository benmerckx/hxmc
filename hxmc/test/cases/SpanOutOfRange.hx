import hxmc.ReadOnlySpan;
import hxmc.unsafe.UInt8;

// A span access out of range in kernels (docs/interop.md, "Spans"):
// a kernel cannot throw, so the program ends (exit 2), with a message on
// stderr naming the index, the length and the access's position. What was
// printed before stays.
class SpanOutOfRange {
	@:hxmc.kernel static function at(s:ReadOnlySpan<UInt8>, i:Int):Int
		return s[i];

	static function main() {
		var b = haxe.io.Bytes.ofString("abc");
		trace(at(ReadOnlySpan.ofBytes(b), 2));
		Sys.stdout().flush();
		trace(at(ReadOnlySpan.ofBytes(b), 3));
		trace("not reached");
	}
}
