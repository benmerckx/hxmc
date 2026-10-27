package hxmc;

// The collector's API (hxmc.rt.Gc, or hxmc.rt.wasm.Gc on WebAssembly): its
// finalisers, for Eval's Gc.finalise (`f` is called with `v` once a major
// collection finds `v` unreachable; values outside the heap are never
// collected; never on WebAssembly), collections, and the heap measurements
// of the port's server/memory (context/Memory.hx: objsize, reached, heapBytes).
typedef NativeGc = #if (hxmc.target == "wasm32-wasi") hxmc.rt.wasm.Gc #else hxmc.rt.Gc #end;
