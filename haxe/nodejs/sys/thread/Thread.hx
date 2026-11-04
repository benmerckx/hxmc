package sys.thread;

// Node compiler passes are single-threaded; user thread creation is unsupported.
class Thread {
	static final main = new Thread();
	function new() {}
	public static function current():Thread return main;
	public static function create(job:() -> Void):Thread {
		throw "Thread.create is not supported by the Node.js compiler host";
	}
	public function join():Void {}
}
