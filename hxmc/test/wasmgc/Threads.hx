// threads with -D hxmc.wasm-gc's one thread (GcCheck): a thread created runs
// when another waits for it (hxmc.rt.gc.GcThreads): fork-join, a consumer
// drained at the end, messages
import sys.thread.Deque;
import sys.thread.Lock;
import sys.thread.Mutex;
import sys.thread.Thread;

class Threads {
	static function main() {
		// fork-join
		var lock = new Lock();
		var result = 0;
		Thread.create(() -> {
			for (i in 0...10)
				result += i;
			lock.release();
		});
		lock.wait();
		Sys.println("joined " + result);
		// several, joined in turn
		var locks = [for (_ in 0...3) new Lock()];
		var parts = [0, 0, 0];
		for (k in 0...3)
			Thread.create(() -> {
				parts[k] = (k + 1) * 100;
				locks[k].release();
			});
		for (l in locks)
			l.wait();
		Sys.println("parts " + parts);
		// a consumer drained at the end
		var q = new Deque<Null<Int>>();
		var done = new Lock();
		var sum = 0;
		var m = new Mutex();
		Thread.create(() -> {
			while (true) {
				var x = q.pop(true);
				if (x == null) break;
				m.acquire();
				sum += x;
				m.release();
			}
			done.release();
		});
		for (i in 1...5)
			q.add(i);
		q.add(null);
		done.wait();
		Sys.println("consumed " + sum + " " + (q.pop(false) == null));
		// messages
		var main = Thread.current();
		var t = Thread.create(() -> {
			var s:String = Thread.readMessage(true);
			main.sendMessage(s + "!");
		});
		t.sendMessage("hi");
		Sys.println(Thread.readMessage(true));
		// a timed wait nothing ends
		Sys.println("timed " + new Lock().wait(0.01));
	}
}
