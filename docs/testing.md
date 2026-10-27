# Testing and CI

For contributors: which tests to run for a change, what each harness
checks, which CI jobs gate a release, and how benchmarks are measured.
Building is in [development.md](development.md).

## Which tests to run

| Change | Run |
| --- | --- |
| hxmc (`hxmc/src`, `hxmc/std`) | `make quick` after every edit, `make check` before a commit, `make full` before a push |
| typing or filters in the port | `make test LANES="hxb macro"` |
| a generator in the port | `make test-fuzz LANE=diff:<target>`, `make test LANES=targets` |
| display or the server | `make test LANES="display server jsonrpc"` |
| anything broad | all of the above, `make fixpoint`, `make crosshost` |

The fixpoint and crosshost must stay byte-identical.

| Tier | What it runs |
| --- | --- |
| `make quick` | the tool, the x64 corpus, again with `RT_VERIFY=1`, the wasm corpus under node, the module cache's store, the lowering's queries (`CASES=` restricts the corpus) |
| `make check` | quick, plus arm64 (qemu), x64 Windows (wine), a 16 KB nursery, legacy exception handling, the glibc mode, ThreadNatives x30, crosshost on three cases, debug info, Android's APKs, iOS's apps, shared libraries (`PORT=1`: the port's self-compile) |
| `make full` | every nursery size and `RT_VERIFY`, wasmtime, ThreadNatives x300, the port's self-compile natively and as a module, crosshost on everything, the fixpoint (`hxmc/test/Tiers.hx`) |

## The port against the reference

Every harness compares the port (`PORT_BIN`, default `bin/port/haxe`)
with the reference compiler (`bin/reference/haxe`, `make reference`).
Outputs go to `bin/test/`. Run them with `make test LANES="<lane> ..."`
(default `hxb`; every lane runs and the failed ones are named at the end;
`EVAL` picks the compiler whose Eval runs them, `SUMMARY` writes Markdown),
or `bin/hxmc/hxmc -cp haxe/test --run <Name>` with the options at the top
of each file.

| Script | Lane | Compares | Result |
| --- | --- | --- | --- |
| `Conformance` | `hxb`, `macro`, `hxblib` | HXB archives of `conformance-cases.txt` (upstream's suites and the port's own cases), `conformance-macro-cases.txt`, `conformance-hxblib-cases.txt`; `--hxb-lib`, `--eval`, `--parallel N` modes | 293 + 12 expected failures, 67/67, 7/7 |
| `Display` | `display` | `--display` JSON-RPC requests from upstream's removed display suite | 679/679 |
| `Server` | `server` | the compilation server: cases twice, edits and invalidation, stdin, `--cmd`, errors, an empty connection ([a divergence](porting.md#divergences-from-the-reference)), `--server-connect` | 634/634 |
| `ServerJsonRpc` | `jsonrpc` | the `server/*` methods, both cache modes | 107/107 |
| `UpstreamTargets` | `targets` | upstream's unit suite compiled for js, lua, python, php, neko, hl, hl/c, cpp, cppia, jvm and flash by both, every output file | 12/12 identical |
| `Interp` | `interp` | `--interp` runs of the case lists (not in CI) | 294/295 (`eval-eventLoop-compile` depends on thread timing) |
| `Haxelib` | `haxelib` | `-L` through lix's haxelib shim, batch and `--server` | 14/14 |
| `LibResolution` | `libs` | hxmc's own `-lib` resolution against haxelib and lix's shims: repositories, versions, dependencies, every `resolveLibs` mode, errors | 130/130 |
| `EvalDebugger` | `debugger` | scripted Eval debugger sessions (`SHARD=i/n`) | 6/6 |
| `unit.hxml` | `unit` | unit tests of port modules, in-process | pass |
| `fuzz/` | `make test-fuzz LANE=...` | random programs per target (`diff:<target>`) or by output (`exec:<a>,<b>`), reduced on failure; `--cases haxe/test/fuzz/cases` reruns the kept ones | CI: diff lanes of ten targets, two exec lanes |
| `IpcStress` | (upstream-tests.yml) | multi-byte strings through Eval's `sys.io.Process`, with concurrent file reads | 86 checks per round |
| `EncCheck` | | the x86-64 and AArch64 encoders against `llvm-mc` (not in CI) | |

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
| `Corpus` | `quick`, `check`, `full` | the programs of `hxmc/test/cases/` and the frozen fuzzer programs, run with a 64 KB nursery and compared with golden files |
| `Crosshost` | `crosshost` | the tool as a WebAssembly module writes the same bytes as the native tool, for every target, itself included |
| fixpoint | `fixpoint` | the tool rebuilds itself byte-identically, with the module cache cold, warm and off |
| `ModuleCacheCheck` | `test-module-cache` | outputs with the module cache are byte-identical to outputs without it, through edits, define changes, macros that keep state, shadowing, a second output; for hxmc, JS and Eval (`PORT=1` adds the port) |
| `CacheCheck` | `quick` | the cache store: trimming, packs, the cap, an unwritable cache |
| `LowerQueriesCheck` | `quick` | each lowering query is covered by the server's reuse of bodies |
| `UpstreamSuites` | `upstream-suites` | upstream's runtime suites built by hxmc and run ([below](#upstreams-runtime-suites)) |
| `DebugCheck` | `check` | gdb or lldb on a `-debug` build: breakpoints, backtraces, the tables |
| `ApkCheck` | `android-check` | APKs: the zip and alignment, the manifest, `classes.dex`, the ELF, the v2 signature verified by openssl; `zipalign`, `aapt`, `apksigner`, `dexdump` where installed |
| `android.sh` | `android-device-check` | AndroidHello on a device or emulator: its line in logcat |
| `SharedCheck` | `shared-check` | shared libraries of the glibc mode loaded by an hxmc program |
| `IosCheck` | `ios-check` | the app bundle and `.ipa`: `Info.plist`, the Mach-O, the code signature's hashes recomputed |
| `ios.sh` | `ios-sim-check` | on a Mac with Xcode: IosHello on a new simulator |
| `dev-console.mjs`, `server-verify.mjs` | `dev-check` | `hxmc dev` through edits and a compile error; a compilation server's builds byte-identical to fresh ones |
| `Corpus --mir-run` | `mir-run-check` | the corpus run inside the compiler on the Mir interpreter |
| `Conformance --target-only` | `mir-macros-check` | the macro cases with Mir macros against the reference (66 of 67: Issue11631 uses Eval's `mbedtls`) |
| `MirCacheCheck` | `mir-cache-check` | Mir macros' compiled functions kept across builds |
| `MirServerCheck` | `mir-server-check` | Mir macros' statics in the compilation server, against the reference |

**The corpus.** Golden files are frozen: a new case gets one with
`--bless` (checked by hand); a changed output is an edit of its golden file
with the reason in the commit. A `// build-seconds: <n>` line bounds a
case's build time. `Corpus.WASM_EXCLUDED` and `POSIX_ONLY` name the cases a
target cannot run. `RT_VERIFY=1` fills the free nursery with a pattern so
uninitialized allocations and missed roots show at once. The corpus builds
from HXB archives, without the module cache; CI's npm-pack job builds with
the cache off, so the uncached path stays tested.

**The runtime's symbols** are checked by every build
([hxmc.md](hxmc.md#the-symbols-generated-code-calls)), so every corpus build
checks them.

### Upstream's runtime suites

`make upstream-suites` (`hxmc/test/UpstreamSuites.hx`) builds upstream's
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
| unit | linux-x86_64 | 1519 | 0 | 12 | 0 | 0 |
| sys | linux-x86_64 | 37 | 0 | 0 | 2 | 0 |
| threads | linux-x86_64 | 38 | 0 | 0 | 0 | 0 |
| unit | wasm32-wasi | 1516 | 0 | 15 | 0 | 0 |

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
| `build` | yes | the bootstrap from the stage0, the fixpoint, the module cache checks, `make dev-check`, the release binaries and lix for the six targets |
| `corpus` | yes | the corpus for every target (three jobs), the native compilers with Mir macros, the port as a WebAssembly module, the reference's self-compile |
| `crosshost` | yes | `make crosshost` (two jobs) |
| `fuzz-exec` | yes | the fuzzer's exec lanes |
| `upstream-suites` | yes | upstream's runtime suites, natively and on wasm32-wasi |
| `conformance` | yes | the harnesses above on the release binary's Eval: `hxb macro hxblib haxelib unit`, `display server jsonrpc`, `targets` (with `Targets --strict` on self -> hl, neko: the reference still compiles the port's sources, the outputs identical), the Eval debugger in three shards, the fuzzer's diff lanes in three jobs |
| `test` | yes | on each of the six machines: the release binary's smoke test (TLS handshake, libuv), lix, the corpus, the self-compile; then the Mir lane (`Corpus --mir-run`, the macro cases with Mir macros, `MirCacheCheck`, `MirServerCheck` except on Windows, `MirBench`) |
| `wasm` | yes | the corpus and the self-compile under node and wasmtime, also with legacy exception handling |
| `npm-pack` | yes | the npm packages, built with the module cache off |
| `npm` | yes | the seven packages installed from their tarballs in fresh projects on each machine: native at once through the platform package, js, `-lib` from lix, node_modules and haxelib, `--ignore-scripts`; on linux-x64 a cross build for windows-x86_64 (first failing with the package to install, then with `@hxmc/win32-x64` installed with `--force`) and Android's message; lix with `dist/` on linux-x64, and on all six on main, tags and nightly |
| `site`, `playground` | yes | the website, and `make site-check` in Chromium, Firefox and WebKit |
| `android` | no (experimental) | `make android-check`, `make shared-check`, AndroidHello on an x86-64 emulator |
| `ios`, `ios-simulator` | no (experimental) | `make ios-check` on Linux; IosHello on an iPhone simulator on macOS |
| `upstream-tests` | no | upstream's compiler-side suite (RunCi `macro`) and `IpcStress` |
| `publish-npm` | | after every gate: the seven packages at one version (the six platform packages, then `@hxmc/cli`), names, versions and optional dependencies checked, with provenance through npm's trusted publishing; on `v*` tags as `latest`, from main as `<version>-nightly.<date>.<commit>` tagged `next` |
| `release`, `pages` | | the nightly release or a tagged release; the website from main |

**What runs when.** Main, tags, the nightly schedule (02:41 UTC) and
dispatches run everything. On other branches a push runs only what its
changes since the last green commit need: only `*.md`, nothing; `site/`,
`site` and `playground`; anything else, everything. A newer push to a
branch cancels its run; runs on main, `hxmc` and tags always finish.

## Benchmarks

| Make target | What |
| --- | --- |
| `bench` | the [HaxeBenchmarks](https://github.com/HaxeBenchmarks/benchmark-runner) cases built by hxmc (native and wasm) and by the port for C++, JVM, JS, HL/C and HashLink: median wall time of interleaved runs, CPU time, peak RSS, sizes, compile times; each case's output compared across targets (`hxmc/test/Bench.hx`) |
| `bench-compile` | the port built by hxmc (native, wasm under node and wasmtime) against the reference, compiling `hello`, `stdlib` and itself to HXB; every archive compared before its times count (`hxmc/test/CompileBench.hx`) |
| `bench-micro` | `WHICH=arrays`: Array, NativeArray and Vector ([notes](../hxmc/test/bench/README.md)); `WHICH=maps`: ObjectMap and StringMap |
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
