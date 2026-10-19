package hxmc.rt.gc;

// -D hxmc.wasm-gc: hxmc.NativeThread with one thread, as hxmc.rt.wasm.Threads
// (mutexes count: they are reentrant; semaphores count; thread-local values
// are globals; waits with a timeout sleep it out), but a thread created is
// not an error: it runs, to its end, when a running thread waits for what
// nothing else can do (a semaphore without a permit, a condition no one
// signalled, a park without an unpark, and no timeout): fork-join (a lock a
// thread releases), a pipe's reader, a queue's consumer drained at its end.
// Then the wait is tried again; a wait nothing ends still throws instead of
// hanging. Threads not run when the program ends never run.
class GcThreads {
	static var tls:Array<Dynamic>;
	static var tlsNext:Int;
	static var pending:Array<{id:Int, job:Dynamic}>;
	static var created:Int;
	static var running:Int; // the running thread's id, 0 the main thread (1)
	static var unparked:Map<Int, Bool>;

	static function never(what:String):Void
		throw what + ": no other thread can end this wait (WebAssembly has one thread)";

	static function sleep(timeout:Float)
		if (timeout > 0) GcSys.sleep(timeout);

	// the oldest thread not run yet, run to its end (an exception it lets
	// through reported as natively); false when there is none
	static function runOne():Bool {
		if (pending == null || pending.length == 0) return false;
		var t = pending.shift();
		var prev = running;
		running = t.id;
		try {
			t.job();
		} catch (e:Dynamic) {
			GcSys.printErr("Uncaught exception in thread " + t.id + ": " + Std.string(e) + "\n");
		}
		running = prev;
		return true;
	}

	public static function spawn(job:Dynamic):Int {
		if (pending == null) pending = [];
		var id = 2 + created++;
		pending.push({id: id, job: job});
		return id;
	}

	public static function current():Int
		return running == 0 ? 1 : running;

	// (no other threads call in)
	public static function attach():Bool
		return false;

	public static function count():Int
		return 1;

	public static function parallel():Bool
		return false;

	static function takeUnpark():Bool {
		if (unparked == null || !unparked.exists(current())) return false;
		unparked.remove(current());
		return true;
	}

	public static function park(timeout:Float):Bool {
		while (true) {
			if (takeUnpark()) return true;
			if (!runOne()) break;
		}
		if (timeout < 0) never("Thread park");
		sleep(timeout);
		return false;
	}

	public static function unpark(id:Int):Void {
		if (unparked == null) unparked = new Map();
		unparked.set(id, true);
	}

	public static function yield():Void {}

	public static function mutexNew():Dynamic
		return new Counter(0);

	public static function mutexAcquire(m:Dynamic):Void
		(m : Counter).n++;

	public static function mutexTryAcquire(m:Dynamic):Bool {
		(m : Counter).n++;
		return true;
	}

	public static function mutexRelease(m:Dynamic):Void {
		var c:Counter = m;
		if (c.n > 0) c.n--;
	}

	// (a condition counts its signals: a wait that finds one returns at once, a
	// wakeup its caller checks its condition after, as for any other)
	public static function condNew():Dynamic
		return new Counter(0);

	public static function condWait(c:Dynamic, m:Dynamic, timeout:Float):Bool {
		var k:Counter = c;
		while (k.n == 0 && runOne()) {}
		if (k.n > 0) {
			k.n--;
			return true;
		}
		if (timeout < 0) never("Condition wait");
		sleep(timeout);
		return false;
	}

	public static function condSignal(c:Dynamic):Void
		(c : Counter).n++;

	public static function condBroadcast(c:Dynamic):Void
		(c : Counter).n++;

	public static function semNew(value:Int):Dynamic
		return new Counter(value);

	public static function semAcquire(s:Dynamic, timeout:Float):Bool {
		var c:Counter = s;
		while (c.n == 0 && runOne()) {}
		if (c.n > 0) {
			c.n--;
			return true;
		}
		if (timeout < 0) never("Semaphore acquire");
		sleep(timeout);
		return false;
	}

	public static function semRelease(s:Dynamic):Void
		(s : Counter).n++;

	public static function tlsNew():Int
		return tlsNext++;

	public static function tlsGet(id:Int):Dynamic
		return tls == null || id < 0 || id >= tls.length ? null : tls[id];

	public static function tlsSet(id:Int, v:Dynamic):Void {
		if (id < 0) return;
		if (tls == null) tls = [];
		tls[id] = v;
	}
}

private class Counter {
	public var n:Int;

	public function new(n:Int)
		this.n = n;
}
