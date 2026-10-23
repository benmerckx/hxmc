# Compiler and cache

Open designs for the front half (typing, macros) and for build caching.
What is built is described in [docs/hxmc.md](../hxmc.md) ("Module cache",
"Runtime in Haxe") and [docs/using.md](../using.md) ("Fast rebuilds").

## Cached modules

Most of a small program's build is the front half typing the std from
source every time (hello world: about 330 ms of 0.375 s). The compilation
server already caches per module, with upstream's rules (per-module
dependencies, file checks, invalidation of dependents, an HXB mode). The
module cache is that cache made durable on disk, not a new unit of
caching: no library boundaries, so the std, haxelib, lix and node_modules
libraries and the user's code are all modules alike.

Built (docs/hxmc.md, "Module cache"; `hxmc/src/hxmc/ModuleCache.hx`,
`ModuleStore.hx`, `ModuleInterface.hx`), on by default since 2026-10-17
(it replaced the types cache, an HXB archive of hxmc's own package typed by
a separate run of the tool): the store, lazy validation (content hashes
where dates or sizes differ, shadowing, missing dependencies), what HXB
does not keep (the modifiers of unbound monomorphs, the sort's walk of each
module; also an anonymous structure's fields are now in name order, which
showed only in hxmc), and the gate (`make test-module-cache`,
docs/testing.md). CI keeps the source path tested: the npm-pack job builds
the packages' compilers with the cache off, the fixpoint builds the tool
cold, warm and off, and crosshost compares the native tool (cached) with
the WebAssembly one (WASI: never cached). The corpus builds from HXB
archives, without it.

