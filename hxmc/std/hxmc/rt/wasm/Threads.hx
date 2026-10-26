package hxmc.rt.wasm;

import hxmc.rt.C;

// hxmc.NativeThread for WebAssembly, which has one thread here
// (docs/hxmc.md, "WebAssembly"): creating a thread throws; mutexes count
// (they are reentrant), semaphores count, waits that nothing can end
// (no timeout, no permit, nobody to signal) throw instead of hanging, and
// waits with a timeout sleep it out; thread-local values are globals.
class Threads {
	static var tls:Array<Dynamic>;
	static var tlsNext:Int;
	static var unparked:Bool;

	static function never(what:String):Void
		Rt.rt_throw(what + ": no other thread can end this wait (WebAssembly has one thread)");

	static function sleep(timeout:Float) {
		if (timeout > 0) hxmc.rt.WasiSys.sleep(timeout);
	}

	public static function spawn(job:Dynamic):Int {
		Rt.rt_throw("threads are not supported on WebAssembly");
		return 0;
	}

	@:hxmc.unsafe public static function current():Int
		return 1;

	// (no other threads call in)
	@:hxmc.unsafe public static function attach():Bool
		return false;

	@:hxmc.unsafe public static function count():Int
		return 1;

	@:hxmc.unsafe public static function parallel():Bool
		return false;

	public static function park(timeout:Float):Bool {
		if (unparked) {
			unparked = false;
			return true;
		}
		if (timeout < 0) never("Thread park");
		sleep(timeout);
		return false;
	}

	public static function unpark(id:Int):Void {
		if (id == 1) unparked = true;
	}

	@:hxmc.unsafe public static function yield():Void {}

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

	public static function condNew():Dynamic
		return new Counter(0);

	public static function condWait(c:Dynamic, m:Dynamic, timeout:Float):Bool {
		if (timeout < 0) never("Condition wait");
		sleep(timeout);
		return false;
	}

	public static function condSignal(c:Dynamic):Void {}

	public static function condBroadcast(c:Dynamic):Void {}

	public static function semNew(value:Int):Dynamic
		return new Counter(value);

	public static function semAcquire(s:Dynamic, timeout:Float):Bool {
		var c:Counter = s;
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
