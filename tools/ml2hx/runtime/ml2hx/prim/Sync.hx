package ml2hx.prim;

import ml2hx.rt.*;

class Mutex {
	public var locked = false;
	public function new() {}
}

class Condition {
	public function new() {}
}

// OCaml's sync.c on one thread: locking a locked mutex, or waiting on a
// condition, could never return.
class Sync {
	public static function camlAtomicMakeContended<T>(v:T):Ref<T> return new Ref(v);
	public static function camlMlMutexNew(_:Unit):Mutex return new Mutex();
	public static function camlMlMutexLock(m:Mutex):Unit {
		if (m.locked) throw new SysError("Mutex.lock: Resource deadlock avoided");
		m.locked = true;
		return Unit.value;
	}
	public static function camlMlMutexTryLock(m:Mutex):Bool {
		if (m.locked) return false;
		m.locked = true;
		return true;
	}
	public static function camlMlMutexUnlock(m:Mutex):Unit {
		if (!m.locked) throw new SysError("Mutex.unlock: Operation not permitted");
		m.locked = false;
		return Unit.value;
	}
	public static function camlMlConditionNew(_:Unit):Condition return new Condition();
	public static function camlMlConditionWait(c:Condition, m:Mutex):Unit throw new SysError("Condition.wait: no other thread can signal (one domain)");
	public static function camlMlConditionSignal(c:Condition):Unit return Unit.value;
	public static function camlMlConditionBroadcast(c:Condition):Unit return Unit.value;
}
