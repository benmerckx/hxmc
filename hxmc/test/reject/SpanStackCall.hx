// A span a kernel returns may be one of its span arguments: of a frame's scratch passed in, it is scratch too.
// expect: SpanStackCall.hx:11: SpanStackCall.scratch: a span of the frame's scratch (Span.stack) returned (kernel: a span of a kernel's frame lives while the kernel runs)
import hxmc.Span;

class SpanStackCall {
	@:hxmc.kernel static function id(s:Span<Int>):Span<Int>
		return s;

	@:hxmc.kernel static function scratch():Span<Int> {
		var t:Span<Int> = Span.stack(4);
		return id(t.sub(1, 2));
	}

	@:hxmc.kernel static function use():Int
		return scratch()[0];

	static function main()
		trace(use());
}
