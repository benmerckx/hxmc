# A lean hxmc (plan)

Where hxmc should head, and how to get there by subtraction. The plan has
four aims:

- safe memory management that is easy to use, with as little of a tracing
  collector as measurements allow, and scoped values as an opt-in library;
- much less code (one IR, one wasm, one cache, one macro engine in hxmc);
- a final decision on WasmGC, with whatever stays shared;
- speed, memory use, compile time and binary size improving at every step.

Status: proposal (2026-10-25). Nothing here is built. Estimates are marked
as estimates. Every measured number names where it comes from.

## Why

hxmc on main (`4a88f8e`) is 91,001 lines of Haxe in `hxmc/src` and
`hxmc/std`, tests excluded. Grouped by a rough classification of file
paths:

| Part | Lines |
| --- | ---: |
| runtime: std, strings, maps, Dynamic, boxes, the rest | 21,286 |
| driver, object readers, ABI, data generation, the rest of the compiler | 9,294 |
| native back end: x64, a64, register allocation, linkers | 9,071 |
| object-level and memory-level Mir, optimizer, escape analysis | 8,576 |
| the first IR (`ir/`): lowering from the typed AST, facts, reachability | 7,740 |
| WasmGC back end (`wasmgc/`) | 7,242 |
| runtime: OS layers, threads, sockets, TLS | 6,913 |
| caching (module cache, lowered bodies, store, fingerprints, interfaces) | 6,218 |
| Mir interpreter and Mir macros (`interp/`, `macro/`) | 4,856 |
| WasmGC runtime (`rt/gc/`) | 1,630 |
| native collector (`rt/Gc.hx`, `GcCore`, `GcPaths`) | 1,772 |
| linear-memory wasm back end (`wasm/`) | 2,372 |
| linear-memory wasm runtime (`rt/wasm/`) | 2,045 |
| Android and iOS packaging | 1,986 |

Recent work added code faster than it paid back in whole programs:

