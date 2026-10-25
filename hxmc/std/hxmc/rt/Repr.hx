package hxmc.rt;

// The representation the runtime's shared natives (Str, Arr, Bytes, Date:
// @:hxmc.anyHeap classes, each algorithm written once) work on: strings and
// their units, arrays and their elements, bytes, StringBuf's and
// BytesBuffer's storage, dates. Chosen at compile time: hxmc.rt.MemRepr over
// linear memory (Mem), or -D hxmc.wasm-gc's hxmc.rt.gc.GcRepr over WasmGC
// objects (W). All inline: what a native compiles to is its
// representation's own code.
#if (hxmc.wasm_gc)
typedef Repr = hxmc.rt.gc.GcRepr;
typedef Chars = hxmc.rt.gc.GcRepr.GcChars;
typedef Chars1 = hxmc.rt.gc.GcRepr.GcChars;
typedef Octets = hxmc.rt.gc.GcRepr.GcOctets;
#else
typedef Repr = hxmc.rt.MemRepr;
typedef Chars = hxmc.rt.MemRepr.MemChars;
typedef Chars1 = hxmc.rt.MemRepr.MemChars1;
typedef Octets = hxmc.rt.MemRepr.MemOctets;
#end
