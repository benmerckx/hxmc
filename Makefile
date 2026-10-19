# hxmc: the Haxe compiler ported to Haxe (haxe/src) and hxmc, its machine-code
# and WebAssembly target (hxmc/). GNU make, from the repository root; needs
# node (and git), zig only to build the runtime objects (README.md, docs/development.md).
#
#   make help                 the targets and variables below
#   make hxmc                 bin/hxmc/hxmc, the tool (from the committed stage0 on first use)
#   make port                 bin/port/haxe: the port with every generator (seconds after an edit)
#   make quick|check|full     the tiered checks (hxmc/test/Tiers.hx)
#   make release TARGET=macos-arm64   bin/release/<TARGET>/haxe[.exe]
#
# Outputs go to bin/ (ignored by Git). hxmc keeps the typed modules and an
# object per module in the user cache directory (HXMC_CACHE overrides) and
# types and compiles again only what changed.

# --- Variables (override on the command line: make release TARGET=windows-arm64) ---

# the upstream std, for every compiler run below
export HAXE_STD_PATH := $(CURDIR)/haxe/upstream/std
# the runtime objects, for every build by the tool (also as a WebAssembly module)
export HXMC_RT_DIR := $(CURDIR)/bin/hxmc/rt
JOBS ?= $(shell nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
NODE ?= node
ZIG ?= zig
export ZIG
# the machine the tool runs on (Linux or macOS; its own runtime object)
HOST ?= $(if $(filter Darwin,$(shell uname -s)),macos,linux)-$(if $(filter aarch64 arm64,$(shell uname -m)),arm64,x86_64)
# `make release`, `make lix-release`: one of the six targets
TARGET ?= $(HOST)
TARGETS := linux-x86_64 linux-arm64 windows-x86_64 windows-arm64 macos-x86_64 macos-arm64
# the runtime objects: the six targets, Linux in the dynamic glibc mode (-D hxmc.libc=glibc), Android
RT_TARGETS := $(TARGETS) linux-x86_64-glibc linux-arm64-glibc android-arm64 android-x86_64
# `make rt-target`: one of RT_TARGETS
RT_TARGET ?= $(HOST)
# `make corpus-stage`: the six targets, wasm32-wasi, wasm32-wasi-legacy, linux-x86_64-glibc, linux-arm64-glibc
CORPUS_TARGETS ?= $(TARGETS) wasm32-wasi wasm32-wasi-legacy linux-x86_64-glibc linux-arm64-glibc
# `make gfx-programs`: any of the six targets, or the host's (`make gfx-check GFX_TARGET=windows-x86_64`: under Wine)
GFX_TARGET ?= $(HOST)
# `make audio-programs`, `make audio-check`: the same for packages/os's audio
AUDIO_TARGET ?= $(HOST)
# `make android-programs`, `android-check`, `android-device-check`: android-x86_64 or android-arm64
ANDROID_TARGET ?= android-x86_64
# `make ios-programs`, `ios-check`: ios-sim-arm64 or ios-arm64 (`ios-sim-check`: the simulator's, on a Mac)
IOS_TARGET ?= ios-sim-arm64
# extra arguments of the port's build (e.g. HXFLAGS="-D retain")
HXFLAGS ?=
# the port the tests check
PORT_BIN ?= bin/port/haxe
# the reference compiler: the nightly build of the pinned upstream commit (`make reference`)
REFERENCE ?= bin/reference/haxe
# `make test-fuzz`: the lane and the number of programs
LANE ?= diff:hxb
N ?= 200
# `quick`, `check`, `full`: the corpus cases to restrict the corpus lanes to
# (CASES="Int64Gc Bench"); PORT=1 adds the port's self-compile to `check`
CASES ?=
PORT ?=
# `make site`: a directory of lix binaries to publish under tools/ (lix-<target>[.exe])
LIX_DIR ?=
# `make site`: a checkout of the bench-data branch (its history.json and
# latest.json become bin/site/bench/, the Programs benchmarks)
BENCH_DATA ?=
# `make bench`: the arguments of hxmc/test/Bench.hx (e.g. "-n 3 -c nbody -t hxmc,js")
BENCH_ARGS ?=
# `make bench-arrays`: length, rounds, samples, optional JSON output
ARRAY_BENCH_ARGS ?=
# `make crosshost`: the arguments of hxmc/test/Crosshost.hx (CI splits the targets: "--targets a,b")
CROSSHOST_ARGS ?= --tool

# --- Sources ---

PORT_SRC := $(shell find haxe/src -name '*.hx')
HXMC_SRC := $(shell find hxmc/src -name '*.hx')
# (the directories too: a file deleted changes only its directory's time)
STD_SRC := $(shell find hxmc/std)
RT_SRC := $(wildcard hxmc/deps/*)
LIX_SRC := $(shell find tools/lix/src -name '*.hx')
FUZZ_SRC := $(wildcard haxe/test/fuzz/*.hx haxe/test/fuzz/fuzz/*.hx) haxe/test/HlcNames.hx

TOOL := bin/hxmc/hxmc
STAGE0 := hxmc/bootstrap/stage0.wasm.br
STD := bin/hxmc/std/.stamp
HOST_RT := bin/hxmc/rt/$(HOST)/rt.o
# node runs WebAssembly modules (a large stack for the compiler's recursion)
WASI := ulimit -s unlimited 2>/dev/null || true; $(NODE) --stack-size=65500 hxmc/bootstrap/wasi.mjs
# a Haxe script on Eval: the tool when there is one, else the stage0 module
RUN = $(if $(wildcard $(TOOL)),ulimit -s unlimited 2>/dev/null || true; $(TOOL),$(WASI) $(STAGE0))
# the test scripts (haxe/test, hxmc/test), on Eval with the tool
SCRIPT := ulimit -s unlimited 2>/dev/null || true; $(TOOL) -cp hxmc/test -cp haxe/test --run
# the hxmc target: bin/hxmc/std (hxmc/std merged with the Eval originals for
# macros), given last
HXMC_ARGS := -cp bin/hxmc/std --custom-target hxmc
# the compilers' runtime: the collector's helper thread that faults in the old
# space's pages ahead of the minor collections (less wall time, more CPU time)
COMPILER_ARGS := -D hxmc.gc-prefault
# the tool is the port (haxe/src) with hxmc (hxmc/src) as
# its generate hook, typed against hxmc's std, without the port's other
# target generators
TOOL_CP := -cp haxe/src -cp hxmc/src -main hxmc.Main -D disable-parallelism -D hih_no_generators -cp bin/hxmc/std
TOOL_ARGS := $(TOOL_CP) $(COMPILER_ARGS) --custom-target hxmc
# the port (typed with -D disable-parallelism; the binary runs its parallel
# passes unless its own invocation passes that define)
PORT_ARGS := -cp haxe/src -main haxe.Main -D disable-parallelism $(COMPILER_ARGS) $(HXFLAGS) $(HXMC_ARGS)
# `haxe` with hxmc built in (the npm package's compiler: every generator)
PKG_ARGS := -cp haxe/src -cp hxmc/src -main hxmc.HaxeMain -D disable-parallelism $(COMPILER_ARGS) $(HXMC_ARGS)
EXE = $(if $(findstring windows,$(1)),.exe)
RELEASE_BIN := bin/release/$(TARGET)/haxe$(call EXE,$(TARGET))
LIX_BIN := bin/release/$(TARGET)/lix$(call EXE,$(TARGET))

# $(call hxmc,<out>,<args>): a build by the tool, its log next to the output
define hxmc
@mkdir -p $(dir $(1))
ulimit -s unlimited 2>/dev/null || true; $(TOOL) $(1) $(2) > $(1).log 2>&1 || { cat $(1).log; exit 1; }
@ls -l $(1)
endef

.DEFAULT_GOAL := help
.PHONY: help std deps rt rt-build rt-target rt-layouts hxmc tool bootstrap fixpoint stage0 crosshost port dev release wasm npm site fuzz \
	lix lix-release lix-dist reference bench bench-arrays test test-fuzz test-display test-server test-jsonrpc test-unit-targets test-interp \
	test-haxelib test-eval-debugger test-node-libs test-module-cache smoke hxmc-test corpus-stage gfx-programs gfx-check gfx-web-check gfx-cache-check gfx-shader-check \
	android-programs android-check android-device-check touch-check shared-check ios-programs ios-check ios-sim-check \
	audio-programs audio-check audio-web-check native-macros ui-programs view-check web-check text-check ui-check ui-layout-fuzz ui-layout-reduce theme-check theme-fidelity-check theme-dom-check web-widgets ui-draw-check ui-web-check dev-check portcheck measure site-check \
	quick check full clean distclean wasmgc-check wasmgc-bench wasmgc-port test-wasmgc-port

help:
	@sed -n '/^# --- Targets/,$$p' $(MAKEFILE_LIST) | sed -n 's/^## \{0,1\}//p'

# --- Targets ---
## hxmc        bin/hxmc/hxmc: the tool, built by the previous tool from source (alias: tool);
##             the first one by the stage0 module under node (bin/hxmc/boot/hxmc1)
## bootstrap   the tool from the stage0 only, then the fixpoint
## fixpoint    bin/hxmc/hxmc builds bin/hxmc/fix/a, which builds bin/hxmc/fix/b: byte-identical
## stage0      hxmc/bootstrap/stage0.wasm.br: the tool as a wasm32-wasi module, brotli (commit it
##             when the sources need a newer one)
## std         bin/hxmc/std: hxmc/std merged with the Eval originals (hxmc/src/hxmc/MkStd.hx)
## rt          the runtime objects (bin/hxmc/rt/<target>/{rt,ssl,uv}.o): the release
##             rt-<hash of hxmc/deps> (hxmc/bootstrap/rt.mjs), else rt-build
## rt-build    the runtime objects with zig: mbedtls and libuv (hxmc/deps/deps.sh), hxmc/deps/mkrt.sh
## rt-target   RT_TARGET's objects alone (and linux-x86_64's, the tool's); rt-layouts then checks
##             the committed layouts against every target's headers and writes bin/hxmc/rt/HASH
##             (CI builds the eight targets in parallel)
## crosshost   the tool as a WebAssembly module (under node) builds the corpus for every target
##             and the tool itself byte-identical to the native tool (hxmc/test/Crosshost.hx)
## port        PORT_BIN (bin/port/haxe): the port for the host, built by hxmc (alias: dev)
## release     bin/release/TARGET/haxe[.exe]: the port cross-built by hxmc, with mbedtls and libuv
## wasm        bin/wasm/hih.wasm: the playground's compiler (wasm32-wasi, -D hih_no_generators),
##             and bin/wasm/hih-legacy.wasm, the same with -D hxmc.wasm-eh=legacy (browsers without exnref)
## npm         bin/npm/*.tgz: the npm packages of packages/ (packages/pack.mjs): @hxmc/cli, its six
##             platform packages @hxmc/<os>-<cpu>, @hxmc/wasm and @hxmc/source (NPM_VERSION), and
##             in bin/npm/packages/ the others with a version of their own (sources only)
## site        bin/site: the website (site/: pages rendered by site/src with @hxmc/web, the packages'
##             examples built for the browser, the API read by the compiler; LIX_DIR's lix binaries
##             under tools/, BENCH_DATA's benchmark history under bench/)
## site-check  bin/site in headless browsers: every page rendered, islands hydrated, examples
##             drawing, the playground compiling, no console errors, no broken links
##             (site/tools/browser-test.mjs; Playwright; BROWSERS="chromium firefox webkit")
## fuzz        bin/fuzz/fuzz: the differential fuzzer, built by hxmc
## lix         bin/lix/lix (+ haxe, haxelib, neko links): lix (tools/lix) for the host
## lix-release bin/release/TARGET/lix[.exe]: lix cross-built for TARGET
## lix-dist    bin/lix-dist/lix-<target>[.exe]: lix for the six targets (the release, the site's tools/)
## reference   REFERENCE (bin/reference/haxe): the nightly of the pinned upstream commit, by lix
## test        HXB conformance of PORT_BIN against the reference (haxe/test/Conformance.hx;
##             CASES_FILE=haxe/test/conformance-macro-cases.txt for the macro cases)
## test-fuzz   the fuzzer on PORT_BIN: LANE (default diff:hxb), the kept programs, then N programs
## test-display, test-server, test-jsonrpc, test-interp, test-haxelib, test-eval-debugger
##             the display requests, the compilation server, its JSON-RPC methods, --interp
##             runs, -lib, the Eval debugger: PORT_BIN against the reference (haxe/test/*.hx)
## test-unit-targets   upstream's unit suite compiled for each target by both, compared
## smoke       hxmc/test/smoke.sh on PORT_BIN: --interp, HXB, JS, sys.ssl, eval.luv
## hxmc-test   hxmc's corpus against its golden files (hxmc/test/Corpus.hx)
## test-module-cache  the persistent module cache's gate: the same outputs with and without it,
##             cold, warm, after edits, for hxmc and JS (hxmc/test/ModuleCacheCheck.hx; with
##             bin/npm/native/HOST/haxe; PORT=1 adds the port itself)
## corpus-stage  bin/corpus/<target>: hxmc's corpus cross-built for each of CORPUS_TARGETS, to run on
##             the target's machine (Check; CI's test and wasm jobs): wasm32-wasi-legacy with legacy
##             exception handling, linux-*-glibc in the glibc mode (checked with readelf: ElfCheck);
##             the native targets' debugging information checked and a -debug build staged in _debug/
##             (DebugCheck: its --run on the target's machine runs gdb or lldb)
## test-node-libs  -lib from node_modules with the npm package's compiler for the host (hxmc/test/NodeLibs.hx)
## gfx-programs  bin/gfx/GFX_TARGET/{GfxTest,Triangle,Cube,Instances,Targets,Mips,Formats}[.exe]: packages/gfx's test programs (Linux: glibc mode)
## android-programs  bin/android/ANDROID_TARGET/*.apk: APKs written by hxmc (android-x86_64, android-arm64)
## android-check  their structure (hxmc/test/ApkCheck.hx: zip, manifest, ELF, v2 signature, classes.dex)
## android-device-check  the Android tests on the device or emulator adb reaches (android.sh, android-native.sh, android-mix.sh, android-touch.sh)
## touch-check  packages/os's touch gesture (TouchDrag, Android's and iOS's: a tap, a drag, a fling's glide) natively here
## ios-programs  bin/ios/IOS_TARGET/*.app, Cube.ipa: iOS apps written by hxmc (ios-sim-arm64, ios-arm64); bin/ios/SimTap (macOS)
## ios-check   their structure (hxmc/test/IosCheck.hx: bundle, Info.plist, Mach-O, code signature)
## ios-sim-check  IosTest on an iPhone simulator (a Mac with Xcode: packages/gfx/test/ios.sh)
## shared-check  shared libraries of the glibc mode (-D hxmc.shared), loaded by an hxmc program (hxmc/test/SharedCheck.hx)
## gfx-check   packages/gfx: the examples (triangle, cube, instances, targets, mips, formats) headless and in a window, against
##             golden images (packages/gfx/test/check.sh; Linux: Mesa, Xvfb; macOS: Metal, Cocoa);
##             GFX_TARGET=windows-x86_64: D3D11 and Win32 under Wine
## gfx-web-check  packages/gfx on WebGPU and WebGL2 (wasm32-wasi): the same, headless and in a
##             canvas, in headless Chromium (packages/gfx/test/web.mjs; Playwright with Chromium);
##             then built with -D hxmc.wasm-gc (the hybrid module)
## gfx-cache-check  the module cache across WasmGC and native builds on one store: WebTest with
##             -D hxmc.wasm-gc, GfxTest natively, each again from the store, linked, the same, run
## gfx-shader-check  packages/gfx's shader macro on Eval: shaders run on the CPU, the emitted
##             GLSL, WGSL, MSL and HLSL against packages/gfx/test/shader/, the programs it must
##             reject (packages/gfx/test/ShaderTest.hx; BLESS=1 rewrites the sources)
## view-check  packages/view on Eval, natively and in JavaScript (the port, node): signals, markup
##             (elements, attributes, whitespace, components, text runs, reactive values), the control
##             flow components, on two test renderers with boundaries between them, and the programs
##             the macro rejects (packages/view/test/ViewTest.hx)
## web-check   packages/web: the static renderer on Eval and natively (escaping, markers, islands:
##             packages/web/test/StaticTest.hx), then in headless Chromium (packages/web/test/web.mjs;
##             Playwright): the DOM renderer (DomTest.hx), the demo page (packages/web/examples)
##             hydrated without making nodes again, reactive after, a mismatch rendered again, a
##             JavaScript island calling a wasm module, gfx's cube as a wasm island loaded once in view;
##             the sizes of a small island's bundle and of the loader
## text-check  packages/text on Eval: the rasterizer, DejaVu Sans (metrics, cmap, kerning, outlines),
##             line layout, and a text sample through the atlas against packages/text/test/sample.png
## ui-check    packages/ui on Eval: the layout against Chromium's flexbox (layout-expected.json,
##             from packages/ui/test/layout-ref.mjs), text wrapping, events and focus (UiTest.hx);
##             markup rendered into nodes (MarkupTest.hx); the guide's examples (GuideTest.hx); the
##             widgets' examples rendered and their reference complete (WidgetExamplesTest.hx; the
##             reference written to bin/ui/widgets.json, tools/WidgetDocs.hx)
## theme-check  packages/theme on Eval: Tailwind's classes read as rules, Tw's rules made at compile time,
##             shadcn's sheet made, the classes it rejects (packages/theme/test/ThemeTest.hx)
## theme-fidelity-check  packages/theme's widgets drawn headless against shadcn's markup in Chromium
##             (packages/theme/test/ref, from ref.mjs; the cases known to differ reported, not failed)
## web-widgets  the DOM's widgets (packages/web, hxmc.web.widgets): the gallery driven in Chromium by pointer
##             and keys (packages/web/test/widgets.mjs), the sizes of the counter, form and gallery bundles
## theme-dom-check  the DOM's widgets (packages/web) under the theme's CSS in Chromium against the same
##             references (packages/theme/test/dom-fidelity.mjs)
## ui-layout-fuzz  random flex trees (SEED, COUNT; FEATURES=more: grids, absolute positions, auto margins, order and more) against Chromium's boxes (Playwright): differences to reduce into layout-cases.mjs
## ui-layout-reduce  one of them (CASE='fuzz 41-87', after ui-layout-fuzz) reduced: nodes and properties dropped while it still differs
## ui-programs  bin/ui/GFX_TARGET/{UiDrawTest,TodoTest,GalleryTest,StressTest,ClipboardTest,EmojiTest,BoxTest,WindowTest}[.exe], NativeTest (GTK 3, Win32, AppKit), TextInputTest (X11), LinuxAccessTest and AtspiProbe (AT-SPI), WinAccessTest (Windows): packages/ui's test programs (Linux: glibc mode)
## ui-draw-check  packages/ui's GPU renderer (hxmc.ui.draw): the sample UI headless against
##             packages/ui/test/draw.png (also in a window, under Xvfb), then the todo example (markup, signals, widgets) driven
##             through its Ui and drawn against todo.png (Linux: Mesa, DejaVu Sans; BLESS=1 rewrites them)
## ui-web-check  the todo example as wasm32-wasi in headless Chromium, on WebGPU and WebGL2, driven by
##             real pointer and keyboard events, against todo.png (packages/ui/test/web.mjs; DejaVu Sans);
##             the native form (native-web.mjs); native text editors in a drawn window (web-field.mjs);
##             each also built with -D hxmc.wasm-gc
## dev-check   the dev loop (docs/dev.md): hxmc.dev.Hot and a store written as a third-party library
##             across a reload (packages/os/test/HotTest.hx: natively and on Eval, a changed type reset),
##             view's signals keyed by component instance (packages/view/test/RefreshTest.hx), then
##             `hxmc dev` on ui's Counter: in headless Chromium, also as WasmGC (packages/os/test/dev/dev-web.mjs: an edit
##             keeps the count, a changed type resets it, a compile error shows in the overlay while the last
##             good build runs) and natively in a window (dev-native.mjs; Linux: under Xvfb); the compilation
##             server's builds through edits (one changing a module's API, one of markup using code it did not use before)
##             against fresh ones (dev-verify.mjs; small programs: server-verify.mjs)
## audio-programs  bin/audio/AUDIO_TARGET/{AudioTest,Tone}[.exe]: packages/os's audio test and example
## audio-check  packages/os's audio through each back end without speakers (packages/os/test/audio.sh):
##             ALSA's null and file devices (Linux), CoreAudio's generic output (macOS), WASAPI
##             (Windows; AUDIO_TARGET=windows-x86_64: under Wine, to an ALSA file); the samples
##             that reach the API against the signal, the callbacks' count and rate
## audio-web-check  packages/os's audio on WebAudio (wasm32-wasi) in headless Chromium: realtime
##             and in an OfflineAudioContext (packages/os/test/web.mjs; Playwright with Chromium)
## native-macros  the native macros prototype (docs/plans/compiler.md, "Native macros"): bin/jit/haxe, the
##             npm compiler built with -D hxmc.jit (Linux x86-64), runs the macro cases with
##             -D hxmc.macros=verify (MACROS=native: native only, the HXB compared)
## portcheck   the port built by hxmc self-compiles to the reference's HXB (hxmc/test/Selfcheck.hx)
## bench       the HaxeBenchmarks cases on hxmc (native, wasm under node), C++, JVM, JS, HL/C and
##             HL, built by hxmc and the port: times, peak RSS, sizes (hxmc/test/Bench.hx; BENCH_ARGS)
## bench-arrays  Array vs hxmc.NativeArray vs Vector: nine element types and five workloads
##             (ARRAY_BENCH_ARGS="65536 128 7 bin/vector-bench/results.json")
## measure     peak memory and time of the self-compile (ours, the reference) and of the
##             tool's builds (haxe/test/Measure.hx)
## wasmgc-check  -D hxmc.wasm-gc (WasmGC, an experiment): hxmc/test/wasmgc's programs and a few corpus
##             cases as WasmGC modules under node, their output against the native build's (hxmc/test/GcCheck.hx);
##             wasmgc-bench adds linear-memory wasm: times, peak RSS, sizes
## wasmgc-port  bin/wasmgc-port/haxe: the port as a WasmGC module (-D hxmc.wasm-gc) run by node
## test-wasmgc-port  the lanes with it as the port: HXB (the three lists), --interp, display, -L, the
##             upstream target suites (docs/testing.md)
## quick       after every edit (under a minute): the tool, then the x64 corpus, again with
##             RT_VERIFY=1, and the wasm corpus under node (CASES restricts the corpus)
## check       before a local commit (a few minutes): quick + arm64 (qemu), wine, a 16 KB
##             nursery, the wasm corpus with legacy exception handling, ThreadNatives x30,
##             crosshost on three cases; PORT=1 adds the native port's self-compile
## full        before a push: every nursery, RT_VERIFY, wasmtime, ThreadNatives x300, the
##             port's self-compile natively and as a module, crosshost, the fixpoint
## clean       remove the build outputs (keeps the tool, the runtime objects and the reference)
## distclean   also remove bin/ entirely
##
## Variables: JOBS, NODE, ZIG, HOST, TARGET, RT_TARGET, GFX_TARGET, AUDIO_TARGET, HXFLAGS, PORT_BIN, REFERENCE, LANE, N, CASES, PORT,
## LIX_DIR, BENCH_DATA, BENCH_ARGS, ARRAY_BENCH_ARGS, CROSSHOST_ARGS, CORPUS_TARGETS (defaults and meaning: the top of the Makefile).

std: $(STD)
$(STD): hxmc/src/hxmc/MkStd.hx $(STD_SRC)
	$(RUN) -cp hxmc/src --run hxmc.MkStd

# --- hxmc: the runtime objects and the tool ---

# the published objects of this hxmc/deps, else built here
rt: $(HOST_RT)
$(HOST_RT): $(RT_SRC)
	$(NODE) hxmc/bootstrap/rt.mjs fetch bin/hxmc/rt || $(MAKE) rt-build
	touch bin/hxmc/rt/*/*.o

# mbedtls and libuv per target (rebuilt only when their versions or flags change)
deps: $(foreach t,$(RT_TARGETS),bin/hxmc/deps/$(t)/VERSIONS)
.PRECIOUS: bin/hxmc/deps/%/VERSIONS
bin/hxmc/deps/%/VERSIONS: hxmc/deps/deps.sh
	sh hxmc/deps/deps.sh $* bin/hxmc/deps/$*
	touch $@

# the host's object needs no tool (Linux: zig cc and ld.lld); the Windows and
# macOS ones are assembled by the tool (hxmc --mkrt)
rt-build: deps
	sh hxmc/deps/mkrt.sh linux-x86_64
	$(MAKE) $(TOOL)
	for t in $(filter-out linux-x86_64,$(RT_TARGETS)); do HXMC=$(CURDIR)/$(TOOL) sh hxmc/deps/mkrt.sh $$t || exit 1; done
	$(MAKE) --no-print-directory rt-layouts

# one target's objects (with linux-x86_64's, which the tool that assembles the
# others links)
rt-target: bin/hxmc/deps/linux-x86_64/VERSIONS bin/hxmc/deps/$(RT_TARGET)/VERSIONS
	sh hxmc/deps/mkrt.sh linux-x86_64
	if [ $(RT_TARGET) != linux-x86_64 ]; then $(MAKE) --no-print-directory $(TOOL) && HXMC=$(CURDIR)/$(TOOL) sh hxmc/deps/mkrt.sh $(RT_TARGET); fi

# the committed layouts are what every target's headers give (bin/hxmc/deps/<target>/include)
rt-layouts: $(TOOL)
	$(TOOL) -cp hxmc/deps --run Layouts --check
	$(NODE) hxmc/bootstrap/rt.mjs hash > bin/hxmc/rt/HASH

# The tool compiles its own source with the previous tool (written next to it,
# then moved: the running binary is replaced); the first one comes from the
# stage0 module under node. A change to code generation reaches the tool's own
# code on the next rebuild (`fixpoint` checks that a rebuild changes nothing).
hxmc tool: $(TOOL)
$(TOOL): $(PORT_SRC) $(HXMC_SRC) $(STD) $(HOST_RT)
	@if [ ! -x $@ ]; then $(MAKE) --no-print-directory bin/hxmc/boot/hxmc1; fi
	@T=$@; [ -x $$T ] || T=bin/hxmc/boot/hxmc1; \
	echo "$$T $@.new $(TOOL_ARGS)"; \
	ulimit -s unlimited 2>/dev/null || true; \
	$$T $@.new $(TOOL_ARGS) > bin/hxmc/tool.log 2>&1 || { cat bin/hxmc/tool.log; exit 1; }
	mv $@.new $@
	rm -rf $@.new.hxmc
	@ls -l $@

# the stage0 module builds the first native tool (one thread, about half a minute)
bin/hxmc/boot/hxmc1: $(STAGE0) $(STD) $(HOST_RT)
	@mkdir -p $(dir $@)
	$(WASI) $(STAGE0) $@ $(TOOL_ARGS) -D hxmc.target=$(HOST) > $@.log 2>&1 || { cat $@.log; exit 1; }
	chmod +x $@
	@ls -l $@

bootstrap:
	rm -rf $(TOOL) bin/hxmc/boot
	$(MAKE) --no-print-directory $(TOOL)
	$(MAKE) --no-print-directory fixpoint

# (the tool rebuilt by itself three times, the same executable each time:
# with the module cache cold, warm, and off, hxmc/src/hxmc/ModuleCache.hx;
# the cache in bin/hxmc/fix/cache)
fixpoint: $(TOOL)
	@rm -rf bin/hxmc/fix; mkdir -p bin/hxmc/fix
	ulimit -s unlimited 2>/dev/null || true; \
	$(TOOL) bin/hxmc/fix/a $(TOOL_ARGS) > bin/hxmc/fix/a.log 2>&1 || { cat bin/hxmc/fix/a.log; exit 1; }; \
	for b in cold warm; do \
		HXMC_CACHE=bin/hxmc/fix/cache HXMC_STATS=1 bin/hxmc/fix/a bin/hxmc/fix/$$b $(TOOL_ARGS) > bin/hxmc/fix/$$b.log 2>&1 || { cat bin/hxmc/fix/$$b.log; exit 1; }; \
		grep "module cache:" bin/hxmc/fix/$$b.log; \
	done; \
	HXMC_MODULE_CACHE=0 bin/hxmc/fix/a bin/hxmc/fix/off $(TOOL_ARGS) > bin/hxmc/fix/off.log 2>&1 || { cat bin/hxmc/fix/off.log; exit 1; }
	cmp bin/hxmc/fix/a bin/hxmc/fix/cold && cmp bin/hxmc/fix/a bin/hxmc/fix/warm && cmp bin/hxmc/fix/a bin/hxmc/fix/off && cmp $(TOOL) bin/hxmc/fix/a \
		&& echo "fixpoint: the tool rebuilt by itself is byte-identical (the module cache cold, warm and off)"
	rm -rf bin/hxmc/fix

# a new stage0 (deliberate: commit it when the sources need it)
stage0: $(TOOL)
	$(call hxmc,bin/stage0/hxmc.wasm,$(TOOL_ARGS) -D hxmc.target=wasm32-wasi)
	$(NODE) -e "const z=require('zlib'),fs=require('fs'),b=fs.readFileSync('bin/stage0/hxmc.wasm');fs.writeFileSync('$(STAGE0)',z.brotliCompressSync(b,{params:{[z.constants.BROTLI_PARAM_QUALITY]:11,[z.constants.BROTLI_PARAM_LGWIN]:24,[z.constants.BROTLI_PARAM_SIZE_HINT]:b.length}}))"
	@ls -l $(STAGE0)

crosshost: $(TOOL) $(STD) $(HOST_RT)
	$(SCRIPT) Crosshost $(CROSSHOST_ARGS) $(CASES)

# --- The port ---

port dev: $(PORT_BIN)
$(PORT_BIN): $(TOOL) $(PORT_SRC) $(STD) $(HOST_RT)
	$(call hxmc,$@,$(PORT_ARGS))

# the release binaries: cross-built from Linux, with mbedtls and libuv (ssl.o, uv.o)
release: $(RELEASE_BIN)
bin/release/%/haxe: $(TOOL) $(PORT_SRC) $(STD) $(HOST_RT)
	$(call hxmc,$@,$(PORT_ARGS) -D hxmc.target=$*)
bin/release/%/haxe.exe: $(TOOL) $(PORT_SRC) $(STD) $(HOST_RT)
	$(call hxmc,$@,$(PORT_ARGS) -D hxmc.target=$*)

# the playground's compiler: a wasm32-wasi module (its runtime is Haxe, no
# runtime object), without the target generators; with exnref, and with the
# legacy exception-handling instructions for browsers without exnref (the
# playground fetches one of the two)
wasm: bin/wasm/hih.wasm bin/wasm/hih-legacy.wasm
bin/wasm/hih.wasm: $(TOOL) $(PORT_SRC) $(STD)
	$(call hxmc,$@,$(PORT_ARGS) -D hih_no_generators -D hxmc.target=wasm32-wasi)
bin/wasm/hih-legacy.wasm: $(TOOL) $(PORT_SRC) $(STD)
	$(call hxmc,$@,$(PORT_ARGS) -D hih_no_generators -D hxmc.target=wasm32-wasi -D hxmc.wasm-eh=legacy)

# --- The npm packages (packages/, packed by packages/pack.mjs) ---

# what @hxmc/cli ships besides its sources (packages/cli): hxmc's merged std
# and the runtime objects
CLI_BOOT := packages/cli/hxmc/bootstrap
NPM_GEN := $(CLI_BOOT)/hxmc-std/.stamp $(CLI_BOOT)/rt/HASH
$(CLI_BOOT)/hxmc-std/.stamp: hxmc/src/hxmc/MkStd.hx $(STD_SRC)
	$(RUN) -cp hxmc/src --run hxmc.MkStd hxmc/std haxe/upstream/std $(CLI_BOOT)/hxmc-std
$(CLI_BOOT)/rt/HASH: $(HOST_RT)
	rm -rf $(CLI_BOOT)/rt
	for t in $(RT_TARGETS); do mkdir -p $(CLI_BOOT)/rt/$$t && cp bin/hxmc/rt/$$t/rt.o bin/hxmc/rt/$$t/ssl.o bin/hxmc/rt/$$t/uv.o $(CLI_BOOT)/rt/$$t/ || exit 1; done
	cp bin/hxmc/rt/LICENSE.* $(CLI_BOOT)/rt/ 2>/dev/null || true
	$(NODE) hxmc/bootstrap/rt.mjs hash > $@
# the compilers: native for the platform packages (@hxmc/<os>-<cpu>), with
# every generator as a wasm32-wasi module (@hxmc/wasm)
NPM_NATIVES := $(foreach t,$(TARGETS),bin/npm/native/$(t)/haxe$(call EXE,$(t))) bin/npm/native/wasm32-wasi/haxe.wasm
bin/npm/native/wasm32-wasi/haxe.wasm: $(TOOL) $(PORT_SRC) $(HXMC_SRC) $(STD)
	$(call hxmc,$@,$(PKG_ARGS) -D hxmc.target=wasm32-wasi)
bin/npm/native/%/haxe: $(TOOL) $(PORT_SRC) $(HXMC_SRC) $(STD) $(HOST_RT)
	$(call hxmc,$@,$(PKG_ARGS) -D hxmc.target=$*)
bin/npm/native/%/haxe.exe: $(TOOL) $(PORT_SRC) $(HXMC_SRC) $(STD) $(HOST_RT)
	$(call hxmc,$@,$(PKG_ARGS) -D hxmc.target=$*)
# NPM_VERSION: the version of all nine packages (default packages/cli/package.json's)
NPM_VERSION ?= $(shell $(NODE) -p "require('./packages/cli/package.json').version")
npm: $(NPM_GEN) $(NPM_NATIVES)
	rm -f bin/npm/*.tgz
	$(NODE) packages/pack.mjs $(NPM_VERSION) bin/npm/native bin/npm
	@ls -l bin/npm/*.tgz

# --- The website (site/) ---

# The pages, rendered by site/src (on the tool's Eval, with @hxmc/web's static
# renderer), which also builds each package example for wasm32-wasi (legacy
# exception handling: every browser with WebGPU has it, those with WebGL2
# since 2021), reads the packages' API with the tool, measures the hxmc
# page's sizes and build times, and copies the packages' browser modules;
# then the playground's compiler (bin/wasm), the pages' JavaScript
# (site/client and site/islands, compiled by the port: site/build.hxml), the
# std subset the playground's compiler reads (site/tools/MkBundle.hx), the
# measured results (site/data), lix under tools/ (LIX_DIR), the benchmark
# history (BENCH_DATA) and the build facts. Needs the DejaVu Sans fonts (the
# ui examples'; fonts-dejavu-core). The site's build in the addresses of the
# files its pages fetch (Version.hx, Site.asset): a deploy reaches browsers at once.
mb = awk '{printf "%.1f MB", $$1 / 1048576}'
SITE_VERSION ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo dev)
SITE_CP := -cp packages/view/src -cp packages/web/src -cp packages/web/examples -cp site/islands -cp site/src -cp packages/ui/tools -D hxmc.view.renderer.html=hxmc.web.StaticRenderer
site: wasm $(TOOL) $(STD) $(HOST_RT) $(PORT_BIN)
	rm -rf bin/site && mkdir -p bin/site
	ulimit -s unlimited 2>/dev/null || true; $(TOOL) $(SITE_CP) --run Site --out bin/site --build bin/site-build --tool $(TOOL) --version $(SITE_VERSION) --jobs $(JOBS)
	cp bin/wasm/hih.wasm bin/wasm/hih-legacy.wasm bin/site/
	$(PORT_BIN) -D site_version=$(SITE_VERSION) site/build.hxml
	$(RUN) -cp site/tools --run MkBundle $(HAXE_STD_PATH) bin/site/std.bundle
	cp site/data/*.json bin/site/
	cp -r site/playground bin/site/playground
	if [ -n "$(LIX_DIR)" ]; then mkdir -p bin/site/tools && cp $(LIX_DIR)/lix-* bin/site/tools/; fi
	if [ -n "$(BENCH_DATA)" ] && [ -f "$(BENCH_DATA)/history.json" ]; then mkdir -p bin/site/bench && cp $(BENCH_DATA)/history.json bin/site/bench/ && { cp $(BENCH_DATA)/latest.json bin/site/bench/ 2>/dev/null || true; }; fi
	printf '{\n\t"date": "%s",\n\t"commit": "%s",\n\t"wasmSize": "%s",\n\t"wasmGz": "%s",\n\t"wasmLegacyGz": "%s",\n\t"dataGz": "%s",\n\t"lixSize": "%s"\n}\n' \
		"$$(date -u +%Y-%m-%d)" "$$(git rev-parse --short HEAD)" \
		"$$(wc -c < bin/site/hih.wasm | $(mb))" \
		"$$(gzip -9c bin/site/hih.wasm | wc -c | $(mb))" \
		"$$(gzip -9c bin/site/hih-legacy.wasm | wc -c | $(mb))" \
		"$$(gzip -9c bin/site/std.bundle | wc -c | $(mb))" \
		"$$(if [ -f bin/site/tools/lix-linux-x86_64 ]; then wc -c < bin/site/tools/lix-linux-x86_64 | $(mb); else echo -; fi)" > bin/site/build-info.json
	cat bin/site/build-info.json
	rm -rf bin/site-build
	$(NODE) site/tools/weights.mjs bin/site

# the site's checks in headless browsers (Playwright, with its browsers):
# every page in Chromium, the key pages in Firefox and WebKit too
# (site/tools/browser-test.mjs)
site-check:
	$(NODE) site/tools/browser-test.mjs bin/site $(or $(BROWSERS),chromium firefox webkit)

# --- Other programs ---

fuzz: bin/fuzz/fuzz
bin/fuzz/fuzz: $(TOOL) $(FUZZ_SRC) $(STD) $(HOST_RT)
	$(call hxmc,$@,-cp haxe/test/fuzz -cp haxe/test -main Fuzz $(HXMC_ARGS))

# --- lix (tools/lix) ---

HXCORO := bin/hxcoro
HXCORO_REV := 4b1a4d49542c578dc184297b75d125093ca444d2
$(HXCORO)/.rev:
	rm -rf $(HXCORO) && git init -q $(HXCORO)
	git -C $(HXCORO) fetch -q --depth 1 https://github.com/HaxeFoundation/hxcoro.git $(HXCORO_REV)
	git -C $(HXCORO) checkout -q FETCH_HEAD
	echo $(HXCORO_REV) > $@

# Mozilla's CA certificates (curl's extract), trusted besides the system's
# (Windows' preinstalled roots lack common ones), as a generated module
CACERT := cacert-2026-09-25.pem
CACERT_SHA256 := a41b5d356aea97a529fe27e0f7316d2f9d946d75927476cf9cf1b90637d00505
bin/lix/gen/shim/CaBundle.hx: tools/lix/CaBundle.hx
	@mkdir -p bin/lix
	curl -sSfL --retry 3 -o bin/lix/$(CACERT) https://curl.se/ca/$(CACERT)
	$(RUN) -cp tools/lix --run CaBundle bin/lix/$(CACERT) $(CACERT_SHA256) bin/lix/gen

LIX_ARGS := -cp tools/lix/src -cp bin/lix/gen -cp $(HXCORO)/src -main lix.cli.Main -D no-deprecation-warnings $(HXMC_ARGS)
LIX_DEPS := $(TOOL) $(LIX_SRC) $(STD) $(HXCORO)/.rev bin/lix/gen/shim/CaBundle.hx $(HOST_RT)
lix: bin/lix/lix
bin/lix/lix: $(LIX_DEPS)
	$(call hxmc,$@,$(LIX_ARGS))
	for cmd in haxe haxelib neko; do ln -sf lix bin/lix/$$cmd; done

lix-release: $(LIX_BIN)
bin/release/%/lix: $(LIX_DEPS)
	$(call hxmc,$@,$(LIX_ARGS) -D hxmc.target=$*)
bin/release/%/lix.exe: $(LIX_DEPS)
	$(call hxmc,$@,$(LIX_ARGS) -D hxmc.target=$*)

lix-dist: $(foreach t,$(TARGETS),bin/release/$(t)/lix$(call EXE,$(t)))
	mkdir -p bin/lix-dist
	for t in $(TARGETS); do e=; case $$t in windows-*) e=.exe ;; esac; cp bin/release/$$t/lix$$e bin/lix-dist/lix-$$t$$e || exit 1; done
	@ls -l bin/lix-dist

# --- The reference compiler ---

# the official nightly (build.haxe.org) of the pinned upstream commit,
# downloaded by lix into bin/reference/lix (HAXESHIM_ROOT); the pin must be a
# commit with a nightly
UPSTREAM_REV = $(shell git rev-parse --short=7 HEAD:haxe/upstream)
reference: $(REFERENCE)
$(REFERENCE): bin/lix/lix
	mkdir -p bin/reference
	cd bin/reference && HAXESHIM_ROOT=$(CURDIR)/bin/reference/lix $(CURDIR)/bin/lix/lix download haxe $(UPSTREAM_REV)
	ln -sf lix/versions/$(UPSTREAM_REV)/haxe $@
	$@ -version

# --- Tests (docs/testing.md) ---

CASES_FILE ?= haxe/test/conformance-cases.txt
# (exported: SCRIPT is a command list, which an assignment in front would not reach)
TEST_ENV = export HAXE_REFERENCE=$(abspath $(REFERENCE)) HAXE_IN_HAXE_PORT=$(abspath $(PORT_BIN));
test: $(PORT_BIN) $(REFERENCE)
	$(TEST_ENV) $(SCRIPT) Conformance -j $(JOBS) --cases $(CASES_FILE)
test-display: $(PORT_BIN) $(REFERENCE)
	$(TEST_ENV) $(SCRIPT) Display -j $(JOBS)
test-server: $(PORT_BIN) $(REFERENCE)
	$(TEST_ENV) $(SCRIPT) Server -j $(JOBS)
test-jsonrpc: $(PORT_BIN) $(REFERENCE)
	$(TEST_ENV) $(SCRIPT) ServerJsonRpc
test-interp: $(PORT_BIN) $(REFERENCE)
	$(TEST_ENV) $(SCRIPT) Interp -j $(JOBS)
test-haxelib: $(PORT_BIN) $(REFERENCE)
	$(TEST_ENV) $(SCRIPT) Haxelib
test-eval-debugger: $(PORT_BIN) $(REFERENCE)
	$(TEST_ENV) $(SCRIPT) EvalDebugger
test-unit-targets: $(PORT_BIN) $(REFERENCE) bin/lix/lix
	$(TEST_ENV) $(SCRIPT) UpstreamTargets -j $(JOBS)

test-fuzz: bin/fuzz/fuzz $(PORT_BIN) $(REFERENCE)
	HAXE_REFERENCE=$(abspath $(REFERENCE)) bin/fuzz/fuzz -j $(JOBS) --cases haxe/test/fuzz/cases --port $(abspath $(PORT_BIN)) --lane $(LANE)
	HAXE_REFERENCE=$(abspath $(REFERENCE)) bin/fuzz/fuzz -j $(JOBS) -n $(N) --port $(abspath $(PORT_BIN)) --lane $(LANE)

smoke:
	sh hxmc/test/smoke.sh $(PORT_BIN)

test-node-libs: bin/npm/native/$(HOST)/haxe
	$(SCRIPT) NodeLibs

test-module-cache: $(TOOL) $(STD) $(HOST_RT) bin/npm/native/$(HOST)/haxe
	$(SCRIPT) ModuleCacheCheck --haxe bin/npm/native/$(HOST)/haxe $(if $(PORT),--port)

hxmc-test: $(TOOL) $(STD) $(HOST_RT)
	$(SCRIPT) Corpus -v $(CASES)

corpus-stage: $(TOOL) $(STD) $(HOST_RT)
	for t in $(CORPUS_TARGETS); do \
		case $$t in \
			wasm32-wasi-legacy) a="--target wasm32-wasi --wasm-eh legacy" ;; \
			*-glibc) a="--target $${t%-glibc} --libc glibc" ;; \
			*) a="--target $$t" ;; \
		esac; \
		rm -rf bin/corpus/$$t; \
		$(SCRIPT) Corpus -v $$a --stage bin/corpus/$$t || exit 1; \
		case $$t in *-glibc) $(SCRIPT) ElfCheck bin/corpus/$$t || exit 1 ;; \
			wasm*) ;; \
			*) $(SCRIPT) DebugCheck --target $$t --stage bin/corpus/$$t/_debug || exit 1 ;; esac; \
	done

# the os and gfx packages' sources (`-lib hxmc.gfx` once the launcher resolves packages/)
GFX_CP := -cp packages/os/src -cp packages/gfx/src -cp packages/gfx/examples -cp packages/gfx/test
# (Linux: the dynamic glibc mode, which loads the GPU drivers)
GFX_ARGS = $(if $(filter linux-%,$(GFX_TARGET)),-D hxmc.libc=glibc) -D hxmc.target=$(GFX_TARGET)
gfx-programs: $(TOOL) $(STD) $(HOST_RT)
	$(call hxmc,bin/gfx/$(GFX_TARGET)/GfxTest$(call EXE,$(GFX_TARGET)),$(GFX_CP) -main GfxTest $(HXMC_ARGS) $(GFX_ARGS))
	$(call hxmc,bin/gfx/$(GFX_TARGET)/Triangle$(call EXE,$(GFX_TARGET)),$(GFX_CP) -main Triangle $(HXMC_ARGS) $(GFX_ARGS))
	$(call hxmc,bin/gfx/$(GFX_TARGET)/Cube$(call EXE,$(GFX_TARGET)),$(GFX_CP) -main Cube $(HXMC_ARGS) $(GFX_ARGS))
	$(call hxmc,bin/gfx/$(GFX_TARGET)/Instances$(call EXE,$(GFX_TARGET)),$(GFX_CP) -main Instances $(HXMC_ARGS) $(GFX_ARGS))
	$(call hxmc,bin/gfx/$(GFX_TARGET)/Targets$(call EXE,$(GFX_TARGET)),$(GFX_CP) -main Targets $(HXMC_ARGS) $(GFX_ARGS))
	$(call hxmc,bin/gfx/$(GFX_TARGET)/Mips$(call EXE,$(GFX_TARGET)),$(GFX_CP) -main Mips $(HXMC_ARGS) $(GFX_ARGS))
	$(call hxmc,bin/gfx/$(GFX_TARGET)/Formats$(call EXE,$(GFX_TARGET)),$(GFX_CP) -main Formats $(HXMC_ARGS) $(GFX_ARGS))
# hxmc dev's host and three builds of DevHostTest as libraries it loads in turn (packages/gfx/test/host-dev.sh)
DEVHOST_ARGS := -D hxmc.dev -D hxmc.dev-host -D hxmc.shared -D hxmc.exports=hxmc_dev_run,hxmc_dev_state
DEVHOST_EXT = $(if $(filter windows-%,$(GFX_TARGET)),dll,$(if $(filter macos-%,$(GFX_TARGET)),dylib,so))
devhost-programs: $(TOOL) $(STD) $(HOST_RT)
	$(call hxmc,bin/gfx/$(GFX_TARGET)/dev/host$(call EXE,$(GFX_TARGET)),-cp packages/os/src -main hxmc.dev.DevHost $(HXMC_ARGS) $(GFX_ARGS))
	$(call hxmc,bin/gfx/$(GFX_TARGET)/dev/DevHost1.$(DEVHOST_EXT),$(GFX_CP) -main DevHostTest $(HXMC_ARGS) $(GFX_ARGS) $(DEVHOST_ARGS) -D devhost_version=1 -D hxmc.dll-base=0x10000000)
	$(call hxmc,bin/gfx/$(GFX_TARGET)/dev/DevHost2.$(DEVHOST_EXT),$(GFX_CP) -main DevHostTest $(HXMC_ARGS) $(GFX_ARGS) $(DEVHOST_ARGS) -D devhost_version=2 -D hxmc.dll-base=0x30000000)
	$(call hxmc,bin/gfx/$(GFX_TARGET)/dev/DevHost3.$(DEVHOST_EXT),$(GFX_CP) -main DevHostTest $(HXMC_ARGS) $(GFX_ARGS) $(DEVHOST_ARGS) -D devhost_version=3 -D hxmc.dll-base=0x10000000)
gfx-check: gfx-programs
	sh packages/gfx/test/check.sh bin/gfx/$(GFX_TARGET)

# Android: APKs written by hxmc (hxmc/src/hxmc/android/Apk.hx), AndroidTest
# (packages/gfx/test/AndroidTest.hx), the cube example and AndroidNativeTest
# (packages/ui/test/AndroidNativeTest.hx: views, so classes.dex), AndroidMixTest
# (a GPU view among views) and AndroidTextTest (packages/os/test: text input
# in a drawn window)
android-programs: $(TOOL) $(STD) $(HOST_RT)
	$(call hxmc,bin/android/$(ANDROID_TARGET)/AndroidTest.apk,$(GFX_CP) -main AndroidTest $(HXMC_ARGS) -D hxmc.target=$(ANDROID_TARGET) -D hxmc.android-package=org.hxmc.gfxtest)
	$(call hxmc,bin/android/$(ANDROID_TARGET)/Cube.apk,$(GFX_CP) -main Cube $(HXMC_ARGS) -D hxmc.target=$(ANDROID_TARGET) -D hxmc.android-package=org.hxmc.cube)
	$(call hxmc,bin/android/$(ANDROID_TARGET)/AndroidNativeTest.apk,$(UI_CP) -main AndroidNativeTest $(HXMC_ARGS) -D hxmc.target=$(ANDROID_TARGET) -D hxmc.android-package=org.hxmc.nativetest)
	$(call hxmc,bin/android/$(ANDROID_TARGET)/AndroidMixTest.apk,$(UI_CP) -cp packages/gfx/examples -main AndroidMixTest $(HXMC_ARGS) -D hxmc.target=$(ANDROID_TARGET) -D hxmc.android-package=org.hxmc.mixtest)
	$(call hxmc,bin/android/$(ANDROID_TARGET)/AndroidTextTest.apk,-cp packages/os/src -cp packages/os/test -main AndroidTextTest $(HXMC_ARGS) -D hxmc.target=$(ANDROID_TARGET) -D hxmc.android-package=org.hxmc.texttest)
	$(call hxmc,bin/android/$(ANDROID_TARGET)/AndroidTouchTest.apk,$(UI_CP) -cp packages/os/test -main AndroidTouchTest $(HXMC_ARGS) -D hxmc.target=$(ANDROID_TARGET) -D hxmc.android-package=org.hxmc.touchtest)
# their structure without a device (hxmc/test/ApkCheck.hx: zip, manifest, ELF, signature, classes.dex; zipalign, aapt, apksigner, dexdump when there)
android-check: android-programs
	ulimit -s unlimited 2>/dev/null || true; $(TOOL) -cp hxmc/test -cp haxe/test -cp hxmc/src --run ApkCheck $(foreach a,AndroidTest Cube AndroidNativeTest AndroidMixTest AndroidTextTest AndroidTouchTest,bin/android/$(ANDROID_TARGET)/$(a).apk)
# shared libraries of the glibc mode loaded by an hxmc program (hxmc/test/SharedCheck.hx), Android's built
shared-check: $(TOOL) $(STD) $(HOST_RT)
	$(SCRIPT) SharedCheck
# the Android tests on the device or emulator adb reaches (packages/gfx/test/android.sh, packages/ui/test/android-native.sh, android-mix.sh)
android-device-check: android-programs
	sh packages/gfx/test/android.sh bin/android/$(ANDROID_TARGET)/AndroidTest.apk bin/android/$(ANDROID_TARGET)
	sh packages/ui/test/android-native.sh bin/android/$(ANDROID_TARGET)/AndroidNativeTest.apk bin/android/$(ANDROID_TARGET)
	sh packages/ui/test/android-mix.sh bin/android/$(ANDROID_TARGET)/AndroidMixTest.apk bin/android/$(ANDROID_TARGET)/AndroidTextTest.apk bin/android/$(ANDROID_TARGET)
	sh packages/os/test/android-touch.sh bin/android/$(ANDROID_TARGET)/AndroidTouchTest.apk bin/android/$(ANDROID_TARGET)

# iOS: app bundles written by hxmc (hxmc/src/hxmc/ios/Bundle.hx), IosTest
# (packages/gfx/test/IosTest.hx) and the cube example (also as an .ipa);
# SimTap (packages/gfx/test/SimTap.hx), a macOS program that taps the
# simulator for ios.sh
# (hxmc dev's host: DevHostTest as the app and as dylibs of later versions, ios-dev.sh)
IOS_DEV := -D hxmc.dev -D hxmc.dev-host -D hxmc.exports=hxmc_dev_run,hxmc_dev_state
ios-programs: $(TOOL) $(STD) $(HOST_RT)
	$(call hxmc,bin/ios/$(IOS_TARGET)/IosTest.app,$(GFX_CP) -main IosTest $(HXMC_ARGS) -D hxmc.target=$(IOS_TARGET) -D hxmc.ios-bundle-id=org.hxmc.gfxtest)
	$(call hxmc,bin/ios/$(IOS_TARGET)/Cube.app,$(GFX_CP) -main Cube $(HXMC_ARGS) -D hxmc.target=$(IOS_TARGET) -D hxmc.ios-bundle-id=org.hxmc.cube)
	$(call hxmc,bin/ios/$(IOS_TARGET)/Cube.ipa,$(GFX_CP) -main Cube $(HXMC_ARGS) -D hxmc.target=$(IOS_TARGET) -D hxmc.ios-bundle-id=org.hxmc.cube)
	$(call hxmc,bin/ios/SimTap,-cp packages/os/src -cp packages/gfx/test -main SimTap $(HXMC_ARGS) -D hxmc.target=macos-arm64)
	$(call hxmc,bin/ios/$(IOS_TARGET)/DevHostTest.app,$(GFX_CP) -main DevHostTest $(HXMC_ARGS) -D hxmc.target=$(IOS_TARGET) -D hxmc.ios-bundle-id=org.hxmc.devhosttest $(IOS_DEV) -D devhost_version=1)
	$(call hxmc,bin/ios/$(IOS_TARGET)/DevHost2.dylib,$(GFX_CP) -main DevHostTest $(HXMC_ARGS) -D hxmc.target=$(IOS_TARGET) $(IOS_DEV) -D hxmc.shared -D devhost_version=2)
	$(call hxmc,bin/ios/$(IOS_TARGET)/DevHost3.dylib,$(GFX_CP) -main DevHostTest $(HXMC_ARGS) -D hxmc.target=$(IOS_TARGET) $(IOS_DEV) -D hxmc.shared -D devhost_version=3)
# their structure without a Mac (hxmc/test/IosCheck.hx: bundle, Info.plist, Mach-O, code signature; llvm-objdump when there)
ios-check: ios-programs
	ulimit -s unlimited 2>/dev/null || true; $(TOOL) -cp hxmc/test -cp haxe/test -cp hxmc/src --run IosCheck $(foreach a,IosTest.app Cube.app Cube.ipa,bin/ios/$(IOS_TARGET)/$(a))
# IosTest on an iPhone simulator (packages/gfx/test/ios.sh: a Mac with Xcode)
ios-sim-check:
	$(MAKE) --no-print-directory ios-programs IOS_TARGET=ios-sim-arm64
	sh packages/gfx/test/ios.sh bin/ios/ios-sim-arm64/IosTest.app bin/ios/ios-sim-arm64 bin/ios/SimTap
	sh packages/gfx/test/ios-dev.sh bin/ios/ios-sim-arm64 bin/ios/ios-sim-arm64

gfx-web-check: $(TOOL) $(STD)
	$(call hxmc,bin/gfx/WebTest.wasm,$(GFX_CP) -main WebTest $(HXMC_ARGS) -D hxmc.target=wasm32-wasi)
	$(NODE) packages/gfx/test/web.mjs bin/gfx/WebTest.wasm bin/gfx
	$(call hxmc,bin/gfx/gc/WebTest.wasm,$(GFX_CP) -main WebTest $(HXMC_ARGS) -D hxmc.target=wasm32-wasi -D hxmc.wasm-gc)
	$(NODE) packages/gfx/test/web.mjs bin/gfx/gc/WebTest.wasm bin/gfx/gc

# the module cache across a WasmGC and a native build on one store
# (hxmc/src/hxmc/ModuleCache.hx: a module restored with the variant typed
# for the build's defines also where only its dependencies read them, as
# GLBackend, which inlines BytesPtr's -D hxmc.wasm-gc functions and calls
# GL's functions made for the target; one a restored module's HXB names
# checked before it is decoded): WebTest with -D hxmc.wasm-gc, GfxTest
# natively, then each again from the store (restored whole), then each with
# a define nothing reads (another signature: no variant typed with the
# build's defines, the modules that depend on the target typed again); each
# linked, the same as the first of its kind, then run (web.mjs's triangle,
# check.sh's headless triangle)
GFX_CACHE_DIR := bin/gfx/cache
gfx-cache-check: $(TOOL) $(STD) $(HOST_RT)
	rm -rf $(GFX_CACHE_DIR); mkdir -p $(GFX_CACHE_DIR)
	@set -e; ulimit -s unlimited 2>/dev/null || true; export HXMC_CACHE=$(abspath $(GFX_CACHE_DIR))/store HXMC_STATS=1; \
	for i in 1 2 3 4 5 6; do \
		case $$i in 1|3|5) o=$(GFX_CACHE_DIR)/WebTest$$i.wasm; a="-main WebTest -D hxmc.target=wasm32-wasi -D hxmc.wasm-gc";; \
		*) o=$(GFX_CACHE_DIR)/GfxTest$$i$(call EXE,$(GFX_TARGET)); a="-main GfxTest $(GFX_ARGS)";; esac; \
		case $$i in 5|6) a="$$a -D gfx_cache_check";; esac; \
		echo "$(TOOL) $$o $$a"; \
		$(TOOL) $$o $(GFX_CP) $(HXMC_ARGS) $$a > $$o.log 2>&1 || { cat $$o.log; exit 1; }; \
		grep "module cache: .* checked" $$o.log; \
	done; \
	for l in WebTest3.wasm GfxTest4$(call EXE,$(GFX_TARGET)); do grep -q " 0 typed from source," $(GFX_CACHE_DIR)/$$l.log || { echo "gfx-cache-check: $$l not restored whole"; exit 1; }; done
	for i in 3 5; do cmp $(GFX_CACHE_DIR)/WebTest1.wasm $(GFX_CACHE_DIR)/WebTest$$i.wasm || exit 1; done
	for i in 4 6; do cmp $(GFX_CACHE_DIR)/GfxTest2$(call EXE,$(GFX_TARGET)) $(GFX_CACHE_DIR)/GfxTest$$i$(call EXE,$(GFX_TARGET)) || exit 1; done
	SCENES=triangle $(NODE) packages/gfx/test/web.mjs $(GFX_CACHE_DIR)/WebTest3.wasm $(GFX_CACHE_DIR)
	LIBGL_ALWAYS_SOFTWARE=1 env -u DISPLAY $(GFX_CACHE_DIR)/GfxTest4 headless triangle packages/gfx/test/triangle.png $(GFX_CACHE_DIR)/triangle-headless.png

# packages/os's audio (Linux: the glibc mode, which loads libasound.so.2)
OS_CP := -cp packages/os/src -cp packages/os/examples -cp packages/os/test
AUDIO_ARGS = $(if $(filter linux-%,$(AUDIO_TARGET)),-D hxmc.libc=glibc) -D hxmc.target=$(AUDIO_TARGET)
audio-programs: $(TOOL) $(STD) $(HOST_RT)
	$(call hxmc,bin/audio/$(AUDIO_TARGET)/AudioTest$(call EXE,$(AUDIO_TARGET)),$(OS_CP) -main AudioTest $(HXMC_ARGS) $(AUDIO_ARGS))
	$(call hxmc,bin/audio/$(AUDIO_TARGET)/Tone$(call EXE,$(AUDIO_TARGET)),$(OS_CP) -main Tone $(HXMC_ARGS) $(AUDIO_ARGS))
audio-check: audio-programs
	sh packages/os/test/audio.sh bin/audio/$(AUDIO_TARGET)

# packages/os's touch gesture (TouchDrag: Android's and iOS's), natively on this host
touch-check: $(TOOL) $(STD) $(HOST_RT)
	$(call hxmc,bin/os/TouchDragTest,$(OS_CP) -main TouchDragTest $(HXMC_ARGS) $(if $(filter linux-%,$(HOST)),-D hxmc.libc=glibc))
	bin/os/TouchDragTest

audio-web-check: $(TOOL) $(STD)
	$(call hxmc,bin/audio/AudioTest.wasm,$(OS_CP) -main AudioTest $(HXMC_ARGS) -D hxmc.target=wasm32-wasi)
	$(NODE) packages/os/test/web.mjs bin/audio/AudioTest.wasm

gfx-shader-check: $(TOOL)
	ulimit -s unlimited 2>/dev/null || true; $(TOOL) -cp packages/gfx/src -cp packages/gfx/examples -cp packages/gfx/test --run ShaderTest $(TOOL) $(if $(BLESS),--bless)

# (two renderers: TestRenderer, OtherRenderer; JavaScript compiled by the port)
VIEW_CP := -cp packages/view/src -cp packages/view/test -D hxmc.view.renderer=TestRenderer -D hxmc.view.renderer.other=OtherRenderer
view-check: $(TOOL) $(STD) $(HOST_RT) $(PORT_BIN)
	ulimit -s unlimited 2>/dev/null || true; $(TOOL) $(VIEW_CP) --run ViewTest $(TOOL)
	$(call hxmc,bin/view/ViewTest,$(VIEW_CP) -main ViewTest $(HXMC_ARGS))
	bin/view/ViewTest
	ulimit -s unlimited 2>/dev/null || true; $(PORT_BIN) $(VIEW_CP) -main ViewTest -js bin/view/ViewTest.js
	$(NODE) bin/view/ViewTest.js

# (packages/web: the static renderer on Eval and natively; the demo page rendered on Eval, its
# islands compiled to JavaScript by the port, lab.wasm and gfx's cube for wasm32-wasi)
WEB_CP := -cp packages/view/src -cp packages/web/src -cp packages/web/test -cp packages/web/examples
WEB_STATIC := $(WEB_CP) -D hxmc.view.renderer.html=hxmc.web.StaticRenderer
WEB_DOM := $(WEB_CP) -D hxmc.view.renderer.dom=hxmc.web.DomRenderer
web-check: $(TOOL) $(STD) $(HOST_RT) $(PORT_BIN)
	ulimit -s unlimited 2>/dev/null || true; $(TOOL) $(WEB_STATIC) --run StaticTest
	$(call hxmc,bin/web/StaticTest,$(WEB_STATIC) -main StaticTest $(HXMC_ARGS))
	bin/web/StaticTest
	rm -rf bin/web/demo
	ulimit -s unlimited 2>/dev/null || true; $(TOOL) $(WEB_STATIC) --run DemoPage bin/web/demo
	$(PORT_BIN) $(WEB_DOM) -D hxmc.view.renderer.html=hxmc.web.StaticRenderer -main DomTest -debug -js bin/web/domtest.js
	$(PORT_BIN) $(WEB_DOM) -main DemoBundle -dce full -debug -js bin/web/demo/islands.js
	$(PORT_BIN) $(WEB_DOM) -main Counter -dce full -D js-es=6 -D analyzer-optimize -js bin/web/demo/counter.js
	$(call hxmc,bin/web/demo/lab.wasm,-cp packages/web/src -cp packages/web/examples -main Lab $(HXMC_ARGS) -D hxmc.target=wasm32-wasi)
	$(call hxmc,bin/web/demo/cube.wasm,$(GFX_CP) -main Cube $(HXMC_ARGS) -D hxmc.target=wasm32-wasi)
	rm -rf bin/web/demo/*.hxmc bin/web/demo/*.log
	$(NODE) packages/web/test/web.mjs bin/web

# (the DOM's widgets: the theme's CSS on Eval, the examples compiled to JavaScript by the port, driven in Chromium)
web-widgets: $(TOOL) $(PORT_BIN)
	@mkdir -p bin/web/widgets
	ulimit -s unlimited 2>/dev/null || true; $(TOOL) -cp packages/ui/tools -cp packages/web/test --run WidgetParity packages/ui/src/hxmc/ui/widgets/Widgets.hx packages/web/src/hxmc/web/widgets/Widgets.hx
	ulimit -s unlimited 2>/dev/null || true; $(TOOL) -cp packages/ui/src -cp packages/theme/src --run hxmc.theme.Css shadcn.json bin/web/widgets/shadcn.css
	ulimit -s unlimited 2>/dev/null || true; $(TOOL) -cp packages/ui/src -cp packages/theme/src --run hxmc.theme.Css shadcn.json bin/web/widgets/shadcn-scoped.css .hxmc
	for m in counter:WidgetCounter form:WidgetForm gallery:WidgetGallery; do \
		ulimit -s unlimited 2>/dev/null || true; $(PORT_BIN) $(DOM_CP) -cp packages/web/examples -main $${m#*:} -dce full -D js-es=6 -D analyzer-optimize -js bin/web/widgets/$${m%%:*}.js || exit 1; \
		printf '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>%s</title><link rel="stylesheet" href="shadcn.css"></head><body><script src="%s.js"></script></body></html>\n' $${m#*:} $${m%%:*} > bin/web/widgets/$${m%%:*}.html; \
	done
	$(NODE) packages/web/test/widgets.mjs bin/web/widgets

text-check: $(TOOL)
	ulimit -s unlimited 2>/dev/null || true; $(TOOL) -cp packages/text/src -cp packages/text/test -cp packages/gfx/test --run TextTest $(if $(BLESS),--bless)

# (hxmc.view and its renderer for hxmc.ui, as -lib hxmc.ui sets it: packages/ui/extraParams.hxml)
UI_VIEW := -cp packages/view/src -D hxmc.view.renderer.ui=hxmc.ui.view.NodeRenderer
ui-check: $(TOOL)
	ulimit -s unlimited 2>/dev/null || true; $(TOOL) -cp packages/text/src -cp packages/ui/src -cp packages/ui/test --run UiTest
	ulimit -s unlimited 2>/dev/null || true; $(TOOL) $(UI_VIEW) -cp packages/text/src -cp packages/ui/src -cp packages/ui/test -cp packages/ui/examples --run MarkupTest
	ulimit -s unlimited 2>/dev/null || true; $(TOOL) $(UI_VIEW) -cp packages/text/src -cp packages/ui/src -cp packages/ui/test -cp packages/ui/examples --run GuideTest
	ulimit -s unlimited 2>/dev/null || true; $(TOOL) $(UI_VIEW) -cp packages/text/src -cp packages/ui/src -cp packages/theme/src -cp packages/ui/test -cp packages/ui/tools -cp packages/ui/examples/widgets --run WidgetExamplesTest
	mkdir -p bin/ui; ulimit -s unlimited 2>/dev/null || true; $(TOOL) -cp packages/ui/tools --run WidgetDocs packages/ui/src/hxmc/ui/widgets/Widgets.hx packages/ui/examples/widgets bin/ui/widgets.json

# random flex trees against Chromium (Playwright): a tool, not a lane
ui-layout-fuzz: $(TOOL)
	node packages/ui/test/layout-fuzz.mjs $(or $(SEED),1) $(or $(COUNT),200) bin/ui/fuzz $(FEATURES)
	ulimit -s unlimited 2>/dev/null || true; $(TOOL) -cp packages/text/src -cp packages/ui/src -cp packages/ui/test --run LayoutFuzz bin/ui/fuzz

ui-layout-reduce: $(TOOL)
	node packages/ui/test/layout-reduce.mjs bin/ui/fuzz/layout-cases.json '$(CASE)' bin/ui/reduce

theme-check: $(TOOL)
	ulimit -s unlimited 2>/dev/null || true; $(TOOL) -cp packages/ui/src -cp packages/theme/src -cp packages/theme/test --run ThemeTest $(TOOL)
	ulimit -s unlimited 2>/dev/null || true; $(TOOL) -cp packages/ui/src -cp packages/theme/src -cp packages/theme/test --run CssTest

# (the theme's CSS on Eval, the DOM's widgets compiled to JavaScript by the port, in Chromium)
DOM_CP := -cp packages/view/src -cp packages/web/src -cp packages/text/src -cp packages/ui/src -D hxmc.view.renderer.dom=hxmc.web.DomRenderer
theme-dom-check: $(TOOL) $(PORT_BIN)
	@mkdir -p bin/theme/dom
	ulimit -s unlimited 2>/dev/null || true; $(TOOL) -cp packages/ui/src -cp packages/theme/src --run hxmc.theme.Css shadcn.json bin/theme/dom/shadcn.css
	ulimit -s unlimited 2>/dev/null || true; $(PORT_BIN) $(DOM_CP) -cp packages/theme/src -cp packages/theme/test -main DomFidelity -dce full -D js-es=6 -js bin/theme/dom/domfidelity.js
	$(NODE) packages/theme/test/dom-fidelity.mjs bin/theme/dom bin/theme/dom/out

theme-fidelity-check: $(TOOL) $(STD) $(HOST_RT)
	$(call hxmc,bin/theme/$(GFX_TARGET)/FidelityTest$(call EXE,$(GFX_TARGET)),$(UI_CP) -cp packages/theme/test -main FidelityTest $(HXMC_ARGS) $(GFX_ARGS))
	mkdir -p bin/theme/out && LIBGL_ALWAYS_SOFTWARE=1 env -u DISPLAY bin/theme/$(GFX_TARGET)/FidelityTest packages/theme/test/ref bin/theme/out

UI_CP := -cp packages/os/src -cp packages/gfx/src -cp packages/gfx/test -cp packages/text/src $(UI_VIEW) -cp packages/ui/src -cp packages/theme/src -cp packages/ui/test -cp packages/ui/examples
ui-programs: $(TOOL) $(STD) $(HOST_RT)
	$(call hxmc,bin/ui/$(GFX_TARGET)/UiDrawTest$(call EXE,$(GFX_TARGET)),$(UI_CP) -main UiDrawTest $(HXMC_ARGS) $(GFX_ARGS))
	$(call hxmc,bin/ui/$(GFX_TARGET)/TodoTest$(call EXE,$(GFX_TARGET)),$(UI_CP) -main TodoTest $(HXMC_ARGS) $(GFX_ARGS))
	$(call hxmc,bin/ui/$(GFX_TARGET)/GalleryTest$(call EXE,$(GFX_TARGET)),$(UI_CP) -main GalleryTest $(HXMC_ARGS) $(GFX_ARGS))
	$(call hxmc,bin/ui/$(GFX_TARGET)/StressTest$(call EXE,$(GFX_TARGET)),$(UI_CP) -main StressTest $(HXMC_ARGS) $(GFX_ARGS))
	$(call hxmc,bin/ui/$(GFX_TARGET)/ClipboardTest$(call EXE,$(GFX_TARGET)),$(UI_CP) -main ClipboardTest $(HXMC_ARGS) $(GFX_ARGS))
	$(call hxmc,bin/ui/$(GFX_TARGET)/NativeTest$(call EXE,$(GFX_TARGET)),$(UI_CP) -main NativeTest $(HXMC_ARGS) $(GFX_ARGS))
	$(call hxmc,bin/ui/$(GFX_TARGET)/EmojiTest$(call EXE,$(GFX_TARGET)),$(UI_CP) -main EmojiTest $(HXMC_ARGS) $(GFX_ARGS))
	$(call hxmc,bin/ui/$(GFX_TARGET)/BoxTest$(call EXE,$(GFX_TARGET)),$(UI_CP) -main BoxTest $(HXMC_ARGS) $(GFX_ARGS))
	$(call hxmc,bin/ui/$(GFX_TARGET)/WindowTest$(call EXE,$(GFX_TARGET)),$(UI_CP) -main WindowTest $(HXMC_ARGS) $(GFX_ARGS))
	$(if $(filter linux-%,$(GFX_TARGET)),$(call hxmc,bin/ui/$(GFX_TARGET)/TextInputTest,$(UI_CP) -main TextInputTest $(HXMC_ARGS) $(GFX_ARGS)))
	$(if $(filter linux-%,$(GFX_TARGET)),$(call hxmc,bin/ui/$(GFX_TARGET)/LinuxAccessTest,$(UI_CP) -main LinuxAccessTest $(HXMC_ARGS) $(GFX_ARGS)))
	$(if $(filter linux-%,$(GFX_TARGET)),$(call hxmc,bin/ui/$(GFX_TARGET)/AtspiProbe,$(UI_CP) -main AtspiProbe $(HXMC_ARGS) $(GFX_ARGS)))
	$(if $(filter windows-%,$(GFX_TARGET)),$(call hxmc,bin/ui/$(GFX_TARGET)/WinAccessTest.exe,$(UI_CP) -main WinAccessTest $(HXMC_ARGS) $(GFX_ARGS)))
ui-draw-check: ui-programs
	LIBGL_ALWAYS_SOFTWARE=1 env -u DISPLAY bin/ui/$(GFX_TARGET)/UiDrawTest packages/ui/test/draw.png bin/ui/$(GFX_TARGET)/draw.png $(if $(BLESS),--bless)
	LIBGL_ALWAYS_SOFTWARE=1 xvfb-run -a -s "-screen 0 640x480x24" bin/ui/$(GFX_TARGET)/UiDrawTest packages/ui/test/draw.png bin/ui/$(GFX_TARGET)/window.png --window
	LIBGL_ALWAYS_SOFTWARE=1 env -u DISPLAY bin/ui/$(GFX_TARGET)/TodoTest packages/ui/test/todo.png bin/ui/$(GFX_TARGET)/todo.png $(if $(BLESS),--bless)
	LIBGL_ALWAYS_SOFTWARE=1 env -u DISPLAY bin/ui/$(GFX_TARGET)/GalleryTest packages/ui/test/gallery.png bin/ui/$(GFX_TARGET)/gallery.png $(if $(BLESS),--bless)
	LIBGL_ALWAYS_SOFTWARE=1 env -u DISPLAY bin/ui/$(GFX_TARGET)/GalleryTest packages/ui/test/gallery-dark.png bin/ui/$(GFX_TARGET)/gallery-dark.png --dark $(if $(BLESS),--bless)
	LIBGL_ALWAYS_SOFTWARE=1 env -u DISPLAY bin/ui/$(GFX_TARGET)/GalleryTest packages/ui/test/gallery-rtl.png bin/ui/$(GFX_TARGET)/gallery-rtl.png --rtl $(if $(BLESS),--bless)
	LIBGL_ALWAYS_SOFTWARE=1 env -u DISPLAY bin/ui/$(GFX_TARGET)/GalleryTest packages/ui/test/gallery-unstyled.png bin/ui/$(GFX_TARGET)/gallery-unstyled.png --unstyled $(if $(BLESS),--bless)
	LIBGL_ALWAYS_SOFTWARE=1 env -u DISPLAY bin/ui/$(GFX_TARGET)/StressTest
	LIBGL_ALWAYS_SOFTWARE=1 env -u DISPLAY bin/ui/$(GFX_TARGET)/EmojiTest packages/ui/test/emoji.png bin/ui/$(GFX_TARGET)/emoji.png
	LIBGL_ALWAYS_SOFTWARE=1 env -u DISPLAY bin/ui/$(GFX_TARGET)/BoxTest packages/ui/test/boxes.png bin/ui/$(GFX_TARGET)/boxes.png
	xvfb-run -a -s "-screen 0 640x480x24" bin/ui/$(GFX_TARGET)/ClipboardTest
	xvfb-run -a -s "-screen 0 640x480x24" bin/ui/$(GFX_TARGET)/TextInputTest
	xvfb-run -a -s "-screen 0 640x480x24" bin/ui/$(GFX_TARGET)/WindowTest
	# (AT-SPI: the window's tree read by another process through libatspi, in a D-Bus session)
	LIBGL_ALWAYS_SOFTWARE=1 xvfb-run -a -s "-screen 0 640x480x24" dbus-run-session -- sh -c 'bin/ui/$(GFX_TARGET)/LinuxAccessTest & p=$$!; bin/ui/$(GFX_TARGET)/AtspiProbe; s=$$?; wait $$p && exit $$s'
	xvfb-run -a -s "-screen 0 640x480x24" bin/ui/$(GFX_TARGET)/NativeTest bin/ui/$(GFX_TARGET)/native.png

ui-web-check: $(TOOL) $(STD)
	$(call hxmc,bin/ui/WebTodo.wasm,$(UI_CP) -main WebTodo $(HXMC_ARGS) -D hxmc.target=wasm32-wasi)
	$(NODE) packages/ui/test/web.mjs bin/ui/WebTodo.wasm bin/ui
	$(call hxmc,bin/ui/NativeForm.wasm,$(UI_CP) -main NativeForm $(HXMC_ARGS) -D hxmc.target=wasm32-wasi)
	$(NODE) packages/ui/test/native-web.mjs bin/ui/NativeForm.wasm bin/ui
	$(call hxmc,bin/ui/WebField.wasm,$(UI_CP) -main WebField $(HXMC_ARGS) -D hxmc.target=wasm32-wasi)
	$(NODE) packages/ui/test/web-field.mjs bin/ui/WebField.wasm
	$(call hxmc,bin/ui/gc/WebTodo.wasm,$(UI_CP) -main WebTodo $(HXMC_ARGS) -D hxmc.target=wasm32-wasi -D hxmc.wasm-gc)
	$(NODE) packages/ui/test/web.mjs bin/ui/gc/WebTodo.wasm bin/ui/gc
	$(call hxmc,bin/ui/gc/NativeForm.wasm,$(UI_CP) -main NativeForm $(HXMC_ARGS) -D hxmc.target=wasm32-wasi -D hxmc.wasm-gc)
	$(NODE) packages/ui/test/native-web.mjs bin/ui/gc/NativeForm.wasm bin/ui/gc
	$(call hxmc,bin/ui/gc/WebField.wasm,$(UI_CP) -main WebField $(HXMC_ARGS) -D hxmc.target=wasm32-wasi -D hxmc.wasm-gc)
	$(NODE) packages/ui/test/web-field.mjs bin/ui/gc/WebField.wasm
# (the dev loop: each program run twice, the second from the first's snapshot)
DEV_OS_CP := -cp packages/os/src -cp packages/os/test
DEV_VIEW_CP := -cp packages/os/src -cp packages/view/src -cp packages/view/test -D hxmc.view.renderer=TestRenderer
dev-check: $(TOOL) $(STD) $(HOST_RT)
	$(call hxmc,bin/dev/HotTest,$(DEV_OS_CP) -main HotTest $(HXMC_ARGS) -D hxmc.dev)
	$(call hxmc,bin/dev/HotTestChanged,$(DEV_OS_CP) -main HotTest $(HXMC_ARGS) -D hxmc.dev -D hot_changed)
	bin/dev/HotTest save bin/dev/hot.snapshot
	HXMC_DEV_SNAPSHOT=bin/dev/hot.snapshot bin/dev/HotTest restore -
	HXMC_DEV_SNAPSHOT=bin/dev/hot.snapshot bin/dev/HotTestChanged restore - > bin/dev/changed.log 2>&1 || { cat bin/dev/changed.log; exit 1; }
	cat bin/dev/changed.log; grep -q "changed reset: its type changed" bin/dev/changed.log
	ulimit -s unlimited 2>/dev/null || true; $(TOOL) $(DEV_OS_CP) -D hxmc.dev --run HotTest save bin/dev/hot-eval.snapshot
	ulimit -s unlimited 2>/dev/null || true; HXMC_DEV_SNAPSHOT=bin/dev/hot-eval.snapshot $(TOOL) $(DEV_OS_CP) -D hxmc.dev --run HotTest restore -
	$(call hxmc,bin/dev/RefreshTest,$(DEV_VIEW_CP) -main RefreshTest $(HXMC_ARGS) -D hxmc.dev)
	bin/dev/RefreshTest save bin/dev/refresh.snapshot
	HXMC_DEV_SNAPSHOT=bin/dev/refresh.snapshot bin/dev/RefreshTest restore -
	$(call hxmc,bin/dev/RefreshTestChanged,$(DEV_VIEW_CP) -main RefreshTest $(HXMC_ARGS) -D hxmc.dev -D refresh_changed)
	HXMC_DEV_SNAPSHOT=bin/dev/refresh.snapshot bin/dev/RefreshTestChanged restore - > bin/dev/refresh-changed.log 2>&1 || { cat bin/dev/refresh-changed.log; exit 1; }
	cat bin/dev/refresh-changed.log; grep -q "main.tuned reset: its initial value changed" bin/dev/refresh-changed.log
	ulimit -s unlimited 2>/dev/null || true; $(TOOL) $(DEV_VIEW_CP) -D hxmc.dev --run RefreshTest save bin/dev/refresh-eval.snapshot
	ulimit -s unlimited 2>/dev/null || true; HXMC_DEV_SNAPSHOT=bin/dev/refresh-eval.snapshot $(TOOL) $(DEV_VIEW_CP) -D hxmc.dev --run RefreshTest restore -
	ulimit -s unlimited 2>/dev/null || true; $(NODE) packages/os/test/dev/dev-web.mjs $(TOOL) bin/dev/web
	ulimit -s unlimited 2>/dev/null || true; $(NODE) packages/os/test/dev/dev-web.mjs $(TOOL) bin/dev/web-gc --wasm-gc
	ulimit -s unlimited 2>/dev/null || true; $(if $(filter linux-%,$(HOST)),xvfb-run -a -s "-screen 0 640x480x24") $(NODE) packages/os/test/dev/dev-native.mjs $(TOOL) bin/dev/native
	ulimit -s unlimited 2>/dev/null || true; $(NODE) packages/os/test/dev/server-verify.mjs $(TOOL)
	ulimit -s unlimited 2>/dev/null || true; $(NODE) packages/os/test/dev/dev-verify.mjs $(TOOL) Counter web

# (each macro class compiled in a child of bin/jit/haxe; the engine's report in each
# case's port.log)
MACROS ?= verify
native-macros: $(TOOL) $(STD) $(HOST_RT) $(REFERENCE)
	$(call hxmc,bin/jit/haxe,$(PKG_ARGS) -D hxmc.jit)
	export HXMC_STD=$(abspath bin/hxmc/std) HXMC_RT_DIR=$(abspath bin/hxmc/rt) HAXE_REFERENCE=$(abspath $(REFERENCE)) HAXE_IN_HAXE_PORT="$(abspath bin/jit/haxe) -D hxmc.macros=$(MACROS)"; $(SCRIPT) Conformance -j $(JOBS) --cases haxe/test/conformance-macro-cases.txt
	@cat bin/test/conformance/*/port.log | grep -h "^hxmc.macros: [0-9]* macro calls" | awk '{c+=$$2; n+=$$5; m+=substr($$7,2); mm+=$$9; e+=$$11} END {print "native macros: " c " calls, " n " native (" m " matched, " mm " mismatched), " e " on Eval"}'

portcheck: $(TOOL) $(STD) $(HOST_RT) $(REFERENCE)
	$(SCRIPT) Selfcheck --local --small

bench: $(TOOL) $(STD) $(HOST_RT) $(PORT_BIN) bin/lix/lix
	$(SCRIPT) Bench $(BENCH_ARGS)

bench-arrays: bin/vector-bench/m
	bin/vector-bench/m $(ARRAY_BENCH_ARGS)

bin/vector-bench/m: $(TOOL) $(STD) $(HOST_RT) hxmc/test/bench/VectorBench.hx hxmc/test/bench/VectorBenchMacro.hx
	$(call hxmc,$@,-cp hxmc/test/bench -main VectorBench $(HXMC_ARGS))

# (the self-compile of PORT_BIN; the npm package's WebAssembly compiler)
measure: $(TOOL) $(STD) $(HOST_RT) $(REFERENCE) $(PORT_BIN) bin/npm/native/wasm32-wasi/haxe.wasm
	$(SCRIPT) Measure --port $(PORT_BIN)

quick: $(TOOL) $(STD) $(HOST_RT)
	$(SCRIPT) Tiers quick $(CASES)

wasmgc-check: $(TOOL) $(STD) $(HOST_RT)
	$(SCRIPT) GcCheck

wasmgc-bench: $(TOOL) $(STD) $(HOST_RT)
	$(SCRIPT) GcCheck --bench

# the port as a WasmGC module (-D hxmc.wasm-gc), and the script that runs it
# under node (hxmc/bootstrap/wasmgc.mjs; a large stack for the compiler's
# recursion): the port of test-wasmgc-port
WASMGC_PORT := bin/wasmgc-port/haxe
wasmgc-port: $(WASMGC_PORT)
$(WASMGC_PORT).wasm: $(TOOL) $(PORT_SRC) $(STD)
	$(call hxmc,$@,$(PORT_ARGS) -D hxmc.target=wasm32-wasi -D hxmc.wasm-gc)
$(WASMGC_PORT): $(WASMGC_PORT).wasm
	printf '#!/bin/sh\n# the port as a WasmGC module under node (make wasmgc-port)\nulimit -s unlimited 2>/dev/null\nexec %s --stack-size=65500 %s %s "$$@"\n' \
		"$(NODE)" $(abspath hxmc/bootstrap/wasmgc.mjs) $(abspath $<) > $@
	chmod +x $@

# the lanes with it as the port (docs/testing.md): HXB (the three lists),
# --interp (but a case whose Eval threads interleave: the module has one
# thread), display, -L (batch), upstream's target suites; not the server's
# (sockets)
WASMGC_ENV = export HAXE_REFERENCE=$(abspath $(REFERENCE)) HAXE_IN_HAXE_PORT=$(abspath $(WASMGC_PORT));
test-wasmgc-port: $(WASMGC_PORT) $(REFERENCE) bin/lix/lix
	$(WASMGC_ENV) $(SCRIPT) Conformance -j $(JOBS) --cases haxe/test/conformance-cases.txt
	$(WASMGC_ENV) $(SCRIPT) Conformance -j $(JOBS) --cases haxe/test/conformance-macro-cases.txt
	$(WASMGC_ENV) $(SCRIPT) Conformance -j $(JOBS) --cases haxe/test/conformance-hxblib-cases.txt --hxb-lib
	$(WASMGC_ENV) $(SCRIPT) Interp -j $(JOBS) --skip eval-eventLoop-compile
	$(WASMGC_ENV) $(SCRIPT) Display -j $(JOBS)
	$(WASMGC_ENV) $(SCRIPT) Haxelib
	$(WASMGC_ENV) $(SCRIPT) UpstreamTargets -j $(JOBS)

check: $(TOOL) $(STD) $(HOST_RT)
	$(SCRIPT) Tiers check $(if $(PORT),--port) $(CASES)

full: $(TOOL) $(STD) $(HOST_RT)
	$(SCRIPT) Tiers full $(CASES)

clean:
	rm -rf bin/port bin/release bin/lix-dist bin/site bin/site-build bin/wasm bin/wasmgc-port bin/fuzz bin/lix bin/npm bin/stage0 bin/test bin/gfx bin/audio bin/corpus \
		bin/hxmc/boot bin/hxmc/fix bin/hxmc-t bin/hxmc-fuzz $(CLI_BOOT)/hxmc-std $(CLI_BOOT)/rt

distclean: clean
	rm -rf bin

# --- Experimental OCaml -> Haxe generation ---
.PHONY: generate ml2hx-test ml2hx-frontend ml2hx-frontend-native port-generated ml2hx-bench

generate: ml2hx-frontend-native
	$(NODE) tools/ml2hx/generate.mjs

ml2hx-frontend:
	$(NODE) tools/ml2hx/build.mjs

ml2hx-frontend-native:
	$(NODE) tools/ml2hx/build-native.mjs

ml2hx-test:
	$(NODE) --test tools/ml2hx/test/generator.test.mjs

port-generated: $(TOOL) $(STD) $(HOST_RT) generate
	$(call hxmc,bin/ml2hx/haxe,-cp bin/ml2hx/generated -main upstream.compiler.HaxeModule -D disable-parallelism $(HXFLAGS) $(HXMC_ARGS))

ml2hx-bench: $(PORT_BIN) port-generated
	$(NODE) tools/ml2hx/bench.mjs
