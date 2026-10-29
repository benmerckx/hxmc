import hxmc.I64;
import hxmc.ReadOnlySpan;
import hxmc.Span;
import hxmc.unsafe.IoBuffer;
import hxmc.unsafe.UInt8;
#if (hxmc.target != "wasm32-wasi")
import hxmc.unsafe.Blocking;
import sys.thread.Lock;
import sys.thread.Thread;
#end

// Atomic accesses of a span's integer elements in safe GC-free code
// (docs/interop.md, "Spans"): load, store and compareExchange, checked as
// s[i]. Natively, a worker inside the region it entered (Blocking.enter, as
// a job pool's does) polls a cancel flag the main thread sets, and two
// workers count with compareExchange; on wasm32 (no threads) the same calls
// on one thread. The last load is out of range: the program ends (exit 2).
@:hxmc.kernel class Flags {
	// (a buffer's bytes as Ints: 0 the cancel flag, 1 a worker's start, 2 the counter)
	static inline function words(s:ReadOnlySpan<UInt8>):ReadOnlySpan<Int>
		return s.reinterpret();

	public static function load(s:ReadOnlySpan<UInt8>, i:Int):Int
		return words(s).load(i);

	public static function store(s:Span<UInt8>, i:Int, v:Int):Void {
		var w:Span<Int> = s.reinterpret();
		w.store(i, v);
	}

	// spins until the flag is set: the loads it took
	public static function waitForCancel(s:Span<UInt8>):Int {
		var w:Span<Int> = s.reinterpret();
		w.store(1, 1);
		var n = 0;
		while (w.load(0) == 0)
			n++;
		return n;
	}

	// n increments of the counter, each by compareExchange: the retries
	public static function count(s:Span<UInt8>, n:Int):Int {
		var w:Span<Int> = s.reinterpret();
		var retries = 0;
		for (k in 0...n) {
			var old = w.load(2);
			while (true) {
				var seen = w.compareExchange(2, old, old + 1);
				if (seen == old) break;
				old = seen;
				retries++;
			}
		}
		return retries;
	}

	// UInt and Int64 elements; compareExchange that fails leaves the element
	public static function wide(s:Span<UInt8>):Float {
		var u:Span<UInt> = s.reinterpret(), l:Span<I64> = s.reinterpret();
		u.store(0, 0xFFFFFFFF);
		var big:Float = u.load(0);
		var miss = u.compareExchange(0, 7, 8);
		l.store(1, (1 : I64) << 40);
		var was = l.compareExchange(1, (1 : I64) << 40, 3);
		return big + (miss : Float) + (was >> 30).toInt() + l.load(1).toInt();
	}
}

class SpanAtomics {
	static function main() {
		var buf = IoBuffer.alloc(16);
		Flags.store(Span.ofIoBuffer(buf), 0, 0);
		Flags.store(Span.ofIoBuffer(buf), 2, 0);
		trace("flag", Flags.load(ReadOnlySpan.ofIoBuffer(buf), 0), buf.getInt32(0));
		var polls = -1;
		#if (hxmc.target != "wasm32-wasi")
		// a worker polls the flag inside its region until this thread sets it
		var done = new Lock();
		Thread.create(() -> {
			var region = Blocking.enter();
			var n = Flags.waitForCancel(Span.ofIoBuffer(buf));
			Blocking.leave(region);
			polls = n;
			done.release();
		});
		while (Flags.load(ReadOnlySpan.ofIoBuffer(buf), 1) == 0)
			Sys.sleep(0.001);
		hxmc.NativeGc.collect(true);
		Flags.store(Span.ofIoBuffer(buf), 0, 1);
		done.wait();
		// two workers count with compareExchange
		var finished = new Lock();
		for (t in 0...2)
			Thread.create(() -> {
				var region = Blocking.enter();
				Flags.count(Span.ofIoBuffer(buf), 100000);
				Blocking.leave(region);
				finished.release();
			});
		finished.wait();
		finished.wait();
		Flags.count(Span.ofIoBuffer(buf), 100000);
		#else
		// (one thread: the flag set before the poll, the counts one after the other)
		Flags.store(Span.ofIoBuffer(buf), 0, 1);
		polls = Flags.waitForCancel(Span.ofIoBuffer(buf));
		for (t in 0...3)
			Flags.count(Span.ofIoBuffer(buf), 100000);
		#end
		trace("cancelled", polls >= 0);
		trace("count", Flags.load(ReadOnlySpan.ofIoBuffer(buf), 2), buf.getInt32(8));
		trace("wide", Flags.wide(Span.ofIoBuffer(buf)));
		Sys.stdout().flush();
		trace(Flags.load(ReadOnlySpan.ofIoBuffer(buf), 4));
		trace("not reached");
	}
}
