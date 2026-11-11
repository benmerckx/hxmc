// A C function's span result lives in kernels only, as every span.
// expect: CBindingSpanResult.hx:11: CBindingSpanResult.main: the result of the C function counter has a span type (kernel: spans exist only in kernels: only a @:hxmc.kernel function holds one)
import hxmc.Span;

@:hxmc.c @:hxmc.fast @:hxmc.safe extern class C {
	@:hxmc.len(1) static function counter():Span<Int>;
}

class CBindingSpanResult {
	static function main() {
		trace(C.counter()[0]);
	}
}
