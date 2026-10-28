import hxmc.unsafe.Blocking;
import hxmc.unsafe.UInt8;
import sys.thread.Lock;
import sys.thread.Thread;

// The safe subset of GC-free code (docs/interop.md, "GC-free code"): without
// @:hxmc.unsafe a @:hxmc.gcfree or @:hxmc.blocking function computes with
// flat values (Int, Float, Bool, C scalars, enum abstracts), struct values
// (their constructors checked as its own code), locals, loops, switches,
// static reads, Math and calls of other such functions, and nothing else
// (reject/GcFree*). Called on the main thread, in a worker's region, and as
// a blocking function from a worker.
@:hxmc.struct @:publicFields class Vec {
	var x:Float;
	var y:Float;

	inline function new(x:Float, y:Float) {
		this.x = x;
		this.y = y;
	}
}

enum abstract Shape(Int) {
	var Square;
	var Circle;
}

class GcFreeSafe {
	static final SIDES = 4;
	static var scale = 2.0;

	@:hxmc.gcfree static function area(s:Shape, r:Float):Float
		return switch s {
			case Square: r * r * scale;
			case Circle: Math.PI * r * r;
		}

	@:hxmc.gcfree static function length(v:Vec):Float
		return Math.sqrt(v.x * v.x + v.y * v.y);

	@:hxmc.gcfree static function walk(n:Int):Vec {
		var p = new Vec(0, 0);
		for (i in 0...n) {
			var d = new Vec(i % SIDES == 0 ? 1.0 : 0.5, i % 3 == 0 ? -0.25 : 0.75);
			p.x += d.x;
			p.y += d.y;
		}
		return p;
	}

	@:hxmc.gcfree static function wrap(v:Int):UInt8
		return v;

	@:hxmc.gcfree static function collatz(n:Int):Int {
		var steps = 0;
		while (n != 1) {
			n = n & 1 == 0 ? n >> 1 : 3 * n + 1;
			steps++;
		}
		return steps;
	}

	@:hxmc.blocking static function busy(n:Int):Int {
		var best = 0;
		for (i in 1...n) {
			var s = collatz(i);
			if (s > best) best = s;
		}
		return best + Std.int(length(walk(n)));
	}

	static function main() {
		trace(area(Square, 3), Std.int(area(Circle, 1) * 1000));
		var p = walk(10);
		trace(p.x, p.y, Std.int(length(p) * 1000));
		trace((wrap(300) : Int), collatz(27));
		trace("main thread", busy(1000));
		var done = new Lock();
		var a = 0, b = 0;
		Thread.create(() -> {
			a = busy(1000);
			var region = Blocking.enter();
			var r = collatz(97);
			Blocking.leave(region);
			b = r;
			done.release();
		});
		done.wait();
		trace("worker", a, b);
	}
}
