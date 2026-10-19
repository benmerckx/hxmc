package ml2hx.prim;

import ml2hx.rt.*;

class Mutex {
	public var locked = false;
	public var owner:Null<ml2hx.std.Thread.ThreadT>;
	public function new() {}
}

class Condition {
	public final waiters:Array<{woken:Bool}> = [];
	public function new() {}
}

// OCaml's sync.c (error-checking mutexes) over the master lock
// (ml2hx.rt.Gil): mutexes and conditions are state the lock's holder
// changes; a thread that waits releases the lock until another notifies.
// With one thread, locking a locked mutex, or waiting on a condition, could
// never return.
class Sync {
	public static function camlAtomicMakeContended<T>(v:T):Ref<T> return new Ref(v);
	public static function camlMlMutexNew(_:Unit):Mutex return new Mutex();
	public static function camlMlMutexLock(m:Mutex):Unit {
		var me = ml2hx.std.Thread.current;
		if (m.locked && (m.owner == me || !Gil.active)) throw new SysError("Mutex.lock: Resource deadlock avoided");
		while (m.locked) Gil.wait();
		m.locked = true;
		m.owner = me;
		return Unit.value;
	}
	public static function camlMlMutexTryLock(m:Mutex):Bool {
		if (m.locked) return false;
		m.locked = true;
		m.owner = ml2hx.std.Thread.current;
		return true;
	}
	public static function camlMlMutexUnlock(m:Mutex):Unit {
		if (!m.locked || m.owner != ml2hx.std.Thread.current) throw new SysError("Mutex.unlock: Operation not permitted");
		m.locked = false;
		m.owner = null;
		Gil.notifyAll();
		return Unit.value;
	}
	public static function camlMlConditionNew(_:Unit):Condition return new Condition();
	public static function camlMlConditionWait(c:Condition, m:Mutex):Unit {
		if (!Gil.active) throw new SysError("Condition.wait: no other thread can signal (one domain)");
		var w = {woken: false};
		c.waiters.push(w);
		camlMlMutexUnlock(m);
		while (!w.woken) Gil.wait();
		return camlMlMutexLock(m);
	}
	public static function camlMlConditionSignal(c:Condition):Unit {
		if (c.waiters.length > 0) {
			c.waiters.shift().woken = true;
			Gil.notifyAll();
		}
		return Unit.value;
	}
	public static function camlMlConditionBroadcast(c:Condition):Unit {
		if (c.waiters.length > 0) {
			for (w in c.waiters) w.woken = true;
			c.waiters.resize(0);
			Gil.notifyAll();
		}
		return Unit.value;
	}
}
