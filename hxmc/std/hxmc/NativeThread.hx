package hxmc;

// Threads, the base of the hxmc sys.thread package and of haxe.atomic:
// hxmc.rt.ThreadApi over hxmc.rt.Threads (OS threads in parallel, 1:1), or
// hxmc.rt.wasm.Threads on WebAssembly (one thread; with -D hxmc.wasm-gc
// hxmc.rt.gc.GcThreads, which runs a thread created when another waits for
// it). Threads are ids; the main thread is 1. park can return early, so
// callers check their condition again. Mutexes, conditions and semaphores
// are handles freed by the GC. An alias, so that the implementation is typed
// only for the programs that use threads.
typedef NativeThread = #if (hxmc.wasm_gc) hxmc.rt.gc.GcThreads #elseif (hxmc.target == "wasm32-wasi") hxmc.rt.wasm.Threads #else hxmc.rt.ThreadApi #end;
