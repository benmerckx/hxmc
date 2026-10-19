# Testing and CI

## Harnesses

Every harness compares the port (`PORT_BIN`, default `bin/port/haxe`) with the
reference (`bin/reference/haxe`); outputs go to `bin/test/`. They are Haxe
scripts on the tool's Eval (`make test-<name>`, or `bin/hxmc/hxmc -cp
haxe/test --run <Name> --help`-style options at the top of each file):

| Script | Compares | Result |
| --- | --- | --- |
| `Conformance` | HXB archives (member names, uncompressed payloads) of `conformance-cases.txt` (286 configurations of the upstream suites), `conformance-macro-cases.txt` (66, run macros), `conformance-hxblib-cases.txt` (`--hxb-lib`); `--hxb-lib`, `--eval`, `--parallel N` modes | 279 + 7 expected failures, 66/66, 7/7 |
| `Display` | `--display` JSON-RPC requests from upstream's removed display suite | 679/679 |
| `Server` | the compilation server: cases twice, edits and invalidation (with the verbose logs), stdin, `--cmd`, errors, `--server-connect` | 595/595 |
| `ServerJsonRpc` | the `server/*` methods, both cache modes | 107/107 |
| `UpstreamTargets` | upstream's unit suite compiled for js, lua, python, php, neko, hl, hl/c, cpp, cppia, cppia host, jvm, flash by both, every output file (jars by member, hl/c after `HlcNames`) | 12/12 identical |
| `Interp` | `--interp` runs of the case lists | 275/276 (`eval-eventLoop-compile` depends on thread timing) |
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
`Conformance` on the three lists (279 + 7 expected failures, 66/66, 7/7),
`Interp` (275/275: `eval-eventLoop-compile` is skipped, `--skip`: its Eval
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
with the reason in the commit. `Crosshost`: the tool as a WebAssembly module
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

## Graphics

`make gfx-check`: the examples of `packages/gfx`, the triangle, the cube
(textured, lit, depth-tested, with a uniform block, over a blended backdrop
shaded by the fragment position and a soft shadow, turned by a fixed
angle), the instances, the render targets (a scene with its depth texture
rendered into a texture shown on the cube), the mip maps (a trilinear
floor through generated levels, levels written one by one read at given
levels) and the texture formats (each written and rendered into, depth
textures sampled), rendered headless and in a window, compared with
`packages/gfx/test/<scene>.png` (a pixel matches when no
channel differs by more than 2, and at most 0.5% may differ by more), and
in the window the input sent to it (a key's character, the wheel) checked
as events: on Linux by Mesa's llvmpipe (an EGL pbuffer, an X11 window under
Xvfb), on macOS by Metal (an offscreen texture, a Cocoa window; skipped
without a Metal device or outside a GUI session), on Windows by D3D11's
WARP (an offscreen texture, a Win32 window); `GFX_TARGET=windows-x86_64`
runs the Windows build under Wine (wined3d over llvmpipe, under Xvfb) (CI:
the `gfx` and `gfx-arm64` jobs on Linux, `gfx-windows` on Windows x86-64
and arm64, `gfx-macos` from the npm packages).
`make gfx-web-check`: the same on WebGPU and on WebGL2 (forced), built for
wasm32-wasi, headless and in a canvas, in headless Chromium (SwiftShader;
`packages/gfx/test/web.mjs`; CI's `gfx` job); CI checks the site's triangle and
cube the same way (`make site-check`, `site/tools/browser-test.mjs`, the
`playground` job: WebGPU and WebGL2 in Chromium, WebGL2 in Firefox, under
Xvfb, and in WebKit), and in Chromium on an emulated phone (touch, a 390x844 viewport, Chromium's
own touch input through DevTools): a horizontal touch drag turns the still
cube (its frame read back differs), a vertical swipe starting on the canvas
scrolls the page (`touchAction: 'pan-y'`); and the spinning cube held: while
a finger, or the mouse, holds it after a drag (the mouse's leaving the
canvas), its frames do not change, and once let go it spins again.
`make gfx-cache-check` (CI's `gfx` job): the module cache across builds with
other defines on one store, WebTest with `-D hxmc.wasm-gc`, GfxTest
natively, then each again: each restored whole, the same bytes, linked and
run (`web.mjs`'s triangle, GfxTest's headless triangle).
`make gfx-shader-check`: the shader macro on Eval (shaders run on the CPU, the
emitted sources, the programs it rejects: `packages/gfx/test/ShaderTest.hx`),
and the tests' PNG files (`Png.hx`: written as `--bless` writes them, in
stored blocks of 65535 bytes, and read back).
`make android-check ANDROID_TARGET=android-arm64|android-x86_64`: the APKs
of `AndroidTest` and the cube (`hxmc/test/ApkCheck.hx`: the zip and its
alignment, the manifest read back, the library's ELF: a shared object, 16 KB
segments, Bionic's imports and versions, the TLS models; the v2 signature's
digest recomputed and its signature verified by openssl; `zipalign`, `aapt`
and `apksigner` where installed), and RFC 6979's vector for the P-256 code;
`make shared-check`: shared libraries of the glibc mode loaded by an hxmc
program (`hxmc/test/SharedCheck.hx`; arm64 under qemu); `make
android-device-check`: AndroidTest on the device or emulator adb reaches
(`packages/gfx/test/android.sh`: the cube headless on the device's GPU
against `cube.png` by the rule above, frames in the activity's window, a tap
and a key as events, Home and back as Suspend and Resume, Back; a screenshot
and the log). CI's `android` job runs them, the last on an x86-64 emulator
with KVM (not a required check yet).
`make ios-check IOS_TARGET=ios-arm64|ios-sim-arm64`: the app bundles of
`IosTest` and the cube, and the cube's `.ipa` (`hxmc/test/IosCheck.hx`: the
bundle's files, `Info.plist` read back, the Mach-O's header, build version,
dylibs and signature's place, the code signature's CodeDirectory: its
identifier, page hashes and special slots recomputed against the
`Info.plist`, requirements and `CodeResources`; `llvm-objdump` where
installed); `make ios-sim-check` on a Mac with Xcode: IosTest on a new
iPhone simulator (`packages/gfx/test/ios.sh`: `codesign --verify` and
`plutil -lint` first, the cube headless on the simulator's Metal against
`cube.png`, frames in the window, its pixels lit, a tap on the Simulator's
window (`SimTap.hx`) as MouseDown and MouseUp, Settings and back as Suspend
and Resume; the screenshot, stdout and the system log). CI's `ios` job runs
the first on Linux, `ios-simulator` the second on a macOS runner (not
required checks yet).
`gfx-check` and `gfx-web-check` also draw `FeatureScene` (buffer and texture
writes, R8 and RGBA8 textures, blending, scissor) against
`packages/gfx/test/features.png`.

## UI

On Eval: `make view-check` (`@hxmc/view` on two test renderers, on Eval,
natively and in JavaScript (compiled by the port, run by node): signals,
markup, components, text runs, reactive values, the control flow
components, boundaries between renderers, the programs the macro
rejects), `make web-check` (`@hxmc/web`'s static renderer on Eval and
natively: escaping, attributes, the markers hydration reads, islands;
then in headless Chromium: the DOM renderer, and the demo page of
`packages/web/examples` hydrated without making a node again, reactive
afterwards, a mismatch rendered again, a JavaScript island calling a
wasm32-wasi module's exports, gfx's cube as a WebAssembly island fetched
once it scrolls into view; it prints the sizes of a small island's bundle
and of the loader), `make text-check` (the rasterizer,
DejaVu Sans' tables and outlines, line layout, a text sample through the
atlas against `packages/text/test/sample.png`: the same pixels on every
machine with that font; Inter's CFF outlines and GPOS kerning against
`sample-cff.png`, when fonts-inter is installed, as in CI; Arabic, Hebrew and marks against Chromium's widths and ink, grapheme clusters against `Intl.Segmenter`), `make ui-check` (the flexbox layout against
Chromium's on 89 cases (29 of them CSS grids), `packages/ui/test/layout-expected.json`, which
`layout-ref.mjs` writes from `layout-cases.mjs` (`make ui-layout-fuzz SEED=n COUNT=n`, a tool and not a lane: random flex trees against Chromium's boxes, `FEATURES=more` grids, absolute positions, auto margins, order, aspect ratios, hidden overflow and display none too, a difference reduced into a case there, `make ui-layout-reduce CASE='fuzz 41-87'` dropping nodes and properties while it still differs; the plain trees of seeds 3, 5, 8, 11, 13, 17, 19, 23, 29, 31, 41 and 99 all match, the more trees differ mostly where aspect ratios meet stretching); text wrapping, events and
focus; PNG files of every colour type, depth, filter and interlacing,
`packages/ui/test/png/`, which `png-cases.mjs` writes with the pixels
expected, checked against Chromium's decoder when written; JPEG files of
every kind the decoder reads, `packages/ui/test/jpeg/`, which
`jpeg-cases.mjs` writes with the pixels Chromium decodes, matched exactly,
and GIF files the same way (`gif/`, `gif-cases.mjs`); SVG documents drawn
by `Svg` against Chromium's pixels (`svg/`, `svg-cases.mjs`; the shapes
must agree, edge anti-aliasing may differ); CSS colours and gradients
against Chromium's (`css/`, `css-cases.mjs`);
popups placed, hit and dismissed; then markup rendered into hxmc.ui's
nodes (`MarkupTest.hx`: attributes from Style's properties), the popup widgets driven by pointer and keys, a VirtualList of
100000 rows scrolled; the examples of `packages/ui/GUIDE.md`, run by
`GuideTest.hx`). `make theme-check` (`@hxmc/theme`: Tailwind's class lists read as rules, Tw's rules made at compile time, shadcn's sheet made, the classes it rejects at compile time). Natively: `make
ui-draw-check` (the sample UI, the todo example and the widget gallery,
the last two driven through their Ui under @hxmc/theme's `Shadcn.sheet`, drawn headless against `draw.png`,
`todo.png` and `gallery.png` (and the gallery dark, right to left, and
with no sheet at all: `gallery-unstyled.png`, its frame only); `BoxTest`, boxes with their own corners' radii
and sides' borders, a clip to rounded corners, box shadows (blurred, a
spread ring, inset, several), boxes turned, scaled, skewed
and nested, against Chromium's `boxes.png` (`box-ref.mjs` from
`boxes.json`), a text under `scale(2)` against the same text
twice the size; `BLESS=1` writes the goldens again, uncompressed, and
`node packages/gfx/test/png-deflate.mjs` compresses them before a commit; Linux: llvmpipe, DejaVu
Sans; the sample in a window under Xvfb, whose loop must sleep once it has
nothing to draw; `StressTest`, a list of 1000 rows: the time of each step,
mounting, layout, frames, a change to one row, a scroll; `ClipboardTest`,
the clipboard between two windows under Xvfb, through X11's selection
protocol; also on Windows and macOS in CI; `TextInputTest`, key presses
typed through X11's input method under Xvfb, keys given other symbols: a
Cyrillic letter, a dead key composed with the next; `LinuxAccessTest`
and `AtspiProbe`, a window's accessibility tree read and pressed by
another process through libatspi, in a D-Bus session with AT-SPI's bus
(at-spi2-core); on macOS in CI
`TextInputTest` types through the window's text view and composes in it,
`MacAccessTest` reads the accessibility tree through NSAccessibility and
performs its actions, and drives the native views: a field (an
NSTextField, a password's NSSecureTextField), a text area (an NSTextView),
a context menu chosen from (NSMenu), the menu bar's item performed; on
Windows `WinAccessTest` calls the UI Automation providers through their
COM interfaces and asks UI Automation for the window's element, and drives
the native views: an EDIT typed into and centred, a popup menu chosen
from by keys, the window's menu bar and a command of it). In the browser: `make ui-web-check` (the native form on the DOM's own
controls, `native-web.mjs`; native text editors over a drawn window,
the page's input and textarea, typed in, submitted, tabbed between drawn
widgets and hidden under a popup, `web-field.mjs`; the todo example (its
fields drawn) for
wasm32-wasi in headless Chromium on WebGPU and WebGL2, driven by real pointer
and keyboard events, an input method's composition through the DevTools
protocol, against `todo.png`). CI runs all five in the `gfx` job.

## The dev loop

`make dev-check` ([dev.md](dev.md); CI: the `gfx` job): `HotTest`
(`packages/os/test`: `hxmc.dev.Hot` and a store written as a third-party
library, `test/store/Store.hx`, run twice, the second time from the first
one's snapshot, natively and on Eval; built again with a changed type, that
value reset and logged), `RefreshTest` (`packages/view/test`: signals keyed
by their variables in each component instance, two instances apart, `For`
rows by position, the `key` attribute, a `Show` turned on later), then
`hxmc dev` itself on a copy of ui's Counter (`packages/os/test/dev`): in
headless Chromium, as wasm and as WasmGC (`dev-web.mjs`: clicks through the
canvas's ARIA mirror, an edit reloads the page with the count kept, a
changed signal type resets it with a notice, a compile error shows in the
overlay while the page and its program go on, the fix reloads with the count
kept), and natively in a window under Xvfb (`dev-native.mjs`: the same
through the process's restarts). Each prints its reloads' times.

## CI

CI (`.github/workflows/build.yml`) runs as parallel jobs, each waiting only
for what it uses: `changes` (what the run needs, `.github/select.sh`, and
whether the runtime objects' release exists), `rt-build` and `rt` (only when
it is missing: one job per target, `make rt-target`, then `make rt-layouts`
and the release), `build` (the bootstrap from the stage0, the fixpoint, the types and module
cache checks, the
release binaries and lix for the six targets) and next to it, each with a tool
of its own from the stage0: `corpus` (`make corpus-stage`: the corpus for
every target in three jobs, the port as a WebAssembly module, the reference's
self-compile), `fuzz-exec` (the fuzzer's exec lanes, a job each),
`crosshost` (`make crosshost`, the targets in two jobs),
`memory and time` (`make measure`), `npm-pack` (the npm packages), `site` and
`gfx` (`make gfx-check` on Linux x86-64, and the programs cross-built for
`gfx-arm64` to check on ARM64; `gfx-macos`, after `npm-pack`: built from the
npm packages with `-lib hxmc.gfx`, on Metal and in a Cocoa window). Then
`conformance` (the harnesses above; the Eval debugger in three shards,
`EvalDebugger --shard i/n`, and the fuzzer's diff lanes in three jobs), `test`
(on each of the six machines: the release binary's smoke test with a TLS
handshake and libuv, lix, the corpus, the self-compile), `wasm` (the corpus
and the self-compile under node and wasmtime, both also with legacy exception
handling under node), `playground` (the website in three browser engines,
`make site-check`: a link check; every page in Chromium and the key pages
in Firefox and WebKit at a desktop's and a phone's width, rendered with
its islands hydrated, no errors and no horizontal scrolling; the menu, the
theme, the examples running, the triangle and the cube against their
golden images, web's Counter and Lab islands, the tone; the playground's
compiler with both modules, its fallback to the legacy one in a
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
nightly prerelease `<version>-nightly.<date>.<commit>` tagged `next`; then the
source-only packages of `packages/` at their own versions when those are not
on npm yet; never from other branches), the nightly release and the website.

Main, tags, the nightly schedule (02:41 UTC) and dispatches run everything. On
other branches a push runs only what its changes need, since the last commit
whose run succeeded (else since the merge base with main): only `*.md` or
`site/`, `site` and `playground` (the site renders the docs); only
source-only packages (`packages/os`, `packages/gfx`: a version of their own),
`build`, `npm-pack`, the `gfx` jobs and the site; anything else (`haxe/`, `hxmc/src`,
`hxmc/std`, `hxmc/deps`, `hxmc/test`, the workflows, the Makefile, the
compiler's npm packages), everything. A newer push to a branch cancels its
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
