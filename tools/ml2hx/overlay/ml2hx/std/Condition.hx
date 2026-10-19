package ml2hx.std;

import String;
import StdTypes;

import ml2hx.rt.*;

// Stdlib.Condition on one thread: nothing else can signal, so waiting
// would block forever.
class ConditionT {
	public function new() {}
}

class Condition {
	public static function create(_:Unit):ConditionT return new ConditionT();
	public static function wait(c:ConditionT, m:Mutex.MutexT):Unit throw new SysError("Condition.wait: no other thread can signal (single-threaded runtime)");
	public static function signal(c:ConditionT):Unit return Unit.value;
	public static function broadcast(c:ConditionT):Unit return Unit.value;
}
