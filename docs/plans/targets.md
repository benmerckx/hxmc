# Targets

Built: Linux, Windows and macOS on x86-64 and ARM64, the glibc mode on
Linux, and wasm32-wasi ([docs/hxmc.md](../hxmc.md), "Targets" and
"WebAssembly"). Dropped: APE (Cosmopolitan) executables; the six targets
are built natively and the releases ship per platform.

## WebAssembly

Built: a linear-memory module from Mir with the whole runtime in Haxe;
the corpus passes under node and wasmtime, the port as a module compiles
itself (about 1.8x native time); the playground runs it in browsers
(WASI's imports from JavaScript, `site/client/WasiHost.hx`; exnref, or
the legacy encoding). Left:

- Threads: wasm threads (shared memory, atomics, `memory.atomic.wait`)
  under wasi-threads or a browser's workers; the collector's
  stop-the-world handshake of the native targets (`Threads.hx`) would come
  back. Until then `Thread.create` throws.
- Sockets and processes need WASI preview 2 (or JavaScript imports).
- Firefox's throws walk the whole stack (0.17 us per frame each): a
  lighter use of exceptions in the port's hot paths, or setjmp-free try
  blocks, would avoid it.
- Speed: no tail calls; 485k `i32.wrap_i64` remain in the playground's
  module, of i64 values also used in full: a second, i32 local for those
  with many address uses, or an i32 pointer type in Mir, would remove most
  (about 480 KB raw, little gzipped).
