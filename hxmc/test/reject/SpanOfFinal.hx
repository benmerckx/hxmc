// Span.of(x) writes x after the call: no final local or field.
// expect: SpanOfFinal.main: Span.of(x) of the final v (kernel: C writes the span: x is copied back after the call (ReadOnlySpan.of for a value))
import hxmc.Span;

@:hxmc.c @:hxmc.fast @:hxmc.safe extern class C {
	@:hxmc.len(v, 1) static function twice(v:Span<Float>):Void;
}

class SpanOfFinal {
	static function main() {
		final v = 1.5;
		C.twice(Span.of(v));
		trace(v);
	}
}