- **Keys** (built): an index per working directory, class paths and std,
  of module variants, each with the defines it read: its file's conditions
  (recorded while parsing), its macros' `Context.defined`/`getDefines`
  (attributed to the module whose macro runs), and those the compiler read
  in the build that typed it (`Define.readHook`: the typer's and filters'
  options, the target's). A build restores the variant whose reads have
  its values, so a define one module reads leaves the others alone. The
  macros' context's defines are predicted as `MacroContext` makes them when
  it does not exist yet (checked when it is created). An edit undone
  restores the earlier variant (chosen by its file's content).
- **Early cutoff** (built): each variant keeps, per dependency, the hash
  of its interface as it was when the variant was typed: the parsed
  declarations without the bodies of functions whose type is written out
  (not inline, macro, @:generic, nor in a class a build macro makes),
  positions only for the expressions it keeps (inlining copies them), with
  its own dependencies' interfaces per strongly connected component; across
  contexts (a macro's module), the whole content. A module typed again
  whose interface did not change leaves its dependents restored; it is
  typed from its source where the server expects it cached. In a cycle,
  the restored modules a module typed from source loads while it is being
  created are typed from source too (decoded then, they would reach its
  types before they are ready); the rest of the cycle stays restored.
  Coupling found on the way: the typing of a module marks fields of its
  dependencies as maybe used through structures (`CfMaybeUsed`, which DCE
  reads). The marks are attributed to the module whose typing made them
  (`TUnification.maybeUsedHook`; the module being typed known through
  `Typecore.typeExprRef`, the tasks it delays, its lazy typings and its
  creation) and stored with its variant; a restored module's fields lose
  the marks its HXB kept, and get this build's: those of the modules typed
  again, made again, and those the restored modules replay. A build where
  a mark has no maker writes nothing.
  Modules build macros make are restored too (built). What macros keep
  between calls is tracked: the static variables of macro classes (not
  the std's) that the macros run in a module's typing read or write
  (`EvalJit.staticVarHook`) are kept with its variant (the gfx shaders'
  `@:autoBuild` registry, json2object's counter naming generated parsers).
  Such a module is restored while no macro of the build uses that state.
  A macro that uses it after such a module was restored makes the build run
  again, with those modules typed (`HXMC_MODULE_CACHE_RETYPE`). An edited
  module whose macros keep state has the others that keep state in the same
  class typed from the start, so a shader edit does not run the build twice.
  A callback registered while a module is typed (`onGenerate`...) makes
  that module typed every build. The macros' context's modules restored as
  processed get their exception constructors patched once
  (`MacroContext.processedTypeHook`). Without it, `SaveStacks` added a
  `__skipStack++` each build, so blobs grew and were rewritten. A build
  whose modules are all restored skips the capture.
- **Nondeterministic macros** (built): the macro std's natives tell the
  cache what a macro's result depends on beyond the sources
  (`EvalStdLib.volatileHook`, `fileHook`, `envHook`: null-default hooks the
  wrapped natives call before they run), for the module being typed when
  the macro runs (the top of the typing stack the static-variable tracking
  uses).
  - Volatile: `Date.now`, `Sys.time` (and `Timer.stamp`), `Sys.cpuTime`,
    `Math.random`, `Std.random`, sockets, `sys.net.Host`, `sys.Http`,
    `sys.ssl`, `Sys.command`, `sys.io.Process`, `Sys.getChar`, and
    eval.luv's network, processes, signals, time, random, file system and
    system information: the module is typed every build (its macros run);
    its dependents stay restored through its interface as parsed, unless
    the call was where they copy the result (an inline or macro field, a
    field whose type is not written out, a build macro, a lazy typing):
    then that interface counts as new every build, so its dependents (and
    theirs, as for an interface edit) are typed again too.
  - Reads instead of volatility: a file (`File.getContent`, `getBytes`,
    `read`: its content's hash; `readDirectory`: the sorted listing;
    `exists`, `isDirectory`: what is there; `stat`: date, size and mode;
    `fullPath`: the result) and an environment variable (`Sys.getEnv`,
    `Sys.environment`: all of it but hxmc's own `HXMC_*`; eval.luv's `Env`)
    are reads of the module, kept with their values like a macro's
    `Context.defined`: a variant per value, its interface its whole content.
    A file touched but not changed leaves it restored. A macro reading the
    module's own file (the view package's markup) adds nothing.
    `registerModuleDependency` keeps working; a file it names that the
    macro reads is both.
  - Escape hatches: `@:hxmc.noCache` on a type of the module,
    `-D hxmc.no-cache=<package, module, or a directory of its class path's
    path such as a library's>` (comma-separated, read without entering the
    key; without a value every module), both typing the module and its
    dependents every build; `HXMC_MODULE_CACHE=0`. `HXMC_MODULE_CACHE_LOG=1`
    says why (`Clock typed every build (macro called Date.now at
    src/Macros.hx:4)`, `Data dirty: ... (data.txt, read by a macro)`), and
    `HXMC_STATS=1` counts the modules typed from source, those typed every
    build and those whose macros read files or the environment.
  - `--wait` keeps upstream's behaviour (the hooks do nothing without the
    disk cache). Init macros already bypass the cache.
  - Gate (`make test-module-cache`, the nondet and nethttp programs, for
    hxmc, JS and `--interp`, against builds without the cache, with the
    modules typed from source counted): `Date.now` in a body (typed every
    build, its dependent restored) and in an inline variable (its dependents
    with it), a process, a file read (typed again when it changes, not when
    touched), an environment variable, `@:hxmc.noCache`, `-D hxmc.no-cache`,
    the log, a failing HTTP request.
  - Found on the way: a module of the macros' context whose types share a
    path (`@:native` on an abstract renames its implementation class to the
    abstract's path, eval's `mbedtls.SslAuthmode`) cannot be restored (HXB
    names a type by its module and name; restored, "Type name ... is
    redefined"): it is not kept, nor what depends on it, so a macro using
    `sys.Http` has its module's dependents typed every build. What stands
    for a hash not known in a build now has a nonce (two builds made the
    same string, so a stored hash could match it).
  - Measured (one 4-core VM shared with other builds, seconds, before and
    after): no module of hello, the formatter, tink_json (24 types through
    `tink.Json`), the port, the gfx cube or the ui Todo is volatile or
    reads a file or the environment (the std's macros included); warm builds
    0.17/0.17 (hello), 0.41/0.43 (formatter), 1.94/1.86 (tink_json),
    3.9/3.9 (the port), cold builds the same within the noise (the port
    13.8-14.0/13.3-13.9). The hooks cost a null check where the cache is
    off; with it on, a push per expression typed through `typeExprRef`.
  - Limits: a file a macro writes is not tracked (nor a std class's statics:
    "Macro state"); a volatile module is encoded again each build (its new
    module id); a read of a whole directory tree is a read per call; eval.luv
    file handles count as volatile, not as reads.
- Cold runs (built): the interface hash walks the syntax tree directly
  and runs as each file is parsed, so no declarations are kept. File
  and closure hashes are a 64-bit two-lane hash instead of MD5. A build's
  new blobs go in one pack (`b/<name>.pk`), written on a thread beside the
  rest of the build. The capture and the skeletons use the pool even under
  `-D disable-parallelism`. A define read again costs a lookup. The tool's
  first old-space limit is 3 GB, up from 2 GB: the port's cold build with
  the cache promotes just over 2 GB, which cost a major collection of
  about a second.
- Measured (one 4-core VM shared with other builds). Each entry gives the
  time to the start of lowering, the whole build with the objects cached,
  and the number of modules typed or processed again. Before is main's tool,
  measured in the same session:

  | | before | after |
  | --- | --- | --- |
  | hello, cold | 408 ms, 0.51 s | 406 ms, 0.49 s |
  | hello, warm | 96 ms, 0.17 s | 101 ms, 0.18 s |
  | hello, after `-D unrelated` | 383 ms, 0.45 s, 94 | 100 ms, 0.17 s, 0 |
  | hello, a body edited, then undone | 97 ms, 0.18 s, 1; 1 | 106 ms, 0.19 s, 1; 0 |
  | formatter, cold | 1043 ms, 1.42 s | 1017 ms, 1.39 s |
  | formatter, warm | 187 ms, 0.39 s, 0 | 205 ms, 0.40 s, 0 |
  | formatter, after `-D unrelated` | 1193 ms, 1.41 s, 334 | 196 ms, 0.41 s, 0 |
  | formatter, a body edited (tokentree.TokenTree) | 565 ms, 0.84 s, 173 | 244 ms, 0.52 s, 6 |
  | formatter, an interface edited | 566 ms, 0.78 s, 173 | 609 ms, 0.84 s, 118 |
  | the port, cold | 8.5 s, 14.1 s | 8.0 s, 13.6 s |
  | the port, warm | 1.33 s, 3.48 s | 1.28 s, 3.45 s |
  | the port, after `-D unrelated` | 8.4 s, 10.7 s, 563 | 1.34 s, 3.52 s, 0 |
  | the port, a body edited (core.TFunctions) | 6.7 s, 9.0 s, 274 | 1.58 s, 3.91 s, 1 |
  | the port, the edit undone | 6.7 s, 9.1 s, 274 | 1.39 s, 3.73 s, 0 |
  | the port, an interface edited | 7.1 s, 9.5 s, 274 | 6.7 s, 8.9 s, 228 |

  Cold builds still pay for encoding the modules (the port: about 0.33 s
  on four threads) and the skeletons, so the gain on the port's cold build
  comes from the 3 GB old-space limit.

Open:

- **Macro state**: the tracking sees static variables, not state a macro
  keeps elsewhere (a file it writes, a std class's statics, the macro
  API's own registries beyond the callbacks). A conflict found late costs
  a second run of the build.
- **Interface edits undone**: an undone edit of a module restores its
  earlier variant but not its dependents' (the newest variant of each is
  chosen by its own file); choosing among a module's variants by its
  dependencies' hashes would restore them too.
- **Cold runs**: encoding is upstream's HXB writer. Starting it before
  the filters end, or writing less, would lower it.
- **Init macros**: their effects are data (`addGlobalMetadata` filters,
  `Compiler.define`, class paths); until they are in the key, builds with
  `--macro` do not use the cache. A macro registering `onGenerate`,
  `onAfterTyping` or `onAfterGenerate`, or defining something, while
  typing makes the build write nothing (a restored module would not do it
  again).
- **Back half**: the per-module objects are in the same store, keyed by
  the hash of the lowered IR (`Fingerprint`), shared by every output
  ("Central object cache" below). Next: DCE is whole-program: move it
  to link time (reachability over symbols with Haxe's rules: `@:keep`,
  implemented interfaces, overrides of reachable fields, reflection roots;
  reflection tables generated from the live set), so a module's object
  does not depend on the rest of the program; whole-program "features"
  become link-time switches. Program-wide numbering is already symbolic.
  `@:generic` instances belong to the module that instantiates them, as
  mergeable (COMDAT-like) symbols; inline bodies are covered by the
  interface hash.
- **Typing order**: some Haxe behaviour depends on it (monomorph
  resolution, anonymous type numbering, build macro order, static
  initialization), and restoring changes it; the gate covers it.
- **Then**: builds with init macros, `-lib` HXB archives as one more
  source of modules. The `npm` postinstall warming the std's modules does
  not pay while an index is per working directory and class paths (a
  warm-up in the package's directory serves no project): it needs the
  std's variants shared across keys.
- Decided against: shipping the std as HXB in the distribution. There is
  no single typed std (per target, per define, again for the macro
  context), the sources have to ship anyway, init macros cannot change
  pre-typed modules, and an edited compiler (`hxmc-rebuild`) invalidates
  it.

## Central object cache and quieter builds

Done for the objects (2026-10-17, `ObjectStore.hx`): the per-module
objects live in the module cache's store (`<cache>/modules/<tool>/o/`),
named by the hash of their lowered IR with the tool and the target
(`Fingerprint`) and the module, so every output and project compiling the
same code for the same target shares them; per output, `<hash>.objs` names
the objects its last build used (the trim removes the objects no `.objs`
names after a day, the `.objs` with their last use) and `<hash>.key` is the
up-to-date record (`UpToDate.hx`). `<out>.hxmc/` remains only where the
cache directory cannot be written (and under WASI). Left: logs only on
request (the Makefile's build rule still writes `<out>.log`, shown on
failure); `-D hxmc.cache=<dir>` beside `HXMC_CACHE`.

## Faster rebuilds, smaller outputs

- One-edit rebuilds below 1 s: needs incremental program preparation,
  module keys, data tables and linking, and incremental DCE in the port
  (today 2.0 s through the resident server, 2.7 s without).
- Server builds from `--hxb-lib`: the port's server re-decodes
  HXB-library modules every build, or loses their function bodies with
  `-D disable-hxb-cache` ("static main is not a function"). A port bug to
  check against the reference compiler.
- Program-level dead-code elimination and data-table compaction (type
  info, field names, dispatch rows, string literals).

## Macro-heavy builds

After the macro-perf fixes (Eval's object encoding, calls and field
lookups, `haxe.ds.Vector` allocation) the `macro` timer is at or below the
reference compiler's on every workload; the remaining gap is in typing
and the collector. Macro share of the build (native port, Linux x86-64,
`--times`):

| Workload | port | reference |
| --- | --- | --- |
| tink_json, 12 nested types (JS) | 29% (0.97 of 3.32 s) | 34% (0.89 of 2.65 s) |
| tink_json, 24 nested types (JS) | 24% (3.27 of 13.4 s) | 24% (2.84 of 12.1 s) |
| upstream unit suite (JS) | 16% (0.54 of 3.33 s) | 17% (0.54 of 3.19 s) |
| upstream unit suite (--interp) | 14% (+ interp 32%) | 13% (+ interp 46%) |
| gfx's GfxTest (universe's since) | 8% | 7% |
| macro conformance cases (66, summed) | 39% | 37% |

Done since: the adaptive nursery (docs/hxmc.md, "Runtime in Haxe") and
the typing of generated code (`ctx.e.monomorphs` as an immutable list
consing onto shared arrays, `Typecore.MonomorphList`; callback lists no
longer unshift; maps share empty arrays). The port now beats the
reference on tink_json (40 types: 34.1 s against 42.5 s) and types itself
in 6.3 s against 7.6 s. The collector's share is 17-21%, as in the
reference.

What is left, ranked by estimated payoff, each needing more than a local
fix:

- **monomorph_transaction**: upstream snapshots every unbound monomorph
  of the function for each optional argument passed (`CallUnification`),
  quadratic in a function's size in the reference too. 15% of tink_json
  at 40 types, 6% at 24, little elsewhere; the walk is memory-bound. A
  trail of the monomorphs bound or constrained since the snapshot (the 12
  places that set `tmType` or `tmDownConstraints`) would make it
  proportional to the changes; a departure from upstream's algorithm.
  Estimate: -12% at 40 types.
- **Medium-lived objects in the collector**: a minor collection promotes
  whatever survives it (9% of what tink_json allocates), and major
  collections stop the world (1.8 s at 40 types, charged to wherever an
  allocation lands: the "superlinear" `BasicBlock.create`,
  `Abstract.findToFrom` and DCE's mark are their pauses). An aging
  survivor space, or incremental major marking ([runtime.md](runtime.md)).
  Estimate: 5-10% on large builds.
- **Allocation in the typer and analyzer**: spread thin (texpr records,
  `InterferenceReport`'s four maps per expression, Eval's encoding of
  macro arguments); escape analysis ([codegen.md](codegen.md)) is the
  general answer.
- **Eval call frames**: each call allocates an Env, two slot vectors and
  the argument array, and stores the frame into the long-lived Eval record
  twice (two write-barrier slow calls): a quarter of a call's cost. A frame
  stack reused across calls is a redesign of EvalContext. Estimate: 20-30%
  on call-heavy macro code.
- **Eval instance layout**: a field read is four dependent loads (the
  VInstance box, the instance, the Array header, its data) against three
  in OCaml; instance fields as an object with inline slots would remove
  one.
- Minor: `Finalization.sortTypes` and `TPrinting.sType` sort through
  `Reflect.compare` (2% of the unit suite); source lines for messages are
  read a byte at a time, each byte a poll and a read system call.
- Tried and not kept: the write barrier testing the value for youth before
  its slow call (within noise, 2.6% more code); `encodeObjS` without its
  intermediate records (no gain).

## Mir macros: size and speed

Where Mir macros (docs/hxmc.md, "Macros on the Mir interpreter") stand
against Eval, and the plan to close the gaps before they can be the
default. Measured on the jit build after the stub-free bundles (#57),
Intel Xeon @ 2.10 GHz, 4 vCPUs:

| | Mir macros | Eval |
| --- | --- | --- |
| compute-bound macros (mandelbrot, json, binarytrees) | 3-10x faster | |
| formatter with json2object's macros | 1.04 s | 0.70 s |
| trivial macro, cold | 0.22 s | 0.12 s |
| trivial macro edited under the server | 0.020 s | |
| compiler binary (linux-x86_64) | 26.3 MB, every native compiler (the jit build: 28.6 MB) | |

Eval's cost is inherent (dynamic values, encode/decode at the API
boundary); Mir's is preparation (typing the runtime in the macro
context, lowering every macro function through the Mir pipeline) and
binary size, both reducible. Since then (Speed of typical builds, below)
the compiled functions are kept across builds and their compilation is
cheaper; the macro context is what is left.

### Speed of typical builds

Measured on an Intel Xeon @ 2.10 GHz, 4 vCPUs, Linux 6.18, the
linux-x86_64 native compiler.

1. **Breakdown** (done). The formatter build with json2object's macros,
   module cache off, by where the main thread is (`perf` samples, each
   charged to the innermost frame of a category, the collector's to its
   caller's; ms, the mean of five runs, `perf` adding about a third):

   | | Mir before | Mir now | Mir now, compiled functions kept | Eval |
   | --- | --- | --- | --- | --- |
   | typing (the macro context, hxmc's std and runtime in it, included), filters, the rest of the compiler | 701 | 651 | 610 | 555 |
   | parsing | 167 | 162 | 166 | 151 |
   | `Lower`, `Prep`, the macro context's facts, fingerprints | 49 | 52 | 41 | |
   | `MirBuild` (object-level Mir) | 43 | 44 | 0 | |
   | `Opt` (with `Sroa`, `Frames`, `Fold`, the inliner) | 78 | 22 | 0 | |
   | `MemLower` and the rest of the lowering | 30 | 33 | 0 | |
   | `InterpGen` | 201 | 132 | 1 | |
   | bundle load (and the cache's reads) | 16 | 15 | 21 | |
   | running the macros: the interpreter, API calls, values | 82 | 67 | 77 | 111 |
   | total (of which the collector) | 1,368 (297) | 1,178 (263) | 917 (207) | 818 (181) |

   Compiling for the interpreter was 417 ms, `InterpGen` half of it (its
   register coalescing built dense liveness sets per block: the
   `DataBuilder` functions have 38,000 values) of the 550 ms over Eval;
   typing and parsing the macro context against hxmc's std most of the
   rest (162 ms), and most of a cold trivial macro's: 384 ms against Eval's 212,
   typing and parsing 356 against 207, compiling 28 (instructions: 1.30 G,
   Eval 0.70 G, no macro 0.33 G; 1.78 G with the runtime's bodies typed,
   `HXMC_MIR_TYPE_RUNTIME=1`). The interpreter itself runs the macros
   faster than Eval.
2. **Compiled functions on disk** (done, `interp.BundleCache`; docs/hxmc.md,
   "Macros on the Mir interpreter"). Per function rather than per bundle:
   a bundle depends on what the macros called before it, a function's
   descriptor only on its IR (`Fingerprint`, with the inlined callees'
   digests), the compiler's target and options, and which of its calls
   are of interpreted functions (kept with it, checked). The store,
   limits, trim and the off switch are the module cache's; the typed macro
   context is the module cache's already (it keeps the macro context's
   modules), so nothing else is kept. `make mir-cache-check`.
3. **Cold path** (done, a static policy): the optimizer gains the giant
   functions nothing and costs them most of `Opt`'s time, so a function
   over 8,000 IR words is compiled without it (`HXMC_MIR_COLD`); the
   others are optimized as before. All functions without `Opt` saves 4.6%
   of the formatter build's instructions, the policy 2.5%; but json then
   runs 19% slower and mandelbrot (its loop in one call) 2.6 times slower,
   so the functions of compute-bound macros (under 3,000 words) stay
   optimized. Tiering up hot functions is not done: no measured workload
   has a hot function over the threshold (decision below).
4. **Results** (MirBench, interleaved, the median of five, wall time; the
   caches warm: the module cache and the compiled functions, each
   compiler its own, filled by a first build, then each run after the edit
   named):

   | | Mir before | Mir now | Eval |
   | --- | --- | --- | --- |
   | json as a macro | 3.60 s | 3.51 s | 8.57 s |
   | mandelbrot as a macro | 6.57 s | 6.63 s | 88.5 s |
   | formatter build, cold | 1.11 s | 0.989 s | 0.636 s |
   | formatter build, warm, unchanged | 0.194 s | 0.144 s | 0.144 s |
   | formatter build, warm, main module edited | 0.225 s | 0.229 s | 0.195 s |
   | formatter build, warm, configuration edited (json2object's macros run) | 1.37 s | 1.07 s | 0.943 s |
   | formatter build, only the compiled functions kept (every macro runs) | 1.27 s | 0.924 s | 0.716 s |
   | trivial macro, cold | 0.330 s | 0.378 s (the same instructions) | 0.187 s |
   | trivial macro, warm, main module edited | 0.177 s | 0.160 s | 0.083 s |
   | trivial macro edited under the server (the median of 12 builds, two sessions) | 0.022 s, 0.020 s | 0.020 s, 0.021 s | 0.023 s, 0.019 s |

   Mir macros are on par with Eval where the module cache holds (the
   formatter unchanged or with its main module edited, which runs none of
   json2object's macros) and under the server, 13% behind where the
   macros run again with the caches warm (29% with only the compiled
   functions kept), and behind on cold builds and the trivial macro by
   the cost of typing the macro context; compute-bound macros stay 2.4x
   (json) to 13x (mandelbrot) faster.

**What is left: the macro context.** With compilation gone from warm
builds, what Mir macros pay over Eval is the macro context typed (and
restored from the module cache) against hxmc's std: 47 more modules than
Eval's (168 against 121 for the trivial macro), whose bodies Eval's
externs do not have. A cold trivial macro types 1,456 bodies there (249 KB
of source; the runtime's 113 KB of them, 141 KB more not typed already:
the compiler's native code, `MacroRuntime`), among them `hxmc.Regex` and
`RegexUnicode` (42 KB, for `EReg`), `WinSys` (17 KB, Windows' on Linux),
`LibM`'s tables (26 KB), `StringTools` (16 KB). Warm, the module cache
decodes all of their expressions as it restores them (the macro context
reads them eagerly, `ServerCache.readExpressionEagerly`), and encodes the
macro context's edited modules again. Levers, none done:

- the bodies the compiler runs natively, not typed nor parsed: instance
  methods of the runtime too, and the std's classes of files the compiler
  was built from (`MacroCuts` keyed by content, as for the runtime's
  statics);
- the macro context's bodies typed lazily, when the lowering reaches them
  (the filters then per function), and their expressions decoded so from
  the module cache;
- a macro std that does not load the whole runtime (`Std` imports
  `hxmc.rt.Runtime`), loading a runtime module when lowering needs it.

Eval stays the default (decision below).

Open decisions:

- **Tiering up.** Options: (a) none, the static size policy only (now);
  (b) counts of calls in each descriptor (from interpreted callers: native
  ones enter with addresses the collector does not see) and, at a
  threshold, the function compiled with the optimizer into a bundle of
  its own and the old descriptor forwarding to it (the interpreter checks
  the forward pointer where it enters a function, so frames running the
  old one finish on it); (c) (b) with counts of backward jumps too, for a
  loop in one call, which needs entering the new code in the middle of a
  frame. (b) covers a giant function called often, (c) mandelbrot's shape
  over the threshold; neither has a measured workload yet.
- **The default engine.** Mir macros now match Eval where the module cache
  holds and under the server, are 2.4 to 13 times faster on compute-bound
  macros, and are behind on cold builds, on a trivial macro and where the
  macros run again (13% on the formatter), by the macro context's typing.

### Names

Done. The run-time switches are `-D hxmc.macros=mir|eval` (default
eval) and `-D hxmc.run=mir` (for `--run`/`--interp`; default Eval);
an unknown value is an error. The jit build flavor and its define
are folded in: every native build of the compiler is a Mir
host (docs/hxmc.md, "Macros on the Mir interpreter"), since its cost
measured below the bar (about 10% of the binary or less, no measurable
speed cost).

### Binary size

Measured on linux-x86_64 (the same sources; gzip -9). The jit build was
3.35 MB over the normal compiler (`hxmc.HaxeMain` without it; the 8 MB
first estimated was against the port's own binary, which has no hxmc
back end); it is now 1.12 MB over it raw and 0.14 MB under it gzipped:

| build | raw | gzipped |
| --- | --- | --- |
| normal compiler (no Mir host, before) | 25,221,008 | 8,366,385 |
| jit build (before) | 28,567,480 | 9,242,836 |
| every native compiler (now) | 26,343,288 (+4.4%) | 8,221,662 (-1.7%) |

By part (from the symbols, `<exe>.syms`, and the unwind sections):

| part | normal | jit before | now |
| --- | --- | --- | --- |
| host table | 0 | 1,507,536 | 215,920 |
| pools' entries, call-outs, accessors | 0 | 397,136 | 80,976 |
| unwind entries (.eh_frame, its index) | 1,291,988 | 1,707,400 | 1,443,144 |
| type tables (rt_types, the type objects) | 736,076 | 1,206,704 | 976,432 |
| signature tables | 22,764 | 240,820 | 234,197 |
| the Mir host's code (Loader, MirMacros, MirRun, the interpreter) | 129,360 | 407,640 | 315,616 |
| other code | 20,250,536 | 20,799,512 | 20,804,216 |
| other data | 3,523,200 | 3,106,548 | 3,044,971 |

1. **What the table must hold.** Three configurations:

   | configuration | raw | gzipped | json as a macro | formatter build |
   | --- | --- | --- | --- | --- |
   | everything kept (now) | 26,343,288 | 8,221,662 | 4.15 s | 1.14 s |
   | compiler-only (`Reach`, static closures) | 27,713,352 | 8,923,431 | 4.04 s | 1.06 s |
   | hot set | not built: at least compiler-only's | | | |

   (MirBench, five runs each interleaved, the median; Eval in the same
   compiler: 9.25 s and 0.72 s.) Compiler-only is larger: the reachable
   set drops only about 690 functions (75 KB of code), static closures
   add 1.45 MB of data, and the table keeps nearly as many names. A hot
   set adds to compiler-only, so the dual design does not pay; every
   function stays. What shrinks the table is naming less: not the
   compiler's own classes' entities (functions, type and field tables,
   globals), which the macro context and `--run` programs type again,
   so a bundle never asks for them (20,439 of 63,450 symbols).
2. **How the table is encoded** (`macro.HostTable`): 1.5 MB to 216 KB.

   | part | before | now |
   | --- | --- | --- |
   | name keys | 64-bit hash, sorted, binary search | a minimal perfect hash (PTHash: a 16-bit pilot per bucket, 21,078 slots for 20,439 names) and a 32-bit check per slot (16 bits would let about one in 65,536 of a build's misses through, and a build has hundreds) |
   | addresses | 64-bit absolute, relocated by the loader | 32-bit, relative to the entry (resolved at the link: no relocations; macOS's bound imports keep 64-bit slots) |
   | kinds | a byte | 4 bits |
   | fingerprints | 8 + 12 bytes, binary search | their own perfect hash, a 32-bit check, the key and a flags byte (1,563 entries) |
   | MacroCuts' lines | text | 4,717 bytes of text, not compressed |

   A lookup takes 0.23 µs instead of 0.40 (the formatter build's 6,878:
   1.6 ms instead of 2.8).
3. **The entry pools**: 6144 + 1024 + 512 + 128 entries to 1024 + 256 +
   128 + 32 (the most measured: 99, 16, 2 and 0; the formatter build 70),
   an exhausted pool's error names it;
   397 KB of code to 81 KB, and their unwind entries with them. The spare
   type entries 4096 to 2048 (the most measured: 339), the spare
   signatures 256 (none measured).

The tool (`bin/hxmc/hxmc`, which has `hxmc.HaxeMain` for scripts) is a
Mir host too: 18.67 MB to 19.83 MB. The WebAssembly compiler does not
type the Mir host's classes (`HaxeMain`), so it is unchanged.

Speed (interleaved, the median): the port's self-compile to HXB 7.46 s
normal, 7.47 s now (nine runs); 20 corpus builds 9.98 s and 10.53 s, and
10.71 s and 10.37 s, in two sessions; `haxe -version` 7 ms and 5 ms.
Mir macros (MirBench against the jit build): json 4.11 s and 3.89 s now
against 4.25 s and 3.83 s before, the formatter build 1.33 s and 1.19 s
against 1.19 s and 1.17 s (two sessions, the order swapped; the same
functions run natively).

## Code generation at run time

The code generator compiles to in-memory objects with relocations, and
program-wide numbers stay symbolic, so these remain possible:

- **Native macros**: macro code compiled by hxmc into the running
  compiler instead of interpreted. A prototype (machine-code bundles
  mapped below 2 GB on linux-x86_64, with a verify mode comparing each
  call against Eval) was removed once Mir macros (docs/hxmc.md, "Macros
  on the Mir interpreter") replaced it; hot macro functions compiled from
  the same Mir would be a tier of that engine, and a Mir-versus-Eval check
  like verify mode could be rebuilt on it.
- **Hot reload / live patching**: replace changed modules in a running
  process (needs runtime registration of new types and dispatch rows).
- **A JIT library** for interpreters written in Haxe (only the code
  generator half). About 0.5 ms per function single-threaded: suits hot
  functions, not baseline tiers.
- Platform limits: iOS and consoles forbid generating code at run time,
  hardened macOS apps need the allow-JIT entitlement, browsers use
  WebAssembly instead.

### Bootstrap plus bundled program

Executables made of a small native bootstrap (runtime, code generator,
loader) and the program as a portable archive, compiled at first launch
(then cached per CPU and version), lazily per function, or tiered. One
archive for every platform, code tuned for the actual CPU, plugins and
mods, small updates. Costs: first-launch latency, the platform limits
above, a larger footprint than one AOT executable for small programs.

Archive format: hxmc's own lowered IR rather than HXB. When bootstrap and
archive ship together the format is private and needs only a version
stamp; HXB would mean a larger bootstrap (HXB reader, typed AST,
lowering), lowering on every user's machine, and compiler internals and
absolute paths in shipped programs. A versioned format matters only if
archives and bootstraps are built separately (plugins, patches from a
newer hxmc, a shared installed bootstrap).
