package ml2hx.rt;

// OCaml 5's systhreads on host threads: one master lock, held by the thread
// that runs converted code, released around blocking operations (Thread.join,
// yield and delay, Mutex.lock and Condition.wait when they wait, sleeps, I/O
// that waits), as OCaml's runtime lock is. Converted code thus never runs on
// two threads at once (it is not written for that), and Thread.self is the
// lock's holder. Inactive (no lock) until a second thread is created. Unlike
// OCaml, no tick thread preempts a thread that never blocks.
class Gil {
	#if (target.threaded || target.name == "hxmc")
	static var cond:Null<sys.thread.Condition>;
	static var self:sys.thread.Tls<ml2hx.std.Thread.ThreadT>;
	#end

	public static var active(get, never):Bool;

	static inline function get_active():Bool {
		#if (target.threaded || target.name == "hxmc")
		return cond != null;
		#else
		return false;
		#end
	}

	// before the first other thread: the calling (main) thread takes the lock
	public static function start(main:ml2hx.std.Thread.ThreadT) {
		#if (target.threaded || target.name == "hxmc")
		if (cond != null) return;
		self = new sys.thread.Tls();
		self.value = main;
		var c = new sys.thread.Condition();
		c.acquire();
		cond = c;
		#end
	}

	// a new thread's start: waits for the lock
	public static function enterNew(t:ml2hx.std.Thread.ThreadT) {
		#if (target.threaded || target.name == "hxmc")
		self.value = t;
		cond.acquire();
		ml2hx.std.Thread.current = t;
		#end
	}

	// around a blocking operation
	public static inline function leave() {
		#if (target.threaded || target.name == "hxmc")
		if (cond != null) cond.release();
		#end
	}

	public static inline function enter() {
		#if (target.threaded || target.name == "hxmc")
		if (cond != null) {
			cond.acquire();
			ml2hx.std.Thread.current = self.value;
		}
		#end
	}

	// waits (the lock released meanwhile) for another thread's notifyAll
	public static function wait() {
		#if (target.threaded || target.name == "hxmc")
		cond.wait();
		ml2hx.std.Thread.current = self.value;
		#end
	}

	public static inline function notifyAll() {
		#if (target.threaded || target.name == "hxmc")
		if (cond != null) cond.broadcast();
		#end
	}

	// a thread's end: the lock given up for good
	public static function exit() {
		#if (target.threaded || target.name == "hxmc")
		cond.broadcast();
		cond.release();
		#end
	}
}
