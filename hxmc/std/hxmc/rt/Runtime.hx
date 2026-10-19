package hxmc.rt;

// The runtime's Haxe modules (docs/hxmc.md, "Runtime in Haxe"), loaded
// into every program through Std (hxmc/std/Std.hx). Their classes are
// @:keep (DCE keeps them typed); hxmc compiles only the functions a program
// calls, and the @:hxmc.export ones (generated code calls them by symbol).
import hxmc.rt.Str;
import hxmc.rt.Dyn;
import hxmc.rt.Arr;
import hxmc.rt.NArray;
import hxmc.rt.Bytes;
import hxmc.rt.Date;
import hxmc.rt.Names;
import hxmc.rt.FloatText;
import hxmc.rt.Boxes;
import hxmc.rt.LibM;
// WebAssembly's runtime (@:hxmc.wasm: what C provides on the native
// targets), typed for a program built for it only
#if (hxmc.target == "wasm32-wasi")
import hxmc.rt.wasm.Heap;
import hxmc.rt.wasm.Gc;
import hxmc.rt.wasm.Exit;
import hxmc.rt.wasm.Wasi;
import hxmc.rt.wasm.Libc;
import hxmc.rt.wasm.Threads;
// -D hxmc.wasm-gc's runtime (@:hxmc.wasmgc: the only one it binds, hxmc.wasmgc)
#if (hxmc.wasm_gc)
import hxmc.rt.gc.GcStr;
import hxmc.rt.gc.GcSys;
import hxmc.rt.gc.GcDyn;
import hxmc.rt.gc.GcNative;
#end
#else
// the native targets' runtime over the C library (@:hxmc.native): the
// collector, the threads, the start
import hxmc.rt.Gc;
import hxmc.rt.GcPaths;
import hxmc.rt.Threads;
import hxmc.rt.Start;
import hxmc.rt.WinRt;
#if hxmc.census
import hxmc.rt.Census;
#end
#end
// the threads' API (ThreadApi), mbedtls's and libuv's glue (Ssl, Uv; on
// WebAssembly NoSsl, NoUv) are typed with hxmc.NativeThread, NativeSsl and
// NativeUv, for the programs that use them

class Runtime {}
