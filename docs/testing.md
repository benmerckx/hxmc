# Testing and CI

## Harnesses

Every harness compares the port (`PORT_BIN`, default `bin/port/haxe`) with the
reference (`bin/reference/haxe`); outputs go to `bin/test/`. They are Haxe
scripts on the tool's Eval (`make test-<name>`, or `bin/hxmc/hxmc -cp
haxe/test --run <Name> --help`-style options at the top of each file):

| Script | Compares | Result |
| --- | --- | --- |
| `Conformance` | HXB archives (member names, uncompressed payloads) of `conformance-cases.txt` (305: configurations of the upstream suites, and the port's own cases of `haxe/test/conformance`: OCaml's string order, Eval's string offsets and bounds, bytes that are not UTF-8), `conformance-macro-cases.txt` (66, run macros), `conformance-hxblib-cases.txt` (`--hxb-lib`); `--hxb-lib`, `--eval` (`noeval`: a case Eval as the host cannot run), `--parallel N` modes | 293 + 12 expected failures, 66/66, 7/7 |
| `Display` | `--display` JSON-RPC requests from upstream's removed display suite | 679/679 |
| `Server` | the compilation server: cases twice, edits and invalidation (with the verbose logs), stdin, `--cmd`, errors, `--server-connect` | 633/633 |
| `ServerJsonRpc` | the `server/*` methods, both cache modes | 107/107 |
| `UpstreamTargets` | upstream's unit suite compiled for js, lua, python, php, neko, hl, hl/c, cpp, cppia, cppia host, jvm, flash by both, every output file (jars by member, hl/c after `HlcNames`) | 12/12 identical |
| `Interp` | `--interp` runs of the case lists | 294/295 (`eval-eventLoop-compile` depends on thread timing) |
| `Haxelib` | `-L` through lix's haxelib shim, batch and server | 14/14 |
| `EvalDebugger` | scripted Eval debugger sessions (`-D eval-debugger`): breakpoints, stepping, scopes, evaluation, assignment, exception and function breakpoints, a macro | 6/6 |
| `fuzz/` | random programs per target (`diff:<target>`) or by program output (`exec:<a>,<b>`), with reduction (`make test-fuzz LANE=diff:js`); `--cases haxe/test/fuzz/cases` checks the kept programs (failures fixed since, reduced, one directory each) on the lanes | CI: the diff lanes of ten targets, `exec:interp,hxmc` and `exec:interp,hxmc-wasm` (below) |
| `Targets` | the website's target table (`bench.yml`'s `targets` jobs, published to `bench-data` as `targets.json`; `site/data/targets.json` the fallback): haxe-formatter and the port itself compiled for every target by both, sequential (`-D disable-parallelism`: CPU) and with default parallelism (wall), peak RSS, outputs compared (hl/c after `HlcNames`; a parallel output where the reference's own parallel output varies is marked `varies`); `-p self -t hlc --merge --json site/data/targets.json` replaces those rows only | 18/18 identical (the rows the reference compiles) |
| `Measure` | peak RSS, wall and CPU time: the self-compile (ours and the reference), the native build, the WebAssembly builds | self-compile 879 MB vs the reference's 1414 MB |
| `unit.hxml` | unit tests of port modules, in-process | pass |
| `IpcStress` | round trips of multi-byte strings through Eval's `sys.io.Process` (echo through stdin, a grandchild's environment variable as in upstream's `TestUnicode.testIPC`, short reads while the child writes; once per round a process closed after its stdin while another thread reads files reusing that number: the double close the runtime no longer does), `haxe -cp haxe/test --run IpcStress <haxe> [rounds]`; CI: four at once on both `linux-test` machines (upstream-tests.yml) | 52 checks per round, no failures |

Sequential runs pass `-D disable-parallelism`: the reference itself is not
deterministic in parallel mode. Upstream's compiler-side suite (RunCi `macro`:
the unit tests in the macro context with their HXB round trip, null safety,
misc, sys on Eval, threads, third-party projects) runs with the release
binaries as `haxe` (`.github/workflows/upstream-tests.yml`); no target runtime
is installed anywhere: target suites are compared, not run.

## The port as a WasmGC module

`make test-wasmgc-port` runs the lanes with the port built as a WasmGC
module (`make wasmgc-port`: `bin/wasmgc-port/haxe.wasm`, `-D hxmc.wasm-gc`,
and `bin/wasmgc-port/haxe`, a script running it under node with
`hxmc/bootstrap/wasmgc.mjs`; docs/hxmc.md, "WasmGC") as the port:
`Conformance` on the three lists (293 + 12 expected failures, 66/66, 7/7),
`Interp` (294/294: `eval-eventLoop-compile` is skipped, `--skip`: its Eval
threads interleave, and the module's threads only run when another waits
for them), `Display` (679/679), `Haxelib` without `--server` (7/7) and
`UpstreamTargets` (every target's files identical; jvm needs a JDK), the
same results as natively. The server lanes (`Server`, `ServerJsonRpc`,
`Haxelib --server`, `EvalDebugger`) need sockets, which its runtime does not
have. The lanes take several times as long as with the native
port (a run starts in about 0.4 s; the self-compile to HXB takes 9 s
against 3.7 s: docs/plans/targets.md, "WasmGC").

## hl/c digest names

hl/c's digest names (`HlcNames.hx`): hl2c names function, virtual and context
types `t$fun_`/`t$vrt_`/`t$ctx_` after the MD5 of the type's description
marshalled with closures. When the description reaches an object or virtual
prototype, it holds a PMap's comparison closure, which the reference writes
as a code pointer into its own machine code (an offset and the MD5 of its
code area); the port writes a fixed placeholder there
(`haxe/src/generators/Hl2c.hx`, `OcamlExtern`), so those names differ by
design (two in the port's self-compile, none in upstream's unit suite).
Wherever hl/c output is compared (`UpstreamTargets`, the fuzzer's
`diff:hlc`, `Targets`), the digest names found on one side only are renamed
on both sides in order of first appearance, with the context headers named
after them; every other byte must match, so the outputs still have to use
their names in the same places.

## Printed floats

The port's Math is hxmc's port of musl's libm (`hxmc/std/hxmc/rt/LibM.hx`,
bit-identical to musl) wherever it runs, Eval included; the reference's is
glibc's. The two round some results an ulp apart (`Math.sin(-2.5)`), and the
arithmetic after them can widen that (`100 * Math.sin(-2.5)`: 2 ulps), so the
fuzzer's output comparison (`Runner.sameOutput`) accepts two printed floats at
the same place of a line when they are at most `Runner.MAX_ULPS` (4) apart,
both finite and of the same sign; every other character must match. The kept
case `interp-108625377` is that example.

## The fuzzer's exec lanes

`exec:interp,hxmc` runs each program on the reference's Eval (`--interp`)
and as a native executable built by hxmc (`bin/hxmc/hxmc`, `bin/hxmc/std`),
`exec:interp,hxmc-wasm` as a wasm32-wasi module (`-D
hxmc.target=wasm32-wasi`, under node with `hxmc/bootstrap/wasi.mjs`); both
hxmc sides run with a 64 KB nursery (`RT_MINOR_KB=64`, as the corpus: a
missing root shows), and what the two print must match (with the float
tolerance above). Exec lanes generate portable programs (`--portable`:
only constructs every target runs alike: no Unicode, Dynamic or operand
side effects, numbers printed through `H.fmt`, Int arithmetic wrapped to 24
bits); one more restriction there works around a bug of the reference: Eval
keeps an Int where a Float is stored and multiplies two such Floats as Ints,
overflowing, so portable programs never use an Int value as a Float without
converting it (`x + 0.0`; `Types.intAsFloat`). The kept cases `exec-<seed>`
are hxmc bugs this lane found: wrong code (a static variable read after a
later operand's call assigned it; an override's default argument values; a
method overridden only by a subclass of a subclass, called statically),
and methods that failed to compile (an abstract method no class
implements). CI's `fuzz-exec` job runs each lane on the kept cases and 400
random programs (about a minute and a half each, beside the corpus jobs).

## hxmc's corpus

hxmc's corpus (`hxmc/test`, `Corpus`): the programs of `cases/` and the frozen
fuzzer programs, compiled by the tool, run with a 64 KB nursery (a missing
root shows) and compared with their golden files, which are frozen (the
outputs of hxc, the C target hxmc came from): a new case gets one with
`--bless` (checked by hand), a changed output is an edit of its golden file
with the reason in the commit. A `// build-seconds: <n>` line of a case bounds
the tool's time to build it (`BigInit`: a function of a thousand nested
constructor calls, the shape of ml2hx's generated tables, once a minute of
register allocation). `Corpus.WASM_EXCLUDED` and `POSIX_ONLY` name the cases
a target cannot run (threads and sockets on wasm32-wasi; `NullAccessCrash`, a
fault that is not a null access, dies of SIGSEGV on Linux and macOS only:
docs/hxmc.md, "Null access"). `Crosshost`: the tool as a WebAssembly module
writes the same bytes as the native tool, for every target, itself included.
`RT_VERIFY=1` fills the free nursery with a pattern, so uninitialized
allocations and missed roots show at once. `ModuleCacheCheck` (`make
test-module-cache`; `PORT=1` adds the port): the persistent module cache
gives the same outputs, byte for byte, as a build without it, cold, warm,
after a new date, after an edit of a module and of a std override, after a
new file shadows a module, after a define no module reads (nothing typed
again) and one a single module reads (that module only), a body edited in
a dependency (only it typed again), an inline function edited (its
dependents typed again), a body edited in a cycle, an edit undone (the
earlier variant restored), a build macro keeping no state (its module
restored), one keeping what an expression macro reads (an `@:autoBuild`
registry: restored while nothing reads it; a define typing the reader
again runs the build again with the registering module typed), a class used through a structure under `-dce full` and then no
longer (its field dropped as without the cache), and a second output
sharing every object, for
hxmc (the tool and `haxe`), JS and Eval. `CacheCheck` (`make quick`): its
store (tool directories, the trim of indexes, packs of blobs, objects and
tool directories, a tiny cap held as builds write past it, a cache that
cannot be written). The cache is on by default, so builds from
source use it (the corpus builds from HXB archives and does not); CI's
npm-pack job builds with it off (`HXMC_MODULE_CACHE=0`), the fixpoint
builds the tool with it cold, warm and off, and `Crosshost` compares the
native tool (cached) with the WebAssembly one (never cached).

## The runtime's symbols

Every build checks that the runtime defines each symbol generated code may
call by name, whatever the program calls (docs/hxmc.md, "The symbols
generated code calls"), so the corpus' builds on every target check it, and
a missing module fails all of them alike instead of only the programs that
happen to call it; it has no lane of its own. A runtime symbol that
generated code calls and that `RuntimeSymbols` does not list fails the
build that calls it.

## The targets' apps

The targets whose output is an app, a library or a module that something
else loads are checked with the smallest programs that need nothing but
hxmc (`hxmc/test/android`, `hxmc/test/ios`, `hxmc/test/shared`):
`make android-check ANDROID_TARGET=android-arm64|android-x86_64`: the APKs
of `AndroidHello` (the NativeActivity entry in no-GC Haxe, the program on a
thread of its own, a line to logcat) and `AndroidViews` (the same with the
functions that make the APK carry `classes.dex` and `org.hxmc.Activity`)
(`hxmc/test/ApkCheck.hx`: the zip and its alignment, the manifest read
back, `classes.dex`'s structure, the library's ELF: a shared object, 16 KB
segments, Bionic's imports and versions, the TLS models; the v2 signature's
digest recomputed and its signature verified by openssl; `zipalign`,
`aapt`, `apksigner` and `dexdump` where installed), and RFC 6979's vector
for the P-256 code; `make shared-check`: shared libraries of the glibc mode
loaded by an hxmc program (`hxmc/test/SharedCheck.hx`; arm64 under qemu);
`make android-device-check`: AndroidHello on the device or emulator adb
reaches (`hxmc/test/android/android.sh`: installed, launched, its line in
logcat). CI's `android` job runs them, the last on an x86-64 emulator with
KVM (not a required check yet).
`make ios-check IOS_TARGET=ios-arm64|ios-sim-arm64`: the app bundle of
`IosHello` and its `.ipa` (`hxmc/test/IosCheck.hx`: the bundle's files,
`Info.plist` read back, the Mach-O's header, build version, dylibs and
signature's place, the code signature's CodeDirectory: its identifier, page
hashes and special slots recomputed against the `Info.plist`, requirements
and `CodeResources`; `llvm-objdump` where installed); `make ios-sim-check`
on a Mac with Xcode: IosHello on a new iPhone simulator
(`hxmc/test/ios/ios.sh`: `codesign --verify` and `plutil -lint` first, then
its line on stdout). CI's `ios` job runs the first on Linux, `ios-simulator`
the second on a macOS runner (not required checks yet).
WebAssembly modules run under node and wasmtime (the corpus, the port's
self-compile: `wasm` below). Programs with windows, GPUs, audio or a UI,
and their tests on devices, browsers and simulators, are universe's
(<https://github.com/benmerckx/universe>).

## The dev loop

`make dev-check` ([dev.md](dev.md); CI: the `build` job):
`hxmc/test/dev/dev-console.mjs` runs `hxmc dev` on a console program that
prints a line and keeps running: the first build runs (with `HXMC_DEV` set),
an edit starts the new build in place of the old one, a compile error shows
while the old build keeps running, the fix runs; `server-verify.mjs`: a
compilation server's builds of small programs through edits are the bytes a
one-shot build of the same sources makes (typed modules kept in memory, then
read back from HXB).

## CI

CI (`.github/workflows/build.yml`) runs as parallel jobs, each waiting only
for what it uses: `changes` (what the run needs, `.github/select.sh`, and
whether the runtime objects' release exists), `rt-build` and `rt` (only when
it is missing: one job per target, `make rt-target`, then `make rt-layouts`
and the release), `build` (the bootstrap from the stage0, the fixpoint, the types and module
cache checks, the dev loop, the
release binaries and lix for the six targets) and next to it, each with a tool
of its own from the stage0: `corpus` (`make corpus-stage`: the corpus for
every target in three jobs, the port as a WebAssembly module, the reference's
self-compile), `fuzz-exec` (the fuzzer's exec lanes, a job each),
`crosshost` (`make crosshost`, the targets in two jobs),
`memory and time` (`make measure`), `npm-pack` (the npm packages), `site`,
`android` and `ios` (the targets' apps above). Then
`conformance` (the harnesses above; the Eval debugger in three shards,
`EvalDebugger --shard i/n`, and the fuzzer's diff lanes in three jobs), `test`
(on each of the six machines: the release binary's smoke test with a TLS
handshake and libuv, lix, the corpus, the self-compile), `wasm` (the corpus
and the self-compile under node and wasmtime, both also with legacy exception
handling under node), `playground` (the website in three browser engines,
`make site-check`: a link check; every page at a desktop's and a phone's
width, no errors and no horizontal scrolling; the benchmark tables; the
playground's compiler with both modules, its fallback to the legacy one in a
Chromium without exnref, and its worker running a request again after a
fault of the engine, faked (the WebKit of Safari 26.0 at times faults in
correct code: `site/client/Worker.hx`)), `npm` (the nine packages in fresh projects on each of the six
machines: native at once through the platform package, `-lib` from
node_modules (`hxmc/test/NodeLibs.hx`), `--ignore-scripts`; and on linux-x64,
or on all six on main, tags and the nightly run, lix with `dist/`, the
WebAssembly fallback, downloaded (from the local tarball: `HXMC_WASM_TARBALL`,
a path or URL in place of the registry's) and installed (with `-lib` by the
WebAssembly compiler), and `hxmc-rebuild` with `--reset`), `upstream-tests`,
and `publish-npm` (after every check; all nine at one version, skipping those
published already: the six platform packages, `@hxmc/wasm`, `@hxmc/source`,
then `@hxmc/cli`, with provenance: on `v*` tags as `latest`, from main as a
nightly prerelease `<version>-nightly.<date>.<commit>` tagged `next`; never
from other branches), the nightly release and the website.

Main, tags, the nightly schedule (02:41 UTC) and dispatches run everything. On
other branches a push runs only what its changes need, since the last commit
whose run succeeded (else since the merge base with main): only `*.md`,
nothing; `site/` (and Markdown), `site` and `playground`; anything else
(`haxe/`, `hxmc/src`, `hxmc/std`, `hxmc/deps`, `hxmc/test`, `packages/`, the
workflows, the Makefile), everything. A newer push to a branch cancels its
run; runs on main, hxmc and tags always finish.

## Benchmarks

Array, NativeArray and Vector microbenchmark: `make bench-arrays`, with
nine element types and read, read4, write, update and allocation workloads. The
[benchmark notes](../hxmc/test/bench/README.md) describe the arguments,
measurement method and native Vector backing.

Benchmarks (`make bench`, `hxmc/test/Bench.hx`): the
[HaxeBenchmarks](https://github.com/HaxeBenchmarks/benchmark-runner) cases
built by hxmc (x86-64, and wasm under node) and by the port for C++ (hxcpp),
the JVM, JS on node, HL/C and the HashLink JIT (HashLink, hxcpp, hxnodejs and
hxjava pinned in the script; the runner, libraries and HashLink go to
`bin/bench`): the median wall time of N interleaved runs, CPU time, peak RSS,
sizes and compile times (`haxe_s`: the Haxe compiler, hxmc's whole build for
its targets; `cc_s`: the C++ or C compiler for C++ and HL/C; `build_s`: their
sum), with each case's check program compared across the
targets. `.github/workflows/bench.yml` runs it nightly on main (skipped when
the commit is measured already) and on demand, apart from `build.yml`,
sharded by case (groups of cases on runners of their own, every target of a
case on the same one; `Bench --merge` joins the shards' results, recording
each case's machine under `machines`); from
main it appends `results/<date>-<commit>.json` to the `bench-data` branch and
regenerates `history.json` (per run, case and target: median, min, max,
peak RSS and the compile times) and `latest.json` there (`Bench --history`),
which the website build copies (`make site BENCH_DATA=<checkout>`) for its
table and charts. The same workflow runs `Targets` in groups of targets
(`targets` jobs, both compilers of a row on one runner; `Targets --join`
joins them) and appends `targets/<date>-<commit>.json`, regenerating
`targets.json` and `targets-history.json` (`Targets --history`), which
replace the committed `site/data/targets.json` in the site's build. The first points on `bench-data` are earlier measurements
imported from this repository's history (`"source": "imported"`: a
development VM, best of the runs).

Micro-benchmarks (`hxmc/test/micro`, built and run by hand, not a lane):
`VectorBlitBench`, `haxe.ds.Vector.blit` against the plain loop for Float
and String vectors and overlapping moves, times per operation, and one row
at a time for instruction counts under callgrind (the numbers before and
after hxmc's `Vector.hx` in its header).
