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
interop matter (browser games, `@hxmc/web`). The structuring pass and the
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

(As of the 17th; both build and run now: "The hybrid module" below.)
Neither ui-counter nor gfx-cube builds. `HXMC_GC_SURVEY=1` lists what each
lacks (=2 writes the module, those functions trapping):

- ui-counter, 34 constructs, all at the browser boundary, none in the
  ui, text and view code: imports that take pointers (`@hxmc/os`'s canvas
  window, text input, clipboard and cursor; the accessibility mirror;
  WebGPU's shader, buffer and texture uploads; the page's fonts read into
  a Bytes), raw memory (`Mem`, `malloc`/`free`, `Arena`, `CString`,
  strings as UTF-8 through memory), and the GL back end (reached because
  `Device` picks its back end at run time; its calls take pointers too).
  Imports of numbers only are now supported (`scale`,
  `prefers_dark`, `font_count`...).
- gfx-cube, 31: the same, plus `@:hxmc.struct` values (the shaders' Vec2,
  Vec3, Vec4 and Mat4 data, written into GPU buffers through field
  addresses).

What does build is the engine itself. StressTest's list of 1000 rows
without the GPU (markup, signals, styles, flex layout, text shaped with
DejaVu Sans by `@hxmc/text`, the accessibility tree; a program outside the
repository: the fonts added from a file, the page's font lookup skipped),
median of 5, node 22:

| | native | linear | WasmGC |
| --- | --- | --- | --- |
| mount (markup to nodes) ms | 17 | 39 | 32 |
| first layout (styles, flex, text) ms | 33 | 59 | 61 |
| toggle, relabel, scroll, append (each) ms | 0.7-1 | 0.6-1.1 | 0.5-1.3 |
| 5 accessibility trees ms | 7 | 7 | 8 |
| whole run (5 rounds) s | 0.32 | 0.72 | 0.73 |
| peak RSS MB | 102 | 261 | 204 |
| module KB (gzip -9) | 2163 | 1609 (396) | 775 (251) |

Frame times (an update's layout and text) are at parity with linear
memory, the module half the size; painting and the GPU's part could not be
measured. Getting there needed four fixes found by this program (a
structural call to a method of another representation, Vector reads in
generic code, Std.int out of range, BytesBuffer) and the identity hashes.

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

Checked: `make wasmgc-check` (now with `Unsafe.hx`), and the browser tests
on WasmGC builds (`make gfx-web-check`: 6 scenes on WebGPU and WebGL2,
headless and in a canvas, resize, text input, wheel, the readback
checksum, the same pixel differences as linear memory; `make
ui-web-check`: the todo example on both APIs with pointer, keyboard,
clipboard, accessibility mirror, input method, wheel and touch, the
native form, the native text editors).

#### The site's examples, both ways

Built as the site builds them (`-D hxmc.wasm-eh=legacy`, no name
section), the linear builds with main's startup memory fix (010fa12):

| example | linear KB | gzip -9 | WasmGC KB | gzip -9 | WasmGC / linear |
| --- | --- | --- | --- | --- | --- |
| gfx-cube | 193.0 | 53.0 | 100.8 | 37.1 | 0.52 (0.70 gzipped) |
| ui-counter | 1226.9 | 319.3 | 824.0 | 273.3 | 0.67 (0.86) |
| ui-gallery | 2275.9 | 530.0 | 1481.0 | 466.5 | 0.65 (0.88) |

(ui-counter's WasmGC module: code 688 KB, string literals as globals 54
KB, the dispatch table's elements 21 KB, a dense class-by-selector matrix
linear memory overlays.)

Run in Chromium 141, Firefox 142 (headed, under Xvfb: headless Firefox
has no WebGL) and WebKit 26.0 by Playwright, 3 runs each, the medians:
ready (fetch, compile, instantiate and main), the first frame, the frame
callbacks' time while the cube turns, the counter is clicked 30 times or
the gallery scrolled 30 times; memory: the linear memory plus, in
Chromium, the JS heap (which holds WasmGC's objects; the others give no
such number, so their WasmGC column shows the linear memory only); RSS:
the browser's own processes above an empty page. WebGPU on SwiftShader in
Chromium, WebGL2 elsewhere (llvmpipe, Mesa); no GPU, a shared 4-core
machine:

| browser | example | build | ready ms | first frame ms | frame mean ms | frame p90 ms | memory MB | browser RSS MB |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Chromium | gfx-cube | linear | 70 | 80 | 0.43 | 0.9 | 12.6 | 62 |
| Chromium | gfx-cube | WasmGC | 61 | 81 | 0.36 | 0.7 | 3.6 | 62 |
| Chromium | ui-counter | linear | 117 | 177 | 0.57 | 2.1 | 23.9 | 88 |
| Chromium | ui-counter | WasmGC | 147 | 199 | 0.56 | 2.1 | 9.5 | 96 |
| Chromium | ui-gallery | linear | 161 | 270 | 2.12 | 5.1 | 24.8 | 130 |
| Chromium | ui-gallery | WasmGC | 237 | 465 | 1.99 | 5.0 | 17.8 | 131 |
| Firefox | gfx-cube | linear | 121 | 123 | 0.31 | 1.0 | 10.3 | 85 |
| Firefox | gfx-cube | WasmGC | 173 | 175 | 0.25 | 1.0 | (1.3) | 89 |
| Firefox | ui-counter | linear | 279 | 316 | 0.59 | 2.0 | 21.6 | 117 |
| Firefox | ui-counter | WasmGC | 309 | 378 | 0.49 | 2.0 | (2.3) | 125 |
| Firefox | ui-gallery | linear | 445 | 581 | 3.54 | 12.0 | 21.8 | 144 |
| Firefox | ui-gallery | WasmGC | 422 | 575 | 3.43 | 9.0 | (3.3) | 164 |
| WebKit | gfx-cube | linear | 118 | 146 | 2.72 | 3.0 | 10.3 | 53 |
| WebKit | gfx-cube | WasmGC | 93 | 115 | 2.93 | 4.0 | (1.3) | 55 |
| WebKit | ui-counter | linear | 198 | 262 | 0.44 | 1.0 | 21.6 | 104 |
| WebKit | ui-counter | WasmGC | 210 | 263 | 0.40 | 1.0 | (2.3) | 106 |
| WebKit | ui-gallery | linear | 350 | 540 | 1.63 | 4.0 | 21.8 | 118 |
| WebKit | ui-gallery | WasmGC | 331 | 664 | 2.64 | 6.0 | (3.3) | 217 |

(Firefox and WebKit time in whole milliseconds.) Before main's startup fix
the linear builds took 98-106 MB of linear memory at start; against the
fixed ones the difference in memory is a few MB, and the browsers' RSS
shows none (WebKit's gallery: WasmGC's larger).

What it says:

- **Size**: the modules are a half to two thirds of linear memory's, but
  gzip narrows it (0.70-0.88): linear memory's code compresses better.
  What a visitor downloads shrinks by 16-65 KB per example.
- **Frame times**: at parity in Chromium and Firefox (the UI engine's
  layout, text and drawing, and the cube's per-frame work, including
  the copies of uniforms through the memory); in WebKit the gallery's
  frames are 60% slower (2.64 against 1.63 ms) and its RSS higher.
- **Startup**: the cube starts as fast or faster; the UI examples' first
  frame is slower in Chromium (gallery 465 against 270 ms) and in WebKit
  (664 against 540): a larger part of a UI program runs before the first
  frame (styles, layout, text, its strings made from globals at
  instantiation), and how the engines tier WasmGC code up is not
  measured here.
- **Memory**: a few MB less than the fixed linear builds' linear memory,
  none in the browsers' RSS.
- **WebKit's trap**: in 108 runs in WebKit 26.0 (54 per build, the three
  examples), one failed, a WasmGC ui-counter on its first frame:
  "RuntimeError: Out of bounds array.set" under the callbacks' table's
  call, not reproduced in the 53 other WasmGC runs nor in Chromium and
  Firefox; the linear builds had none. It fits the intermittent WebKit
  trap the playground shows (believed an engine bug), but one in 54 is
  not enough to tell; it needs its own investigation before WebKit users
  get WasmGC by default.

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

Switch the site's examples, `@hxmc/web`'s islands and `@hxmc/os`'s canvas
programs when the first frame and WebKit hold; keep linear memory for
WASI, the compiler modules and threads, and as the fallback (one define,
`-D hxmc.wasm-gc`, chooses).

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

The port (`haxe.Main`, every generator) builds with `-D hxmc.wasm-gc` (`make
wasmgc-port`) and, run by node as the port, passes the lanes the native
port passes (`make test-wasmgc-port`, docs/testing.md): HXB 279 + 7
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

Measured with node 24, the self-compile to HXB (`-cp haxe/src -main
haxe.Main --interp --no-output --hxb`):

| | native | linear | WasmGC |
| --- | --- | --- | --- |
| self-compile s | 3.7 | 7.1 | 9.1 |
| peak RSS MB | 650 | 1160 | 1220 |
| a small compile s | 0.04 | 0.37 | 0.68 |
| module MB (gzip -9) | | 15.3 (3.6) | 11.0 (2.8) |

(The small compile: `unit.moduleload.TryCatch` to `--interp`; `--version`
alone takes 0.37 s, linear memory's 0.09 s, most of it V8's optimizing
compiler: 0.12 s with `--liftoff-only`, which makes the self-compile 17 s.)
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

1. GPU only (done, [hxmc.md](../hxmc.md#android)): `NativeActivity`
   (`hasCode="false"`), EGL and the GLES back end on its `ANativeWindow`,
   the cube; the APK writer (binary XML, an aligned zip, v2 signing with a
   generated debug key: ECDSA P-256 in plain Haxe rather than through
   mbedtls, so that the WebAssembly tool writes APKs too); `adb` only to
   install. No `resources.arsc` was needed (the label a plain string, a
   framework theme). TLS: TLSDESC on arm64, the general dynamic model on
   x86-64 (Bionic implements TLSDESC on arm64 and riscv64 only), never
   initial-exec (refused for a dlopen'ed library); the floor is API 29, the
   first Bionic with ELF TLS. CI: AndroidTest on an x86-64 emulator with
   KVM on a Linux runner, not a required check yet. Left from this step:
   several ABIs in one APK, release signing with the developer's keystore
   (PKCS#12, v3 for key rotation), icons and a `resources.arsc`, the `.aab`
   for Google Play, `DT_RELR` (API 30+) or Android's packed relocations to
   shrink the RELATIVE table, RELRO for the data that holds addresses.
2. Native controls (done, [hxmc.md](../hxmc.md#android)): JNI bound in
   Haxe (`JNIEnv` and `JavaVM` through `hxmc.os.VTable`, COM's macro),
   a minimal DEX writer in hxmc (`Dex.hx`) for the glue (`org.hxmc.Glue`,
   one listener class whose methods call a static native registered with
   `RegisterNatives`; `org.hxmc.Activity`, a `NativeActivity` whose window
   draws views), `hxmc.ui.native`'s Android backend (`android.widget`'s
   button, label, field, checkbox, slider, progress bar in an
   `AbsoluteLayout`, laid out by our flexbox). Views live on Java's main
   thread: the runtime attaches it (`NativeThread.attach`), the program's
   thread hands it work through its looper, and `NativeHost.run` is
   driven by Choreographer's frames there (`AChoreographer`: no Java
   `Runnable`s needed). CI: the form's checks on the emulator, taps,
   text through the input method, uiautomator's accessibility dump. Left:
   lists and scrolling (no backend of `hxmc.ui.native` has them yet),
   edge-to-edge insets on Android 15 (the root fits the system bars), the
   theme following a dark mode change while running (the activity keeps
   `uiMode` changes).
3. Mixing, as on the desktop (done, [hxmc.md](../hxmc.md#android); the UI
   design, [ui.md](ui.md)): a GPU view inside native controls (a
   `SurfaceView` giving an `ANativeWindow` to the GL back end:
   `ChildSurface`, ui's `GpuView`); a native control inside a drawn tree
   only for text input (a hidden `EditText` for the keyboard and the input
   method: `Window.startTextInput`, `TextInput`). CI: the cube among views
   through Home and back; the soft keyboard shown and hidden, a composition
   and a commit through the field's `InputConnection`. Left: several GPU
   views in one window (each frame does not make its context current),
   a `TextureView` for a GPU view under other views or animated with them,
   the input method's candidates placed at the caret (`CursorAnchorInfo`),
   a drawn UI's text on Android checked in CI (`hxmc.text` does not look in
   `/system/fonts` yet), `GpuView` on the desktop backends (a child
   window or view where gfx draws).

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
   linker signature now is too), the `.ipa`; `hxmc.os.uikit`:
   `UIApplicationMain` run by the generated main (`hxmc_ui_main`), the
   program's body inside UIKit's loop, a `CAMetalLayer`-backed view for the
   Metal back end, touches, the safe area, Suspend and Resume. CI:
   `IosCheck` on Linux, IosTest on an iPhone simulator of a macOS runner
   (`xcrun simctl`, a tap posted on the Simulator's window), not required
   checks yet. `ios-sim-x86_64` is left out: x86-64 needs
   `objc_msgSend_stret` for gfx ([graphics.md](graphics.md)) and Intel
   runners are going away. Left from this step:
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
   - keys and text input (a `UIKeyInput` view and an input method, as
     macOS's text view), multiple touches, UIScene (required by the SDK
     after iOS 26), `os_log` for what the app prints on a device;
   - the App Store's checks (the declared SDK and Xcode in `Info.plist`'s
     DT* keys, `LC_ENCRYPTION_INFO_64`), the main stack (`RT_STACK_MB`'s
     1 GB reservation; iOS limits an app's address space).
2. Native controls via UIKit: `hxmc.ui.native` on `UIButton`, `UILabel`,
   `UITextField`, ... (the AppKit backend's pattern: classes made at run
   time for targets and delegates).
3. Mixing: a GPU view among UIKit views (`GpuView` over a
   `CAMetalLayer`-backed `UIView`), a native field in a drawn tree for text
   input, as on Android.

## Shared libraries and position-independent output

Needed by Android and plugins: the relocation model, TLS model, output
kind and segment alignment are already parameters in `Abi`/`Target`.

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
- x86-64 for the gfx back end: `objc_msgSend_stret` for results over 16
  bytes ([graphics.md](graphics.md)).
