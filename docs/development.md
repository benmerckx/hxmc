# Developing hxmc and the port

## Layout

| Path | |
| --- | --- |
| `haxe/src/` | the port, module by module after upstream's `haxe/upstream/src/` |
| `haxe/upstream/` | upstream Haxe (submodule, commit `066bd8331`): the reference sources and std |
| `haxe/test/` | the port's tests: conformance against the reference (HXB, display, server, JSON-RPC, `--interp`, `-L`, upstream's target suites), the fuzzer (`fuzz/`), unit tests of port modules (`unit/`, `unit.hxml`), peak memory and times (`Measure.hx`) |
| `hxmc/src/hxmc/` | hxmc's sources (package `hxmc`, class path `hxmc/src`): the IR and lowering (`ir/`), the code generators (`x64/`, `a64/`, `wasm/`), the linkers, the driver, `Main.hx` (the tool) and `HaxeMain.hx` (`haxe` with hxmc built in) |
| `hxmc/std/` | hxmc's std: overrides of upstream modules and the runtime's Haxe part (`hxmc.rt`), merged with the Eval originals by `hxmc/src/hxmc/MkStd.hx` |
| `hxmc/deps/` | no C of ours: `deps.sh` (mbedtls and libuv), `mkrt.sh` (the runtime objects: the C library's members, or the glibc mode's import table, mbedtls, libuv), `Layouts.hx` (system and libuv struct layouts per target, checked against the C headers), `probe.c` (build-time layout probe), `zig-version` |
| `hxmc/test/` | hxmc's corpus (`cases/`, golden outputs `expected/`, frozen fuzzer programs `fuzz-1000.zip`), the encoder tests (`encoder/`), the scripts that run them (`Corpus`, `Check`, `Crosshost`, `Selfcheck`, `Tiers`, `EncCheck`), `-lib` from node_modules (`NodeLibs`), the release smoke test (`smoke.sh`), the benchmarks (`Bench`, with the cases' check programs in `bench/`) |
| `site/` | the website, built with `@hxmc/web`: its generator (`src/`), the islands both the pages and their JavaScript compile (`islands/`), the pages' scripts (`client/`: the playground, which runs the port as a WebAssembly module, the benchmark tables), the measured data (`data/`), the playground's examples (`playground/`), the browser tests and tools (`tools/`) |
| `hxmc/bootstrap/` | the committed stage0 (`stage0.wasm.br`), node's WASI runner (`wasi.mjs`), the runtime objects by hash (`rt.mjs`) |
| `packages/` | everything published to npm, one folder per package, packed by `packages/pack.mjs`: `cli` (`@hxmc/cli`, laid out as its tarball, with the launcher and `dist/haxe` for lix), `wasm`, `source` (with `hxmc-rebuild`), `platform` (the template of the six `@hxmc/<os>-<cpu>`), and the source-only libraries `os` and `gfx` (docs/plans/graphics.md); any other folder whose `package.json` has its own version is published as it is |
| `tools/lix/` | lix (the lix client and haxeshim) ported to build with hxmc |

## Building

```sh
git submodule update --init
make hxmc           # bin/hxmc/hxmc, the tool: on first use node runs the stage0, then the tool rebuilds itself
make port           # bin/port/haxe: the port with every generator (seconds after an edit)
make release TARGET=macos-arm64   # bin/release/<target>/haxe[.exe], with mbedtls and libuv
make lix            # bin/lix/lix
make npm            # bin/npm/*.tgz: the npm packages of packages/ (packages/pack.mjs)
make site           # bin/site: the website (The site, below)
make help           # everything else
```

The [Makefile](../Makefile) needs GNU make, node 22 and git; zig only for the
runtime objects. Everything is cross-built from Linux (macOS works as a host
too).

