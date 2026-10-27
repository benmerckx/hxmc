import hxmc.I64;
import hxmc.NativeGc;
import hxmc.unsafe.*;
import sys.thread.Lock;
import sys.thread.Thread;

// @:hxmc.blocking on an @:hxmc.unsafe Haxe function (docs/interop.md,
// "Blocking calls"): its calls run in a safe region, so a long loop without
// a GC point in it lets other threads collect. A worker calls one that
// spins until the main thread has collected, and others that sum a buffer,
// call a @:hxmc.blocking extern and another blocking function (no new
// region inside one). Before, the call ran outside any region: the
// collection waited for the worker and the worker for the collection.
@:hxmc.c extern class Ext {
	@:hxmc.blocking @:native("strlen") static function strlen(p:Ptr):I64;
}

class BlockingFunctions {
	// spins until the flag at p + 4 is set, after setting the one at p
	@:hxmc.unsafe @:hxmc.blocking static function waitFor(p:Ptr):Int {
		Atomic.store32(p, 1);
		while (Atomic.load32(p.add(4)) == 0) {}
		return 1;
	}

	@:hxmc.unsafe @:hxmc.blocking static function sum(p:Ptr<UInt8>, n:Int):Int {
		var s = 0;
		for (i in 0...n)
			s = (s * 31 + p[i]) & 0xFFFFFF;
		return s + (Ext.strlen(Mem.cstr("four")) : I64).toInt() + twice(1);
	}

	@:hxmc.unsafe @:hxmc.blocking static function twice(v:Int):Int
		return v * 2;

	static function main() {
		var flags = IoBuffer.alloc(8);
		var data = IoBuffer.alloc(1000);
		for (i in 0...1000)
			data.set(i, i * 7);
		var p = flags.ptr;
		var done = new Lock();
		var got = [];
		Thread.create(() -> {
			got.push(waitFor(p));
			got.push(sum(data.ptr, data.length));
			done.release();
		});
		while (Atomic.load32(p) == 0)
			Sys.sleep(0.001);
		var junk = [for (i in 0...1000) "x" + i];
		NativeGc.collect(true);
		trace("collected while the worker was in waitFor", junk.length);
		Atomic.store32(p.add(4), 1);
		done.wait();
		trace(got);
		trace(twice(21), sum(data.ptr, 10));
		flags.free();
		data.free();
	}
}
