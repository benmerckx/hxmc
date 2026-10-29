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

**Current state** (after stage 1 and 2a; lines of `hxmc/src/hxmc`):

| Part | Stores | Key | On disk | Invalidation | Read and written by | Tests |
| --- | --- | --- | --- | --- | --- | --- |
| typed modules: `ModuleCache` (1,694), `ModuleCacheState` (663), `WatchedCallbacks` (125), `CheckingHxbWriter` (69), `Skeletons` (207) | per module, up to four variants: HXB chunks, monomorphs' modifiers, skeletons, `ModuleDefExtra`, defines read, file record, dependencies with the hash each had, what its dependents expected of it (`shape`), macro state, marks | the index: `CacheKey` `ModuleIndex` of working directory, std, class paths; a variant: its reads match the build's defines; a module: `CacheKey` `TypedModule` (file content, reads, dependencies' `expect`) | `i/m<hash>` (header + `ModuleStore` index), `p/<nonce>.pk` | lazy, per module the build loads (`ServerCache.checkModuleHook`): file by content hash, path resolution, defines, each dependency's interface or whole-content hash (`Closure`), macro state (retype and rerun), volatile, file and environment reads; early cutoff; definer rule for macro-defined modules; one verdict per module (`ModuleCacheState.verdicts`), final at the capture | the port's server hooks (`ServerCache`, `TFunctions.dependencyHook`, `MacroContext.definedHook`, `EvalStdLib` hooks), `finish` writes | `ModuleCacheCheck` (the gate), fixpoint, `CacheCheck` |
| encoding: `ModuleStore` (589) | the index and blob formats | | inside the index and packs | `MAGIC` | `ModuleCache`, `ModuleCacheState` | as above |
| interfaces: `ModuleInterface` (577) | nothing: hashes of a module's declarations without the bodies of functions with written types | | | | `ModuleCache` (as files are parsed) | as above |
| lowered bodies: `LowerCache` (1,253) | in memory, server only: per field, the lowered body and the queries it asked with their answers | the field object, or module/class/field while the module's `m_processed` is the same | none | a query answered differently, or an object the binding does not know: the whole lowering again; target, flags and resources change: all | `Main.generate` under `Driver.resident` | `LowerQueriesCheck`, `make dev-check` (server-verify) |
| module objects: `Driver` (was `ObjectStore`, 83) | per module, its object (ELF); in a server also in memory (`memObjs`) | `CacheKey` `ModuleObject` of the `Fingerprint` (tool key, IR, what `MirBuild` reads, inlined callees' digests) | `o/o<hash>-<module>.o`; per output `i/l<hash>` naming them; `<out>.hxmc/` without a store | content-addressed: a new key misses | `Driver.build` | fixpoint, corpus, `CacheCheck` |
| Mir macro functions: `interp/BundleCache` (123) | per function, its object, its key and symbol, which calls are interpreted | `CacheKey` `MacroFunction` of the `Fingerprint` with the tool key and Mir options | `o/f<hash>-mir.o`; per command line `i/l<hash>` | content-addressed, plus its dependencies checked when read | `interp/MirMacros` | `MirCacheCheck` |
| up to date: `UpToDate` (131) | per output, the build's key and the stamps of linked files | archive's ZIP directory, arguments, tool, runtime objects | `i/u<hash>` (else `<out>.hxmc/build.key`) | any change of the key or a stamp | `Main` (`--hxb-lib` builds only) | corpus (archive builds) |
| hashes: `Fingerprint` (596) | | IR words, two lanes | | | `Driver`, `MirMacros`, `MirRun` | |
| the store: `CacheStore` (238), `CacheKey` and `CacheKind` (61), `CacheDir` (371) | the layout; root, trim, cap, size | | `<cache>/modules/<layout>-<tool>/{i,p,o}`, `size.txt`, `trim.txt` | unused 14 days; past the cap, least recently used; packs and objects with their last index | everyone above | `CacheCheck` |

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
   another tool's directory. Outputs, hits and misses unchanged; the
   self-build's cold, warm, off and server times within noise of
   before, the store 1.5 KB larger (the headers).
2. **One validation pass**, split by level, each behind the gate:
   - **2a, modules** (done): one verdict per module of the store
     (`Verdict`, `ModuleCacheState.verdicts`), read by every user. Its
     check gives `Valid` or `Retyped` while the build types (what the early
     cutoff, `onDependencyDirty`, reads in place of the `approved` set);
     the capture settles it for every module the build ends with:
     restored, typed again with the same interface, or with a new one (the
     capture's `Closure.di` of the new variant against the one the old
     was written with, `Variant.shape`, which the index now keeps). A
     module's key is `CacheKey` `TypedModule` (`Variant.typedKey`: its
     file's content hash, its reads, each dependency's path and `expect`
     hash); its check and `reselect` compare it with the key from the
     dependencies' hashes now (`typedKeyNow`). `Closure`'s hashes are
     `CacheKey`s (`Interface`, `Content`) of each member's own part and
     its dependencies' hashes, then of the members, in place of the
     concatenated strings; its unused `clean` is gone. Hits and misses are
     unchanged (the self-build: 677 encoded cold, 676 checked and 0 typed
     warm; a body edit of `Options.hx`: 675 valid, 1 typed again with the
     same interface; a new class in it: 659 valid, 18 with a new interface);
     outputs byte-identical; cold, warm, off and server times within noise
     of before, the store 22 KB larger (the shapes).
     Learned:
     - a verdict read before the capture is provisional: the server's
       own checks after the hook (shadowing, the file's date, a dependency
       on a macro-defined module) and the cycle guard can still type a
       module its check found valid. The lowering and `Driver` run after
       the capture and before `finish`, so they read final verdicts
       (`ModuleCache.current()`). A build that writes nothing (volatile
       macros, errors) settles without comparing interfaces (`Retyped`);
     - the module cache is off in the compilation server, so there are no
       verdicts there: the server's reuse keeps its own test
       (`m_processed`, the server's `mCacheState`) until the server
       starts from the store;
     - an undone interface edit still types the dependents again (the 18
       above, edited back): `register` picks a variant by its file's hash
       and signature. Picking, among the variants whose reads match, one
       whose `typedKeyNow` equals its `typedKey` is the same test the check
       makes, so sound; a small follow-up;
     - where a warm self-build goes (4.2 s): 1.5 s to the lowering
       (restoring, filters, DCE), 1.3 s lowering, 0.2 s preparing, 0.24 s
       the objects' keys and reading them (`Fingerprint`), 0.7 s data and
       linking. 2b is the large win; 2c saves at most the keys.
   - **2b, bodies**: a `CacheKind` `LoweredBodies` entry per module
     (`i/b<hash>`, keyed by `TypedModule` and the lowering's switches
     `LowerCache.lower` compares: target, platform, Mir host, lines,
     bounds, null and span checks, resources), holding its fields' lowered
     bodies and recorded calls. A one-shot build replays it for a module
     whose final verdict is `Valid` through the `byKey` path (`translating`:
     each class and field the current build's of the same path), which
     exists already. What it needs: a codec for `Stmt`/`Ex` and for
     `LCall`'s arguments and results, whose objects (`T`, `TClass`,
     `FuncInfo`, `ClassInfo`, `Ty`) are written by path and name (types
     structurally: anonymous structures, functions, monomorphs bound or
     not) and read back through the binding; `Entry.gen`'s numbers bound
     anew, as a replay does. Keep the in-memory replay for the server. A
     mismatch still abandons the whole lowering, so the gate and
     `LowerQueriesCheck` must cover a stale entry. Risks: `@:logged`
     queries that return objects by identity (each needs a name), entries
     of DCE-removed fields (written only for what the build lowered),
     store size (bodies are larger than HXB: measure on the self-build).
   - **2c, objects**: a module's object depends on more than its bodies:
     the digests of the callees it may inline from other modules
     (`Fingerprint.Inlined`), the field layouts and signatures `MirBuild`
     reads, no-GC flags. So keeping the previous object key needs the
     module `Valid` with its bodies replayed **and** each inline candidate
     it calls from another module `Valid` too (its digest unchanged), and
     the layouts of the classes it touches unchanged (DCE can remove a
     field of an unchanged class). Store per module, with its object key,
     the inputs that are not its own (the callees' digests, a hash of the
     layouts read), and reuse the key when they match; else `Fingerprint`
     as today. The payoff is bounded by the keys' time (0.24 s above).
   Risks for both: the gate's typing-order cases (restoring changes it);
   server memory (the server keeps both forms meanwhile).
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
