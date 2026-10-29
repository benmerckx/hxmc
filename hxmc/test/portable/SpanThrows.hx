import hxmc.ReadOnlySpan;
import hxmc.Span;
import hxmc.unsafe.UInt8;

// On the other targets a span's failed check throws a SpanError (on hxmc
// the program ends: SpanOutOfRange): an element, a range, an Int64 atomic.
// expect: SpanThrows.hx:26: element, span index 3 out of range [0, 3)
// expect: SpanThrows.hx:27: negative, span index -1 out of range [0, 3)
// expect: SpanThrows.hx:28: sub, span range 2 + 2 out of range [0, 3)
// expect: SpanThrows.hx:29: blit, span range 0 + 4 out of range [0, 3)
// expect: SpanThrows.hx:30: done
@:hxmc.kernel class K {
	public static function at(s:ReadOnlySpan<UInt8>, i:Int):Int
		return s[i];

	public static function sub(s:ReadOnlySpan<UInt8>):Int
		return s.sub(2, 2).length;

	public static function blit(s:Span<UInt8>):Void
		s.blit(0, s, 0, 4);
}

class SpanThrows {
	static function main() {
		var b = haxe.io.Bytes.ofString("abc");
		try K.at(ReadOnlySpan.ofBytes(b), 3) catch (e:hxmc.Span.SpanError) trace("element", e.message);
		try K.at(ReadOnlySpan.ofBytes(b), -1) catch (e:hxmc.Span.SpanError) trace("negative", e.message);
		try K.sub(ReadOnlySpan.ofBytes(b)) catch (e:hxmc.Span.SpanError) trace("sub", e.message);
		try K.blit(Span.ofBytes(b)) catch (e:hxmc.Span.SpanError) trace("blit", e.message);
		trace("done");
	}
}
