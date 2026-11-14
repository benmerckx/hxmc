# Developing hxmc

For contributors: the repository's layout, how to build everything, how
the bootstrap works, and the everyday edit-test loop. Tests and CI are in
[testing.md](testing.md); the rules for changing the port are in
[porting.md](porting.md).

## Layout

| Path | |
| --- | --- |
| `haxe/src/` | the port, module by module after upstream's `haxe/upstream/src/` |
| `haxe/upstream/` | upstream Haxe (submodule, commit `b34720791`): the reference sources and std. Never edit it |
| `haxe/test/` | the port's tests: conformance against the reference, the fuzzer (`fuzz/`), unit tests of port modules (`unit/`), `Measure.hx` |
| `hxmc/src/hxmc/` | hxmc's compiler (class path `hxmc/src`): IR and lowering (`ir/`), code generators (`x64/`, `a64/`, `wasm/`), linkers, the driver; `Main.hx` (the tool) and `HaxeMain.hx` (`haxe` with hxmc built in) |
| `hxmc/std/` | hxmc's std: overrides of upstream modules and the runtime (`hxmc.rt`), merged with the Eval originals by `MkStd.hx` |
| `hxmc/portable/` | hxmc's spans on the other targets (over `Bytes`), which `MkStd.hx` copies into the std as `hxmc-portable` with the C scalars ([interop.md](interop.md#spans-on-other-targets)) |
| `hxmc/deps/` | the third-party C: `deps.sh` (mbedtls, libuv), `mkrt.sh` (the runtime objects), `Layouts.hx` (struct layouts per target, checked against the C headers), `probe.c`, `zig-version` |
| `hxmc/test/` | hxmc's corpus (`cases/`, golden outputs in `expected/`, frozen fuzzer programs), the scripts that run it, the native-output checks (NativeCheck, with the smallest Android and iOS programs), the dev loop's tests, the benchmarks |
| `hxmc/bootstrap/` | the committed stage0 (`stage0.wasm.br`), node's WASI runner (`wasi.mjs`), the runtime objects by hash (`rt.mjs`) |
| `packages/` | the npm packages, one folder each, packed by `packages/pack.mjs`: `cli` (`@hxmc/cli`: the launcher, `dist/` for lix, upstream's and hxmc's std), `platform` (template of the six `@hxmc/<os>-<cpu>`: the native compiler and that machine's runtime objects), `source` (`@hxmc/source`: the compiler's sources, `hxmc-rebuild`) |
| `site/` | the website: plain HTML pages, their scripts (`client/`: the playground, the benchmark tables), measured data (`data/`), browser tests (`tools/`) |
| `tools/lix/` | lix (client and haxeshim), built with hxmc |
| `tools/hxmc/` | maintainers' tools: `EncCheck` (the encoders against llvm-mc), `MkCaseMap` (writes the std's `CaseMap.hx`) |

## Building

```sh
git submodule update --init
node make.mjs hxmc           # bin/hxmc/hxmc, the tool
node make.mjs port           # bin/port/haxe: the port with every generator
node make.mjs release TARGET=macos-arm64   # bin/release/<target>/haxe[.exe]
node make.mjs lix            # bin/lix/lix
node make.mjs npm            # bin/npm/*.tgz: the npm packages
node make.mjs site           # bin/site: the website
node make.mjs reference      # bin/reference/haxe: the reference compiler
node make.mjs help           # everything else
```

This needs node 22 and git, on Linux, macOS and Windows alike: no make, no
shell. zig (with a POSIX shell, for `hxmc/deps`' scripts) is needed only to
build the runtime objects. Everything cross-builds from any of the three.

`make.mjs` runs the build's driver, `tools/make/Make.hx`, on the tool's
Eval; without a tool yet, it first builds the stage-1 compiler from the
committed stage0 under node (below). The targets build in order, each
output only when a prerequisite is newer, as make did; `NAME=value` sets a
variable (else the environment's, else its default: `node make.mjs
help`), and `-o <file>` takes a file as up to date whatever its
prerequisites (CI's downloaded binaries). Commands run without a shell
(libuv, `Harness.spawn`); on Linux and macOS with the stack limit lifted,
as the Makefile's recipes had it.

Scripts are Haxe run on the tool's Eval: `bin/hxmc/hxmc -cp ... --run X`.
A first argument starting with `-` makes the tool the compiler's command
line. There is no Python.

### Bootstrap

As Zig does: `hxmc/bootstrap/stage0.wasm.br` is the tool built for
wasm32-wasi (brotli), committed and replaced only when the sources need a
newer one (`node make.mjs stage0`).

1. node runs the stage0 to build the first native tool from source
   (`bin/hxmc/boot/hxmc1`; `node make.mjs --stage1` alone: the runtime
   objects, the std, then that). `hxmc/bootstrap/wasi.mjs` runs a module
   given `--stack-size` on a worker thread with a stack of that size, so
   the compiler's recursion needs no `ulimit -s`.
2. That builds `bin/hxmc/hxmc`.
3. `bin/hxmc/hxmc` rebuilds itself byte-identically (`node make.mjs fixpoint`).

`node make.mjs bootstrap` does all three.

### Runtime objects

`rt.o`, `ssl.o` and `uv.o` per target are built by zig from `hxmc/deps`.
They are keyed by a hash of `hxmc/deps` (scripts, versions, flags, zig's
version) and published as the GitHub release `rt-<hash>`
(`node hxmc/bootstrap/rt.mjs hash|fetch|pack`). `node make.mjs rt` downloads them
and falls back to `node make.mjs rt-build` (zig) when the release is missing. CI
builds them only then: `fetch` retries a failed download and exits 2 only
for a missing release (an HTTP 404), 3 for a network failure, which fails
the run instead of rebuilding.

### The reference compiler

The official nightly of the pinned upstream commit (build.haxe.org),
downloaded by lix: `node make.mjs reference`. Nothing builds OCaml.

## The edit-test loop

| | When |
| --- | --- |
| `node make.mjs hxmc` | after an edit of hxmc or the port: rebuilds the tool (unchanged modules come from the cache) |
| `node make.mjs port` | after an edit of the port |
| `node make.mjs quick` | after every edit of hxmc (`CASES="Int64Gc Bench"` restricts the corpus) |
| `node make.mjs check` | before a commit (`PORT=1` adds the port's self-compile) |
| `node make.mjs test LANES="..."` | after an edit of the port: conformance against the reference |

What each runs, and which lanes a change needs: [testing.md](testing.md).
Never commit `bin/`.

## The site

`node make.mjs site` builds `bin/site`; any static server shows it (`npx http-server
bin/site`). `node make.mjs site-check` tests it in headless Chromium, Firefox and
WebKit (Playwright; `BROWSERS=chromium` for one).

The pages are plain HTML (`site/index.html`, `benchmarks.html`,
`playground.html`) with one stylesheet. The build adds their scripts
(`site/build.hxml`, compiled by the port), the playground's compiler
(`bin/wasm`) and examples, the std it reads, the measured data (`site/data`,
or the `bench-data` branch's with `BENCH_DATA=<checkout>`), lix
(`LIX_DIR`) and `build-info.json`. Every file a page loads carries the
commit in its address. CI builds the site in `site`, tests it in
`playground` and deploys it from main in `pages`.
