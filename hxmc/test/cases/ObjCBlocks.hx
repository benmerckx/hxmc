import hxmc.objc.AutoreleasePool;
import hxmc.objc.Block;
import hxmc.unsafe.*;

@:hxmc.lib("/usr/lib/libobjc.A.dylib") @:hxmc.objc extern class NSObject {
	static function alloc():NSObject;
	function init():NSObject;
}

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSNumber extends NSObject {
	static function numberWithLongLong(v:Int64):NSNumber;
	var longLongValue(get, never):Int64;
	function get_longLongValue():Int64;
	function compare(other:NSNumber):Int64;
}

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSArray extends NSObject {
	function objectAtIndex(i:Int64):NSObject;
	function enumerateObjectsUsingBlock(block:(obj:NSObject, idx:Int64, stop:Ptr) -> Void):Void;
	function sortedArrayUsingComparator(cmptr:(a:NSObject, b:NSObject) -> Int64):NSArray;
}

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSMutableArray extends NSArray {
	static function alloc():NSMutableArray;
	override function init():NSMutableArray;
	function addObject(o:NSObject):Void;
	function removeAllObjects():Void;
}

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSOperationQueue extends NSObject {
	static var mainQueue(get, never):NSOperationQueue;
	static function get_mainQueue():NSOperationQueue;
	function addOperationWithBlock(block:() -> Void):Void;
}

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSRunLoop extends NSObject {
	static var currentRunLoop(get, never):NSRunLoop;
	static function get_currentRunLoop():NSRunLoop;
	function runUntilDate(date:NSDate):Void;
}

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSDate extends NSObject {
	static function dateWithTimeIntervalSinceNow(s:Float):NSDate;
}

@:hxmc.struct class Pair {
	public var a:Int64;
	public var b:Float;
	public var c:Int64;
	public inline function new(a, b, c) {
		this.a = a;
		this.b = b;
		this.c = c;
	}
}

@:hxmc.c extern class Dispatch {
	static function dispatch_async(queue:Ptr, block:Block<() -> Void>):Void;
	static function dispatch_get_global_queue(identifier:Int64, flags:Int64):Ptr;
	static function dispatch_semaphore_create(value:Int64):Ptr;
	static function dispatch_semaphore_signal(sema:Ptr):Int64;
	static function dispatch_semaphore_wait(sema:Ptr, timeout:Int64):Int64;
	// (a block of libdispatch's own, calling the one given)
	static function dispatch_block_create(flags:Int64, block:Block<() -> Void>):Block<() -> Void>;
}

// Haxe methods Objective-C calls with blocks, and returning one
class Calls extends NSObject {
	public function new() {}

	public function callTwice(f:(x:Int64) -> Int64):Int64
		return f(f(1));

	public function adder(n:Int64):(x:Int64) -> Int64
		return x -> x + n;
}

@:hxmc.objc extern class CallsMessages extends NSObject {
	function callTwice(f:(x:Int64) -> Int64):Int64;
	function adder(n:Int64):(x:Int64) -> Int64;
}

class Holder {
	public var block:Block<() -> Void>;

	public function new() {}
}

class ObjCBlocks {
	static function run(seconds:Float)
		NSRunLoop.currentRunLoop.runUntilDate(NSDate.dateWithTimeIntervalSinceNow(seconds));

