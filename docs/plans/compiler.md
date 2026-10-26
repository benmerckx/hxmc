# Plans: compiler and caches

Open work on the front half (typing, macros) and build caching. What is
built: [hxmc.md](../hxmc.md#module-cache) and
[using.md](../using.md#fast-rebuilds).

## Cached modules

- **Macro state beyond statics.** The cache tracks static variables of
  macro classes, not state kept elsewhere (a file a macro writes, a std
  class's statics, the macro API's registries). A conflict found late
  costs a second run of the build.
- **Undone interface edits.** Undoing an edit restores the module's earlier
  variant but not its dependents'. Choose among a module's variants by its
  dependencies' hashes.
- **Cold builds** pay for encoding (upstream's HXB writer). Start it before
  the filters end, or write less.
- **Init macros.** Builds with `--macro` do not use the cache. Their
  effects (`addGlobalMetadata`, `Compiler.define`, class paths) are data:
  put them in the key.
- **Typing order.** Some behaviour depends on it (monomorph resolution,
  anonymous type numbering, build macro order); restoring changes it. The
  gate covers it; keep it so.
- **Then**: `-lib` HXB archives as a source of modules; std variants shared
  across keys, so an npm postinstall could warm the cache.
- **Decided against**: shipping the std as HXB. There is no single typed
  std (per target, per define, the macro context), init macros cannot
  change pre-typed modules, and the sources ship anyway.

## Faster rebuilds

- **One-edit rebuilds under 1 s**: incremental program preparation, data
  tables and linking, and incremental DCE in the port.
- **Link-time DCE**: move whole-program DCE to link time (reachability over
  symbols with Haxe's rules: `@:keep`, interfaces, overrides, reflection
  roots), so a module's object does not depend on the rest of the program.
  `@:generic` instances become mergeable symbols of the instantiating
  module. Program-wide numbering is already symbolic.
- **Data-table compaction**: type info, field names, dispatch rows, string
  literals.
- **Server builds from `--hxb-lib`** re-decode HXB-library modules every
  build, or lose their bodies with `-D disable-hxb-cache`. Check against
  the reference: a port bug.
- **Quieter builds**: the Makefile's build rule writes `<out>.log`; logs
  only on request. `-D hxmc.cache=<dir>` beside `HXMC_CACHE`.

## Macro-heavy builds

The `macro` timer is at or below the reference's on every workload; what
is left is typing and the collector. By estimated payoff:

- **Monomorph transactions.** Upstream snapshots every unbound monomorph
  of the function for each optional argument (`CallUnification`),
  quadratic in the function's size: 15% of tink_json at 40 types. A trail
  of the monomorphs changed since the snapshot would make it proportional
  to the changes. A departure from upstream's algorithm.
- **Medium-lived objects.** A minor collection promotes whatever survives
  once (9% of tink_json's allocations), and major collections stop the
  world. An aging survivor space or incremental marking
  ([runtime.md](runtime.md#collector)).
- **Eval call frames.** Each call allocates an Env, two slot vectors and the
  argument array, and stores the frame twice into a long-lived record (two
  barrier slow paths): a quarter of a call's cost. A reused frame stack is
  a redesign of EvalContext.
- **Eval instance layout.** A field read is four dependent loads against
  OCaml's three; instance fields as inline slots would remove one.
- **Allocation in the typer and analyzer**: spread thin; escape analysis
  ([codegen.md](codegen.md#escape-analysis)) is the general answer.
- Minor: `Finalization.sortTypes` and `TPrinting.sType` sort through
  `Reflect.compare`; source lines for messages are read a byte at a time.

## Mir macros

Where Mir macros stand against Eval (MirBench, median of five, wall time):

| | Mir | Eval |
| --- | --- | --- |
| json as a macro | 2.96 s | 7.1 s |
| formatter build, cold | 0.74 s | 0.61 s |
| formatter build, warm, unchanged | 0.131 s | 0.127 s |
| formatter build, warm, config edited (macros run) | 0.93 s | 0.76 s |
| trivial macro, cold | 0.20 s | 0.16 s |
| trivial macro, warm, main module edited | 0.129 s | 0.073 s |
| trivial macro edited under the server | 0.021 s | 0.020 s |

Mir macros are on par where the module cache holds and under the server,
2.4 to 13 times faster on compute-bound macros, and behind on cold builds,
on a trivial macro's warm edit and where macros run again. The cold gap is
compiling the few giant functions code-writing macros are made of
(json2object's `DataBuilder`) and typing the macro context.

- **The native tier** (linux-x86_64, [hxmc.md](../hxmc.md#the-native-tier)):
  hot functions are compiled from the same Mir to machine code, their
  descriptors made forwarders. Left: entering native code in the middle of
  a frame, for a loop in one call (mandelbrot as a macro, nbody under
  `--run`); native code calling another tiered function's code directly
  (it goes through the pool entry and the forwarder now); arm64, macOS
  (`MAP_JIT`) and Windows; more than one thread running interpreted code
  (`become` as one atomic store). A Mir-versus-Eval verify mode can be
  rebuilt on it.
- **A cheap first tier**: a function's first calls run code translated from
  the lowered IR without MirBuild, Opt and MemLower. The formatter's cold
  build spends 70-100 ms compiling functions run once or twice.
- **Lazy decoding of the macro context** from the module cache (it reads
  bodies eagerly, `ServerCache.readExpressionEagerly`): it restores 168
  modules where Eval's restores 121.
- **A macro std that does not load the whole runtime** (`Std` imports
  `hxmc.rt.Runtime`): typing the runtime's declarations is most of what the
  macro context's typing still pays.
- **No-GC-point functions compiled lazily** too, with collection held off
  meanwhile.
- **Encoding**: a cold build that writes the cache types the macro context's
  remaining bodies first; it could keep them untyped.

Open decisions:

- **Tiering up**: call counts per descriptor and, at a threshold, a forward
  to native code (the native tier, on by default on linux-x86_64; the size
  policy, `HXMC_MIR_COLD`, still decides what is optimized). Loop back-edge
  counts are still open.
- **The default engine**: Eval stays the default until Mir macros win the
  cold builds.

## Code generation at run time

Objects are in-memory with relocations, and program-wide numbers are
symbolic, so these stay possible:

- **Hot reload** of changed modules in a running process (needs run-time
  registration of types and dispatch rows).
- **A JIT library** for interpreters written in Haxe (about 0.5 ms per
  function: hot functions only).
- **A bootstrap plus bundled program**: a small native loader and the
  program as hxmc's lowered IR, compiled at first launch for the actual
  CPU. One archive for every platform, at the cost of first-launch latency.
  The format can stay private while bootstrap and archive ship together.

iOS and consoles forbid run-time code; hardened macOS apps need the JIT
entitlement; browsers use WebAssembly.
