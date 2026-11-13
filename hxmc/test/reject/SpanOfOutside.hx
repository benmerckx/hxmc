// Span.of(x) lives for one call, a kernel's too: it is that call's argument.
// expect: SpanOfOutside.twice: Span.of(x) outside a call's arguments (kernel: x is copied in for the call, and back after it: an argument only)
import hxmc.Span;

class SpanOfOutside {
	@:hxmc.kernel static function twice(x:Float):Float {
		var s = Span.of(x);
		s[0] *= 2;
		return x;
	}

	static function main()
		trace(twice(1.0));
}
