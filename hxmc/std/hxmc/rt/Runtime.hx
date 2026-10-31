package hxmc.rt;

// The runtime's Haxe modules (docs/hxmc.md, "Runtime in Haxe"), loaded
// into every program through Std (hxmc/std/Std.hx). Their classes are
// @:keep (DCE keeps them typed); hxmc compiles only the functions a program
// calls, and the @:hxmc.export ones (generated code calls them by symbol).
// A module defining a symbol generated code refers to is imported here for
// each target that needs it, not left to another module that loads it:
// every build checks these imports define them all, whatever the program
// calls (hxmc/src/hxmc/ir/RuntimeSymbols.hx).
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
// what a null access calls
import hxmc.rt.NullAccess;
// WebAssembly's runtime (@:hxmc.wasm: what C provides on the native
// targets), typed for a program built for it only
#if (hxmc.target == "wasm32-wasi")
import hxmc.rt.wasm.Heap;
import hxmc.rt.wasm.Gc;
import hxmc.rt.wasm.Exit;
import hxmc.rt.wasm.Wasi;
import hxmc.rt.wasm.Libc;
import hxmc.rt.wasm.Threads;
#else
// the native targets' runtime over the C library (@:hxmc.native): the
// collector, the threads, the start
import hxmc.rt.Gc;
import hxmc.rt.GcPaths;
import hxmc.rt.Threads;
import hxmc.rt.Start;
import hxmc.rt.WinRt;
// Objective-C exceptions reaching Haxe frames (Apple's systems: LinkMachO, DataGen.objcCaught)
import hxmc.rt.ObjCExceptions;
#if hxmc.census
import hxmc.rt.Census;
#end
// (the interpreter: a program interpreted; a Mir host reaches it through its own code, macro.Loader)
#if hxmc.interp
import hxmc.rt.Interp;
#end
#end
// the threads' API (ThreadApi), mbedtls's and libuv's glue (Ssl, Uv; on
// WebAssembly NoSsl, NoUv) are typed with hxmc.NativeThread, NativeSsl and
// NativeUv, for the programs that use them

class Runtime {}
