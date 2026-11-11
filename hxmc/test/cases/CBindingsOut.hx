import hxmc.ReadOnlySpan;
import hxmc.Span;
import hxmc.unsafe.*;

// Out-parameters and structs from GC code (docs/interop.md, "Typed
// bindings"): Span.of(x) passes a variable as a span of one, copied in for
// the call and back after it (a local, a field, a static), ReadOnlySpan.of(v)
// a value as `const T *`; structs pass and return by value.
@:hxmc.struct @:hxmc.cname("struct co_qr") @:publicFields class QR {
	var q:Int32;
	var r:Int32;

	inline function new(q = 0, r = 0) {
		this.q = q;
		this.r = r;
	}
}

@:hxmc.c @:hxmc.fast @:hxmc.safe @:hxmc.header("CBindingsOut.h") extern class O {
	@:hxmc.len(out, 1) static function co_divmod(a:Int, b:Int, out:Span<QR>):Int;
	@:hxmc.len(min, 1) @:hxmc.len(max, 1) static function co_minmax(a:Int, b:Int, c:Int, min:Span<Int>, max:Span<Int>):Void;
	static function co_make(q:Int, r:Int):QR;
	static function co_total(qr:QR):Int;
	@:hxmc.len(input, 1) static function co_scale(input:ReadOnlySpan<QR>, k:Int):Int;
	@:hxmc.len(v, 1) static function co_twice(v:Span<Float>):Void;
}

class Holder {
	public var qr = new QR();
	public var x = 1.5;

	public function new() {}
}

class CBindingsOut {
	static var last = new QR();

	static function main() {
		var qr = new QR();
		trace(O.co_divmod(47, 5, Span.of(qr)), qr.q, qr.r);
		var h = new Holder();
		trace(O.co_divmod(100, 7, Span.of(h.qr)), h.qr.q, h.qr.r);
		trace(O.co_divmod(9, 0, Span.of(last)), last.q, last.r);
		var lo = 0, hi = 0;
		O.co_minmax(3, -7, 12, Span.of(lo), Span.of(hi));
		trace(lo, hi);
		var m = O.co_make(4, 2);
		trace(m.q, m.r, O.co_total(m), O.co_total(new QR(1, 1)));
		trace(O.co_scale(ReadOnlySpan.of(m), 3), O.co_scale(ReadOnlySpan.of(new QR(5, 5)), 2));
		O.co_twice(Span.of(h.x));
		trace(h.x);
		var sum = 0;
		for (i in 1...1000) {
			O.co_divmod(i * 13, 7, Span.of(qr));
			sum += qr.q + qr.r;
		}
		trace(sum);
	}
}
