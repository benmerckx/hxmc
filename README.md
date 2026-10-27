# hxmc

hxmc is two things in one compiler:

- **A faithful port of the Haxe compiler**, from OCaml to Haxe. It gives the
  same output as upstream Haxe at its pinned commit: byte-identical HXB and
  target output, the same `--interp` runs, the same display and server
  answers.
- **A Haxe target for native code and WebAssembly**, with its own code
  generator and linkers. It needs no C compiler, assembler, system linker or
  SDK, and it cross-compiles to every target from any host.

The compiler is distributed through npm. Website, benchmarks and a
playground: <https://haxe-in-haxe.ben.mk>.

## Status

| | |
| --- | --- |
| **Supported** | |
| Compiler port | Haxe 5.0.0-preview.1, upstream commit `066bd83` |
| Native targets | Linux, macOS, Windows; x86-64 and ARM64 |
| WebAssembly | `wasm32-wasi` (node, wasmtime, browsers) |
| Macros | Eval, as upstream |
| Coroutines | upstream's `TestCoroutines` passes natively and on wasm32-wasi |
| Rebuilds | the module cache on disk, the compilation server, `haxe --dev` |
| **Experimental** | |
| Android, iOS | APKs and app bundles written by hxmc, no SDK; not yet for store release |
| Mir macros | `-D hxmc.macros=mir`: macros on hxmc's own interpreter |
| **Not yet** | |
| | WebAssembly threads, sockets and processes; call stacks on WebAssembly |
| | debugger variables (lines and backtraces work), Windows PDB |
| | iOS device signing, Android release signing |

## Install

```sh
npm i -D @hxmc/cli      # node 22+; then `npx haxe` (or `npx hxmc`)
```

`haxe` is the full Haxe command line with hxmc built in. Every Haxe target
works as usual (`--js`, `--interp`, ...), and `--custom-target hxmc=<out>`
writes an executable.

npm installs the native compiler for your machine (Linux, macOS or Windows;
x86-64 or ARM64) with the runtime objects of its targets. To cross-compile
for another of those machines, install its package too, with `--force`:

```sh
npm i -D --force @hxmc/win32-x64   # windows-x86_64's runtime objects
```

Android's runtime objects are not on npm: use the release archive of the
runtime objects or build them from source. Packages, editors and lix:
[docs/using.md](docs/using.md).

## Quick start

```hxml
# build.hxml
-cp src
-main Main
--custom-target hxmc=bin/app
# -D hxmc.target=windows-x86_64   # cross-compile
```

```sh
npx haxe build.hxml && ./bin/app
npx haxe --dev build.hxml          # rebuild and rerun on every save
```

## Documentation

| | |
| --- | --- |
| [docs/using.md](docs/using.md) | user guide: targets, options, outputs, libraries, the module cache, debugging, limitations |
| [docs/interop.md](docs/interop.md) | calling C, struct values and the low-level API |
| [docs/dev.md](docs/dev.md) | the dev loop's protocol, for libraries that keep state across reloads |
| [docs/development.md](docs/development.md) | contributing: layout, building, bootstrap |
| [docs/testing.md](docs/testing.md) | tests, CI and benchmarks |
| [docs/porting.md](docs/porting.md) | rules for changes to the port (`haxe/src`) |
| [docs/hxmc.md](docs/hxmc.md) | how the target works: pipeline, runtime, collector, linkers |
| [ROADMAP.md](ROADMAP.md) | direction and what comes next |
| [docs/plans/](docs/plans/README.md) | open designs, by area |

[universe](https://github.com/benmerckx/universe) is a separate,
experimental app and GUI stack built on hxmc (windows, GPU, UI). hxmc does
not depend on it.

## Building from source

```sh
git submodule update --init
make hxmc        # the tool (node runs the committed stage0 on first use)
make port        # bin/port/haxe: the port with every generator
make quick       # after every change to hxmc
make help        # everything else
```

This needs GNU make, node 22 and git. zig is needed only to rebuild the
runtime objects, which are normally downloaded. See
[docs/development.md](docs/development.md).

## License

GPL-2.0-or-later, like the Haxe compiler it is ported from. hxmc's runtime
and std, which end up in compiled programs, are MIT. See [LICENSE](LICENSE).
