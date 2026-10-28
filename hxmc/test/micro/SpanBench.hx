import haxe.Timer;
import hxmc.ReadOnlySpan;
import hxmc.Span;
import hxmc.unsafe.IoBuffer;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Ptr;
import hxmc.unsafe.UInt8;

// A checked span's access against a raw one (docs/interop.md, "Spans"), in
// tight loops over an IoBuffer: a byte sum (loads, Adler-32's inner loop)
// and a Float axpy (loads and stores, y[i] = a * x[i] + y[i]), each written
// raw (@:hxmc.unsafe: Mem's indexed loads and stores, the fastest raw
// form, as helder's kernels write them) and on spans. Built twice, with and without the
// element checks; the median of 7 runs, in nanoseconds per element (the
// buffers in the cache by default: the cost of the access, not of memory).
// Not a corpus case (times vary); built and run by hand, natively or as a
// module:
//   bin/hxmc/hxmc -cp hxmc/test/micro -main SpanBench -cp bin/hxmc/std --custom-target hxmc=bin/spanbench [-D hxmc.span-checks=0]
//   bin/spanbench [bytes]                (default 64 KB; 256 M elements a kernel)
// For instruction counts, one kernel under callgrind minus the same with 0
// passes: `bin/spanbench <bytes> <kernel> <passes>` (kernel: sumRaw,
// sumSpan, axpyRaw, axpySpan). Results: docs/plans/io.md, "Bounds checks".
class SpanBench {
	@:hxmc.unsafe @:hxmc.kernel static function sumRaw(p:Ptr<UInt8>, n:Int):Int {
		var s = 0;
		for (i in 0...n)
			s += Mem.getU8At(p, 0, i);
		return s;
	}

	@:hxmc.kernel static function sumSpan(b:ReadOnlySpan<UInt8>):Int {
		var s = 0;
		for (i in 0...b.length)
			s += b[i];
		return s;
	}

	@:hxmc.unsafe @:hxmc.kernel static function axpyRaw(a:Float, x:Ptr<Float>, y:Ptr<Float>, n:Int) {
		for (i in 0...n)
			Mem.setF64At(y, 0, i, a * Mem.getF64At(x, 0, i) + Mem.getF64At(y, 0, i));
	}

	@:hxmc.kernel static function axpySpan(a:Float, x:ReadOnlySpan<Float>, y:Span<Float>) {
		for (i in 0...y.length)
			y[i] = a * x[i] + y[i];
	}

	@:hxmc.kernel static function axpy(a:Float, xb:ReadOnlySpan<UInt8>, yb:Span<UInt8>) {
		var x:ReadOnlySpan<Float> = xb.reinterpret(), y:Span<Float> = yb.reinterpret();
		axpySpan(a, x, y);
	}

	static var sink = 0.0;

	// the median of 7 runs of f, in ns per element
	static function time(f:() -> Void, elements:Float):Float {
		var r = [];
		for (k in 0...7) {
			var t0 = Timer.stamp();
			f();
			r.push((Timer.stamp() - t0) * 1e9 / elements);
		}
		r.sort(Reflect.compare);
		return r[3];
	}

	static function main() {
		var args = Sys.args();
		var bytes = args.length > 0 ? Std.parseInt(args[0]) : 64 << 10;
		var passes = args.length > 2 ? Std.parseInt(args[2]) : Std.int(Math.max(1, (256 << 20) / bytes));
		var b = IoBuffer.alloc(bytes), x = IoBuffer.alloc(bytes), y = IoBuffer.alloc(bytes);
		for (i in 0...bytes)
			b.set(i, i * 31);
		var n = bytes >> 3;
		for (i in 0...n) {
			x.setDouble(i * 8, i * 0.5);
			y.setDouble(i * 8, 1.0);
		}
		var p = b.ptr, xp:Ptr<Float> = cast x.ptr, yp:Ptr<Float> = cast y.ptr;
		if (args.length > 1) {
			switch args[1] {
				case "sumRaw": for (k in 0...passes) sink += sumRaw(p, bytes);
				case "sumSpan": for (k in 0...passes) sink += sumSpan(ReadOnlySpan.ofIoBuffer(b));
				case "axpyRaw": for (k in 0...passes) axpyRaw(1.0001, xp, yp, n);
				case "axpySpan": for (k in 0...passes) axpy(1.0001, ReadOnlySpan.ofIoBuffer(x), Span.ofIoBuffer(y));
				case k: throw "kernel " + k;
			}
			return;
		}
		var rawSum = time(() -> for (k in 0...passes) sink += sumRaw(p, bytes), bytes * passes);
		var spanSum = time(() -> for (k in 0...passes) sink += sumSpan(ReadOnlySpan.ofIoBuffer(b)), bytes * passes);
		var rawAxpy = time(() -> for (k in 0...passes) axpyRaw(1.0001, xp, yp, n), n * passes);
		var spanAxpy = time(() -> for (k in 0...passes) axpy(1.0001, ReadOnlySpan.ofIoBuffer(x), Span.ofIoBuffer(y)), n * passes);
		inline function f(v:Float)
			return Std.string(Math.round(v * 1000) / 1000);
		#if hxmc.span_checks
		var mode = "unchecked";
		#else
		var mode = "checked";
		#end
		Sys.println('$mode bytes=$bytes sum: raw ${f(rawSum)} span ${f(spanSum)} ns/byte (${f(spanSum / rawSum)}x); axpy: raw ${f(rawAxpy)} span ${f(spanAxpy)} ns/element (${f(spanAxpy / rawAxpy)}x)');
		if (sink == 0.12345) Sys.println(sink);
		b.free();
		x.free();
		y.free();
	}
}
