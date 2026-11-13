// hxmc.Safepoint.poll (docs/interop.md, "Safepoints"): a loop that
// allocates nothing lets the collections another thread asks for in at
// each poll; without it they would wait for the loop's end. The worker's
// garbage needs many collections while the main thread loops.
class SafepointPoll {
	static function main() {
		var done = new sys.thread.Lock();
		sys.thread.Thread.create(() -> {
			var keep = [];
			for (i in 0...200000) {
				var s = "x" + i;
				if (i % 1000 == 0) keep.push(s);
			}
			trace("worker: " + keep.length + " kept");
			done.release();
		});
		var x = 0;
		for (i in 0...50000000) {
			x = (x * 31 + i) & 0xFFFFFF;
			if (i & 0xFFF == 0) hxmc.Safepoint.poll();
		}
		done.wait();
		trace("main: " + x);
	}
}