- **Scoped memory** (branches `scoped` and `scoped-apply`, draft PRs
  #63/#64): +9,706 / −2,869 lines against main.
  - The self-build was speed-neutral, and allocation went from 12.70 to
    12.62 GB.
  - The one large whole-program win was the self-build's peak memory, from
    1.56 to 1.23 GB. It came from the heap growth fix, which does not
    depend on scoped memory.
- **Mir macros** (4,856 lines): 2.4× (json) to 13× (mandelbrot) faster
  than Eval on compute-bound macros. They are behind Eval on cold builds
  (formatter 0.989 against 0.636 s), and are not the default
  ([compiler.md](compiler.md), "Mir macros: size and speed").
- **Escape analysis of closures and boxes** (branch `escape-closures`, in
  progress, about +930 lines): the self-build allocates 10% less and runs
  15% fewer minor collections. Wall time is unchanged.

The pattern: a second implementation was added next to the first, and the
first stayed. Today there are two macro engines, two wasm back ends with
two runtime representations, three IR levels, six cooperating cache parts,
and two memory models (the GC heap and scoped memory).

## Rules for every change

1. **Every change reports four numbers:**
   - the self-build's wall and CPU time;
   - peak memory;
   - the size of the compiler binary and of the HaxeBenchmarks executables;
   - the line count.

   A change that adds lines must pay in a measured number. A change that
   removes lines may not make the other numbers worse beyond noise.
2. **A replacement deletes what it replaces, in the same PR series.** No
   second implementation lives behind a define past the series that
   introduces it.
3. **Experiments state their kill criterion before they start,** on their
   own branch. A failed experiment leaves a paragraph here, and nothing on
   main.
4. **The conformance suites, the fixpoint, the fuzz lanes and the exec lane
   make deletion cheap.** They are the only safety net, so none of them
   is weakened.

`make lean-stats` (to be written, step 0.1) prints the four numbers. CI
records them on `bench-data` next to `bench.json`, so every PR shows its
delta.

## The end state

```
typed AST --(build)--> IR, object level --(inline, escape, scalar replacement, GVN, LICM,
    check elimination, ownership)--> --(memory lowering: layouts, allocation,
    reference counts)--> IR, memory level --(x64 | a64 | wasm32 isel, regalloc, emit
    | interpreter bytecode)--> objects --(link)--> executable | wasm module
```

- **One IR.** A typed SSA IR, built once from the typed AST. Lowering
  memory is a pass that rewrites object operations into memory operations
  inside the same IR. It is not a new IR.
  - This replaces the hxmc IR (`ir/Ir.hx`, `Lower`, `FnLower`), the two
    Mir levels as separate builders (`MirBuild`, `MemLower`), and the
    WasmGC generator (`wasmgc/MirGen`, `FuncGen`).
  - LIR stays only as instruction selection's output: a list of machine
    instructions, not an IR that passes run on.
  - Reachability and the program-wide facts (`ir/Reach`, `ir/Facts`) run
    on the typed AST or on the IR, not on a third form.
  - **Data-oriented.** Instructions and blocks live in flat arrays,
    referenced by integer indices, with no object per instruction. The
    collector sees a handful of large arrays, and a function's IR is
    dropped by clearing them. This is where Zig's and Cranelift's compile
    speed comes from, and it needs no scoped memory.
- **One wasm:** wasm32 with linear memory, as one more instruction set of
  the IR (see "WasmGC: the decision").
- **One cache:** per module, keyed by the module's source and the
  interface hashes of what it depends on. It holds the typed module and
  what was compiled from it: IR per function, object code. One store, one
  invalidation rule. It replaces `ModuleCache`, `LowerCache`,
  `ModuleStore`, `ModuleCacheState`, `ModuleInterface`, `ObjectStore` and
  `interp/BundleCache`, with `Fingerprint` and `CacheDir` folded in
  (5,960 lines today).
- **One macro engine in hxmc,** chosen by measurement (see "Macros"). Eval
  stays regardless: it is part of the port (`haxe/src`), and implements
  `--interp` and upstream's macro tests.
- **One runtime representation:** the runtime written once in Haxe, over
  one object layout. There is no `Repr` indirection for a second
  representation. A small trusted core, plus libraries the build names as
  trusted, is the only unsafe code, and the compiler enforces that (see
  "Safety").
- **Scoped values as a package** (`packages/scoped`), not compiler code
  (see "Memory").
- **Packaging moves out.** Android and iOS packaging (dex, apk, bundles)
  moves to `packages/`, next to the other platform packages.

Rough size of the end state (estimates, to be replaced by measurements as
steps land):

| Part | Today | Target |
| --- | ---: | ---: |
| `ir/` + Mir + optimizer | 16,316 | 9,000–11,000 |
| WasmGC back end and runtime | 8,872 | 0 |
| caching (the parts named under "One cache") | 5,960 | 2,000–3,000 |
| Mir interpreter and macros | 4,856 | 0 or 3,000 (see "Macros") |
| memory management: collectors, roots, shadow stack, stack tables, census, or what replaces them (see "Memory") | about 4,600 | 2,500–5,000 |
| scoped values | 0 (about 6,800 net on `scoped-apply`) | 0 here (`packages/scoped`) |
| Android and iOS packaging | 1,986 | 0 here (moved) |
| everything else | about 48,400 | 45,000–47,000 |
| **total** | **91,001** | **about 60,000–70,000** |

## Memory: safe, easy to use, as little collector as measurements allow

### Goals

- **Safe by construction.** No manual free, and bounds come from the
  allocation.
- **Nothing to write in ordinary code.** A plain Haxe class just works.
- **Short pauses or none,** and peak memory close to the live data.
- **Fast,** with a runtime and compiler no larger than they need to be.
- **Real-time code** (audio, per-frame work) is a checked subset, not an
  unsafe one.

### Precedents

Reference counting as the main memory manager is proven in production, with
caveats that matter here:

- **Swift and Objective-C (ARC).**
  - Apple deprecated its tracing GC for Objective-C in favour of ARC.
  - Swift has no cycle collector: cycles leak unless marked `weak` or
    `unowned`.
  - Retain/release traffic is a known cost. It took years of compiler
    work, and the `borrowing` and `consuming` parameter modifiers, to cut
    it.
- **CPython and PHP:** counts plus a cycle collector.
- **Nim:** ORC, counts plus a cycle collector using trial deletion, is the
  default since Nim 2.0 (2023). It is the closest precedent: imperative,
  mutable objects with cycles, compiled natively. Its `acyclic` annotation
  keeps types out of the cycle collector.
- **Lean 4 and Koka (Perceus):** precise counts with reuse. Lean's compiler
  runs on it, but its data is mostly immutable, which counting suits best.
- **In research JVMs:** naive counting averaged 30% slower than tracing
  ("Down for the count?", 2012). Optimized counting matched mark-sweep. RC
  Immix (2013) beat a production generational collector, and LXR (2022)
  beats G1. These are counts inside a GC runtime (deferred, with backup
  tracing), not the precise per-pointer counts of Swift or Perceus.

Haxe code is imperative and object-oriented: mutable fields, parent
pointers, observers, closures capturing `this`. That places it with Swift,
Python and Nim, not with Lean or Koka. "No tracing GC" therefore means no
heap-wide tracing: cycles still need a small tracer that looks at suspects
only, or they leak.

### Objects: three candidates, decided by measurement

**A. Counted, non-moving (Nim's ORC and Perceus as models).**
Class instances, closures, arrays, strings, enum values with arguments,
anonymous objects and `Dynamic` all get a count, and never move.

- **Ownership pass** on the object-level IR: increments and decrements
  inserted, borrow inference for parameters and locals that don't need a
  count, and reuse of a dropped object's memory for a new object of the
  same size.
- **Escape analysis runs first.** An object that doesn't escape lives in
  the frame and is never counted. The `escape-closures` work carries over.
- **Allocator:** per-thread pages of size classes with free lists per page
  (mimalloc's shape), in the trusted core. No nursery, and nothing zeroed
  in bulk.
- **Cycles:** trial deletion (Bacon–Rajan), run over candidates only, that
  is, objects decremented to a nonzero count whose type can be part of a
  cycle.
  - Acyclic types are computed on the class graph and never become
    candidates.
  - `Dynamic`, interfaces and unconstrained type parameters count as
    possibly cyclic.
  - Optional `@:weak` fields break known cycles. Debug builds report what
    leaked through cycles at exit.
- **Threads:**
  - An object is local to its thread until it is published: captured by a
    `Thread.create` closure, stored in a static, or stored into a shared
    object. Publishing marks what it reaches as shared.
  - Shared objects get atomic increments, applied at once, and decrements
    buffered until an epoch boundary (Levanoni–Petrank). So a racing
    reader never holds freed memory.
  - Quiescent points: blocking calls, the event loop's turns, and a
    counter on loop back edges.
- **Exceptions:** a throw drops what the unwound frames own, through
  cleanup tables per call site, read by the unwinder. Nothing moves, so
  these are simpler than stack maps.
- **Resources:** Haxe has no destructors, so the order things are freed in
  is not observable. Files and sockets can close deterministically when
  their last reference goes.

What A removes and adds:

| Goes | Comes |
| --- | --- |
| The copying nursery, its zeroing and its minor collections: 12.7% and 4.8% of the self-build's instructions (callgrind, `escape-closures` base, 2026-10-25) | the allocator |
| The shadow stack, the stack tables, reloads after safepoints in `MemLower` | the ownership pass |
| Write barriers and remembered sets | count updates, mostly removed at compile time |
| `Roots.hx`, the GC parts of `Frames`, safepoint polls, the census of the heap | cleanup tables for exceptions, the cycle collector |
| Pinning, and `BytesPtr` copies at C and browser boundaries | nothing: objects don't move |
| The tracing collectors: native `Gc.hx` 1,678 lines, wasm `Gc.hx` 765 | the epochs for shared objects |

**B. Non-moving tracing (mark-region, after Immix).** Objects are still
traced, but are never moved: lines and blocks are reused in place, and
generations come from sticky mark bits.

- **What it keeps:** stack maps and barriers.
- **What it drops:** pinning and boundary copies, because nothing moves.
  For the same reason, a `String`'s bytes can be lent to C or to scoped
  code without a copy.
- **What it costs:** some of the copying nursery's allocation speed.

**C. Today's generational copying GC, with its costs removed:**
- regions as a GC hint: a nursery mark at scope boundaries, evacuated or
  freed when the scope exits;
- pretenuring by allocation site, from the census;
- constructors that skip zeroing.

It is the known quantity, and it keeps the most code.

**Gate M** is an experiment on its own branch:

- **What it builds:** candidate A on today's object-level Mir, which
  becomes the one IR, so the work carries over.
  - Insertion with borrow inference, no reuse yet.
  - A size-class allocator.
  - No cycle collector, so leaks through cycles are counted, not collected.
  - Single-threaded programs only.
- **What it measures:** HaxeBenchmarks and the self-build.
- **A continues if** the self-build's CPU time is at most 10% worse and its
  peak memory at least 30% lower, or CPU time equal and peak memory lower.
- **Otherwise C,** with B measured only if pinning and boundary copies show
  up as a measured cost.

**The risks for A:**
- **Speed.** A bump-allocating nursery is hard to beat at the self-build's
  12.4 GB allocated with a 1.5 GB peak.
- **Cycles in the compiler's own data.** The typed AST and class
  references form cycles. Most of that data lives until exit, and exit
  frees nothing.
- **Threads.** The exact publish points are open.

### Real-time code

The same under every candidate:

- `@:hxmc.realtime` is a checked effect. Such a function may not allocate,
  take a lock, block, touch a shared count, drop anything that could free,
  or call a function that isn't real-time. Breaking a rule is a compile
  error, as with Clang's `[[clang::nonblocking]]`.
- Real-time code reads buffers that another thread owns and handed over.
  It communicates through the core's single-producer, single-consumer rings
  and atomic floats.
- A buffer it no longer uses is retired through epochs, so it is freed only
  after the real-time thread has finished a callback since the swap.
- The check is a macro over the typed AST: allocations, closures, boxing
  and calls are visible there. So it can live in `packages/scoped` (below),
  next to the types real-time code uses.

### Scoped values: a library (`packages/scoped`)

The Goose-style layer ([lowlevel.md](lowlevel.md), "Scoped memory"):
struct values and the `hxmc.scoped` types (`Str`, `Slice`, `Grow`,
`Fixed<T,N>`) on per-thread data stacks, freed when their scope ends, with
a root checker that proves no reference outlives its scope. It moves out of
the compiler into an opt-in package:

| Piece | Lines on `scoped-apply` | As a library |
| --- | ---: | --- |
| the types | 1,474 | as they are: inline abstracts over `Ptr`/`Mem` |
| data stacks and aborts | 271 | as they are, over two primitives from the core: reserving and committing memory, and a hook run when a thread exits |
| the root checker (`ir/Scoped.hx`) | 1,352 | a macro over the typed AST. Its errors then show in the editor's diagnostics, not only in a full build. The types' own methods carry small annotations of what they return a reference to, since a macro sees code before inlining. |
| scope marks and resets (in `FnLower`) | +423 | a build macro inserting inline mark and reset calls at entry, at each return and loop iteration, and around exceptions |
| literals and interpolation as `Str` (`HxmcLiterals`) | 186 | a `@:from` macro that accepts only constant strings |

**What the compiler keeps:**
- `Ptr`/`Mem` and struct values (on main);
- the two primitives above;
- trust for the package's implementation (rule 3 of "Safety").

**Dropped, not moved:**
- the WasmGC representation (`ir/Soa.hx`, 339 lines);
- Images and `Rel` (`ir/Images.hx`, 341 lines), unless a measurement
  brings them back;
- scope-bound classes;
- `@:try` (80 lines);
- the typer hooks in `haxe/src`: `HxmcValues`, `HxmcLiterals`, `HxmcTry`,
  `HxmcScoped`, and the edits in `Typer`, `Operators`, `Inline` and others.
  That is about 570 lines where the port diverged from upstream's typer.

**The runtime does not use it.** It is part of every program, so it can't
depend on an opt-in package. On `scoped-apply`, 23 runtime files use the
scoped types. Their measured wins land written against the core's
primitives and the checked views of "Safety" (step 1.1). "One core, two
faces" goes away.

**A `Bytes` fallback** would let scoped code compile on js, hl, cpp and jvm:
- the data stacks as byte buffers, references as buffer and offset;
- the types written once over load and store at an offset;
- an adapter of roughly 100–200 lines per target.

The expected gains:
- fewer GC objects where the collector hurts (HashLink's non-generational
  mark-sweep, per-frame game data);
- allocation-free AudioWorklet code;
- zero-copy hand-off to WebGL, WebGPU and workers;
- one source for codecs, DSP and physics across targets.

On JS, strings get worse (a `TextDecoder` at every crossing). It is built
only if the particles benchmark, ported to HashLink and JS (`Slice` against
`Array<Particle>`), pays.

**Why not in the compiler.** Two cases would justify keeping it there, and
neither holds:

- **The compiler's own IR in scoped memory, making it much faster.** The
  back end is a minority of the build: the Mir phase took 4.40–4.68 s of
  18.8–19.4 s of CPU in a single-threaded self-build
  ([codegen.md](codegen.md)). And the census found the back end's objects
  are about 160 MB of the 1.34 GB promoted. The front end, the port's typer
  and filters, can't be scoped. The speed that compilers like Zig's and
  Cranelift get comes from a data-oriented IR, which plain Haxe can have
  (see "The end state").
- **Macros.** Their speed comes from typed values in the interpreter, from
  the macro context's cold typing, and later perhaps from native
  compilation. None of these needs scoped memory.

## Safety: simple rules, enforced

These hold under every memory candidate, after Fil-C's approach, applied to
the places hxmc can still be unsafe:

1. **Bounds come from the allocation.** Outside the trusted core, memory is
   reached through a reference to an object plus an index, checked against
   that object's own header. There are no raw addresses and no
   integer-to-pointer conversions. A stale length read by a racing thread
   is still checked against the real storage.
2. **Nothing is freed by hand.** Counts, scopes or the collector free
   memory, never code.
3. **Only the trusted core is unsafe.** `@:hxmc.unsafe` compiles only in
   `hxmc.rt.kernel` and in packages the build names as trusted
   (`-D hxmc.trust=scoped`). The IR verifier rejects raw memory operations
   anywhere else.
   - The core: the allocator and counts (or the collector), threads and
     stack switching, fault handling, atomics, the epochs, the rings, and
     the system-call trampolines.
   - Target: about 250 unsafe functions, from 532 on `scoped-apply`. CI
     prints the count, and it only goes down.
4. **System calls and C take checked views.** A call passes an object, an
   offset and a length, checked once at the boundary. C keeps a pointer
   after the call only through a `@:hxmc.retains` parameter. Third-party C
   is the remaining hole. Optionally, sandbox it RLBox-style: compile each
   library to wasm and translate it back to C with wasm2c.
5. **Races give wrong values, never corruption.**
   - A heap slot holding a reference is one word.
   - Multi-word values that contain a reference or a length are immutable
     once published, or boxed.
   - The epochs keep racing readers of shared objects valid.
6. **One pass removes checks, and it is tested.** A `-D hxmc.checked` build
   keeps every check, and the fuzz lane runs it against the optimized
   build.

## WasmGC: the decision

**Recommendation: retire the WasmGC back end.**

- **It is a second memory model.** The host's collector replaces ours, so
  the runtime needs a second representation (`rt/gc/`, the `Repr`
  indirection), and so did every scoped feature (typed arrays, SoA). Under
  candidate A it can't be expressed at all: counted, non-moving objects
  have no WasmGC equivalent.
- **It lost its own go/no-go** ([targets.md](targets.md), "What switching
  the browser builds would take, and the call"):
  - Linear memory has been the default since the startup fix (10–22 MB at
    start).
  - On WasmGC the UI examples' first frame is up to 72% later in Chromium.
  - WebKit's gallery frames are 60% slower, and one WebKit trap is still
    unexplained.
  - It is ahead on module size (2–8× smaller on small programs, about half
    for the UI), and on some benchmarks (mandelbrot_anon 1.01 s against
    2.40 s for linear memory).
- **Linear memory is needed anyway:** for WASI (node, wasmtime, the npm
  compiler, the playground), for engines without WasmGC, and for threads.
- **The code:** 7,242 lines of back end, 1,630 of runtime, the hybrid
  module's boundary, `make wasmgc-check`, and the `Repr` indirection that
  lets the runtime be written for both.

**What is given up, and the answers:**

- **Module size.** Under candidate A, without a tracing collector, the
  linear runtime is smaller. One reachability pass and dead-code removal
  already apply.
  `lean-stats` tracks the size of the UI counter's module.
- **Holding JavaScript objects without leaking them through the host's
  collector.** Use a handle table (an `externref` table) with explicit
  release, and a `FinalizationRegistry` on the JavaScript side to report
  leaks.

**Before deleting:**

- record the final numbers in [targets.md](targets.md);
- tag the last commit that has WasmGC (`wasmgc-final`), so it can be
  revived from there.

**Shared after the decision:** wasm32 is one more instruction set of the
IR. It gets the same runtime, object layout, memory model and trusted core,
with WASI and the browser's imports behind the system-call layer. The only
wasm-specific parts are instruction selection, structured control flow,
the module writer and the linker.

**If the owner keeps WasmGC instead,** it should be an emitter from the
memory-level IR only, with no runtime of its own. But it remains a second
memory model, which is exactly the duplication this plan removes.

## Macros

**Measure first (step 0.2).** Run the macros people use under both
engines: our own (`@hxmc/theme`'s Tailwind subset, the shader macro, the
markup macros) and common libraries (json2object, the formatter's).
Measure cold builds, warm builds, and edits under the server.

- **If none of them is compute-bound:** delete the Mir macros (−4,856
  lines) and keep Eval.
- **If some are:** make the Mir interpreter the default, and remove its
  cold cost by shipping a prebuilt image of the typed macro context with
  the compiler.
  - The interpreter is then one more back end of the one IR: bytecode
    emitted from the memory-level IR, run by `hxmc.rt.Interp`.
  - Eval stays only for `--interp`.

**Not done:** starting in Eval and moving hot functions to the interpreter.
It needs both engines and a bridge between them.

## Speed, memory, compile time, size

Baselines (Intel Xeon @ 2.10 GHz, 4 vCPUs):

- **Typing the port** (`site/data/bench.json`, 2026-10-21): hxmc 6.96 s
  and 646 MB, against the OCaml reference's 12.45 s and 1,529 MB.
- **The self-build by the tool** (2026-10-25, the `escape-closures` base
  runs):
  - wall 12.1–12.3 s, CPU 17.5–18.0 s;
  - peak 1.52 GB, 12.4 GB allocated;
  - binary 19.93 MB.
- **Where the self-build's instructions go:** zeroing 12.7%, register
  allocation about 10.5%, minor collections 4.8%, the slow path of array
  push 3.2%, `memcpy` 1.3%.
- **HaxeBenchmarks, native:** [targets.md](targets.md). V8 running the
  WasmGC output beats native on mandelbrot (0.70 against 0.79 s) and
  mandelbrot_anon (1.01 against 1.31 s). So native code leaves speed on
  the table in loops.

Levers, each a step below with its own numbers. The percentages are
estimates:

- **Memory model:**
  - Candidate A removes zeroing and minor collections (17.5%), but count
    updates cost an unknown amount, which gate M settles.
  - Candidate C cuts part of the same 17.5% with region hints and
    constructors that skip zeroing.
- **Register allocation** (about 10.5%): a better linear scan (intervals
  in a tree, not lists), or second-chance binpacking.
- **Removing bounds checks in loops** (range analysis on the IR), for the
  numeric gap.
- **A parallel back end:** 18 s of CPU in 12 s of wall time is 1.5× on 4
  cores. Compiling functions in parallel is worth more in wall time than
  any single pass.
- **Binary size:** a smaller runtime (no tracing collector under A), and
  one IR for a smaller compiler binary. Track the compiler's binary and the
  HaxeBenchmarks executables.
- **A yardstick (step 0.3):** HaxeBenchmarks through hlc (HashLink's C
  output, clang -O2) and hxcpp, on the same machine. This turns "how much
  faster can native get" into a measured gap per case.

## Order

Each step is one PR series. It reports the four numbers and keeps the
conformance suites, the fixpoint and the fuzz lanes green.

### 0. Measure and decide (no product code)

1. `make lean-stats`, and CI recording it on `bench-data`.
2. Macros under both engines (see "Macros").
3. The hlc and hxcpp yardstick.
4. The owner's decisions:
   - retire WasmGC (recommended);
   - #63/#64 are harvested, not merged as they stand, and scoped values
     become `packages/scoped` (recommended);
   - the thresholds of gate M.

### 1. Subtract

1. Land the parts of `scoped-apply` that pay off on their own:
   - the heap growth fix (peak 1.56 to 1.23 GB);
   - the measured hot spots: json 0.44 to 0.39 s, inflate 12% faster,
     concatenation chains 40% faster, `indexOf` on objects 19× faster.

   Each lands as its own PR on main, without the scoped layer. The
   `scoped` and `scoped-apply` branches are then parked; #63 and #64 are
   closed with a pointer here.
2. Retire WasmGC: the tag, the final numbers, then the deletion of
   `wasmgc/`, `rt/gc/`, the `Repr` indirection and the hybrid module's
   boundary in the packages.
3. Carry out the macro decision.
4. One cache.
5. Move Android and iOS packaging to `packages/`.
6. Finish or stop `escape-closures` by rule 1: it lands only if it pays in
   a measured number.

### 2. One IR

Incrementally. Each step leaves the output byte-identical, or measured,
and passes the fixpoint.

1. Object-level Mir becomes the IR. `MirBuild` builds it from the typed AST
   directly. `ir/Lower` and `FnLower` fold into it, and the hxmc IR
   retires.
2. Reachability and the facts run on the typed AST and the IR.
3. Memory lowering as a pass within the IR. LIR stays only as instruction
   selection's output.
4. The interpreter's bytecode emitted from the IR, if the Mir engine stays.

### 3. Memory

1. Gate M.
2. If it passes, candidate A:
   - the ownership pass, the allocator, the cycle collector, threads with
     epochs, the cleanup tables for exceptions;
   - then delete the tracing collectors, the shadow stack, the stack
     tables, the barriers and the census of the heap.
3. If it fails, candidate C: region hints, pretenuring, constructors that
   skip zeroing. Candidate B only if boundary copies and pinning show up as
   a measured cost.
4. Whatever the outcome:
   - the trusted-core boundary enforced (rule 3);
   - `-D hxmc.checked` with the differential fuzz lane.
5. `packages/scoped` when a user needs it (audio, real-time work):
   - the types, the data stacks, the macro checker and the scope macro;
   - `@:hxmc.realtime`;
   - the `Bytes` fallback only if the particles benchmark on HashLink and
     JS pays.

### 4. Speed

Register allocation, bounds-check removal in loops, the parallel back end,
then what the yardstick and `lean-stats` point at.

## Open questions

- The thresholds of gate M, and whether a fail means candidate C for good,
  or a second attempt with reuse and the cycle collector.
- Whether `packages/scoped`'s checker is fast enough in the macro engine
  that is kept, on large amounts of scoped code.
- Publish points for shared objects: is a static shared, or only what a
  second thread reads? This decides how much ordinary single-threaded code
  pays for atomics.
- Whether `hxmc.rt.kernel` holds the OS layers' system-call trampolines
  only, or also the thin wrappers around them.
- Whether the interpreter keeps a role without Mir macros: `--run` with
  `-D hxmc.run=mir`, and the iOS device fallback in
  [dev-loop.md](dev-loop.md).
