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
# `make release`: one of the six targets
TARGET ?= $(HOST)
TARGETS := linux-x86_64 linux-arm64 windows-x86_64 windows-arm64 macos-x86_64 macos-arm64
# the runtime objects: the six targets, Linux in the dynamic glibc mode (-D hxmc.libc=glibc), Android
RT_TARGETS := $(TARGETS) linux-x86_64-glibc linux-arm64-glibc android-arm64 android-x86_64
# `make rt-target`: one of RT_TARGETS
RT_TARGET ?= $(HOST)
# `make corpus-stage`: the six targets, wasm32-wasi, wasm32-wasi-legacy, linux-x86_64-glibc, linux-arm64-glibc
CORPUS_TARGETS ?= $(TARGETS) wasm32-wasi wasm32-wasi-legacy linux-x86_64-glibc linux-arm64-glibc
# `make android-check`, `android-device-check`: android-x86_64 or android-arm64
ANDROID_TARGET ?= android-x86_64
# `make ios-check`: ios-sim-arm64 or ios-arm64 (`ios-sim-check`: always the simulator's, on a Mac)
IOS_TARGET ?= ios-sim-arm64
# extra arguments of the port's build (e.g. HXFLAGS="-D retain")
HXFLAGS ?=
# the port the tests check
PORT_BIN ?= bin/port/haxe
# the reference compiler: the nightly build of the pinned upstream commit (`make reference`)
REFERENCE ?= bin/reference/haxe
# `make test`: the lanes, among hxb, macro, hxblib, display, server, jsonrpc,
# interp, haxelib, libs, debugger, targets, unit (TEST_LANES below; default hxb);
# SHARD=i/n splits the debugger lane (EvalDebugger --shard)
LANES ?= hxb
SHARD ?=
# `make test-fuzz`: the lane and the number of programs
LANE ?= diff:hxb
N ?= 200
# `make test`, `test-fuzz`: the compiler whose Eval runs the harnesses (CI:
# EVAL=bin/port/haxe, the job has no tool) and the fuzzer (CI: the Fuzz script
# on that Eval, FUZZ="bin/port/haxe -cp haxe/test/fuzz -cp haxe/test --run Fuzz");
# SUMMARY: a file the harnesses append Markdown results to (CI: the job summary)
EVAL ?= $(TOOL)
FUZZ ?= bin/fuzz/fuzz
SUMMARY ?=
# `quick`, `check`, `full`: the corpus cases to restrict the corpus lanes to
# (CASES="Int64Gc Bench"); PORT=1 adds the port's self-compile to `check`
CASES ?=
PORT ?=
# `make site`: a directory of lix binaries to publish under tools/ (lix-<target>[.exe])
LIX_DIR ?=
# `make site`: a checkout of the bench-data branch (its history.json and
# latest.json become bin/site/bench/, the Programs benchmarks; its targets.json
# replaces site/data/targets.json, the Target generators table)
BENCH_DATA ?=
# `make bench`: the arguments of hxmc/test/Bench.hx (e.g. "-n 3 -c nbody -t hxmc,js")
BENCH_ARGS ?=
# `make bench-compile`: the arguments of hxmc/test/CompileBench.hx (e.g. "-n 5 --build --out site/data/bench.json")
COMPILE_BENCH_ARGS ?=
# `make bench-micro`: which microbenchmarks (arrays, maps; default both)
WHICH ?= arrays maps
# `make bench-micro WHICH=arrays`: length, rounds, samples, optional JSON output
ARRAY_BENCH_ARGS ?=
# `make bench-micro WHICH=maps`: keys, rounds
MAP_BENCH_ARGS ?=
# `make crosshost`: the arguments of hxmc/test/Crosshost.hx (CI splits the targets: "--targets a,b")
CROSSHOST_ARGS ?= --tool

# --- Sources ---

