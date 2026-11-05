import hxmc.com.*;
import hxmc.unsafe.*;
import sys.thread.Lock;
import sys.thread.Thread;

// COM's apartments and the runtime's releases (docs/interop.md, "COM";
// Windows only): a value's reference is released on the thread that made it
// (an apartment-threaded object's Release belongs to its apartment). A
// single-threaded apartment's thread blocked in its message loop, which
// never allocates, is woken by a thread message (Com.WM_DEFERRED) once
// another thread's collection found its values dead, and runs their
// releases (Com.runDeferred). An ended thread's go to any thread. A thread
// of C's own that the runtime attached (a thunk's call) runs its own as it
// leaves Haxe. ComThreads_dyn.c is ComCalls_dyn.c: the same DLL.
@:hxmc.com("{6A1B0C2D-0001-4E5F-8A9B-0C1D2E3F4A01}")
extern interface ICounter extends IUnknown {
	function Add(n:Int):Void;
	function Get():Int;
}

@:hxmc.com("{6A1B0C2D-0001-4E5F-8A9B-0C1D2E3F4A08}")
extern interface ITake extends IUnknown {
	function Take(c:ICounter):Void;
	function Ping():Void;
}

class Taker implements ITake {
	public var taken:Null<ICounter>;
	public var pings = 0;

	public function new() {}

	public function Take(c:ICounter):Void
		taken = c;

	public function Ping():Void
		pings++;
}

@:hxmc.lib("comthreadsdyn") @:hxmc.c extern class Native {
	static function counter_new(out:Ptr):Int;
	static function counter_live():Int;
	static function counter_released_on():Int;
	static function taker_start(t:Ptr):Int;
	static function taker_finish():Void;
}

@:hxmc.c @:hxmc.lib("user32") extern class User32 {
	static function GetMessageW(msg:Ptr, hwnd:Ptr, min:Int, max:Int):Int;
	@:hxmc.fast static function PeekMessageW(msg:Ptr, hwnd:Ptr, min:Int, max:Int, remove:Int):Int;
}

@:hxmc.c @:hxmc.lib("kernel32") extern class Kernel32 {
	@:hxmc.fast static function GetCurrentThreadId():Int;
}

class ComThreads {
	static function counter():ICounter {
		var out = Mem.stack(8);
		Native.counter_new(out);
		return Com.adopt(Mem.getPtr(out, 0), ICounter);
	}

	// counters made and dropped by this thread: their values die here
	static function makeAndDrop(n:Int):Int {
		var sum = 0;
		for (i in 0...n) {
			var c = counter();
			c.Add(i);
			sum += c.Get();
		}
		return sum;
	}

	static function main() {
		Com.init(MultiThreaded);
		var base = Native.counter_live();
		var ready = new Lock(), done = new Lock();
		var tid = 0, woken = 0, sum = 0;
		Thread.create(() -> {
			Com.init(SingleThreaded);
			tid = Kernel32.GetCurrentThreadId();
			var msg = Mem.stack(64);
			// (the thread's message queue, made before anyone posts to it)
			User32.PeekMessageW(msg, Ptr.nil(), 0, 0, 0);
			sum = makeAndDrop(10);
			ready.release();
			// the apartment's message loop: no allocation, so the releases put
			// off for this thread run when its message comes
			while (User32.GetMessageW(msg, Ptr.nil(), 0, 0) > 0) {
				if (Mem.getI32(msg, 8) != Com.WM_DEFERRED) continue;
				woken++;
				Com.runDeferred();
				if (Native.counter_live() == base) break;
			}
			Com.uninit();
			done.release();
		});
		ready.wait();
		trace("made", sum, Native.counter_live() - base);
		// this thread's collection finds the apartment's values dead: their
		// releases go to that thread, which a thread message wakes
		hxmc.NativeGc.collect(true);
		Com.runDeferred();
		trace("released by its apartment's thread", done.wait(30), Native.counter_live() - base, Native.counter_released_on() == tid, woken > 0);

		// a thread that ends: what is put off for it runs as it ends, or once it
		// has ended on any thread (this one's collections: whichever comes first)
		var ended = new Lock();
		Thread.create(() -> {
			Com.init(MultiThreaded);
			keep = [for (i in 0...5) counter()];
			Com.uninit();
			ended.release();
		});
		ended.wait();
		trace("held after its maker ended", Native.counter_live() - base);
		keep = null;
		var left = -1;
		for (i in 0...500) {
			hxmc.NativeGc.collect(true);
			Com.runDeferred();
			left = Native.counter_live() - base;
			if (left == 0) break;
			Sys.sleep(0.01);
		}
		trace("released once its maker ended", left);

		// a thread of C's own: its value of the counter dropped by this
		// thread, released on it as it next leaves Haxe
		var taker = new Taker();
		var takerId = Native.taker_start(Com.ptr(taker, ITake));
		trace("taken on C's thread", taker.taken != null, Native.counter_live() - base);
		taker.taken = null;
		hxmc.NativeGc.collect(true);
		Com.runDeferred();
		var heldThen = Native.counter_live() - base;
		Native.taker_finish();
		trace("released on it as it left", heldThen, Native.counter_live() - base, Native.counter_released_on() == takerId, taker.pings);
		Com.uninit();
	}

	static var keep:Null<Array<ICounter>>;
}
