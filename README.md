# hxmc

The Haxe compiler ported from OCaml to Haxe, and **hxmc**, a Haxe target that
compiles programs (the compiler included) straight to machine code and
WebAssembly, with its own code generator and linkers: no C compiler, assembler
or system linker.

- **Targets:** Linux, macOS and Windows on x86-64 and ARM64, Android (APKs
  written without the SDK), iOS (app bundles written without Xcode), and
  wasm32-wasi.
- **Faithful port:** it behaves exactly like the reference compiler of its
  pinned upstream commit: byte-identical HXB and target output, the same
  `--interp` runs, display and server answers.
- **Self-hosting:** hxmc builds itself; a clean checkout builds with only node.
- **No C of our own:** the runtime, collector and threads are Haxe.
- **Graphics in pure Haxe:** `@hxmc/os` and `@hxmc/gfx` draw with GL, Metal,
  D3D11, WebGPU or WebGL2 through the system's own APIs.

Website, examples, docs and playground: <https://haxe-in-haxe.ben.mk> (built
from `site/` with `@hxmc/web`: `make site`, see
[docs/development.md](docs/development.md#the-site)).

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
| `-D hxmc.native-array-outofbounds=throws\|silent` | Vector (and `hxmc.NativeArray`) accesses out of bounds throw `haxe.exceptions.ArgumentException`, or read the default value and write nothing (default: not tested) |
| `HXMC_STATS=1` | what the build did and how long it took |
| `HXMC_CACHE=<dir>` | the cache directory (default: the user's cache folder) |
| `HXMC_MODULE_CACHE=0`, `-D hxmc.no-module-cache` | turn off the module cache (on by default: typed modules are kept between builds, a rebuild types only what changed) |

Rebuilds only recompile changed modules; `haxe --wait 6000` plus
`haxe --connect 6000 build.hxml` keeps everything in memory. `haxe --dev
build.hxml` is the dev loop: it rebuilds on save and reloads the program,
keeping its state ([docs/dev.md](docs/dev.md)).

## Libraries

Haxe libraries install from npm and are found by `-lib`, through a `"haxe"`
field in their `package.json` (lix and haxelib still work):

```sh
npm i -D @hxmc/gfx
```

```hxml
-lib hxmc.gfx
```

| Package | |
| --- | --- |
| `@hxmc/os` | windows, input and the app loop: X11, Cocoa, Win32, Android's NativeActivity, UIKit and the browser canvas |
| `@hxmc/gfx` | a portable GPU API with back ends for GL/GLES (Linux, Android), Metal (macOS, iOS), D3D11 (Windows), WebGPU and WebGL2 (browser), and shaders written in Haxe (compiled to GLSL, WGSL, MSL, HLSL); see `packages/gfx/examples/Triangle.hx` and `Cube.hx` |
| `@hxmc/3d` | a scene layer for 3D games on gfx: math shared with the shaders, a handle-based scene graph, cameras, glTF 2.0 (typed `Model.of` references), a lit PBR renderer (shadows with cascades, instancing, skinning, morph targets, normal maps, blending, an environment map, sky, particles), build-time packed models, input actions, keyframe animation, a debug overlay; see `packages/3d/examples/GltfViewer.hx` and the plan, `docs/plans/3d.md` |
| `@hxmc/physics` | a small rigid-body core for `@hxmc/3d`: spheres, boxes, capsules and planes, contacts with restitution and friction, joints, a walking character, sleeping, raycasts, deterministic on every target; see `packages/physics/examples/Falling.hx` and `Walker.hx` |
| `@hxmc/3d-ui` | `@hxmc/view`'s markup and signals on `@hxmc/3d`'s scene graph (a prototype): nodes, meshes, lights and cameras as elements, properties bound to signals |
| `@hxmc/text` | TrueType fonts in pure Haxe: parsing, an anti-aliased rasterizer, shaping with kerning and fallback fonts, bidi and Arabic shaping, line layout, a glyph atlas, the system's fonts |
| `@hxmc/view` | signals and JSX-like markup for Haxe on every target: fine-grained reactivity as Solid has it, markup compiled to direct calls on a renderer chosen at compile time; components are type-checked calls |
| `@hxmc/web` | `@hxmc/view` on the web: a DOM renderer (JavaScript), static HTML rendered at build time, hydration, islands in JavaScript or WebAssembly with a small loader, typed calls from JavaScript into wasm32-wasi modules |
| `@hxmc/ui` | a UI toolkit: a node tree with flexbox layout (checked against Chromium's), events and focus, drawn with the GPU on gfx or as the platform's controls, written in view's markup, widgets; see `packages/ui/examples/Todo.hx` |
| `@hxmc/theme` | the look of ui's unstyled widgets, after shadcn/ui: its tokens, light and dark, and its components' Tailwind class lists, made rules at compile time |

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
| [docs/dev.md](docs/dev.md) | the dev loop: `hxmc dev`, live reload, fast refresh by keyed state, `hxmc.dev.Hot` for state libraries, the protocol |
| [docs/development.md](docs/development.md) | repository layout, building, bootstrap, the developer loop |
| [docs/testing.md](docs/testing.md) | the harnesses, hxmc's corpus, graphics tests, CI, benchmarks |
| [docs/porting.md](docs/porting.md) | the rules for every change of the port |
| [docs/hxmc.md](docs/hxmc.md) | hxmc's pipeline, runtime, targets |
| [ROADMAP.md](ROADMAP.md) | the goals and what comes next |
| [docs/plans/](docs/plans/README.md) | design docs: open designs and decisions by area |
| [docs/plans/lowlevel.md](docs/plans/lowlevel.md) | C interop and low-level Haxe (design, partly built) |
| [docs/plans/ui.md](docs/plans/ui.md) | native controls or a drawn UI: the survey and the design of `@hxmc/ui` |

## License

GPL-2.0-or-later, like the Haxe compiler it is ported from. hxmc's runtime and
std, which end up in compiled programs, and the packages in `packages/` are
MIT. Details: [LICENSE](LICENSE).
