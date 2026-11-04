package sys.thread;

// Single-threaded stand-in for the Node.js compiler frontend.
class Semaphore {
	var count:Int;
	public function new(value:Int) count = value;
	public function acquire():Void {
		if (count <= 0) throw "Semaphore.acquire would block forever (single-threaded JS build)";
		count--;
	}
	public function tryAcquire(?timeout:Float):Bool {
		if (count <= 0) return false;
		count--;
		return true;
	}
	public function release():Void count++;
}
