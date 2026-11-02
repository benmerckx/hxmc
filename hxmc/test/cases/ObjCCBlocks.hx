import hxmc.objc.AutoreleasePool;
import hxmc.objc.Block;
import hxmc.objc.Id;
import hxmc.unsafe.*;

// blocks through C functions (docs/interop.md, "Blocks"): hxmc.objc.Block<F>,
// converted from and to functions where they are passed: Core Graphics
// calling back while the call runs, Grand Central Dispatch on its threads
// (dispatch_async, dispatch_apply), a block made by C called as a function.
@:hxmc.struct @:publicFields class CGPoint {
	var x:Float;
	var y:Float;

	function new(x:Float, y:Float) {
		this.x = x;
		this.y = y;
	}
}

@:hxmc.struct @:publicFields class CGSize {
	var w:Float;
	var h:Float;

	function new(w:Float, h:Float) {
		this.w = w;
		this.h = h;
	}
}

@:hxmc.struct @:publicFields class CGRect {
	var origin:CGPoint;
	var size:CGSize;

	function new(origin:CGPoint, size:CGSize) {
		this.origin = origin;
		this.size = size;
	}
}

extern class CGPath implements Id {}
extern class CGMutablePath extends CGPath {}

@:hxmc.c @:hxmc.framework("CoreGraphics") extern class CG {
	@:hxmc.retained static function CGPathCreateMutable():CGMutablePath;
	static function CGPathAddRect(p:CGMutablePath, m:Ptr, r:CGRect):Void;
	static function CGPathApplyWithBlock(p:CGPath, block:Block<(element:Ptr) -> Void>):Void;
}

@:hxmc.c extern class Dispatch {
	static function dispatch_get_global_queue(identifier:Int64, flags:Int64):Ptr;
	static function dispatch_async(queue:Ptr, block:Block<() -> Void>):Void;
	static function dispatch_apply(iterations:Int64, queue:Ptr, block:Block<(i:Int64) -> Void>):Void;
	static function dispatch_semaphore_create(value:Int64):Ptr;
	static function dispatch_semaphore_signal(s:Ptr):Int64;
	static function dispatch_semaphore_wait(s:Ptr, timeout:UInt64):Int64;
	static function dispatch_block_create(flags:Int64, block:Block<() -> Void>):Block<() -> Void>;
}

class ObjCCBlocks {
	static function main() AutoreleasePool.run(() -> {
		// called back during the call (moveTo 0, addLineTo 1, closeSubpath 4)
		var path = CG.CGPathCreateMutable();
		CG.CGPathAddRect(path, Ptr.nil(), new CGRect(new CGPoint(0, 0), new CGSize(2, 3)));
		var kinds = [];
		CG.CGPathApplyWithBlock(path, element -> kinds.push(Mem.getI32(element, 0)));
		trace("path", kinds);

		// on Dispatch's threads, a semaphore waited for
		var queue = Dispatch.dispatch_get_global_queue(0, 0);
		var done = Dispatch.dispatch_semaphore_create(0);
		var log = [];
		for (i in 0...3) {
			var label = "job " + i;
			Dispatch.dispatch_async(queue, () -> {
				log.push(label + " " + [for (k in 0...100) "x" + k].length);
				Dispatch.dispatch_semaphore_signal(done);
			});
			Dispatch.dispatch_semaphore_wait(done, -1);
		}
		trace("async", log);

		// many threads at once, each its own index
		var squares = [for (_ in 0...200) 0];
		Dispatch.dispatch_apply(200, queue, i -> {
			var n = i.toInt();
			squares[n] = [for (k in 0...n) 1].length * n;
		});
		hxmc.rt.Gc.collect(true);
		var sum = 0;
		for (s in squares)
			sum += s;
		trace("apply", sum);

		// a block made by C (dispatch_block_create: a copy of ours), called as a function
		var called = 0;
		var f:() -> Void = Dispatch.dispatch_block_create(0, () -> called++);
		f();
		f();
		trace("block result", called);
	});
}
