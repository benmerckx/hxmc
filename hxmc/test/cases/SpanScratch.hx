import hxmc.I64;
import hxmc.Span;
import hxmc.unsafe.UInt8;

// A kernel's scratch (docs/interop.md, "Spans"): Span.stack(n), n zeroed
// elements in the kernel's frame, as checked as any span's, never its
// result (reject/SpanStackResult); and a span's atomic add and exchange:
// the value the element held.
@:hxmc.struct @:publicFields class Acc {
	var n:Int;
	var sum:Float;
}

class SpanScratch {
	// digits of v in a scratch, read back reversed
	@:hxmc.kernel static function reversed(v:Int):Int {
		var d:Span<UInt8> = Span.stack(12);
		var n = 0;
		do {
			d[n] = v % 10;
			v = Std.int(v / 10);
			n++;
		} while (v > 0 && n < d.length);
		var r = 0;
		for (i in 0...n)
			r = r * 10 + d[i];
		return r;
	}

	// zeroed each call, structs too
	@:hxmc.kernel static function fresh(k:Int):Float {
		var t:Span<Int> = Span.stack(8);
		var a:Span<Acc> = Span.stack(2);
		var z = 0;
		for (i in 0...t.length)
			z += t[i];
		t[k & 7] = k;
		a[1].n += k;
		a[1].sum += k * 0.5;
		return z + a[0].n + a[1].n + a[1].sum;
	}

	@:hxmc.kernel static function atomics():Int {
		var c:Span<Int> = Span.stack(1);
		var w:Span<I64> = Span.stack(1);
		var r = c.add(0, 5);
		r = r * 10 + c.add(0, 2);
		r = r * 100 + c.exchange(0, 3);
		w.add(0, (1 : I64) << 40);
		var old = w.exchange(0, 9);
		return r * 10 + c[0] + (old >>> 40).toInt() + w[0].toInt();
	}

	static function main() {
		trace(reversed(12345), reversed(0), fresh(3), fresh(5), atomics());
	}
}
