import hxmc.objc.Selector;
import hxmc.unsafe.*;

// Haxe methods Objective-C calls on threads the runtime did not start (an
// NSThread of performSelectorInBackground, GCD's workers): their entries
// attach the thread first
@:hxmc.lib("/usr/lib/libobjc.A.dylib") @:hxmc.objc extern class NSObject {
	static function alloc():NSObject;
	function init():NSObject;
	@:hxmc.framework("Foundation") function performSelectorInBackground(aSelector:Selector, withObject:Null<NSObject>):Void;
}

@:hxmc.c extern class Dispatch {
	static function dispatch_semaphore_create(value:Int64):Ptr;
	static function dispatch_semaphore_signal(sema:Ptr):Int64;
	static function dispatch_semaphore_wait(sema:Ptr, timeout:Int64):Int64;
}

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSOperationQueue extends NSObject {
	static function alloc():NSOperationQueue;
	override function init():NSOperationQueue;
	function addOperation(op:NSOperation):Void;
	function waitUntilAllOperationsAreFinished():Void;
}

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSOperation extends NSObject {}

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSInvocationOperation extends NSOperation {
	static function alloc():NSInvocationOperation;
	function initWithTarget(target:NSObject, selector:Selector, object:Null<NSObject>):NSInvocationOperation;
}

// a struct result through the entry, on another thread
@:hxmc.struct class Pair {
	public var a:Float;
	public var b:Float;
	public var c:Float;

	public inline function new(a, b, c) {
		this.a = a;
		this.b = b;
		this.c = c;
	}
}

class Worker extends NSObject {
	public var sema:Ptr;
	public var result:Array<String> = [];

	public function new() {}

	// (called by an NSThread: allocates, collects, then signals)
	public function work(arg:Null<NSObject>):Void {
		var keep = [for (i in 0...100000) "w" + i];
		hxmc.rt.Gc.collect(true);
		result.push(keep[99999]);
		Dispatch.dispatch_semaphore_signal(sema);
	}

	// (called by an operation queue's workers, concurrently)
	public function step(arg:Null<NSObject>):Void {
		var keep = [for (i in 0...10000) "s" + i];
		var p = pair(keep.length);
		lock.acquire();
		steps.push(p.a + p.b + p.c);
		lock.release();
	}

	public var steps:Array<Float> = [];
	var lock = new sys.thread.Mutex();

	public function pair(x:Float):Pair
		return new Pair(x, x * 2, x * 3);
}

@:hxmc.objc extern class WorkerMessages extends NSObject {
	function pair(x:Float):Pair;
}

class ObjCThreads {
	static var worker:Worker;

	static function main() {
		worker = new Worker();
		worker.sema = Dispatch.dispatch_semaphore_create(0);
		worker.performSelectorInBackground(Selector.of("work:"), null);
		Dispatch.dispatch_semaphore_wait(worker.sema, -1);
		trace("background thread: " + worker.result);

		// an operation queue's workers (GCD's)
		var queue = NSOperationQueue.alloc().init();
		for (_ in 0...16) queue.addOperation(NSInvocationOperation.alloc().initWithTarget(worker, Selector.of("step:"), null));
		queue.waitUntilAllOperationsAreFinished();
		trace("operations: " + worker.steps.length + ", " + worker.steps[0]);

		// a struct result through the entry
		var w:WorkerMessages = cast (worker : NSObject);
		var p = w.pair(2);
		trace("pair: " + p.a + " " + p.b + " " + p.c);
	}
}
