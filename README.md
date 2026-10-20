# hxmc

A faithful port of the Haxe compiler from OCaml to Haxe, faster than
upstream, and **hxmc**, a Haxe target that compiles programs (the compiler
included) straight to machine code and WebAssembly, with its own code
generator and linkers: no C compiler, assembler, system linker or SDK.
Distributed through npm.

- **Faithful port:** it behaves exactly like the reference compiler of its
  pinned upstream commit: byte-identical HXB and target output, the same
  `--interp` runs, display and server answers. It follows Haxe: its syntax,
  its tests, its releases.
- **Targets:** Linux, macOS and Windows on x86-64 and ARM64, Android (APKs
  written without the SDK), iOS (app bundles written without Xcode), and
  wasm32-wasi.
- **Self-hosting:** hxmc builds itself; a clean checkout builds with only node.
- **No C of our own:** the runtime, collector and threads are Haxe.

Additions that diverge from upstream never change output: the module cache
on disk, faster macros, libraries from `node_modules`, anything that makes
builds faster. The direction and what comes next: [ROADMAP.md](ROADMAP.md)
([#10](https://github.com/benmerckx/hxmc/issues/10)).

Website, benchmarks and playground: <https://haxe-in-haxe.ben.mk> (plain
pages in `site/`: `make site`, see
[docs/development.md](docs/development.md#the-site)).

[universe](https://github.com/benmerckx/universe) is a separate, experimental
app and GUI stack built on hxmc (windows, GPU, text, UI, 3D; the `@hxmc/os`,
`@hxmc/gfx`, `@hxmc/ui`, ... packages). It was split out of this
repository and is unstable; hxmc does not depend on it.

## Install

```sh
npm i -D @hxmc/cli      # node 22+; then `npx haxe`
```

`haxe` is the full Haxe command line with hxmc built in: every target works as
usual (`--js`, `--interp`, ...), and `--custom-target hxmc=<out>` writes an
executable.

```hxml
-cp src
-main Main
--custom-target hxmc=bin/app
# -D hxmc.target=windows-x86_64   # cross-compile to another target
```

npm installs a native compiler for your platform. Where none can run, `haxe`
falls back to a WebAssembly build under node. Details on the packages,
editors, lix and rebuilding the compiler from source:
[docs/using.md](docs/using.md).

### Options

| Option | |
| --- | --- |
| `-D hxmc.target=<target>` | `linux-x86_64`, `linux-arm64`, `windows-x86_64`, `windows-arm64`, `macos-x86_64`, `macos-arm64`, `android-arm64`, `android-x86_64`, `ios-arm64`, `ios-sim-arm64`, `wasm32-wasi` (default: this machine) |
| `-D hxmc.libc=glibc` | Linux: link dynamically against the system's glibc (2.17+) instead of static musl, so shared libraries can be imported (`@:hxmc.lib("libGL.so.1")`) or loaded at run time |
| `--custom-target hxmc=app.apk` | Android: an APK with the program as its `NativeActivity` (`-D hxmc.android-package=<id>`, ...: [docs/hxmc.md](docs/hxmc.md#android)); a `.so` output: the shared library alone |
| `--custom-target hxmc=App.app` | iOS: an app bundle, ad hoc signed (`.ipa`: zipped; `-D hxmc.ios-bundle-id=<id>`, ...: [docs/hxmc.md](docs/hxmc.md#ios)) |
| `-D hxmc.shared` | a shared library (Linux in the glibc mode; a dylib on macOS and iOS; Android's always is one), exporting `-D hxmc.exports=<names>` |
| `-debug`, `-D hxmc.symbols` | a symbol table for profilers (wasm: a name section) |
| `-D hxmc.jobs=<n>` | parallel module compilations (default: the cores) |
| `-D hxmc.wasm-eh=legacy` | wasm: legacy exception handling, for older browsers and runtimes |
| `-D hxmc.null-checks=0\|1` | tests of references against null before each access (default: on WebAssembly, where a null access cannot fault; natively a fault handler throws `Null Access` at no cost: [docs/hxmc.md](docs/hxmc.md#null-access)) |
| `-D hxmc.native-array-outofbounds=throws\|silent` | Vector (and `hxmc.NativeArray`) accesses out of bounds throw `haxe.exceptions.ArgumentException`, or read the default value and write nothing (default: not tested) |
| `HXMC_STATS=1` | what the build did and how long it took |
| `HXMC_CACHE=<dir>` | the cache directory (default: the user's cache folder) |
| `HXMC_MODULE_CACHE=0`, `-D hxmc.no-module-cache` | turn off the module cache (on by default: typed modules are kept between builds, a rebuild types only what changed) |

Rebuilds only recompile changed modules; `haxe --wait 6000` plus
`haxe --connect 6000 build.hxml` keeps everything in memory. `haxe --dev
build.hxml` is the dev loop: it rebuilds on save and runs the new build
([docs/dev.md](docs/dev.md)).

## Libraries

Haxe libraries install from npm and are found by `-lib`, through a `"haxe"`
field in their `package.json` (lix and haxelib still work):
[docs/using.md](docs/using.md#libraries-from-npm).

## Building from source

```sh
git submodule update --init
make hxmc        # the tool (node runs the committed stage0 on first use)
make port        # bin/port/haxe: the port with every generator
make release TARGET=macos-arm64
make help        # everything else
```

Needs GNU make, node 22 and git; zig only to rebuild the runtime objects
(normally downloaded). Everything cross-builds from Linux or macOS.

## Testing

```sh
make quick       # after every hxmc edit (~20 s)
make check       # before a commit
make test        # the port's HXB conformance against the reference compiler
```

Every harness compares against the official nightly of the pinned upstream
commit (`make reference`).

## Documentation

| | |
| --- | --- |
| [docs/using.md](docs/using.md) | npm packages, the launcher, editors and lix, libraries, fast rebuilds |
| [docs/dev.md](docs/dev.md) | the dev loop: `hxmc dev`, rebuilds on save, the protocol a program can speak |
| [docs/development.md](docs/development.md) | repository layout, building, bootstrap, the developer loop |
| [docs/testing.md](docs/testing.md) | the harnesses, hxmc's corpus, the targets' apps, CI, benchmarks |
| [docs/porting.md](docs/porting.md) | the rules for every change of the port |
| [docs/hxmc.md](docs/hxmc.md) | hxmc's pipeline, runtime, targets |
| [ROADMAP.md](ROADMAP.md) | the goals and what comes next |
| [docs/plans/](docs/plans/README.md) | design docs: open designs and decisions by area |
| [docs/plans/lowlevel.md](docs/plans/lowlevel.md) | C interop and low-level Haxe (design, partly built) |

## License

GPL-2.0-or-later, like the Haxe compiler it is ported from. hxmc's runtime and
std, which end up in compiled programs, are MIT. Details: [LICENSE](LICENSE).
