import hxmc.ReadOnlySpan;

// unsafeOf takes a Ptr, hxmc.unsafe's: elsewhere a compile error naming why.
// error: ReadOnlySpan.unsafeOf is hxmc's only: an IoBuffer or a Ptr is hxmc.unsafe's
class SpanUnsafeOf {
	@:hxmc.kernel static function n(s:ReadOnlySpan<Int>):Int
		return s.length;

	static function main()
		trace(n(ReadOnlySpan.unsafeOf(null, 4)));
}
