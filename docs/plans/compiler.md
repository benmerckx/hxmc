# Plans: compiler and caches

Open work on the front half (typing, macros) and build caching. What is
built: [hxmc.md](../hxmc.md#module-cache) and
[using.md](../using.md#fast-rebuilds).

## Cached modules

- **Macro state beyond statics.** The cache tracks static variables of
  macro classes, not state kept elsewhere (a file a macro writes, a std
  class's statics, the macro API's registries). A conflict found late
  costs a second run of the build.
- **Macro-defined modules.** A module `Context.defineType` or
  `defineModule` makes is kept with its definer (the module whose typing
  defined it) and restored only with it; one a callback (`onAfterTyping`,
  `onGenerate`) defines is not kept, nor what such a callback adds to the
  macro API's current module (hxmc.md, "Module cache"). Warm builds run the
  callback and type its output every build (helder reports about 0.25 s
  since its view classes are generated so). Reusing it soundly needs a key for the callback's result rather
  than for a module: the callback's inputs (the types it is given, in
  practice their metadata and fields as it reads them through the macro
  API), the macro classes' static state it reads and writes, the defines
  and files it reads (the existing hooks), and the code of the macro
  itself (its module's whole content). Today's store keys modules by
  their file and dependencies, so this belongs in the one per-module store
  ("One cache" below), not beside it.
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

## One cache

The plan (the `lean-plan` branch's lean.md, step 4): one per-module
store, keyed by the module's source and the interface hashes of what it
depends on, holding the typed module, the IR per function and the object
code, with one invalidation rule, in place of `ModuleCache`,
`ModuleCacheState`, `ModuleStore`, `ModuleInterface`, `LowerCache`,
`ObjectStore` and `interp/BundleCache`, with `Fingerprint` and `CacheDir`
folded in (with `WatchedCallbacks`, `CheckingHxbWriter`, `Skeletons` and
`UpToDate`: 6,500 lines; 41 files of `hxmc/src` and `haxe/src` refer to
them). What it must keep: the gate (`make test-module-cache`, with the
macro-defined cases), the fixpoint cold, warm and off, the variants per
define, nondeterministic macros, the cap and trim, the off switch, the
server's reuse of lowered bodies, Mir's compiled functions.

**Current state** (after stage 1; lines of `hxmc/src/hxmc`):

| Part | Stores | Key | On disk | Invalidation | Read and written by | Tests |
| --- | --- | --- | --- | --- | --- | --- |
| typed modules: `ModuleCache` (1,709), `ModuleCacheState` (616), `WatchedCallbacks` (125), `CheckingHxbWriter` (69), `Skeletons` (207) | per module, up to four variants: HXB chunks, monomorphs' modifiers, skeletons, `ModuleDefExtra`, defines read, file record, dependencies with the hash each had, macro state, marks | the index: `CacheKey` `ModuleIndex` of working directory, std, class paths; a variant: its reads match the build's defines | `i/m<hash>` (header + `ModuleStore` index), `p/<nonce>.pk` | lazy, per module the build loads (`ServerCache.checkModuleHook`): file by content hash, path resolution, defines, each dependency's interface or whole-content hash (`Closure`), macro state (retype and rerun), volatile, file and environment reads; early cutoff; definer rule for macro-defined modules | the port's server hooks (`ServerCache`, `TFunctions.dependencyHook`, `MacroContext.definedHook`, `EvalStdLib` hooks), `finish` writes | `ModuleCacheCheck` (the gate), fixpoint, `CacheCheck` |
| encoding: `ModuleStore` (571) | the index and blob formats | | inside the index and packs | `MAGIC` | `ModuleCache`, `ModuleCacheState` | as above |
| interfaces: `ModuleInterface` (577) | nothing: hashes of a module's declarations without the bodies of functions with written types | | | | `ModuleCache` (as files are parsed) | as above |
| lowered bodies: `LowerCache` (1,253) | in memory, server only: per field, the lowered body and the queries it asked with their answers | the field object, or module/class/field while the module's `m_processed` is the same | none | a query answered differently, or an object the binding does not know: the whole lowering again; target, flags and resources change: all | `Main.generate` under `Driver.resident` | `LowerQueriesCheck`, `make dev-check` (server-verify) |
| module objects: `Driver` (was `ObjectStore`, 83) | per module, its object (ELF); in a server also in memory (`memObjs`) | `CacheKey` `ModuleObject` of the `Fingerprint` (tool key, IR, what `MirBuild` reads, inlined callees' digests) | `o/o<hash>-<module>.o`; per output `i/l<hash>` naming them; `<out>.hxmc/` without a store | content-addressed: a new key misses | `Driver.build` | fixpoint, corpus, `CacheCheck` |
| Mir macro functions: `interp/BundleCache` (123) | per function, its object, its key and symbol, which calls are interpreted | `CacheKey` `MacroFunction` of the `Fingerprint` with the tool key and Mir options | `o/f<hash>-mir.o`; per command line `i/l<hash>` | content-addressed, plus its dependencies checked when read | `interp/MirMacros` | `MirCacheCheck` |
| up to date: `UpToDate` (131) | per output, the build's key and the stamps of linked files | archive's ZIP directory, arguments, tool, runtime objects | `i/u<hash>` (else `<out>.hxmc/build.key`) | any change of the key or a stamp | `Main` (`--hxb-lib` builds only) | corpus (archive builds) |
| hashes: `Fingerprint` (596) | | IR words, two lanes | | | `Driver`, `MirMacros`, `MirRun` | |
| the store: `CacheStore` (238), `CacheKey` and `CacheKind` (52), `CacheDir` (371) | the layout; root, trim, cap, size | | `<cache>/modules/<layout>-<tool>/{i,p,o}`, `size.txt`, `trim.txt` | unused 14 days; past the cap, least recently used; packs and objects with their last index | everyone above | `CacheCheck` |

### Stages

1. **One key type and one layout** (done): `CacheKey` (a kind, then a
   hash of content and dependency hashes) names every entry; `CacheStore`
   owns the tool directory (`i/` indexes, each with a header naming the
   packs and objects it keeps; `p/` packs; `o/` objects), its opening,
   atomic writes and size accounting. The module index, the module
   objects, Mir's functions and the up-to-date record moved onto it
   (`ObjectStore` removed), and the trim reads only index headers (it
   parsed whole module indexes before). The layout's number is in the tool
   directory's name, so an earlier layout is never read and goes as
   another tool's directory. Outputs, hits and misses unchanged.
2. **One validation pass.** Today three checks decide reuse separately:
   the server's per-module check (`ModuleCacheState.check`, `Closure`),
   `LowerCache`'s replay keyed by `m_processed`, and the objects' content
   keys. Steps:
   - `ModuleCacheState`: compute each restored module's verdict once
     (valid, typed again with the same interface, typed again with a new
     one) and keep it per build (`ModuleCacheState.verdicts`), from
     `check` and `dependencyDirtyHook`;
   - `LowerCache`: take that verdict instead of `m_processed` for `byKey`
     hits, so a body is reused in a one-shot build too, from a new
     per-module entry kind (`CacheKind` `LoweredBodies`, `i/b<hash>`:
     a module's lowered bodies and recorded queries, serialized; the
     recorded objects are paths and names already, `CachedLower.stableKey`);
   - `Driver`: a module whose verdict is valid and whose lowered bodies
     were reused keeps its previous object key (stored with the module's
     entry), skipping its `Fingerprint`;
   - `CacheKey.of` for a module's entry: file content hash and its
     dependencies' `expect` hashes, replacing `Closure`'s ad hoc strings.
   Risks: the gate's typing-order cases (restoring changes it); bodies
   that read program-wide facts (`LowerQueries` `@:logged` queries must all
   be serializable: today some return objects by identity); server memory
   (the server keeps both forms meanwhile).
3. **Macro-defined entries** with the key below (definer, macro code,
   inputs, state). Steps: a `CacheKind` `MacroResult` entry per definer
   (`i/d<hash>`), written from `MacroContext.definedHook`; the static
   values (not only names) from `EvalJit.staticVarHook` into the key;
   callback results (`onAfterTyping`) keyed by the types given as the
   callback reads them (`WatchedCallbacks` records the reads). Risks:
   helder's late classes (`ModuleCacheCheck --late`), Mir macros' statics
   (`MirServerCheck`), values that do not serialize (closures in statics:
   then not kept).
4. **Removal**: `ModuleStore`'s index format folds into the entries
   (`CacheStore` holds per-module entries, not one index per class path),
   `UpToDate` becomes an entry over the module entries (no ZIP directory),
   `ObjectList` indexes go once objects belong to module entries,
   `LowerCache`'s in-memory replay goes behind the stored bodies.
   Expected size: 3,500 to 4,500 lines in place of the 6,500, over three
   to five more PRs.

Learned in stage 1: the store's users already shared one directory and
the trim; what differs is what decides reuse, not where it is kept. The
win of later stages is in one decision (stage 2), so keep stage 2's PRs
split by level (modules, then bodies, then objects), each behind the gate.

A module a macro defines has no source, so its entry is keyed by what made
it instead:

- the definer: the module whose typing ran the macro, by whole content (its
  macro calls' arguments are in bodies the interface leaves out), and only
  as part of that definer's entry, so it is restored with it and never on
  its own;
- the macro's code: the whole content of the macro's module and of what it
  depends on (a macro's module already counts so across contexts);
- the macro's inputs beyond the sources: defines, files and environment it
  read, volatile calls (the existing hooks);
- the macro context's state: the static variables of macro classes it read
  (a counter, a registry), with their values, not only their names: two
  programs of one class path can define the same path with different code;
- for a callback's definitions, no definer module: an entry of the build
  keyed by the types given to the callback, as the callback reads them.

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
