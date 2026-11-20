// The polls the compiler adds in a program that starts threads (docs/interop.md,
// "Safepoints"): the workers spin until the main thread's garbage, which needs
// collections, is made, allocating nothing, one in a loop, one in a recursion
// (no loop). Without the polls the first collection waits for a worker, which
// waits for the main thread.
import haxe.atomic.AtomicBool;

class SafepointAuto {
	static var stop = new AtomicBool(false);

	static var last = "";

	// a tree of calls 2^40 leaves deep, each first testing the flag; it reaches a GC point
	// (one that reaches none gets no polls, docs/interop.md), only once the flag is set
	static function wait(d:Int):Int {
		if (stop.load()) {
			last = "stopped at " + d;
			return 0;
		}
		if (d == 0) return 0;
		return wait(d - 1) + wait(d - 1) + 1;
	}

	static function main() {
		var started = new sys.thread.Lock();
		var done = new sys.thread.Lock();
		sys.thread.Thread.create(() -> {
			started.release();
			var n = 0;
			while (!stop.load())
				n = (n + 1) & 0xFFFF;
			done.release();
		});
		sys.thread.Thread.create(() -> {
			started.release();
			wait(40);
			done.release();
		});
		started.wait();
		started.wait();
		var keep = [];
		for (i in 0...300000) {
			var s = "x" + i;
			if (i % 1000 == 0) keep.push(s);
		}
		stop.store(true);
		done.wait();
		done.wait();
		trace("main: " + keep.length + " kept");
	}
}
