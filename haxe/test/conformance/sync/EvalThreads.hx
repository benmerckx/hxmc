// Eval's Lock, Semaphore and Condition (upstream 0f7251bbd and 74c5b464e: a
// counting semaphore and a condition with a timed wait and an owner, ported
// over the host's primitives): results of waits that time out, that are
// released or signaled by another thread, and the errors of a condition used
// without holding its mutex. Only outcomes are printed, never timings.
import sys.thread.Condition;
import sys.thread.Lock;
import sys.thread.Semaphore;
import sys.thread.Thread;

class EvalThreads {
	static function attempt(name:String, f:Void->Dynamic) {
		var r:Dynamic = try f() catch (e:Dynamic) 'error: $e';
		Sys.println('$name: $r');
	}

	static function main() {
		var lock = new Lock();
		attempt("lock timeout", () -> lock.wait(0.05));
		attempt("lock zero", () -> lock.wait(0));
		attempt("lock negative", () -> lock.wait(-1));
		attempt("lock nan", () -> lock.wait(Math.NaN));
		lock.release();
		lock.release();
		attempt("lock released twice, first", () -> lock.wait(0.05));
		attempt("lock released twice, second", () -> lock.wait());
		attempt("lock released twice, third", () -> lock.wait(0.01));
		Thread.create(() -> {
			Sys.sleep(0.05);
			lock.release();
		});
		attempt("lock released by a thread", () -> lock.wait(10));

		var sem = new Semaphore(2);
		attempt("semaphore try 1", () -> sem.tryAcquire());
		attempt("semaphore try 2", () -> sem.tryAcquire());
		attempt("semaphore try 3", () -> sem.tryAcquire());
		attempt("semaphore timeout", () -> sem.tryAcquire(0.05));
		attempt("semaphore zero", () -> sem.tryAcquire(0));
		attempt("semaphore nan", () -> sem.tryAcquire(Math.NaN));
		Thread.create(() -> {
			Sys.sleep(0.05);
			sem.release();
		});
		attempt("semaphore released by a thread", () -> sem.tryAcquire(10));
		sem.release();
		attempt("semaphore acquire", () -> {
			sem.acquire();
			"acquired";
		});

		var cond = new Condition();
		attempt("condition release unheld", () -> {
			cond.release();
			"released";
		});
		attempt("condition wait unheld", () -> {
			cond.wait();
			"waited";
		});
		attempt("condition timedWait unheld", () -> cond.timedWait(0.01));
		attempt("condition tryAcquire", () -> cond.tryAcquire());
		attempt("condition tryAcquire held", () -> cond.tryAcquire());
		attempt("condition acquire held", () -> {
			cond.acquire();
			"acquired";
		});
		attempt("condition timedWait timeout", () -> cond.timedWait(0.05));
		attempt("condition timedWait zero", () -> cond.timedWait(0));
		attempt("condition timedWait negative", () -> cond.timedWait(-1));
		attempt("condition timedWait nan", () -> cond.timedWait(Math.NaN));
		var ready = false;
		Thread.create(() -> {
			Sys.sleep(0.05);
			cond.acquire();
			ready = true;
			cond.signal();
			cond.release();
		});
		var signaled = false;
		while (!ready)
			signaled = cond.timedWait(10);
		Sys.println('condition signaled: $signaled $ready');
		attempt("condition release", () -> {
			cond.release();
			"released";
		});
		attempt("condition release again", () -> {
			cond.release();
			"released";
		});
		// another thread holds the mutex
		var holding = new Lock(), done = new Lock();
		Thread.create(() -> {
			cond.acquire();
			holding.release();
			done.wait();
			cond.release();
			holding.release();
		});
		holding.wait();
		attempt("condition tryAcquire held elsewhere", () -> cond.tryAcquire());
		attempt("condition release held elsewhere", () -> {
			cond.release();
			"released";
		});
		done.release();
		holding.wait();
		attempt("condition tryAcquire after", () -> cond.tryAcquire());
		cond.release();
	}
}
