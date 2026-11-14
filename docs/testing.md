# Testing and CI

For contributors: which tests to run for a change, what each harness
checks, which CI jobs gate a release, and how benchmarks are measured.
Building is in [development.md](development.md).

## Which tests to run

| Change | Run |
| --- | --- |
| hxmc (`hxmc/src`, `hxmc/std`) | `node make.mjs quick` after every edit, `node make.mjs check` before a commit; CI the rest |
| typing or filters in the port | `node make.mjs test LANES="hxb macro"` |
| a generator in the port | `node make.mjs test-fuzz LANE=diff:<target>`, `node make.mjs test LANES=targets` |
| display or the server | `node make.mjs test LANES="display server jsonrpc"` |
| anything broad | all of the above, `node make.mjs fixpoint`, `node make.mjs crosshost` |

The fixpoint and crosshost must stay byte-identical.

| Tier | What it runs |
| --- | --- |
| `node make.mjs quick` | the tool, the x64 corpus, again with `RT_VERIFY=1` and `-D hxmc.verify-tags` ([hxmc.md](hxmc.md#values-of-type-parameters)), the wasm corpus under node, again with `RT_VERIFY=1`, a 64 KB nursery, an old space of 1 MB at first and `RT_MAX_MB=64` (its major collections compact: [hxmc.md](hxmc.md#memory)), the unit checks (`Units`; `CASES=` restricts the corpus) |
| `node make.mjs check` | quick, plus arm64 (qemu), x64 Windows (wine), a 16 KB nursery, legacy exception handling, the glibc mode, ThreadNatives x30, CompactParGc x10, CompactEnums x10 and HeaderEnums x10 (parallel collections of compact objects), crosshost on three cases, debug info, the native output (`NativeCheck` shared, jni, macho; uikit on a Mac with Xcode), the corpus in an iPhone simulator (macOS with Xcode's iOS runtime) and as Mac Catalyst (an arm64 Mac) (`PORT=1`: the port's self-compile) |

## The port against the reference

Every harness compares the port (`PORT_BIN`, default `bin/port/haxe`)
with the reference compiler (`bin/reference/haxe`, `node make.mjs reference`).
Outputs go to `bin/test/`. Run them with `node make.mjs test LANES="<lane> ..."`
(default `hxb`; every lane runs and the failed ones are named at the end;
`EVAL` picks the compiler whose Eval runs them, `SUMMARY` writes Markdown),
or `bin/hxmc/hxmc -cp haxe/test --run <Name>` with the options at the top
of each file.

| Script | Lane | Compares | Result |
| --- | --- | --- | --- |
| `Conformance` | `hxb`, `macro`, `hxblib` | HXB archives of `conformance-cases.txt` (upstream's suites and the port's own cases), `conformance-macro-cases.txt`, `conformance-hxblib-cases.txt`; `--hxb-lib`, `--eval`, `--parallel N` modes; a case that `diverges` ([a divergence](porting.md#divergences-from-the-reference)) passes when the reference cannot read its archive back and the port can | 300 + 24 expected failures, 68/68, 8/8 |
| `Display` | `display` | `--display` JSON-RPC requests from upstream's removed display suite | 679/679 |
| `Server` | `server` | the compilation server: cases twice, edits and invalidation, stdin, `--cmd`, errors, an empty connection ([a divergence](porting.md#divergences-from-the-reference)), `--server-connect` | 674/674 |
| `ServerJsonRpc` | `jsonrpc` | the `server/*` methods, both cache modes | 107/107 |
| `UpstreamTargets` | `targets` | upstream's unit suite compiled for js, lua, python, php, neko, hl, hl/c, cpp, cppia, jvm and flash by both, every output file | 12/12 identical |
| `Interp` | `interp` | `--interp` runs of the case lists (not in CI) | 315/316 (`eval-eventLoop-compile` depends on thread timing) |
| `Haxelib` | `haxelib` | `-L` through lix's haxelib shim, batch and `--server` | 14/14 |
| `LibResolution` | `libs` | hxmc's own `-lib` resolution against haxelib and lix's shims: repositories, versions, dependencies, every `resolveLibs` mode, errors | 130/130 |
| `EvalDebugger` | `debugger` | scripted Eval debugger sessions (`SHARD=i/n`) | 6/6 |
| `unit.hxml` | `unit` | unit tests of port modules, in-process | pass |
| `fuzz/` | `node make.mjs test-fuzz LANE=...` | random programs per target (`diff:<target>`) or by output (`exec:<a>,<b>`), reduced on failure; `--cases haxe/test/fuzz/cases` reruns the kept ones | CI: diff lanes of ten targets, two exec lanes |
| `IpcStress` | (upstream-tests.yml) | multi-byte strings through Eval's `sys.io.Process`, with concurrent file reads | 86 checks per round |
| `tools/hxmc/EncCheck` | | the x86-64 and AArch64 encoders against `llvm-mc` (not in CI) | |

Sequential runs pass `-D disable-parallelism`: the reference itself is not
deterministic in parallel mode.

Upstream's compiler-side suite (RunCi `macro`: unit tests in the macro
context, null safety, misc, sys on Eval, threads, third-party projects)
runs with the release binaries as `haxe` (`upstream-tests.yml`). No target
runtime is installed: other targets' outputs are compared, not run.

### Two exceptions to byte identity

- **hl/c digest names** (`HlcNames.hx`). hl2c names some types after the
  MD5 of a marshalled description that, for object prototypes, contains a
  code pointer into the reference's own binary. The port writes a fixed
  placeholder (`Hl2c.hx`). Where hl/c output is compared, the digest names
  found on one side only are renamed on both sides in order of appearance;
  every other byte must match.
- **Printed floats**. The port's Math is musl's libm everywhere
  (`LibM.hx`); the reference's is glibc's. They can differ by an ulp, which
  arithmetic can widen. The fuzzer's output comparison
  (`Runner.sameOutput`) accepts two printed floats at the same place when
  they are at most 4 ulps apart (`Runner.MAX_ULPS`), finite and of the same
  sign.

### The fuzzer's exec lanes

`exec:interp,hxmc` runs each program on the reference's Eval and as a
native executable built by hxmc; `exec:interp,hxmc-wasm` as a wasm32-wasi
module under node. hxmc's side runs with a 64 KB nursery so a missing root
shows. Programs are portable (`--portable`: no Unicode, Dynamic or operand
side effects, Ints wrapped to 24 bits) and never use an Int value as a
Float without converting it, which works around a bug in the reference's
Eval. The kept cases `exec-<seed>` are hxmc bugs this lane found. CI runs
each lane on the kept cases and 400 random programs.

## hxmc's own tests

| Check | Make target | What |
| --- | --- | --- |
| `Corpus` | `quick`, `check` | the programs of `hxmc/test/cases/` and the frozen fuzzer programs, run with a 64 KB nursery and compared with golden files; `hxmc/test/reject`'s programs the compiler must reject (each `// expect: ` line part of the error) and `hxmc/test/warn`'s it must build with warnings (each `// warns: ` line part of them) |
| `Crosshost` | `crosshost` | the tool as a WebAssembly module writes the same bytes as the native tool, for every target, itself included |
| `HeaderCheck` | `native-check` (`NATIVE=header`) | the C declarations that name their headers (the std's typed bindings, `CBindings*`) against each of the seven targets' headers, compiled by zig as C++ assertions; `hxmc/test/header/BadLayout.hx` must fail ([interop.md](interop.md#checking-declarations-against-the-headers)) |
| `PortableCheck` | `portable-check` | hxmc's spans on other targets ([interop.md](interop.md#spans-on-other-targets)): `SpanInflate` and `SpanPortable`, and hxmc.simd's scalar implementation ([plans/simd.md](plans/simd.md#the-scalar-implementation)): `SimdOps`, `SimdValues` and `SimdExamples`, built by the reference for Eval and JavaScript (node), print the corpus's golden output; `hxmc/test/portable`'s failed checks and compile errors |
| fixpoint | `fixpoint` | the tool rebuilds itself byte-identically, with the module cache cold, warm and off |
| `ModuleCacheCheck` | `test-module-cache` | outputs with the module cache are byte-identical to outputs without it, through edits, define changes, macros that keep state, shadowing, a second output, a module of abstracts with overloaded call operators restored under its typed users, modules macros define built into two programs of one class path one after the other (`--late`), a module defined in its definer's typing that calls back into it, the definer edited and back (`--defined`), a registry a macro class keeps whose readers' fields come from it, two programs of one class path filling it (`--state`), macros that use state no macro keeps (a class's own static initialisation, a std override's statics) restoring the modules they ran in; for hxmc, JS and Eval (`PORT=1` adds the port) |
| `CacheCheck` | `units` | the cache store: trimming, packs, the cap, an unwritable cache |
| `RtSearchCheck` | `units` | the tool, as npm's platform package's `haxe` without the launcher, finds the runtime objects beside itself and in the target's platform package beside it; `HXMC_RT_DIR` adds to the search; a missing one's error lists every directory searched |
| `Units` | `units`, `quick` | `RootFactsCheck` and `MirCompactCheck` (Roots and MIR compaction on hand-made functions), `CacheCheck`, `RtSearchCheck` (not on Windows), and the frontends' seam: a compiler built from hxmc's sources with its own main (`hxmc/test/frontend`) adds a function to the lowered program through `hxmc.Main.beforeCodegen` ([hxmc.md](hxmc.md#frontends)); the program it builds calls it |
| `UpstreamSuites` | `upstream-suites` | upstream's runtime suites built by hxmc and run ([below](#upstreams-runtime-suites)) |
| `DebugCheck` | `check` | gdb or lldb on a `-debug` build: breakpoints, backtraces, the tables |
| `SharedCheck` | `native-check` | shared libraries of the glibc mode loaded by an hxmc program; Android's `.so`, AndroidHello as `libmain.so` (its SONAME, `ANativeActivity_onCreate` exported) |
| `JniCheck` | `native-check` | Java through JNI ([interop.md](interop.md#java-jni)): the corpus's JNI cases in the glibc mode (an embedded JVM), also with `RT_VERIFY=1`; `hxmc/test/jni/JniLib.hx` as a library `java` loads (`JNI_OnLoad`, its Haxe object called from Java's threads); both built for android-arm64 and android-x86_64 (run by helder's emulator jobs); a JDK, else the runs are skipped |
| `MachOCheck` | `native-check` | IosHello as a plain iOS and Mac Catalyst executable and dylib: `LC_BUILD_VERSION`'s platform, minimum and SDK, a device's `LC_ENCRYPTION_INFO_64`, `LC_FUNCTION_STARTS`, `LC_DATA_IN_CODE`, the code signature (linker-signed, or binding `-D hxmc.codesign-*`'s files); UIKit's install name (ObjCUIKit) |
| `UIKitCheck` | `native-check` | UIKitHello, a UIKit app with its own `hxmc_ui_main`, in its bundle: run as a Mac Catalyst agent app and in the iOS simulator's iPhone and iPad (the delegate, the body after launch, the window key and sized); a Mac with Xcode |
| `dev-console.mjs`, `server-verify.mjs` | `dev-check` | `hxmc dev` through edits and a compile error; a compilation server's builds byte-identical to fresh ones (on macOS, an Objective-C program's, run), a class a macro's callback defines and a build macro's persistent state in builds of two signatures (with an initializer or without, and after an error in a macro) among them, in memory, from HXB and connected (`--server-connect`: each answer arriving whole); the modules an edit compiles; two programs in turn under a cap of 1 MB (`hxmc.server-mb`: each build drops the other program's) |
| `MirCheck` | `mir-check` | the Mir lane: the corpus run inside the compiler on the Mir interpreter (`Corpus --mir-run`), the macro cases with Mir macros against the reference (`Conformance --target-only`; Issue11631 uses Eval's `mbedtls`: `MirCheck.KNOWN`), Mir macros' compiled functions kept across builds (`MirCacheCheck`), their statics in the compilation server against the reference (`MirServerCheck`, not on Windows) |
| `NativeCheck` | `native-check` | the native-output checks above as parts (`NATIVE=shared\|jni\|macho\|uikit\|header`; `elf <dir>`: `ElfCheck`, the glibc mode's executables with readelf), each skipping itself where it cannot run |

**The corpus.** Golden files are frozen: a new case gets one with
`--bless` (checked by hand); a changed output is an edit of its golden file
with the reason in the commit. A `// build-seconds: <n>` line bounds a
case's build time. A `// not-live: <function> ...` line names functions
reachability must drop when the case is also built from its source, as
programs are (`HXMC_REACH_WHY`): the archive's build loads only the modules
its program reaches, so what typing loads and DCE keeps shows only there
(`TimerStamp`: `haxe.Timer.stamp()` keeps no event loop; `CompactFree`: a
program without `@:hxmc.compact` classes has none of the collector's code for
compressed references). A
`// span-checks: <Class.function>=<n> ...` line names the span element
checks left in each function's optimized code, which a build with
`HXMC_DUMP` counts (`SpanLoops`: the checks a loop proves are dropped); a
`// range-checks:` line the same of range checks (`sub`, `fill`, `blit`:
`SpanRanges`), a `// bytes-checks:` line of `haxe.io.Bytes`' range tests
(`BytesReadLoops`). Writing a
case's archive must not warn of an unbound type parameter (`hxb-warning`:
an expression of the case or of hxmc's std whose type left its type
parameter's scope, as `Arena.makeArray`'s did when inlined into `slice`).
`Corpus.WASM_EXCLUDED`, `POSIX_ONLY` and `WINDOWS_ONLY` (COM) name the
cases a target cannot run; `WINE_DISPLAY` those wine runs only with a
display and its fonts (`xvfb-run`, fonts-wine: the file dialog, DirectWrite);
`JNI` the cases that embed a JVM (linux-x86_64 in the glibc mode, with a
JDK: javac compiles `<Name>.java` and the glue of the program's manifest,
`JniGlue`; excluded without one, and from staged runs: CI runs them in
`JniCheck`). `RT_VERIFY=1` fills the free nursery with a pattern so
uninitialized allocations and missed roots show at once; `--verify-tags`
builds with `-D hxmc.verify-tags`, which ends a program reading the tagged
word of a type parameter's value as a reference
([hxmc.md](hxmc.md#values-of-type-parameters)). The corpus builds
from HXB archives, without the module cache; CI's npm-pack job builds with
the cache off, so the uncached path stays tested.

**The runtime's symbols** are checked by every build
([hxmc.md](hxmc.md#the-symbols-generated-code-calls)), so every corpus build
checks them.

### Upstream's runtime suites

`node make.mjs upstream-suites` (`hxmc/test/UpstreamSuites.hx`) builds upstream's
`tests/unit`, `tests/sys` and `tests/threads` with hxmc and runs them
natively, and `tests/unit` as a wasm32-wasi module (`SUITES=`,
`SUITES_TARGET=native|wasm32-wasi` narrow it). Each suite is copied to
`bin/test/upstream-suites/` and built from `hxmc/test/upstream/<suite>.hxml`.
In the copy, `<suite>.patch` adds hxmc's branch where a conditional lists
targets, and `skips.txt` leaves out tests, each with a category: `BUG` (to
fix), `TARGET` (a behaviour hxmc chooses) or `EXTERNAL` (a tool the test
needs).

| Suite | Target | Passed | Skipped: BUG | TARGET | EXTERNAL | Failed |
| --- | --- | --- | --- | --- | --- | --- |
| unit | linux-x86_64 | 1586 | 1 | 12 | 0 | 0 |
| sys | linux-x86_64 | 39 | 0 | 0 | 2 | 0 |
| threads | linux-x86_64 | 43 | 0 | 0 | 0 | 0 |
| unit | wasm32-wasi | 1582 | 1 | 16 | 0 | 0 |

`unit` includes `TestCoroutines`. On wasm32-wasi the call-stack and socket
tests are `TARGET` skips.

## CI

`.github/workflows/build.yml` runs as parallel jobs, each waiting only for
what it uses. **Gates** marks the jobs `publish-npm` and `release` wait for:
a release is published only when all of them pass.

| Job | Gates | What |
| --- | --- | --- |
| `changes` | yes | what the run needs (`.github/select.sh`); whether the runtime objects' release exists |
| `rt-build`, `rt` | | the runtime objects, only when their release is missing |
| `build` | yes | the bootstrap from the stage0, the fixpoint, the release binaries and lix for the six targets |
| `checks` | yes | `node make.mjs units`, `node make.mjs test-module-cache PORT=1`, `node make.mjs dev-check`, `node make.mjs native-check` on Linux (`SharedCheck`, `JniCheck` with the image's JDK 21, `MachOCheck`, `HeaderCheck`: [the contract](using.md#native-output-for-a-packager)); apart from `build`, which most jobs wait for |
| `windows` | yes | the tool from source on Windows with node alone: `node make.mjs bootstrap` (the stage-1 compiler from the stage0, the tool, the fixpoint), `NativeCheck macho`, the release binary and its smoke test (`node make.mjs smoke`) |
| `corpus-verify` | yes | the corpus on the runner with `-D hxmc.verify-tags` and `RT_VERIFY=1` (`node make.mjs corpus-verify`: x86-64; wasm32-wasi's `RT_VERIFY=1` run is the `wasm` job's; apart from `corpus`, which the test jobs wait for) |
| `corpus` | yes | the corpus for every target (six jobs: Windows a job per target, Linux a job per architecture), the native compilers with Mir macros, the port as a WebAssembly module, the reference's self-compile |
| `crosshost` | yes | `node make.mjs crosshost` for linux-x86_64, macos-arm64, windows-x86_64 and wasm32-wasi, one target of each format (two jobs, the cases in shards: `--shard i/2`; the module's builds on node workers) |
| `fuzz-exec` | yes | full runs only: the fuzzer's exec lanes; `PortableCheck` |
| `upstream-suites` | yes | upstream's runtime suites, natively and on wasm32-wasi |
| `conformance` | yes | the harnesses above on the release binary's Eval: `hxb macro hxblib haxelib unit`, `display server jsonrpc`, `targets` (with `Targets --strict` on self -> hl, neko: the reference still compiles the port's sources, the outputs identical); full runs only: the Eval debugger and the fuzzer's diff lanes |
| `test` | yes | on each of the six machines: the release binary's smoke test (`hxmc/test/Smoke.hx`: --interp, HXB, JS, a TLS handshake, libuv; on Windows also by backslashed paths), lix, the corpus, the self-compile; then, on Linux x86-64 only, the Mir lane (`MirCheck`, as `node make.mjs mir-check`) |
| `wasm` | yes | the corpus and the self-compile under node and wasmtime, also with legacy exception handling |
| `npm-pack` | yes | the npm packages, built with the module cache off |
| `npm` | yes | the seven packages installed from their tarballs in fresh projects on each machine (linux-x64 alone outside full runs): native at once through the platform package, js, `-lib` from lix, node_modules and haxelib, the platform package's compiler run directly without `HXMC_RT_DIR` (a build and a compilation server), `--ignore-scripts`; on linux-x64 a cross build for windows-x86_64 (first failing with the package to install, then with `@hxmc/win32-x64` installed with `--force`) and Android's message; lix with `dist/` on linux-x64, and on all six on full runs; the UIKit app on the Macs on full runs |
| `site`, `playground` | yes | the website, and `node make.mjs site-check` in Chromium, Firefox and WebKit |
| `llvm` | no | the nightly and dispatches only: the corpus with the LLVM back end (`-D hxmc.llvm`) on linux-x86_64, linux-arm64 and macos-arm64 |
| `upstream-tests` | no | the nightly and dispatches only: upstream's compiler-side suite (RunCi `macro`) and `IpcStress` |
| `publish-npm` | | after every gate: the seven packages at one version (the six platform packages, then `@hxmc/cli`), names, versions and optional dependencies checked, with provenance through npm's trusted publishing; on `v*` tags as `latest`, from main as `<version>-nightly.<date>.<commit>` tagged `next` |
| `release`, `pages` | | the nightly release or a tagged release; the website from main |

**What runs when.** Main, tags, the nightly schedule (02:41 UTC) and
dispatches run everything (full runs). On other branches a push leaves out
the slow lanes (the fuzzers, the debugger, the UIKit app, the npm checks
beyond linux-x64) and runs only what its changes since the last green
commit need: only `*.md`, nothing; `site/`,
`site` and `playground`; anything else, everything. A newer push to a
branch cancels its run; runs on main, `hxmc` and tags always finish.

## Benchmarks

| Make target | What |
| --- | --- |
| `bench` | the [HaxeBenchmarks](https://github.com/HaxeBenchmarks/benchmark-runner) cases built by hxmc (native and wasm) and by the port for C++, JVM, JS, HL/C and HashLink: median wall time of interleaved runs, CPU time, peak RSS, sizes, compile times; each case's output compared across targets (`hxmc/test/Bench.hx`) |
| `bench-compile` | the port built by hxmc (native, wasm under node and wasmtime) against the reference, compiling `hello`, `stdlib` and itself to HXB; every archive compared before its times count (`hxmc/test/CompileBench.hx`) |
| `bench-micro` | `WHICH=arrays`: Array, NativeArray and Vector ([notes](../hxmc/test/bench/README.md)); `WHICH=maps`: ObjectMap and StringMap |
| `bench-simd` | image kernels (an 8x8 IDCT, YCbCr to RGBA, a bilinear resize) as plain Haxe, as span kernels and with `hxmc.simd`, natively and as wasm under node, against the same kernels in C at -O2, -O3 without the vectorizers and -O3; the same checksums everywhere (`hxmc/test/bench/simd`, [plans/simd.md](plans/simd.md#benchmarks)) |
| `measure` | peak RSS, wall and CPU time of the self-compile (ours and the reference's) and of the tool's builds (`haxe/test/Measure.hx`) |

`.github/workflows/bench.yml` runs them nightly on main (skipped when the
commit is measured already), on dispatch, and on pushes to main whose
message says `[bench]` or `[bench-publish]`. Cases are sharded across
runners, every target of a case on one runner. From main the results go to
the `bench-data` branch (`results/`, `compile/`, `targets/`, and the
`history.json` files), which the site's build reads with `BENCH_DATA`. The
reference runs on the same machine in every run, so the site's "vs.
reference" view cancels most differences between CI machines.

The site charts hxmc's history only (from 10 runs on,
`HistoryChart.MIN_POINTS`); other targets appear as tables of the latest
run. Program time is the whole process's wall time; size is the artifact
gzipped; compile time is a cold build. The target generators' table
(`Targets`, `targets.json`) compares the port with the reference on
haxe-formatter and the port itself, sequential and parallel, every
sequential output identical. Its gate (`--strict`, or `--check` on result
files; the nightly's `results` job, after publishing) fails on a reference
failure outside `EXPECTED` in `Targets.hx` (self -> js, lua, php, swf and
formatter -> swf: those targets cannot host the project), a port failure
where the reference compiles, different sequential outputs, or a different
parallel output that is not `varies` (the reference's own parallel output
differs from its sequential one: hxb, jvm).

`hxmc/test/micro` holds benchmarks run by hand, such as `VectorBlitBench`
(`Vector.blit` against a plain loop).
