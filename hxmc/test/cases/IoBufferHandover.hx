import hxmc.unsafe.*;
import sys.thread.Deque;
import sys.thread.Lock;
import sys.thread.Thread;

// An IoBuffer moves between threads as a value (docs/interop.md, "I/O
// buffers"): one allocated on a thread may be freed on another. Its memory
// is the C library's malloc (musl's, glibc's, the UCRT's: one heap for the
// process, safe to free from any thread) or, on wasm32, the runtime's own
// (hxmc.rt.wasm.Heap: one thread, no per-thread caches). Workers fill
// buffers that the main thread checks and frees, and check and free buffers
// the main thread filled; on wasm32 (no threads) the same steps run in turn.
class IoBufferHandover {
	static inline var WORKERS = 4;
	static inline var EACH = 500;

	// the seed in the first 4 bytes, a pattern of it after them
	static function fill(b:IoBuffer, seed:Int) {
		b.setInt32(0, seed);
		for (i in 4...b.length)
			b.set(i, (seed + i * 7) & 0xFF);
	}

	static function check(b:IoBuffer):Bool {
		var seed = b.getInt32(0);
		for (i in 4...b.length)
			if (b.get(i) != (seed + i * 7) & 0xFF) return false;
		return true;
	}

	// a worker's part: EACH buffers filled and sent, then the main thread's checked and freed
	static function worker(w:Int, out:Deque<IoBuffer>, back:Deque<IoBuffer>, done:Lock, bad:Array<Int>) {
		for (i in 0...EACH) {
			var b = IoBuffer.alloc(16 + (i * 37 + w * 101) % 4000);
			fill(b, w * 1000 + i);
			out.add(b);
		}
		for (i in 0...EACH) {
			var b = back.pop(true);
			if (!check(b)) bad[w]++;
			b.free();
		}
		done.release();
	}

	static function main() {
		var threads = Mem.os() != 3;
		var out = new Deque<IoBuffer>();
		var backs = [for (w in 0...WORKERS) new Deque<IoBuffer>()];
		var done = new Lock();
		var bad = [for (w in 0...WORKERS) 0];
		for (w in 0...WORKERS)
			for (i in 0...EACH) {
				var b = IoBuffer.alloc(16 + (i * 53 + w) % 3000);
				fill(b, 5000 + w * 1000 + i);
				backs[w].add(b);
			}
		for (w in 0...WORKERS) {
			if (threads) Thread.create(() -> worker(w, out, backs[w], done, bad));
			else worker(w, out, backs[w], done, bad);
		}
		var freed = 0, wrong = 0, sum = 0;
		for (k in 0...WORKERS * EACH) {
			var b = out.pop(true);
			if (!check(b)) wrong++;
			sum += b.getInt32(0);
			b.free();
			freed++;
		}
		for (w in 0...WORKERS)
			done.wait();
		var badSum = 0;
		for (n in bad)
			badSum += n;
		trace('freed here $freed of the workers\' buffers ($wrong wrong, seeds ${sum}); the workers freed ${WORKERS * EACH} of the main thread\'s ($badSum wrong)');
	}
}
