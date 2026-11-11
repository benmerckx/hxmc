package hxmc;

// A point where a long loop lets a collection in (docs/interop.md,
// "Safepoints"). Natively a collection waits until every other thread
// reaches a safepoint (an allocation's slow path, a safe region): a loop
// that allocates nothing, a decoder's, holds every other thread's
// collection until it ends. poll() is one load while no collection waits,
// else the runtime's safepoint: a GC point, where the caller's references
// are rooted as at an allocation, and other runnable threads may run. GC
// code only (a kernel holds loans no collection may move). WebAssembly
// has one thread: nothing.
class Safepoint {
	#if (hxmc.target == "wasm32-wasi")
	public static inline function poll() {}
	#else
	public static inline function poll()
		if (@:privateAccess hxmc.rt.Threads.gcRequested != 0) stop();

	static function stop()
		@:privateAccess hxmc.rt.Threads.preempt();
	#end
}
