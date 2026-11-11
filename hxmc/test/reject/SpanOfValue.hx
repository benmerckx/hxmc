// Span.of(x) writes back into x after the call: x is a variable.
// expect: SpanOfValue.main: Span.of(x) of no variable (kernel: C writes the span: x is a local, a field or a static, copied back after the call (ReadOnlySpan.of for a value))
import hxmc.Span;

@:hxmc.c @:hxmc.fast @:hxmc.safe extern class C {
	@:hxmc.len(v, 1) static function twice(v:Span<Float>):Void;
}

class SpanOfValue {
	static function main()
		C.twice(Span.of(1.5 * 2));
}
