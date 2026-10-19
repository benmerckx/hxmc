package ml2hx.std;

import String;
import StdTypes;

import ml2hx.rt.*;

// Stdlib.Mutex on one thread: locking an unlocked mutex succeeds, locking a
// locked one would block forever (OCaml raises Sys_error for the owner).
class MutexT {
	public var locked = false;
	public function new() {}
}

class Mutex {
	public static function create(_:Unit):MutexT return new MutexT();
	public static function lock(m:MutexT):Unit {
		if (m.locked) throw new SysError("Mutex.lock: Resource deadlock avoided");
		m.locked = true;
		return Unit.value;
	}
	public static function tryLock(m:MutexT):Bool {
		if (m.locked) return false;
		m.locked = true;
		return true;
	}
	public static function unlock(m:MutexT):Unit {
		if (!m.locked) throw new SysError("Mutex.unlock: Operation not permitted");
		m.locked = false;
		return Unit.value;
	}
	public static function protect<T>(m:MutexT, f:Unit->T):T {
		lock(m);
		try {
			var r = f(Unit.value);
			unlock(m);
			return r;
		} catch (e:haxe.Exception) {
			unlock(m);
			throw e;
		}
	}
}
