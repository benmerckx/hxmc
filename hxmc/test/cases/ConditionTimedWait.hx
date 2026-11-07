// sys.thread.Condition.timedWait (upstream 74c5b464e, hxmc's own over the
// runtime's timed condition wait): a wait that times out keeps the mutex,
// non-positive and NaN timeouts do not block, a signal or a broadcast ends
// waits early, the depth of the re-entrant mutex survives a wait, and a huge
// timeout is cut short as a spurious wakeup would be. Only outcomes are
// printed, never timings.
import haxe.Timer;
import sys.thread.Condition;
import sys.thread.Lock;
import sys.thread.Thread;

class ConditionTimedWait {
	static function main() {
		var c = new Condition();
		c.acquire();
		var t0 = Timer.stamp();
		var r = c.timedWait(0.1);
		var dt = Timer.stamp() - t0;
		Sys.println('timeout: $r, waited ${dt >= 0.05 && dt < 5}');
		Sys.println('zero ${c.timedWait(0)}, negative ${c.timedWait(-1)}, nan ${c.timedWait(Math.NaN)}');

		// signaled by another thread
		var ready = false;
		Thread.create(() -> {
			Sys.sleep(0.05);
			c.acquire();
			ready = true;
			c.signal();
			c.release();
		});
		var deadline = Timer.stamp() + 10, signaled = false;
		while (!ready) {
			var remaining = deadline - Timer.stamp();
			if (remaining <= 0 || !(signaled = c.timedWait(remaining)))
				break;
		}
		Sys.println('signaled: $ready $signaled');
		c.release();

		// the re-entrant mutex: held twice, waited on, released twice
		c.acquire();
		c.acquire();
		c.timedWait(0.01);
		c.release();
		var other = new Lock(), got = false;
		Thread.create(() -> {
			got = c.tryAcquire();
			if (got)
				c.release();
			other.release();
		});
		other.wait();
		Sys.println('still held once after the wait: ${!got}');
		c.release();

		// a broadcast ends every timed wait
		var n = 4, woken = 0, waiting = 0, done = new Lock(), go = false;
		for (i in 0...n)
			Thread.create(() -> {
				c.acquire();
				waiting++;
				var end = Timer.stamp() + 10;
				while (!go && c.timedWait(end - Timer.stamp())) {}
				if (go)
					woken++;
				c.release();
				done.release();
			});
		while (true) {
			c.acquire();
			var all = waiting == n;
			if (all) {
				go = true;
				c.broadcast();
			}
			c.release();
			if (all)
				break;
			Sys.sleep(0.01);
		}
		for (i in 0...n)
			done.wait();
		Sys.println('broadcast woke $woken of $n');

		// a timeout beyond the limit: cut short, reported as a wakeup, not a timeout
		var huge = false;
		Thread.create(() -> {
			Sys.sleep(0.05);
			c.acquire();
			huge = true;
			c.signal();
			c.release();
		});
		c.acquire();
		while (!huge)
			c.timedWait(1e12);
		Sys.println('huge timeout returned');
		c.release();
	}
}
