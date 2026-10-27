package hxmc.unsafe;

// A safe region entered and left by hand (docs/interop.md, "Blocking
// calls"): while the thread is in it, other threads may collect, so it may
// block (a @:hxmc.fast call that waits: read, poll, io_uring_enter in a
// loop) or run a long loop without a GC point, without stalling their
// collections. The per-call forms, @:hxmc.blocking on an extern or on an
// @:hxmc.unsafe function, are preferred: they cannot be left unbalanced.
//
//   var region = Blocking.enter();
//   var n = Posix.read(fd, buf.ptr, buf.length); // native memory only
//   Blocking.leave(region);
//
// enter returns the state it found, which leave takes back: regions nest
// (an inner enter and leave, or a @:hxmc.blocking call, inside a region
// leave it as it was; only the outermost leave ends it).
//
// Between enter and leave: no allocation, no call that may collect, no
// access to heap objects, no address of one (Mem.addr, BytesPtr.of); C gets
// native memory (IoBuffer, Arena, malloc). The references in locals are
// stored before enter and read back after leave (a collection may have
// moved their objects). Leave on every path, exceptions included (nothing
// in between should throw). On WebAssembly (one thread) both do nothing.
class Blocking {
	public static inline function enter():Int {
		#if (hxmc.target != "wasm32-wasi")
		return BlockingC.rt_blocking_enter();
		#else
		return 0;
		#end
	}

	public static inline function leave(region:Int):Void {
		#if (hxmc.target != "wasm32-wasi")
		if (region == 0) BlockingC.rt_blocking_leave();
		#end
	}
}

// (the runtime's markers, hxmc.rt.C's Leaf: calls the code generator knows
// by their symbols, GcPoints and Facts)
@:hxmc.c @:hxmc.fast private extern class BlockingC {
	static function rt_blocking_enter():Int;
	static function rt_blocking_leave():Void;
}