Bootstrap, as Zig does: `hxmc/bootstrap/stage0.wasm.br` is the tool built for
wasm32-wasi (brotli, 1.4 MB), committed and replaced only when the sources need
a newer one (`make stage0`). node runs it to build the first native tool from
source (`bin/hxmc/boot/hxmc1`, about 25 s), which builds `bin/hxmc/hxmc`; that
one rebuilds itself byte-identically (`make fixpoint`). `make bootstrap` does
all three (about a minute). Scripts run on the tool's Eval (`bin/hxmc/hxmc
-cp ... --run X`: a first argument starting with `-` makes the tool the
compiler's command line), or on the stage0's before there is a tool.

Runtime objects: `rt.o`, `ssl.o` and `uv.o` for the six targets are built by
zig from `hxmc/deps` (the C library's members, mbedtls, libuv), which a source-only
bootstrap cannot do. They are keyed by a hash of `hxmc/deps` (scripts, pinned
versions, flags, the zig version) and published as the GitHub release
`rt-<hash>` (`node hxmc/bootstrap/rt.mjs hash|fetch|pack`); `make rt` downloads
them and falls back to `make rt-build` (zig) when the release is missing. CI
builds them only then (one job per target), publishes the release from
pushes to main and hxmc, and passes them to its other jobs as an artifact.

The reference compiler is the official nightly of the pinned upstream commit
(build.haxe.org), downloaded by lix: `make reference` (`bin/reference/haxe`,
cached by CI). Nothing builds OCaml.

## The site

`make site` builds `bin/site`; any static server shows it (`npx http-server
bin/site`), and `make site-check` tests it in headless Chromium, Firefox and
WebKit (Playwright with its browsers; `BROWSERS=chromium` for one). The
pages are components rendered at build time by `site/src` with
`@hxmc/web`'s static renderer, on the tool's Eval (`Site.hx`; it runs
natively too); the same run:

- builds each package example for the browser: every file of a package's
  `examples/` that starts with a header (`// title:`, `// summary:`,
  `// tags:`, `// demo: canvas WxH`, `sound`, `island` or `module`) is a
  card of the examples page, built for wasm32-wasi with its package's class
  paths (`Examples.hx`) and shown as a WebAssembly island next to its
  source and the files of its folder it uses; the ui and text programs get
  DejaVu Sans (`fonts-dejavu-core`);
- renders the docs from the repository's Markdown (`Docs.hx`,
  `Markdown.hx`: `docs/*.md`, `README.md`, `ROADMAP.md`, the plans, each
  package's README and ui's guide; links between them become links between
  the pages, any other file a link to GitHub);
- reads the packages' API with the tool (`Api.hx`: their modules typed
  together, `--json`, and the `//` comment above each public declaration
  read from its source);
- measures the hxmc page's sizes and cold build times (`Measure.hx`: three
  programs for the seven targets);
- copies the packages' browser modules and the island loader.

Then the Makefile adds the playground's compiler (`bin/wasm`), the
JavaScript (`site/build.hxml`, compiled by the port: `site.js`, every
page's islands; `lab.js` and `counter.js`, the examples'; the playground's
and the tables' scripts), the std the playground reads, the data and the
build facts, and prints each page's weight (`site/tools/weights.mjs`). Every
file a page loads carries the commit in its address (`?v=`: `Site.asset`,
`Version.hx`). CI builds it in the `site` job, tests it in `playground` and
deploys it from main in `pages`.

## Developer loop

| | |
| --- | --- |
| `make hxmc` | the tool after an edit of hxmc or the port: about 11 s (8 s of it typing the port; unchanged modules' objects come from the cache directory, `docs/hxmc.md`, "Module cache") |
| `make port` | the port after an edit: about 13 s (an edit of a central module such as the typer recompiles every module: 26 s) |
| `make quick` | after every edit of hxmc: the x64 corpus, again with `RT_VERIFY=1`, the wasm corpus under node, the module cache's store (about 20 s; `CASES="Int64Gc Bench"` restricts it) |
| `make check` | before a commit: quick, arm64 (qemu), x64 Windows (wine), a 16 KB nursery, the wasm corpus with legacy exception handling, ThreadNatives x30, crosshost on three cases (`PORT=1`: the port's self-compile) |
| `make full` | before a push: every nursery and `RT_VERIFY`, wasmtime, the port's self-compile natively and as a module, crosshost on everything, the fixpoint |
| `make test` | HXB conformance of the port against the reference (seconds per 100 cases) |
| `make portcheck` | the port built by hxmc self-compiles to the reference's HXB |
