// Span.of(x) writes x after the call: a field written only in its class, (default, null), is written there and through this in a subclass, not from another class.
// expect: SpanOfReadOnly.main: Span.of(x) of x, which is not writable here (kernel: C writes the span: x is copied back after the call (ReadOnlySpan.of for a value))
import hxmc.Span;

@:hxmc.c @:hxmc.fast @:hxmc.safe extern class C {
	@:hxmc.len(v, 1) static function twice(v:Span<Float>):Void;
}

class P {
	public var x(default, null) = 1.5;

	public function new() {}

	public function twice()
		C.twice(Span.of(x));
}

class Q extends P {
	public function thrice()
		C.twice(Span.of(this.x));
}

class SpanOfReadOnly {
	static function main() {
		var q = new Q();
		q.twice();
		q.thrice();
		C.twice(Span.of(q.x));
	}
}
