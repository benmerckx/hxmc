import hxmc.Span;

// IoBuffer is hxmc's (hxmc.unsafe): elsewhere ofIoBuffer is a compile error naming why.
// error: Span.ofIoBuffer is hxmc's only: an IoBuffer or a Ptr is hxmc.unsafe's
class SpanIoBuffer {
	@:hxmc.kernel static function n(s:Span<hxmc.unsafe.UInt8>):Int
		return s.length;

	static function main()
		trace(n(Span.ofIoBuffer(null)));
}
