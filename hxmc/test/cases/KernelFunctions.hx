import hxmc.unsafe.*;
import sys.thread.Lock;
import sys.thread.Thread;

// @:hxmc.kernel (docs/interop.md, "Kernels"): checked as
// @:hxmc.blocking is (no GC point, no value of a GC type, calls only of
// kernels) but its calls enter no safe region, so one kernel
// serves both paths: called on the main thread, and by a worker inside a
// region it enters itself (Blocking.enter/leave, as a job pool does). A
// kernel may call a @:hxmc.blocking one (its call enters a
// region, which nests), and @:hxmc.kernel on a class covers its functions.
class KernelFunctions {
	@:hxmc.unsafe @:hxmc.kernel static function sum(p:Ptr<UInt8>, n:Int):Int {
		var s = 0;
		for (i in 0...n)
			s = (s * 31 + p[i]) & 0xFFFFFF;
		return s + Kernels.twice(1) + waitless(2);
	}

	@:hxmc.unsafe @:hxmc.blocking static function waitless(v:Int):Int
		return v + 1;

	static function main() {
		var data = IoBuffer.alloc(1000);
		for (i in 0...1000)
			data.set(i, i * 7);
		trace("main thread", sum(data.ptr, data.length));
		var done = new Lock();
		var got = 0;
		Thread.create(() -> {
			var p = data.ptr, n = data.length;
			var region = Blocking.enter();
			var r = sum(p, n);
			Blocking.leave(region);
			got = r;
			done.release();
		});
		done.wait();
		trace("in a worker's region", got);
		trace(Kernels.twice(21), Kernels.clamp(300));
		data.free();
	}
}

@:hxmc.unsafe @:hxmc.kernel class Kernels {
	public static function twice(v:Int):Int
		return v * 2;

	public static function clamp(v:Int):Int
		return v < 0 ? 0 : v > 255 ? 255 : v;
}
