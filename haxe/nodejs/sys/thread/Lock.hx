package sys.thread;

// Single-threaded stand-in: a wait requires an already available release;
// waiting for another thread is unsupported.
class Lock {
	var count = 0;
	public function new() {}
	public function wait(?timeout:Float):Bool {
		if (count == 0) {
			if (timeout != null) return false;
			throw "Lock.wait would block forever in the single-threaded JS shim";
		}
		count--;
		return true;
	}
	public function release():Void count++;
}
