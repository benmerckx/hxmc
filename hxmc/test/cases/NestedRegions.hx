import hxmc.NativeGc;
import hxmc.unsafe.*;
import sys.thread.Lock;
import sys.thread.Thread;

// Safe regions nest (docs/interop.md, "Blocking calls"): Blocking.enter
// returns the state it found and Blocking.leave takes it back, so an inner
// region inside an outer one, a @:hxmc.blocking extern's call or a call of
// an extern not @:hxmc.fast leaves the outer region as it was. A worker
// enters a region, does one of those, then spins without a GC point until
// the main thread has collected. Before, the inner end left the outer
// region too: the worker ran on outside it, the collection waited for it
// and it for the collection (a hang).
@:hxmc.c extern class Inner {
	@:hxmc.blocking @:native("strlen") static function strlenBlocking(p:Ptr):hxmc.I64;
	// (not @:hxmc.fast: a safe region of the call's own, MirBuild.cCall)
	static function getpid():Int;
	@:hxmc.lib("kernel32") static function GetCurrentProcessId():Int;
}

class NestedRegions {
	static function run(what:String, inner:Void->Void) {
		var flags = IoBuffer.alloc(8);
		var p = flags.ptr;
		var done = new Lock();
		Thread.create(() -> {
			var outer = Blocking.enter();
			inner();
			Atomic.store32(p, 1);
			// (no GC point: only the region lets the main thread collect)
			while (Atomic.load32(p.add(4)) == 0) {}
			Blocking.leave(outer);
			done.release();
		});
		while (Atomic.load32(p) == 0)
			Sys.sleep(0.001);
		var junk = [for (i in 0...1000) "x" + i];
		NativeGc.collect(true);
		Atomic.store32(p.add(4), 1);
		done.wait();
		flags.free();
		trace(what + ": collected while the worker was in its outer region", junk.length);
	}

	static function main() {
		run("inner enter/leave", () -> {
			var r = Blocking.enter();
			Blocking.leave(r);
		});
		run("@:hxmc.blocking call", () -> Inner.strlenBlocking(Mem.cstr("abc")));
		run("extern call", () -> Mem.os() == 2 ? Inner.GetCurrentProcessId() : Inner.getpid());
		run("three deep", () -> {
			var a = Blocking.enter();
			var b = Blocking.enter();
			Inner.strlenBlocking(Mem.cstr("abc"));
			Blocking.leave(b);
			Blocking.leave(a);
		});
		// after the outermost leave the thread runs: it allocates and collects
		var t = new Lock();
		Thread.create(() -> {
			var r = Blocking.enter();
			Blocking.leave(r);
			var a = [for (i in 0...20000) {i: i}];
			NativeGc.collect(false);
			trace("allocated after leave", a.length);
			t.release();
		});
		t.wait();
	}
}