	static function main() AutoreleasePool.run(() -> {
		// called while the message runs: a mutable local captured, a result
		var arr = NSMutableArray.alloc().init();
		for (i in 0...5)
			arr.addObject(NSNumber.numberWithLongLong(i * 10));
		var sum:Int64 = 0;
		arr.enumerateObjectsUsingBlock((o, idx, stop) -> sum += (cast o : NSNumber).longLongValue + idx);
		trace("enumerate: " + sum);
		var sorted = arr.sortedArrayUsingComparator((a, b) -> (cast b : NSNumber).compare(cast a));
		trace("sorted: " + [for (i in 0...5) (cast sorted.objectAtIndex(i) : NSNumber).longLongValue]);

		// kept by Objective-C, called later, collections in between
		var log = [];
		for (i in 0...3) {
			var label = "op" + i;
			NSOperationQueue.mainQueue.addOperationWithBlock(() -> log.push(label));
		}
		for (_ in 0...2)
			hxmc.rt.Gc.collect(true);
		run(0.1);
		trace("later: " + log);

		// a C function's block, the main queue's and a worker's (a thread the
		// runtime did not start, which collects)
		var done = false;
		Dispatch.dispatch_async(Mem.sym("_dispatch_main_q"), () -> done = true);
		run(0.1);
		trace("main queue: " + done);
		var sema = Dispatch.dispatch_semaphore_create(0);
		var onWorker:Array<String> = [];
		Dispatch.dispatch_async(Dispatch.dispatch_get_global_queue(0, 0), () -> {
			onWorker.push("ran");
			for (i in 0...100000)
				onWorker.push(null);
			onWorker.resize(1);
			Dispatch.dispatch_semaphore_signal(sema);
		});
		Dispatch.dispatch_semaphore_wait(sema, -1);
		trace("worker: " + onWorker);

		// a function to a block and back: the same function
		var calls:CallsMessages = cast(new Calls() : NSObject);
		trace("round trip: " + calls.callTwice(x -> x * 10));
		var add5 = calls.adder(5);
		trace("block result: " + add5(1));
		var f = x -> x;
		var b:Block<(x:Int64) -> Int64> = f;
		var g:(x:Int64) -> Int64 = b;
		trace("identity: " + (f == g));

		// a block of libdispatch's: called through its invoke
		var count = 0;
		var wrapped:() -> Void = Dispatch.dispatch_block_create(0, () -> count++);
		wrapped();
		wrapped();
		trace("foreign block: " + count);

		// a block of another signature of the same C types: through its invoke,
		// a struct by value both ways
		var ptrBlock:Block<(p:Ptr, s:Pair) -> Pair> = (p, s) -> new Pair(s.a + p.toI64(), s.b * 2, s.c - 1);
		var asObj:(o:NSObject, s:Pair) -> Pair = (cast ptrBlock : Block<(o:NSObject, s:Pair) -> Pair>);
		var r = asObj(cast Ptr.ofI64(100), new Pair(1, 1.5, 7));
		trace("struct: " + r.a + " " + r.b + " " + r.c);

		// a block in a field, null as nil
		var h = new Holder();
		h.block = () -> count += 10;
		(h.block : () -> Void)();
		trace("field: " + count);
		var nothing:Block<() -> Void> = (null : () -> Void);
		trace("null: " + ((nothing : () -> Void) == null));

		// the closure collected once Objective-C releases the block
		var collected = [false];
		AutoreleasePool.run(() -> {
			var keep = NSMutableArray.alloc().init();
			var marker = {name: "captured"};
			hxmc.rt.Gc.finalise(_ -> collected[0] = true, marker);
			var b:Block<() -> Void> = () -> trace(marker.name);
			keep.addObject(cast b);
			keep.removeAllObjects();
		});
		for (_ in 0...3)
			hxmc.rt.Gc.collect(true);
		hxmc.rt.Gc.runFinalisers();
		trace("released and collected: " + collected[0]);

		// many blocks made and released, collections among them
		var total:Int64 = 0;
		for (i in 0...20000) {
			AutoreleasePool.run(() -> arr.enumerateObjectsUsingBlock((o, idx, stop) -> total += idx));
			if (i % 5000 == 0) hxmc.rt.Gc.collect(i % 10000 == 0);
		}
		trace("many: " + total);

		// closures capturing nothing: global blocks (one per function and
		// signature, never freed), the function again when called back
		var g1:Block<(o:NSObject, idx:Int64, stop:Ptr) -> Void> = visit;
		var g2:Block<(o:NSObject, idx:Int64, stop:Ptr) -> Void> = visit;
		trace("global: " + (g1 == g2) + " " + (Mem.getI32(cast g1, 8) & (1 << 28) != 0) + " " + Reflect.compareMethods((g1 : (o:NSObject, idx:Int64, stop:Ptr) -> Void), visit));
		arr.enumerateObjectsUsingBlock(visit);
		arr.enumerateObjectsUsingBlock((o, idx, stop) -> visited += 100);
		hxmc.rt.Gc.collect(true);
		arr.enumerateObjectsUsingBlock(g1);
		var sema = Dispatch.dispatch_semaphore_create(0);
		workerSema = sema;
		Dispatch.dispatch_async(Dispatch.dispatch_get_global_queue(0, 0), signalWorker);
		Dispatch.dispatch_semaphore_wait(sema, -1);
		trace("global calls: " + visited);
	});

	static var visited = 0;
	static var workerSema:Ptr;

	static function visit(o:NSObject, idx:Int64, stop:Ptr):Void
		visited++;

	static function signalWorker():Void {
		var keep = [for (i in 0...10000) "g" + i];
		visited += keep.length;
		Dispatch.dispatch_semaphore_signal(workerSema);
	}
}
