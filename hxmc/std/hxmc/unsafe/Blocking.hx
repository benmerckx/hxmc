package hxmc.unsafe;

// A safe region entered and left by hand (docs/interop.md, "Blocking
// calls"): while the thread is in it, other threads may collect, so it may
// block (a @:hxmc.fast call that waits: read, poll, io_uring_enter in a
// loop) without stalling their collections. The per-call form,
// @:hxmc.blocking on an extern, is preferred: it cannot be left unbalanced.
//
//   Blocking.enter();
//   var n = Posix.read(fd, buf.ptr, buf.length); // native memory only
//   Blocking.leave();
//
// Between enter and leave: no allocation, no call that may collect, no
// access to heap objects, no address of one (Mem.addr, BytesPtr.of); C gets
// native memory (IoBuffer, Arena, malloc). The references in locals are
// stored before enter and read back after leave (a collection may have
// moved their objects). Leave on every path, exceptions included (nothing
// in between should throw). Entering again inside changes nothing; leaving
// outside changes nothing. On WebAssembly (one thread) both do nothing.
class Blocking {
	public static inline function enter():Void {
		#if (hxmc.target != "wasm32-wasi")
		BlockingC.rt_blocking_enter();
		#end
	}

	public static inline function leave():Void {
		#if (hxmc.target != "wasm32-wasi")
		BlockingC.rt_blocking_leave();
		#end
	}
}

// (the runtime's markers, hxmc.rt.C's Leaf: calls the code generator knows
// by their symbols, GcPoints and Facts)
@:hxmc.c @:hxmc.fast private extern class BlockingC {
	static function rt_blocking_enter():Void;
	static function rt_blocking_leave():Void;
}
