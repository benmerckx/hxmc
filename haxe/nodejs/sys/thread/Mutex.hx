package sys.thread;

// No-op mutex for the single-threaded Node compiler frontend.
class Mutex {
	public function new() {}
	public function acquire():Void {}
	public function tryAcquire():Bool return true;
	public function release():Void {}
}
