// Span.ofArray(a) is copied in for one call and back after it: that call's
// argument only.
// expect: SpanOfArrayOutside.main: Span.ofArray(a) outside a call's arguments
import hxmc.Span;

class SpanOfArrayOutside {
	static function main()
		trace(Span.ofArray([1, 2]).length);
}
