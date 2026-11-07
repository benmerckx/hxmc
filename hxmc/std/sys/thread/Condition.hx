// hxmc: haxe/upstream/std/sys/thread/Condition.hx: a condition variable and its own
// re-entrant mutex (rt_thread.c); as with pthread conditions, wait may return
// spuriously

package sys.thread;

import hxmc.NativeThread;

/**
	Creates a new condition variable.
	Conditions variables can be used to block one or more threads at the same time,
	until another thread modifies a shared variable (the condition)
	and signals the condition variable.

	# Example
	```haxe
	import sys.thread.Thread;
	import sys.thread.Condition;

	function main() {
		var started = false;
		final cond = new Condition();
		Thread.create(() -> {
			cond.acquire();
			started = true;
			cond.signal();
			cond.release();
		});
		// Wait for the thread to start up
		cond.acquire();
		while(!started) {
			cond.wait();
		}
		cond.release();
	}
	```
**/
class Condition {
	final mutex:Dynamic = NativeThread.mutexNew();
	final cond:Dynamic = NativeThread.condNew();

	/**
		Create a new condition variable.
		A thread that waits on a newly created condition variable will block.
	**/
	public function new():Void {}

	/**
		Acquires the internal mutex.
	**/
	public function acquire():Void {
		NativeThread.mutexAcquire(mutex);
	}

	/**
		Tries to acquire the internal mutex.
		@see `Mutex.tryAcquire`
	**/
	public function tryAcquire():Bool {
		return NativeThread.mutexTryAcquire(mutex);
	}

	/***
		Releases the internal mutex.
	**/
	public function release():Void {
		NativeThread.mutexRelease(mutex);
	}

	/**
		Blocks the current thread until this condition variable receives a notification or a spurious wakeup occurs.

		The internal mutex is atomically released and the current thread blocked until the condition variable is signaled by a call to
		`signal` or `broadcast`, or a spurious wakeup occurs.
		When this function returns, the internal mutex will have been re-acquired.

		This function is susceptible to spurious wakeups.
		Condition variables should be associated with a boolean predicate,
		and this function should be called in a loop that checks the predicate to protect against spurious wakeups.

		The internal mutex must be locked before this function is called.
	**/
	public function wait():Void {
		NativeThread.condWait(cond, mutex, -1);
	}

	/**
		Like `wait`, but blocks the current thread for at most `timeout` seconds.

		A `timeout` that is zero or negative does not block for any meaningful
		amount of time. Very large timeouts may be cut short at a
		target-specific limit. A wait cut short this way returns `true`, like a
		spurious wakeup, so a loop that recomputes the remaining time (see
		below) keeps waiting.

		Returns `false` if the timeout expired, and `true` otherwise, that is
		when the condition variable was signaled or a spurious wakeup occurred.
		The internal mutex is re-acquired in all cases, including on timeout.

		This function is susceptible to spurious wakeups like `wait`, so it
		should be called in a loop that computes the remaining time on each
		iteration:

		```haxe
		final deadline = haxe.Timer.stamp() + 5.0;
		cond.acquire();
		while (!ready) {
			final remaining = deadline - haxe.Timer.stamp();
			if (remaining <= 0 || !cond.timedWait(remaining)) {
				break; // timed out
			}
		}
		cond.release();
		```

		The internal mutex must be locked before this function is called.
	**/
	// hxmc: a timeout that is not positive (or NaN) waits until now; the limit is
	// about 23 days (Eval's, under Windows' DWORD of milliseconds)
	public function timedWait(timeout:Float):Bool {
		if (!(timeout > 0))
			timeout = 0;
		var capped = timeout > MAX_WAIT;
		return NativeThread.condWait(cond, mutex, capped ? MAX_WAIT : timeout) || capped;
	}

	static inline final MAX_WAIT = 2e6;

	/**
		Unblocks one of the threads that are blocked on the
		condition variable at the time of the call. If no threads are blocked
		on the condition variable at the time of the call, the function does nothing.

		The internal mutex must be locked before this function is called.
	**/
	public function signal():Void {
		NativeThread.condSignal(cond);
	}

	/**
		Unblocks all of the threads that are blocked on the
		condition variable at the time of the call. If no threads are blocked
		on the condition variable at the time of the call, the function does
		nothing.

		The internal mutex must be locked before this function is called.
	**/
	public function broadcast():Void {
		NativeThread.condBroadcast(cond);
	}
}
