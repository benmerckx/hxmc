// A span of a kernel's frame lives while the kernel runs: it is never the kernel's result.
// expect: SpanStackResult.hx:8: SpanStackResult.scratch: a span of the frame's scratch (Span.stack) returned (kernel: a span of a kernel's frame lives while the kernel runs)
import hxmc.Span;

class SpanStackResult {
	@:hxmc.kernel static function scratch():Span<Int> {
		var t:Span<Int> = Span.stack(4);
		return t.sub(1, 2);
	}

	@:hxmc.kernel static function use():Int
		return scratch()[0];

	static function main()
		trace(use());
}
