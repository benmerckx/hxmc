# Developing hxmc

For contributors: the repository's layout, how to build everything, how
the bootstrap works, and the everyday edit-test loop. Tests and CI are in
[testing.md](testing.md); the rules for changing the port are in
[porting.md](porting.md).

## Layout

| Path | |
| --- | --- |
| `haxe/src/` | the port, module by module after upstream's `haxe/upstream/src/` |
| `haxe/upstream/` | upstream Haxe (submodule, commit `066bd8331`): the reference sources and std. Never edit it |
| `haxe/test/` | the port's tests: conformance against the reference, the fuzzer (`fuzz/`), unit tests of port modules (`unit/`), `Measure.hx` |
| `hxmc/src/hxmc/` | hxmc's compiler (class path `hxmc/src`): IR and lowering (`ir/`), code generators (`x64/`, `a64/`, `wasm/`, `wasmgc/`), linkers, the driver; `Main.hx` (the tool) and `HaxeMain.hx` (`haxe` with hxmc built in) |
| `hxmc/std/` | hxmc's std: overrides of upstream modules and the runtime (`hxmc.rt`), merged with the Eval originals by `MkStd.hx` |
| `hxmc/deps/` | the third-party C: `deps.sh` (mbedtls, libuv), `mkrt.sh` (the runtime objects), `Layouts.hx` (struct layouts per target, checked against the C headers), `probe.c`, `zig-version` |
| `hxmc/test/` | hxmc's corpus (`cases/`, golden outputs in `expected/`, frozen fuzzer programs), the scripts that run it, the Android and iOS apps, the dev loop's tests, the benchmarks |
| `hxmc/bootstrap/` | the committed stage0 (`stage0.wasm.br`), node's WASI runner (`wasi.mjs`), the runtime objects by hash (`rt.mjs`) |
| `packages/` | the npm packages, one folder each, packed by `packages/pack.mjs`: `cli` (`@hxmc/cli`: the launcher, `dist/` for lix, upstream's and hxmc's std), `platform` (template of the six `@hxmc/<os>-<cpu>`: the native compiler and that machine's runtime objects); `source` (`hxmc-rebuild`) is not published |
| `site/` | the website: plain HTML pages, their scripts (`client/`: the playground, the benchmark tables), measured data (`data/`), browser tests (`tools/`) |
| `tools/lix/` | lix (client and haxeshim), built with hxmc |

## Building

```sh
git submodule update --init
make hxmc           # bin/hxmc/hxmc, the tool
make port           # bin/port/haxe: the port with every generator
make release TARGET=macos-arm64   # bin/release/<target>/haxe[.exe]
make lix            # bin/lix/lix
make npm            # bin/npm/*.tgz: the npm packages
make site           # bin/site: the website
make reference      # bin/reference/haxe: the reference compiler
make help           # everything else
```

The [Makefile](../Makefile) needs GNU make, node 22 and git. zig is needed
only to build the runtime objects. Everything cross-builds from Linux or
macOS.

Scripts are Haxe run on the tool's Eval: `bin/hxmc/hxmc -cp ... --run X`.
A first argument starting with `-` makes the tool the compiler's command
line. There is no Python.

### Bootstrap

As Zig does: `hxmc/bootstrap/stage0.wasm.br` is the tool built for
wasm32-wasi (brotli), committed and replaced only when the sources need a
newer one (`make stage0`).

1. node runs the stage0 to build the first native tool from source
   (`bin/hxmc/boot/hxmc1`).
2. That builds `bin/hxmc/hxmc`.
3. `bin/hxmc/hxmc` rebuilds itself byte-identically (`make fixpoint`).

`make bootstrap` does all three.

### Runtime objects

`rt.o`, `ssl.o` and `uv.o` per target are built by zig from `hxmc/deps`.
They are keyed by a hash of `hxmc/deps` (scripts, versions, flags, zig's
version) and published as the GitHub release `rt-<hash>`
(`node hxmc/bootstrap/rt.mjs hash|fetch|pack`). `make rt` downloads them
and falls back to `make rt-build` (zig) when the release is missing. CI
builds them only then.

### The reference compiler

The official nightly of the pinned upstream commit (build.haxe.org),
downloaded by lix: `make reference`. Nothing builds OCaml.

## The edit-test loop

| | When |
| --- | --- |
| `make hxmc` | after an edit of hxmc or the port: rebuilds the tool (unchanged modules come from the cache) |
| `make port` | after an edit of the port |
| `make quick` | after every edit of hxmc (`CASES="Int64Gc Bench"` restricts the corpus) |
| `make check` | before a commit (`PORT=1` adds the port's self-compile) |
| `make full` | before a push |
| `make test LANES="..."` | after an edit of the port: conformance against the reference |

What each runs, and which lanes a change needs: [testing.md](testing.md).
Never commit `bin/`.

## The site

`make site` builds `bin/site`; any static server shows it (`npx http-server
bin/site`). `make site-check` tests it in headless Chromium, Firefox and
WebKit (Playwright; `BROWSERS=chromium` for one).

The pages are plain HTML (`site/index.html`, `benchmarks.html`,
`playground.html`) with one stylesheet. The build adds their scripts
(`site/build.hxml`, compiled by the port), the playground's compiler
(`bin/wasm`) and examples, the std it reads, the measured data (`site/data`,
or the `bench-data` branch's with `BENCH_DATA=<checkout>`), lix
(`LIX_DIR`) and `build-info.json`. Every file a page loads carries the
commit in its address. CI builds the site in `site`, tests it in
`playground` and deploys it from main in `pages`.