- Size and startup of UI apps: a small canvas app is about 1.8 MB of wasm,
  against about 44 KB of JavaScript with the DOM renderer. Link-time dead
  code elimination ([compiler.md](compiler.md#central-object-cache-and-quieter-builds))
  first, then code splitting with lazily loaded wasm modules; time to
  first frame measured on a mid-range phone.
- The playground's module size (10.8 MB, 2.1 MB gzipped): folding a call
  into its user (30 KB raw, but 16 KB more gzipped), fewer wraps.

### WasmGC: a later, browser-focused second path

Not the first WebAssembly target, but worth revisiting. An earlier
prototype compiled the same IR to both (`docs/WASM-BACKEND.md`, removed in
ecb1af2; last version at 4a2c28c), Bench under Node 22:

| | Linear memory (C via Emscripten) | WasmGC |
| --- | --- | --- |
| Run time | 0.39 s | 0.36–0.40 s |
| Module size | 32.2 KB (runtime, malloc, printf) | 2.1 KB (no runtime) |
| Code per function | 1.7–3.2× larger | smaller |
| Peak memory | 146 MB | 86 MB |
| Wasmtime (Cranelift) | | 2.0 s (deferred reference counting) |

For WasmGC: much smaller modules (the engine's collector, `struct.new`
allocation, no shadow stack or barriers), direct JavaScript interop
(objects passed by reference), memory returned to the system. Against it:

- A different runtime, not only a different back end: hxmc's runtime in
  Haxe works on raw memory (`Mem.addr`, loads and stores, layouts), which
  WasmGC objects do not have. Strings, Dynamic access, maps, `Bytes` and
  reflection would need separate implementations (the prototype never
  covered Dynamic, anonymous structures or strings).
- Browser-centric: non-browser engines lag (Wasmtime above); linear
  memory runs well everywhere, WASI included.
- No threads until shared-everything threads land.
- Weaker finalizers and weak references.

Revisit when a concrete browser use makes module size or JavaScript
interop matter (browser games, web islands). The structuring pass and the
module writer carry over; the object model and the runtime would be new.

Started (2026-10-17) behind `-D hxmc.wasm-gc` to compare the two collectors
(docs/hxmc.md, "WasmGC"): the IR after Lower, emitted directly, with a
runtime of its own in Haxe over intrinsics. Every HaxeBenchmarks case runs,
its check identical on every target (`make bench`'s `hxmc-wasmgc` target);
`make wasmgc-check` compares `hxmc/test/wasmgc`'s programs (and the
NativeArray and Vector corpus cases) with native. `hxmc.NativeArray` and the
std's Vector over it are the same as natively (docs/hxmc.md, "Native
arrays"): a Vector is the engine's bare array of its kind.

#### Performance against linear memory (2026-10-18)

The question: can it come close enough to linear memory to be the
browser's default? First measured, it took a third to a half of the memory
and was as fast on half the cases, but up to twice as slow where small
objects are made and read in loops (mandelbrot, formatter_noio). What
closed the gap, in hxmc:

- Scalar replacement on the IR (`wasmgc/IrOpt`): a local that only holds
  objects made in the function, read through their fields, becomes a
  local per field (a constructor's writes, right after the allocation,
  allowed). Calls are inlined only where that lets it happen (a callee
  returning an object it makes, or passed one made here): Mir's `Inline`
  and `Sroa` cannot be reused, Mir being memory loads and stores already,
  and inlining more made the modules larger, not faster (V8 inlines small
  functions of a WasmGC module itself; it does not take objects out of the
  heap). Mandelbrot: 1.82 s to 0.70 s; the binaryen run that pointed here
  (`wasm-opt -O3`: inlining, heap2local) gave 1.10 s.
- Fewer casts (V8's own `--experimental-wasm-assume-ref-cast-succeeds`
  measures them: 14% of formatter_noio's time, now 5%): leaf classes'
  types final; arrays, enums, closures, Bytes typed in locals, fields,
  globals, signatures, enum arguments and captures (`GcModule.keyOf`);
  methods with their own typed signatures (the dispatch table holds
  wrappers); a local only ever cast to one type given it (`FuncGen.refine`:
  closure parameters, Dynamic read as a class).
- Inline fast paths: array reads, writes and pushes (kind and range tested,
  `br_on_cast_fail`, the helper only for another kind or growth);
  structural reads and writes test the layouts that have the field (they
  all went through the runtime by name for writes).
- Runtime: identity hashes (ObjectMap had one bucket: keyed lists were
  quadratic), Ints of -128...1023 boxed once as `hxmc.rt.Boxes` does,
  `Null<Int>` loop counters in GcStr typed Int, UTF-8 conversions in one
  pass, Bytes.compare eight bytes a step, `Type.enumEq` casting once.
- Size: literals of 24 characters and more made from passive data segments
  (a byte a character for Latin-1): bcrypt's module 306 KB to 133 KB.

HaxeBenchmarks under node 22 (V8 12.4), wall time, median of 5 runs
interleaved (native, linear, WasmGC before and after), peak RSS, module
size (linear without a name section). `make bench` (`-n 3`) agrees, every
check identical:

| case | native s | linear s | WasmGC before s | WasmGC s | / linear | native MB | linear MB | WasmGC MB | linear KB | WasmGC before KB | WasmGC KB |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| alloc | 1.59 | 2.45 | 2.91 | 2.53 | 1.03 | 749 | 1556 | 678 | 42 | 9 | 10 |
| bcrypt | 2.97 | 3.45 | 3.10 | 3.11 | 0.90 | 4 | 151 | 55 | 278 | 306 | 133 |
| binarytrees | 0.71 | 1.10 | 0.94 | 0.96 | 0.87 | 117 | 183 | 85 | 38 | 8 | 8 |
| json | 0.52 | 0.79 | 0.80 | 0.77 | 0.97 | 140 | 337 | 194 | 117 | 29 | 33 |
| mandelbrot | 0.75 | 0.98 | 1.82 | 0.70 | 0.71 | 11 | 152 | 54 | 43 | 10 | 10 |
| mandelbrot_anon | 1.28 | 2.42 | 3.91 | 0.91 | 0.38 | 11 | 152 | 54 | 46 | 10 | 10 |
| nbody | 0.75 | 1.04 | 1.22 | 0.99 | 0.95 | 0 | 149 | 51 | 42 | 11 | 12 |
| sha256 | 0.19 | 0.35 | 0.38 | 0.34 | 0.97 | 21 | 155 | 67 | 250 | 291 | 116 |
| sha512 | 0.02 | 0.14 | 0.08 | 0.07 | 0.50 | 9 | 151 | 56 | 256 | 296 | 120 |
| formatter_noio | 6.29 | 8.08 | 14.32 | 8.86 | 1.10 | 261 | 258 | 104 | 1092 | 501 | 548 |

Every case is now within 10% of linear memory or faster (seven of ten
faster), with a third to a half of its memory and modules 2 to 8 times
smaller. Build time: the formatter's WasmGC build 3% longer than before
(scalar replacement, the second emission of refined functions; 1.2 s,
about the linear build's). The native and linear paths are unchanged.

What is left of the gap: formatter_noio (10%) spends it spread thin: the
casts left (5%: values read from arrays of references, anonymous
structures' fields, which share layouts across types, and Dynamic), null
checks (4%, `--experimental-wasm-skip-null-checks`), `array.copy` of
references (Array.concat in a loop) and Type.enumEq against hxmc's own.
alloc's collection of half a million 100-byte to 1 KB arrays costs V8
more than hxmc's nursery, and a byte array has no wider reads. All
measured on V8 only, and an older one than Chrome's (node 22: no
Turboshaft for wasm, inlining only for WasmGC modules); SpiderMonkey and
JavaScriptCore are unmeasured.

#### A real program: the UI stack

The UI stack (universe's packages: the counter, the gallery, a list of
1000 rows; frame times at parity with linear memory, the module half the
size) was the program the hybrid module below was made for; its numbers
moved with the packages (universe's docs/plans/wasmgc-ui.md).

#### The hybrid module (2026-10-18)

Done, in this order, each with linear memory's output unchanged (every
corpus program, benchmark case and the tool byte-identical, natively and as
wasm; the fixpoint and crosshost identical):

1. **One runtime** ("One runtime" below): the natives of strings, arrays,
   Bytes, Date and StringBuf written once over `hxmc.rt.Repr`.
2. **One reachability**: `GcGen.Reach` retired for the program-wide
   `hxmc.ir.Reach` (method-level, by name), run a second time over IrOpt's
   bodies so a function inlined everywhere is dropped; the runtime's exports
   live where WasmGC's code calls them. HaxeBenchmarks' modules 0.6-15%
   smaller (formatter_noio 562992 to 519353 bytes with the name section
   now written only with `-debug`; json, which now has Arrays' and
   Strings' methods for structural calls, 34145 to 40173), and Reflect and
   Dynamic access keep what they reach.
3. **The hybrid module** (docs/hxmc.md, "WasmGC"): Haxe's values in the
   engine's collector, a small linear memory for `hxmc.unsafe` (`Mem`,
   `Ptr`, frame areas, C string literals, malloc's heap, `Arena`,
   `CString`) and for the imports, which take pointers into it as linear
   memory's do (wasm32's C ABI); exported as `memory` with the callbacks'
   table, so `browser.mjs` and the packages' `imports.mjs` run either kind
   of module. A Bytes stays a GC array: `hxmc.unsafe.BytesPtr` copies it
   through the memory where it crosses (linear memory: its address, no
   copy): WebGPU's and GL's buffer, texture and uniform writes and GL's
   readback, the page's fonts, text from the page (canvas window, ui's
   drawn and native text). `@:hxmc.struct` classes whose fields are all
   final (the shaders' Vec2-4, Mat4) are objects. i8-array views of a
   Bytes are not something JavaScript can make (a GC array is opaque to
   it), so the copy is a loop in wasm, measured below as part of the
   frame. The packages' changes are a line at each crossing (os, gfx,
   text; ui's two `take`s, one line each), so the same Haxe builds both
   ways. `HXMC_GC_SURVEY`: gfx-cube, ui-counter and ui-gallery 0
   unsupported constructs. Found on the way: structural calls of an
   Array's or a String's methods (Iterable<T>), dead code after an if on
   the target (`IrOpt.live`), a local set from Dynamic (Haxe's unchecked
   conversions: a String holding a closure), all fixed.

Checked: `make wasmgc-check` (now with `Unsafe.hx`), and the packages'
browser tests on WasmGC builds (now universe's: `make gfx-web-check`: 6 scenes on WebGPU and WebGL2,
headless and in a canvas, resize, text input, wheel, the readback
checksum, the same pixel differences as linear memory; `make
ui-web-check`: the todo example on both APIs with pointer, keyboard,
clipboard, accessibility mirror, input method, wheel and touch, the
native form, the native text editors).

#### The site's examples, both ways

Measured on the website's examples before the split (universe's
docs/plans/wasmgc-ui.md): WasmGC modules smaller to download, frame times
at parity in Chromium and Firefox, the first frame of the UI examples up to
72% later in Chromium, WebKit's gallery frames 60% slower.

HaxeBenchmarks under node 22 after all of the above, median of 5 (`make
bench`'s targets hxmc, hxmc-wasm, hxmc-wasmgc; every check identical; the
linear builds with main's startup memory fix):

| case | native s | linear s | WasmGC s | / linear | native MB | linear MB | WasmGC MB | linear KB | WasmGC KB |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| alloc | 1.71 | 2.58 | 2.85 | 1.10 | 749 | 1467 | 667 | 42 | 8 |
| bcrypt | 2.97 | 3.37 | 3.12 | 0.93 | 4 | 58 | 54 | 278 | 131 |
| binarytrees | 0.74 | 1.10 | 1.15 | 1.04 | 117 | 119 | 85 | 38 | 7 |
| json | 0.52 | 0.75 | 0.83 | 1.11 | 140 | 245 | 191 | 103 | 39 |
| mandelbrot | 0.79 | 0.99 | 0.70 | 0.71 | 11 | 64 | 53 | 42 | 8 |
| mandelbrot_anon | 1.31 | 2.40 | 1.01 | 0.42 | 11 | 64 | 53 | 44 | 8 |
| nbody | 0.79 | 1.03 | 1.05 | 1.02 | 0 | 52 | 50 | 42 | 10 |
| sha256 | 0.20 | 0.30 | 0.34 | 1.14 | 21 | 75 | 69 | 250 | 114 |
| sha512 | 0.03 | 0.11 | 0.08 | 0.70 | 9 | 58 | 56 | 255 | 118 |
| formatter_noio | 6.55 | 8.22 | 9.39 | 1.14 | 262 | 193 | 101 | 1045 | 507 |

Against the table above: linear memory got faster and smaller (the
startup fix: sha256 0.35 to 0.30 s, json 0.79 to 0.75 s, peak RSS 58-75 MB
instead of 150), so the memory lead is now small except where much is
allocated (alloc, json, formatter_noio), and four cases are 10-14% slower
than linear memory instead of within 10%. Part of it is WasmGC's own:
formatter_noio 8.86 to 9.39 s, of which about 3% is the local set from
Dynamic that is no longer given a type (correctness: a String local may
hold a closure, as view's text holes do), the rest not yet attributed.

#### What switching the browser builds would take, and the call

What is no longer an obstacle: the packages' boundary (the same code builds
both ways, every browser test passes on both), the duplicated runtime,
the reachability. What stays linear memory regardless: WASI (node's CLI,
wasmtime, the npm compiler and the playground's compiler: files and
processes), engines without WasmGC, programs that need threads (shared
memory and workers exist for linear memory; WasmGC waits for
shared-everything threads).

**Recommendation: not yet (no-go for now), for browser builds only to be
revisited after the items below.** The hybrid module works and is smaller to
download, with frame times at parity in Chromium and Firefox, but the
case for switching rested on memory, which main's startup fix took away
(the linear builds now start at 10-22 MB), and it is not ahead elsewhere:
the UI examples' first frame is up to 72% later in Chromium, WebKit's
gallery frames are 60% slower, and one unexplained trap in WebKit. Next:

1. Startup of large WasmGC modules: string literals made lazily instead
   of in `_start`'s globals, Meta's tables only when reflection is used,
   the dispatch table overlaid as linear memory's rows are; then measure
   the first frame again.
2. WebKit: profile the gallery's frames (JSC's WasmGC casts and
   `array.copy`), and reproduce the trap (stress the WasmGC counter's
   first frame) against the playground's investigation.
3. Smaller modules where gzip counts: the code's casts and the
   strings' encoding.
4. The benchmarks' 10-14% (formatter_noio, sha256, json, alloc): the
   casts the untyped locals cost now, and what else moved since the
   previous table.

Switch browser builds (programs on a canvas, islands of a page) when the
first frame and WebKit hold; keep linear memory for
WASI, the compiler modules and threads, and as the fallback (one define,
`-D hxmc.wasm-gc`, chooses).

#### Object-level Mir and the call again (2026-10-22)

WasmGC is now generated from the native pipeline's object-level Mir
([#34](https://github.com/benmerckx/hxmc/issues/34) stage 5:
docs/plans/codegen.md, "Built: stage 5"): one optimizer (inlining, escape
analysis, value numbering, loop-invariant code motion, condition
propagation) for native code, linear wasm and WasmGC; `wasmgc/IrOpt` and
the IR walker are gone. Measured against main's IrOpt path (node 22, a
machine shared with other work, medians of 5):

| | IrOpt | object-level Mir | linear memory |
| --- | --- | --- | --- |
| the port's module (gzip -9) | 10.8 MB (3.80) | 9.8 MB (3.19) | |
| its self-compile s, peak RSS | 19.35, 1026 MB | 17.94, 951 MB | |
| a small compile s, peak RSS | 2.38, 639 MB | 2.49, 407 MB | |
| `--version` s | 0.30 | 0.31 | |
| HaxeBenchmarks s: alloc | 2.74 | 2.78 | 1.82 |
| bcrypt | 7.93 | 3.05 | 3.14 |
| binarytrees | 1.07 | 1.10 | 1.23 |
| json | 0.92 | 0.94 | 0.91 |
| mandelbrot | 0.76 | 0.73 | 0.71 |
| mandelbrot_anon | 1.00 | 0.72 | 1.48 |
| nbody | 1.16 | 1.23 | 1.11 |
| sha256 | 0.44 | 0.28 | 0.37 |
| sha512 | 0.09 | 0.10 | 0.10 |
| formatter_noio | 11.23 | 11.13 | 8.42 |

(The linear column from the same run as the Mir one; main's bcrypt took
7.9 s in every run here, 3.1 s in the tables above, and the Mir path does
not have that.) Smaller modules where gzip counts (item 3 above: the port
16% smaller gzipped), the same speed elsewhere, and the separate optimizer
gone: the second compiler the "not yet" partly rested on is now a lowering.

**The call: still not yet**, for the same reasons as before, which the
optimizer was not one of: formatter_noio is 1.3 times linear memory's time
and alloc 1.5 (the engine's collector and the casts of untyped values),
the first frame of large modules (item 1) and WebKit (item 2: not
measurable here, no browser in this environment) are where they were.
Revisit with items 1, 2 and 4.

#### A large program: tsc-haxe (2026-10-22)

tsc-haxe (the TypeScript compiler's Haxe port) builds and runs as a WasmGC
module (two MirGen fixes, and WASI's path calls under the WasmGC runner:
docs/hxmc.md, "WasmGC"), its output and emitted files identical to
linear memory's and to the other ports'. On the TS6 compiler's sources
under node 22, medians of 5 (wall s, peak RSS MB):

| | check | decl | full | module MB (gzip -9) |
| --- | --- | --- | --- | --- |
| linear memory | 6.79, 481 | 7.18, 481 | 9.24, 584 | 12.9 (3.48) |
| WasmGC | 7.78, 567 | 8.54, 579 | 11.27, 729 | 10.6 (3.29) |

WasmGC is 15-22% slower and takes 18-25% more memory here, the module 5%
smaller gzipped: a compiler is the allocation-heavy case where V8's
collector costs more than hxmc's nursery (about 10% of the time in GC,
casts and null checks a few percent each), as alloc and formatter_noio
showed. It does not change the call above; a WASI program stays linear.

#### One runtime

The natives of strings, StringBuf, arrays, Bytes, BytesBuffer and Date
(`hxmc.rt.Str`, `Arr`, `Bytes`, `Date`) are one implementation for both
paths (`@:hxmc.anyHeap`), written over `hxmc.rt.Repr`: the representation
chosen at compile time, `MemRepr` over `Mem` (rt.h's layouts, the
barriers) or `hxmc.rt.gc.GcRepr` over `W` (arrays of units and bytes, the
arrays' kinds as wasm types). What a native means (index normalization,
UTF-8 and UTF-16 conversion, number formatting and parsing, hashing,
searching, sorting, the calendar's formats, errors) is written once;
`Repr` is the storage: a string's units, an array's elements by kind,
block copies, StringBuf's and BytesBuffer's storage, a date's fields. All
of it inline, so linear memory's natives compile to what they did: every
program of the corpus (185 executables and modules), the HaxeBenchmarks
cases and the tool are byte-identical to before, natively and as wasm.
WasmGC gets linear memory's semantics where its copies had drifted
(`Array.insert` with a negative position, `String.indexOf` from a
negative start, `Std.parseInt`'s 32-bit wrap, UTF-8 decoding, bounds
errors), and FPHelper. Removed from `hxmc/std/hxmc/rt/gc`: GcStr's
string natives, GcBuf, GcArr, GcBytes, GcBytesBuffer, GcDate (1,300 lines
of duplicated natives to 380 of GcRepr's representation).

What stays WasmGC's own, and why:

| GC module | what | why |
| --- | --- | --- |
| GcRepr | the representation (W) | the counterpart of MemRepr |
| GcStr | `hx_str_eq`, StringBuf.addChar's common case | linear memory's generated code does them inline (MirBuild) |
| GcNArray | NArray's NativeArray views, wrappers, copies, defaults and errors | the same logic over W.na*: a NativeArray is the engine's array of its kind, its kind its wasm type, a wrapper a struct |
| GcDyn, GcNative | Dynamic's comparison, Std.string's dispatch, reflection (as hxmc.Native) | Dyn reads type descriptors and slots through Mem (146 calls); here the tables are Meta's and fields are reached by generated code. Their shared part would be a few lines of comparison: moving it out of Dyn would change linear memory's code |
| GcSys | WasiSys | the host's (node's) fs instead of WASI over linear memory |

Not duplicated either: everything above the natives (Std, Type, Reflect,
the maps, haxe.Json, haxe.crypto...) is the same Haxe source.

#### The compiler itself (2026-10-18)

The port (`haxe.Main`, every generator) builds with `-D hxmc.wasm-gc` and,
run by node as the port, passes the lanes the native port passes
(docs/testing.md, "The port as a WasmGC module"): HXB 279 + 7
expected failures, macros 66/66, `--hxb-lib` 7/7, `--interp` 275/275 (but
a case whose Eval threads interleave), display 679/679, `-L` 7/7 (batch),
upstream's target suites compiled for every target, identical; its
self-compile's HXB archive is the native port's, module by module.
Nothing in `haxe/src` changed. What it lacked, all in hxmc:

- runtime functions over raw memory: the atomics (a NativeArray of one
  element), `NativeZip` (the same decoder, over copies of the Bytes in the
  hybrid module's linear memory), the collector's API (`GcCollector`);
  `rt_throw` (a throw); `FPHelper` came with the one runtime;
- the system: files by descriptor, processes (a worker thread of the host,
  the module waiting on `Atomics.wait` for each answer), the shell, threads
  (one: a thread created runs when another waits for it, `GcThreads`, which
  is what calling haxelib for `-lib` needs: a thread reads stderr),
  directories in the system's order (node's `readdirSync` sorts them, and
  toplevel completion lists types in the order the class path is read);
- reflection: statics through a class value (the macro API's readers are
  classes passed as Dynamic; `hxmc.ir.Reach` takes `GcNative.find`'s names
  as `Dyn`'s), `Reflect.copy` (each macro call copies the compiler API),
  `Std.isOfType` with a type known at run time only, Array and String
  methods through Dynamic (`gc_anon_call`, as through structural types:
  `Lambda` over an Array), calling a non-function as an error rather than
  a trap.

Measured with node 24 (2026-10-19, medians of 5 interleaved runs on an
Intel Xeon E-2356G at 3.2 GHz, 6 cores / 12 threads, 62 GB, Linux 6.1),
the self-compile to HXB (`-cp haxe/src -main haxe.Main --interp
--no-output --hxb`), the same archive from all three:

| | native | linear | WasmGC |
| --- | --- | --- | --- |
| self-compile s | 3.75 | 5.9 | 8.3 |
| peak RSS MB | 640 | 880 | 1130-1440 (V8's collector: it varies by run) |
| a small compile s | 0.06 | 0.32 | 0.74 |
| module MB (gzip -9) | | 15.5 (2.9) | 10.2 (3.5) |

(The small compile: `unit.moduleload.TryCatch` to `--interp`; `--version`
alone takes 0.13 s, linear memory's 0.08 s. WasmGC's took 0.37 s while
V8's optimizing compiler worked on two large functions of enum reflection,
which process.exit waits for; they are one small function per enum now.
Before memory grew by an eighth at a time and the nursery followed the
native policy, linear memory's self-compile took 6.9 s and 1070 MB.)
What it does not have: sockets (the compilation server, the server lanes,
the Eval debugger), threads that interleave, `Sys.getChar`; Math's
transcendental functions are V8's, not musl's as on every other target (no
lane shows a difference).

## Android

ARM64 (and x86-64 for emulators) ELF shared library loaded through JNI or
`NativeActivity`: position-independent code with GOT/PLT, a TLS model for
`.so` (initial-exec/TLSDESC), imports of `libc.so`/`liblog`/`libandroid`
written directly (no NDK), 16 KB segment alignment (Android 15+), runtime
built against Bionic. Packaging without the SDK: binary-XML manifest,
`resources.arsc`, zipalign, APK Signature Scheme v2/v3;
`hasCode="false"` apps need no `classes.dex`. Google Play needs an Android
App Bundle (`.aab`: protobuf manifest/resources). Java glue (permissions,
billing) would need a DEX writer (the port has a JVM generator) or
Google's `d8`.

Order:

1. NativeActivity apps (done, [hxmc.md](../hxmc.md#android)): `NativeActivity`
   (`hasCode="false"`), the program's library and its entry; the APK writer (binary XML, an aligned zip, v2 signing with a
   generated debug key: ECDSA P-256 in plain Haxe rather than through
   mbedtls, so that the WebAssembly tool writes APKs too); `adb` only to
   install. No `resources.arsc` was needed (the label a plain string, a
   framework theme). TLS: TLSDESC on arm64, the general dynamic model on
   x86-64 (Bionic implements TLSDESC on arm64 and riscv64 only), never
   initial-exec (refused for a dlopen'ed library); the floor is API 29, the
   first Bionic with ELF TLS. CI: AndroidHello on an x86-64 emulator with
   KVM on a Linux runner, not a required check yet. Left from this step:
   several ABIs in one APK, release signing with the developer's keystore
   (PKCS#12, v3 for key rotation), icons and a `resources.arsc`, the `.aab`
   for Google Play, `DT_RELR` (API 30+) or Android's packed relocations to
   shrink the RELATIVE table, RELRO for the data that holds addresses.
2. Java glue (done, [hxmc.md](../hxmc.md#android)): a minimal DEX writer
   (`Dex.hx`) for the glue (`org.hxmc.Glue`, one listener class whose
   methods call a static native registered with `RegisterNatives`;
   `org.hxmc.Activity`, a `NativeActivity` whose window draws views),
   added when the program has the glue's functions; the views attach
   Java's main thread to the runtime (`NativeThread.attach`). CI:
   `AndroidViews`'s `classes.dex` checked by ApkCheck. JNI's bindings, the
   views and mixing GPU views among them are a library's (universe's
   `@hxmc/os` and `@hxmc/ui`).

## iOS

ARM64 Mach-O like macOS arm64 with the iOS platform tag (and the
simulator as its own platform), TLV descriptors, `.app` bundle with
`Info.plist` (launch screen via `UILaunchScreen`, no storyboard), real
certificate signing with entitlements and provisioning profiles (as
`rcodesign` does without Apple tools), `.ipa` packaging. Build from Linux
or Windows; install on devices with libimobiledevice. Open questions: the
app icon's compiled asset catalog (`Assets.car`, undocumented), the App
Store's declared SDK/Xcode version checks, simulator testing (macOS
only). No JIT on iOS.

Order:

1. GPU only (done, [hxmc.md](../hxmc.md#ios)): `ios-arm64` and
   `ios-sim-arm64`, macOS arm64's Mach-O and runtime objects with the
   platform in `LC_BUILD_VERSION` (minimum 15.0: `UILaunchScreen` is 14's,
   and 15 is the floor of current Xcodes; SDK 18.0) and `Mem.platform()`
   for packages; the bundle writer (an XML `Info.plist` with an empty
   `UILaunchScreen`, `CodeResources`, an ad hoc signature written by the
   linker with the bundle's special slots, `CodeSign.hx`, which macOS's
   linker signature now is too), the `.ipa`; a UI library's
   `UIApplicationMain` run by the generated main (`hxmc_ui_main`), the
   program's body inside UIKit's loop (universe's `@hxmc/os`). CI:
   `IosCheck` on Linux, IosHello on an iPhone simulator of a macOS runner
   (`xcrun simctl`), not required checks yet. `ios-sim-x86_64` is left
   out: x86-64 needs `objc_msgSend_stret` (Objective-C calls returning
   large structs) and Intel runners are going away. Left from this step:
   - device signing: the CMS signature blob by the developer's
     certificate (RSA or P-256: `P256.hx` has the curve, DER exists for
     Android), the provisioning profile copied in as
     `embedded.mobileprovision`, its entitlements (also as DER, slot 7,
     needed since iOS 15), the designated requirement naming the
     certificate's chain, the team id: `CodeSign.Identity` is the API,
     filled from a PKCS#12 export of the developer's identity and a profile
     downloaded from their account; installs then through
     libimobiledevice or `xcrun devicectl`;
   - the app icon and an asset catalog (`Assets.car`: undocumented; a
     `CFBundleIcons` of plain PNGs works for the home screen until then),
     `PkgInfo`, a binary `Info.plist`;
   - UIScene (required by the SDK after iOS 26: the generated main's
     part), `os_log` for what the app prints on a device;
   - the App Store's checks (the declared SDK and Xcode in `Info.plist`'s
     DT* keys, `LC_ENCRYPTION_INFO_64`), the main stack (`RT_STACK_MB`'s
     1 GB reservation; iOS limits an app's address space).
## Shared libraries and position-independent output

Needed by Android and plugins: the relocation model, TLS model, output
kind and segment alignment are already parameters in `Abi`/`Target`.

## Windows

- **A GUI subsystem define.** Executables are always console programs
  today, so double-clicking a GUI app opens a console as well.
  `-D hxmc.subsystem=windows` writes subsystem 2 (GUI) in the PE header;
  launched from a terminal, the program attaches to the parent console
  (`AttachConsole(ATTACH_PARENT_PROCESS)`) so `trace` still prints.
  Documented beside `-D hxmc.libc=glibc` in the README and docs/using.md.
  (Found building a small app, Oct 19.)
- The dev loop's cold first edit: [dev-loop.md](dev-loop.md#windows-the-first-edit-is-a-cold-build-found-oct-19).

## Linux

- A dynamic musl mode (`/lib/ld-musl-<arch>.so.1`, unversioned:
  `Abi.setLibc`), beside the glibc mode.
- Choosing the glibc mode by itself when a program imports a shared
  library (today an import in the static mode is a compile error naming
  the mode).
- Lazy binding (PLT) if startup with many imports needs it.
- Direct system calls instead of musl: [runtime.md](runtime.md).

## macOS

- Split the runtime's Mach-O objects per function (or select sections) so
  unused runtime code is dropped, as on ELF; today they are linked whole
  (`ssl.o` is 0.8-0.9 MB).
- x86-64 Objective-C calls returning structs over 16 bytes
  (`objc_msgSend_stret`), which a Metal back end needs.
