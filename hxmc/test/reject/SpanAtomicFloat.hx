import hxmc.Span;
import hxmc.unsafe.UInt8;

// Atomic accesses are of a span's integer elements only (Int, UInt, Int64): Atomic has no Float operation.
// expect: hxmc.Span.load: atomic accesses are of Int, UInt and Int64 elements, not Float (
// expect: SpanAtomicFloat.hx:11)
class SpanAtomicFloat {
	@:hxmc.kernel static function first(b:Span<UInt8>):Float {
		var s:Span<Float> = b.reinterpret();
		var v = s[0];
		return v + s.load(0);
	}

	static function main()
		trace(first(Span.ofBytes(haxe.io.Bytes.alloc(8))));
}