PORT_SRC := $(shell find haxe/src -name '*.hx' 2>/dev/null)
HXMC_SRC := $(shell find hxmc/src -name '*.hx' 2>/dev/null)
# (the directories too: a file deleted changes only its directory's time)
STD_SRC := $(shell find hxmc/std 2>/dev/null)
RT_SRC := $(wildcard hxmc/deps/*)
LIX_SRC := $(shell find tools/lix/src -name '*.hx' 2>/dev/null)
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
# the native compiler for the host (the npm package's: Mir macros and --run, mir-run-check)
HOST_HAXE := bin/npm/native/$(HOST)/haxe

# $(call hxmc,<out>,<args>): a build by the tool, its log next to the output
define hxmc
@mkdir -p $(dir $(1))
ulimit -s unlimited 2>/dev/null || true; $(TOOL) $(1) $(2) > $(1).log 2>&1 || { cat $(1).log; exit 1; }
@ls -l $(1)
endef

.DEFAULT_GOAL := help
.PHONY: help rt rt-build rt-target rt-layouts hxmc bootstrap fixpoint stage0 crosshost port release npm site site-check \
	lix lix-dist reference test test-fuzz test-libraries test-module-cache upstream-suites corpus-stage \
	android-check android-device-check shared-check ios-check ios-sim-check mir-run-check mir-macros-check mir-cache-check dev-check \
	bench bench-compile bench-micro measure wasmgc-check wasmgc-bench quick check full clean distclean

help:
	@sed -n '/^# --- Targets/,$$p' $(MAKEFILE_LIST) | sed -n 's/^## \{0,1\}//p'

# --- Targets ---
## Build
##   hxmc        bin/hxmc/hxmc: the tool, built by the previous tool from source (the first one by the
##               stage0 module under node); bootstrap: from the stage0 only, then the fixpoint
##   port        PORT_BIN (bin/port/haxe): the port for the host, built by hxmc (seconds after an edit)
##   lix         bin/lix/lix (+ haxe, haxelib, neko links): lix (tools/lix) for the host
##   reference   REFERENCE (bin/reference/haxe): the nightly of the pinned upstream commit, by lix
##   stage0      hxmc/bootstrap/stage0.wasm.br: the tool as a wasm32-wasi module, brotli (commit it
##               when the sources need a newer one)
##   rt          the runtime objects (bin/hxmc/rt/<target>/{rt,ssl,uv}.o): the release rt-<hash of
##               hxmc/deps> (hxmc/bootstrap/rt.mjs), else rt-build: zig, mbedtls and libuv (hxmc/deps);
##               rt-target: RT_TARGET's alone, rt-layouts: the committed layouts checked (CI's rt jobs)
##
## Test (docs/testing.md)
##   quick       after every edit of hxmc: the tool, the x64 corpus, again with RT_VERIFY=1, the wasm
##               corpus under node, the module cache's store, the lowering's queries (CASES restricts
##               the corpus)
##   check       before a commit: quick + arm64 (qemu), wine, a 16 KB nursery, legacy exception handling,
##               the glibc mode, ThreadNatives x30, crosshost on three cases, debug info, Android's APKs,
##               iOS's apps, shared libraries; PORT=1 adds the native port's self-compile
##   full        before a push: every nursery, RT_VERIFY, wasmtime, ThreadNatives x300, the port's
##               self-compile natively and as a module, crosshost, the fixpoint (hxmc/test/Tiers.hx)
##   test        the port against the reference, the lanes of LANES (default hxb; CI's conformance jobs):
##               hxb, macro, hxblib (HXB of the three case lists, Conformance; CASES_FILE for hxb),
##               display, server, jsonrpc, interp (--interp runs), haxelib (-L, batch and server),
##               libs (hxmc's -lib resolution against haxelib and lix's haxe shim),
##               debugger (the Eval debugger; SHARD=i/n), targets (upstream's unit suite compiled for
##               each target by both, compared), unit (unit tests of port modules, in-process)
##   test-fuzz   the fuzzer on PORT_BIN: LANE (default diff:hxb), the kept programs, then N programs
##   fixpoint    the tool rebuilds itself byte-identical (the module cache cold, warm and off)
##   crosshost   the tool as a WebAssembly module builds the corpus and itself byte-identical to the
##               native tool (hxmc/test/Crosshost.hx; CROSSHOST_ARGS)
##   upstream-suites  upstream's runtime suites (tests/unit, sys, threads) built by hxmc and run
##               (hxmc/test/UpstreamSuites.hx; SUITES: a subset, SUITES_TARGET=native|wasm32-wasi)
##   test-module-cache  the module cache's gate: the same outputs with and without it, for hxmc and
##               JS (hxmc/test/ModuleCacheCheck.hx; PORT=1 adds the port itself)
##   wasmgc-check  -D hxmc.wasm-gc: hxmc/test/wasmgc's programs and corpus cases as WasmGC modules
##               under node against the native build's output (hxmc/test/GcCheck.hx)
##   dev-check   the dev loop: `hxmc dev` through edits and a compile error, the compilation server's
##               builds against fresh ones (hxmc/test/dev)
##   mir-run-check  --interp and --run on the Mir interpreter inside the compiler (-D hxmc.run=mir,
##               hxmc/src/hxmc/interp/MirRun.hx): bin/npm/native/HOST/haxe, the corpus run in it
##               (each bundle without native code: HXMC_MACRO_STATS; the cases known to fail there:
##               Corpus.MIR_RUN_KNOWN)
##   mir-macros-check  the macro cases with Mir macros (-D hxmc.macros=mir, bin/npm/native/HOST/haxe as for
##               mir-run-check) against the reference (Conformance --target-only --parallel 1;
##               MIR_MACROS_KNOWN: Eval's own packages)
##   mir-cache-check  Mir macros' compiled functions kept across builds (interp/BundleCache.hx): what
##               invalidates them, each build against Eval's macros (hxmc/test/MirCacheCheck.hx)
##   android-check, android-device-check, ios-check, ios-sim-check, shared-check  the targets' apps:
##               the APKs (ANDROID_TARGET) checked and run by adb, the iOS apps (IOS_TARGET) checked and
##               run on a simulator (a Mac), shared libraries of the glibc mode
##   corpus-stage, test-libraries  CI's: the corpus cross-built for CORPUS_TARGETS (bin/corpus),
##               -lib (lix's scopes, node_modules, haxelib) with the npm package's compiler
##
## Bench (docs/testing.md, "Benchmarks")
##   bench       the HaxeBenchmarks cases on hxmc, C++, JVM, JS, HL/C and HL (hxmc/test/Bench.hx; BENCH_ARGS)
##   bench-compile  the port against the reference compiling hello, stdlib and itself to HXB
##               (hxmc/test/CompileBench.hx; COMPILE_BENCH_ARGS)
##   bench-micro WHICH=arrays|maps (default both): Array vs NativeArray vs Vector (ARRAY_BENCH_ARGS),
##               ObjectMap and StringMap (MAP_BENCH_ARGS)
##   measure     peak memory and time of the self-compile (ours, the reference) and of the tool's
##               builds (haxe/test/Measure.hx)
##   wasmgc-bench  wasmgc-check's programs as WasmGC, linear-memory wasm and native: times, peak RSS, sizes
##
## Site & release
##   site        bin/site: the website (site/; LIX_DIR's lix binaries, BENCH_DATA's benchmark history)
##   site-check  bin/site in headless browsers (site/tools/browser-test.mjs; Playwright; BROWSERS)
##   release     bin/release/TARGET/haxe[.exe]: the port cross-built by hxmc, with mbedtls and libuv
##   lix-dist    bin/lix-dist/lix-<target>[.exe]: lix for the six targets (the release, the site's tools/)
##   npm         bin/npm/*.tgz: the npm packages of packages/ (packages/pack.mjs; NPM_VERSION)
##
## Dev
##   clean       remove the build outputs (keeps the tool, the runtime objects and the reference)
##   distclean   also remove bin/ entirely
##
## Variables: JOBS, NODE, ZIG, HOST, TARGET, RT_TARGET, ANDROID_TARGET, IOS_TARGET, HXFLAGS, PORT_BIN, REFERENCE,
## LANES, SHARD, LANE, N, EVAL, FUZZ, SUMMARY, CASES, PORT, LIX_DIR, BENCH_DATA, BENCH_ARGS, COMPILE_BENCH_ARGS,
## WHICH, ARRAY_BENCH_ARGS, MAP_BENCH_ARGS, CROSSHOST_ARGS, CORPUS_TARGETS (defaults and meaning: the top of the Makefile).

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
hxmc: $(TOOL)
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

port: $(PORT_BIN)
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

# @hxmc/target's std (packages/target/std): hxmc's merged std; the runtime
# objects' packages (@hxmc/rt-<target>) are packed from bin/hxmc/rt
TARGET_STD := packages/target/std
NPM_GEN := $(TARGET_STD)/.stamp $(HOST_RT)
$(TARGET_STD)/.stamp: hxmc/src/hxmc/MkStd.hx $(STD_SRC)
	$(RUN) -cp hxmc/src --run hxmc.MkStd hxmc/std haxe/upstream/std $(TARGET_STD)
# the compilers: native for the platform packages (@hxmc/haxe-<os>-<cpu>), with
# every generator as a wasm32-wasi module (@hxmc/haxe-wasm)
NPM_NATIVES := $(foreach t,$(TARGETS),bin/npm/native/$(t)/haxe$(call EXE,$(t))) bin/npm/native/wasm32-wasi/haxe.wasm
bin/npm/native/wasm32-wasi/haxe.wasm: $(TOOL) $(PORT_SRC) $(HXMC_SRC) $(STD)
	$(call hxmc,$@,$(PKG_ARGS) -D hxmc.target=wasm32-wasi)
bin/npm/native/%/haxe: $(TOOL) $(PORT_SRC) $(HXMC_SRC) $(STD) $(HOST_RT)
	$(call hxmc,$@,$(PKG_ARGS) -D hxmc.target=$*)
bin/npm/native/%/haxe.exe: $(TOOL) $(PORT_SRC) $(HXMC_SRC) $(STD) $(HOST_RT)
	$(call hxmc,$@,$(PKG_ARGS) -D hxmc.target=$*)
# NPM_VERSION: the version of all the packages (default packages/cli/package.json's)
NPM_VERSION ?= $(shell $(NODE) -p "require('./packages/cli/package.json').version")
npm: $(NPM_GEN) $(NPM_NATIVES)
	rm -f bin/npm/*.tgz
	$(NODE) packages/pack.mjs $(NPM_VERSION) bin/npm/native bin/npm
	@ls -l bin/npm/*.tgz

# --- The website (site/) ---

# Plain pages (site/*.html: About, Benchmarks, Playground) with the stylesheet,
# their scripts (site/client, compiled by the port: site/build.hxml), the
# playground's compiler (bin/wasm) and examples, the std subset its compiler
# reads (site/tools/MkBundle.hx), the measured results (site/data), lix under
# tools/ (LIX_DIR), the benchmark histories (BENCH_DATA: the programs', the
# compiler's, the target generators') and the build facts
# (build-info.json). The site's build in the addresses of the files its pages
# fetch (Version.hx, and the pages' scripts and stylesheet): a deploy reaches
# browsers at once.
mb = awk '{printf "%.1f MB", $$1 / 1048576}'
SITE_VERSION ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo dev)
site: wasm $(TOOL) $(STD) $(PORT_BIN)
	rm -rf bin/site && mkdir -p bin/site
	for f in site/*.html; do sed -e 's/\(src\|href\)="\([a-z]*\.\(js\|css\)\)"/\1="\2?v=$(SITE_VERSION)"/g' $$f > bin/site/$${f#site/} || exit 1; done
	cp site/style.css site/favicon.svg bin/wasm/hih.wasm bin/wasm/hih-legacy.wasm bin/site/
	$(PORT_BIN) -D site_version=$(SITE_VERSION) site/build.hxml
	$(RUN) -cp site/tools --run MkBundle $(HAXE_STD_PATH) bin/site/std.bundle
	cp site/data/*.json bin/site/
	cp -r site/playground bin/site/playground
	if [ -n "$(LIX_DIR)" ]; then mkdir -p bin/site/tools && cp $(LIX_DIR)/lix-* bin/site/tools/; fi
	if [ -n "$(BENCH_DATA)" ] && [ -f "$(BENCH_DATA)/history.json" ]; then mkdir -p bin/site/bench && cp $(BENCH_DATA)/history.json bin/site/bench/ && { cp $(BENCH_DATA)/latest.json bin/site/bench/ 2>/dev/null || true; }; fi
	if [ -n "$(BENCH_DATA)" ] && [ -f "$(BENCH_DATA)/targets.json" ]; then cp $(BENCH_DATA)/targets.json bin/site/targets.json; fi
	if [ -n "$(BENCH_DATA)" ] && [ -f "$(BENCH_DATA)/compile-history.json" ]; then mkdir -p bin/site/bench && cp $(BENCH_DATA)/compile-history.json $(BENCH_DATA)/compile-latest.json bin/site/bench/; fi
	printf '{\n\t"date": "%s",\n\t"commit": "%s",\n\t"wasmSize": "%s",\n\t"wasmGz": "%s",\n\t"wasmLegacyGz": "%s",\n\t"dataGz": "%s",\n\t"lixSize": "%s"\n}\n' \
		"$$(date -u +%Y-%m-%d)" "$$(git rev-parse --short HEAD)" \
		"$$(wc -c < bin/site/hih.wasm | $(mb))" \
		"$$(gzip -9c bin/site/hih.wasm | wc -c | $(mb))" \
		"$$(gzip -9c bin/site/hih-legacy.wasm | wc -c | $(mb))" \
		"$$(gzip -9c bin/site/std.bundle | wc -c | $(mb))" \
		"$$(if [ -f bin/site/tools/lix-linux-x86_64 ]; then wc -c < bin/site/tools/lix-linux-x86_64 | $(mb); else echo -; fi)" > bin/site/build-info.json
	cat bin/site/build-info.json

# the site in headless browsers (Playwright, with its browsers): its links,
# each page, the playground's compiler and page, the benchmark tables
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
# the lanes of `make test` (LANES): the harness and its arguments of each
# (haxe/test/*.hx, on EVAL's Eval), PORT_BIN against the reference
TEST_LANES := hxb macro hxblib display server jsonrpc interp haxelib libs debugger targets unit
LANE_hxb := Conformance -j $(JOBS) --cases $(CASES_FILE)
LANE_macro := Conformance -j $(JOBS) --cases haxe/test/conformance-macro-cases.txt
LANE_hxblib := Conformance -j $(JOBS) --cases haxe/test/conformance-hxblib-cases.txt --hxb-lib
LANE_display := Display -j $(JOBS)
LANE_server := Server -j $(JOBS)
LANE_jsonrpc := ServerJsonRpc
LANE_interp := Interp -j $(JOBS)
LANE_haxelib := Haxelib --server
# (hxmc/test/LibResolution.hx: hxmc/src/hxmc/libs against haxelib, the reference's, and lix's haxe shim)
LANE_libs = LibResolution --haxelib $(dir $(realpath $(REFERENCE)))haxelib --lix bin/lix/haxe
LANE_CP_libs := -cp hxmc/src
LANE_debugger := EvalDebugger $(if $(SHARD),--shard $(SHARD))
LANE_targets := UpstreamTargets -j $(JOBS)
# (unit: haxe/test/unit.hxml, the port's modules typed and run in-process: no
# harness, no reference, no summary)
SUMMARY_ARG = $(if $(SUMMARY),--summary "$(SUMMARY)")
TEST_CMD = $(if $(filter unit,$(1)),$(EVAL) --cwd . haxe/test/unit.hxml,$(EVAL) -cp hxmc/test -cp haxe/test $(LANE_CP_$(1)) --run $(LANE_$(1)) $(SUMMARY_ARG))
# (exported: the harnesses are command lists, which an assignment in front would not reach)
TEST_ENV = export HAXE_REFERENCE=$(abspath $(REFERENCE)) HAXE_IN_HAXE_PORT=$(abspath $(PORT_BIN));
# every lane runs, the failed ones named at the end (lix: -L's shim, the targets' libraries)
test: $(PORT_BIN) $(REFERENCE) $(if $(filter haxelib libs targets,$(LANES)),bin/lix/lix)
	@$(if $(filter-out $(TEST_LANES),$(LANES)),echo "test: no lane $(filter-out $(TEST_LANES),$(LANES)) (LANES: $(TEST_LANES))"; exit 1; )ulimit -s unlimited 2>/dev/null || true; $(TEST_ENV) failed=; \
	$(foreach l,$(LANES),echo '$(call TEST_CMD,$(l))'; $(call TEST_CMD,$(l)) || failed="$$failed $(l)";) \
	if [ -n "$$failed" ]; then echo "test: failed:$$failed"; exit 1; fi

# (the kept programs, then N random ones; both run, either failing fails)
test-fuzz: $(firstword $(FUZZ)) $(PORT_BIN) $(REFERENCE)
	@export HAXE_REFERENCE=$(abspath $(REFERENCE)); failed=; \
	echo '$(FUZZ) -j $(JOBS) --cases haxe/test/fuzz/cases --port $(abspath $(PORT_BIN)) --lane $(LANE)'; \
	$(FUZZ) -j $(JOBS) --cases haxe/test/fuzz/cases --port $(abspath $(PORT_BIN)) --lane $(LANE) || failed="$$failed cases"; \
	echo '$(FUZZ) -j $(JOBS) -n $(N) --port $(abspath $(PORT_BIN)) --lane $(LANE)'; \
	$(FUZZ) -j $(JOBS) -n $(N) --port $(abspath $(PORT_BIN)) --lane $(LANE) || failed="$$failed random"; \
	if [ -n "$$failed" ]; then echo "test-fuzz $(LANE): failed:$$failed"; exit 1; fi

test-libraries: bin/npm/native/$(HOST)/haxe
	$(SCRIPT) Libraries

test-module-cache: $(TOOL) $(STD) $(HOST_RT) bin/npm/native/$(HOST)/haxe
	$(SCRIPT) ModuleCacheCheck --haxe bin/npm/native/$(HOST)/haxe $(if $(PORT),--port)

# upstream's runtime suites on hxmc (docs/testing.md): unit, sys and threads natively,
# unit on wasm32-wasi; SUITES and SUITES_TARGET narrow it (CI: a job per target)
SUITES ?=
SUITES_TARGET ?=
upstream-suites: $(TOOL) $(STD) $(HOST_RT) bin/lix/lix
ifneq ($(SUITES_TARGET),wasm32-wasi)
	$(SCRIPT) UpstreamSuites $(SUITES)
endif
ifneq ($(SUITES_TARGET),native)
	$(SCRIPT) UpstreamSuites --target wasm32-wasi $(or $(SUITES),unit)
endif

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

# Android: APKs written by hxmc (hxmc/src/hxmc/android/Apk.hx): AndroidHello
# (hxmc/test/android/AndroidHello.hx: the NativeActivity entry in no-GC
# Haxe, the program on a thread of its own, a line to logcat) and
# AndroidViews (the same with the functions that make the APK carry
# classes.dex and org.hxmc.Activity; not run)
android-programs: $(TOOL) $(STD) $(HOST_RT)
	$(call hxmc,bin/android/$(ANDROID_TARGET)/AndroidHello.apk,-cp hxmc/test/android -main AndroidHello $(HXMC_ARGS) -D hxmc.target=$(ANDROID_TARGET) -D hxmc.android-package=org.hxmc.hello)
	$(call hxmc,bin/android/$(ANDROID_TARGET)/AndroidViews.apk,-cp hxmc/test/android -main AndroidViews $(HXMC_ARGS) -D hxmc.target=$(ANDROID_TARGET) -D hxmc.android-package=org.hxmc.views)
# their structure without a device (hxmc/test/ApkCheck.hx: zip, manifest, ELF, signature, classes.dex; zipalign, aapt, apksigner, dexdump when there)
android-check: android-programs
	ulimit -s unlimited 2>/dev/null || true; $(TOOL) -cp hxmc/test -cp haxe/test -cp hxmc/src --run ApkCheck $(foreach a,AndroidHello AndroidViews,bin/android/$(ANDROID_TARGET)/$(a).apk)
# shared libraries of the glibc mode loaded by an hxmc program (hxmc/test/SharedCheck.hx), Android's built
shared-check: $(TOOL) $(STD) $(HOST_RT)
	$(SCRIPT) SharedCheck
# AndroidHello on the device or emulator adb reaches (hxmc/test/android/android.sh: its line in logcat)
android-device-check: android-programs
	sh hxmc/test/android/android.sh bin/android/$(ANDROID_TARGET)/AndroidHello.apk bin/android/$(ANDROID_TARGET)

# iOS: app bundles written by hxmc (hxmc/src/hxmc/ios/Bundle.hx): IosHello
# (hxmc/test/ios/IosHello.hx: no UIKit, a line printed), also as an .ipa
ios-programs: $(TOOL) $(STD) $(HOST_RT)
	$(call hxmc,bin/ios/$(IOS_TARGET)/IosHello.app,-cp hxmc/test/ios -main IosHello $(HXMC_ARGS) -D hxmc.target=$(IOS_TARGET) -D hxmc.ios-bundle-id=org.hxmc.hello)
	$(call hxmc,bin/ios/$(IOS_TARGET)/IosHello.ipa,-cp hxmc/test/ios -main IosHello $(HXMC_ARGS) -D hxmc.target=$(IOS_TARGET) -D hxmc.ios-bundle-id=org.hxmc.hello)
# their structure without a Mac (hxmc/test/IosCheck.hx: bundle, Info.plist, Mach-O, code signature; llvm-objdump when there)
ios-check: ios-programs
	ulimit -s unlimited 2>/dev/null || true; $(TOOL) -cp hxmc/test -cp haxe/test -cp hxmc/src --run IosCheck $(foreach a,IosHello.app IosHello.ipa,bin/ios/$(IOS_TARGET)/$(a))
# IosHello on an iPhone simulator (hxmc/test/ios/ios.sh: a Mac with Xcode;
# CI's ios-simulator job: `make -o ios-programs ios-sim-check` on the bundle
# the ios job built)
ios-sim-check: override IOS_TARGET := ios-sim-arm64
ios-sim-check: ios-programs
	sh hxmc/test/ios/ios.sh bin/ios/ios-sim-arm64/IosHello.app bin/ios/ios-sim-arm64

# the dev loop (docs/dev.md): `hxmc dev` on a console program through edits
# and a compile error (dev-console.mjs), then the compilation server's builds
# through edits against fresh ones (server-verify.mjs)
dev-check: $(TOOL) $(STD) $(HOST_RT)
	ulimit -s unlimited 2>/dev/null || true; $(NODE) hxmc/test/dev/dev-console.mjs $(TOOL) bin/dev/console
	ulimit -s unlimited 2>/dev/null || true; $(NODE) hxmc/test/dev/server-verify.mjs $(TOOL)

# (each case typed, compiled for the Mir interpreter and run in the native compiler's process)
mir-run-check: $(TOOL) $(STD) $(HOST_RT) $(HOST_HAXE)
	HXMC_HAXE=$(abspath $(HOST_HAXE)) $(SCRIPT) Corpus --mir-run $(CASES)

# (Mir macros: the macro context typed against hxmc's std, its modules not
# compared; Issue11631 uses Eval's own mbedtls package; CI's test jobs run the
# same on each target's machine)
MIR_MACROS_KNOWN := eval-Issue11631-compile
mir-macros-check: $(TOOL) $(STD) $(HOST_RT) $(REFERENCE) $(HOST_HAXE)
	export HXMC_STD=$(abspath bin/hxmc/std) HAXE_REFERENCE=$(abspath $(REFERENCE)) HAXE_IN_HAXE_PORT="$(abspath $(HOST_HAXE)) -D hxmc.macros=mir"; $(SCRIPT) Conformance -j $(JOBS) --cases haxe/test/conformance-macro-cases.txt --target-only --parallel 1 --known $(MIR_MACROS_KNOWN)

# (Mir macros' compiled functions kept across builds, interp/BundleCache.hx: what
# invalidates them, against Eval's macros)
mir-cache-check: $(TOOL) $(STD) $(HOST_RT) $(HOST_HAXE)
	export HXMC_HAXE=$(abspath $(HOST_HAXE)) HXMC_STD=$(abspath bin/hxmc/std); $(SCRIPT) MirCacheCheck

bench: $(TOOL) $(STD) $(HOST_RT) $(PORT_BIN) bin/lix/lix
	$(SCRIPT) Bench $(BENCH_ARGS)

bench-compile: $(TOOL) $(STD) $(HOST_RT) $(PORT_BIN) $(REFERENCE)
	$(SCRIPT) CompileBench $(COMPILE_BENCH_ARGS)

# the microbenchmarks of WHICH: arrays (hxmc/test/bench/VectorBench.hx,
# hxmc/test/bench/README.md), maps (hxmc/test/bench/MapBench.hx)
MICRO_BIN_arrays := bin/vector-bench/m
MICRO_BIN_maps := bin/map-bench/m
MICRO_ARGS_arrays = $(ARRAY_BENCH_ARGS)
MICRO_ARGS_maps = $(MAP_BENCH_ARGS)
bench-micro: $(foreach w,$(WHICH),$(or $(MICRO_BIN_$(w)),bench-micro-unknown-$(w)))
	$(foreach w,$(WHICH),$(MICRO_BIN_$(w)) $(MICRO_ARGS_$(w)) &&) true
bench-micro-unknown-%:
	@echo "bench-micro: no microbenchmark $* (WHICH: arrays maps)"; exit 1

bin/vector-bench/m: $(TOOL) $(STD) $(HOST_RT) hxmc/test/bench/VectorBench.hx hxmc/test/bench/VectorBenchMacro.hx
	$(call hxmc,$@,-cp hxmc/test/bench -main VectorBench $(HXMC_ARGS))

bin/map-bench/m: $(TOOL) $(STD) $(HOST_RT) hxmc/test/bench/MapBench.hx
	$(call hxmc,$@,-cp hxmc/test/bench -main MapBench $(HXMC_ARGS))

# (the self-compile of PORT_BIN; the npm package's WebAssembly compiler)
measure: $(TOOL) $(STD) $(HOST_RT) $(REFERENCE) $(PORT_BIN) bin/npm/native/wasm32-wasi/haxe.wasm
	$(SCRIPT) Measure --port $(PORT_BIN)

quick: $(TOOL) $(STD) $(HOST_RT)
	$(SCRIPT) Tiers quick $(CASES)

wasmgc-check: $(TOOL) $(STD) $(HOST_RT)
	$(SCRIPT) GcCheck

wasmgc-bench: $(TOOL) $(STD) $(HOST_RT)
	$(SCRIPT) GcCheck --bench

check: $(TOOL) $(STD) $(HOST_RT)
	$(SCRIPT) Tiers check $(if $(PORT),--port) $(CASES)

full: $(TOOL) $(STD) $(HOST_RT)
	$(SCRIPT) Tiers full $(CASES)

clean:
	rm -rf bin/port bin/release bin/lix-dist bin/site bin/wasm bin/fuzz bin/lix bin/npm bin/stage0 bin/test bin/android bin/ios bin/dev bin/corpus \
		bin/hxmc/boot bin/hxmc/fix bin/hxmc-t bin/hxmc-fuzz $(TARGET_STD)

distclean: clean
	rm -rf bin
