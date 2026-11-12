// Span.of(x) copies the span back into x after the call: a field's object is a local or this, not a call evaluated again.
// expect: SpanOfCall.main: Span.of(x) of no variable (kernel: C writes the span: x is a local, a static or a field of this or of a local, copied back after the call (ReadOnlySpan.of for a value))
import hxmc.Span;

@:hxmc.c @:hxmc.fast @:hxmc.safe extern class C {
	@:hxmc.len(v, 1) static function twice(v:Span<Float>):Void;
}

class P {
	public var x = 1.5;

	public function new() {}
}

class SpanOfCall {
	static var ps = [new P()];

	static function main()
		C.twice(Span.of(ps[0].x));
}
