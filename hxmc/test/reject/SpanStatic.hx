// Nor a static (GC-free code reads statics: a static span would be a global one).
// expect: SpanStatic.hx:7: the static keep has a span type (gcfree: spans live in parameters and locals only)
import hxmc.ReadOnlySpan;
import hxmc.unsafe.UInt8;

class SpanStatic {
	static var keep:ReadOnlySpan<UInt8>;

	@:hxmc.gcfree static function first():Int
		return keep[0];

	static function main()
		trace(first());
}
