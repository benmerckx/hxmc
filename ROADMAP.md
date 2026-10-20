# Roadmap

Where hxmc is going and in which order. The direction was settled in
[#10](https://github.com/benmerckx/hxmc/issues/10), "Making this boring
tech". The designs behind each item are in
[docs/plans/](docs/plans/README.md); what is built is in
[docs/](docs/hxmc.md).

## Direction

- **hxmc follows Haxe.** The compiler is a faithful port of upstream's, kept
  forwards: its syntax, its tests, its releases. Generating it from
  upstream's OCaml (ml2hx) is parked: it would take a lot of work and tune
  the target towards OCaml's semantics
  ([haxe-versions.md](docs/plans/haxe-versions.md), the draft PR #9).
  Trust that it is the same compiler comes from the tests: the conformance
  lanes, the fuzzer, upstream's suites, and real code bases.
- **Distribution through npm.** `@hxmc/cli` with a native compiler per
  platform and a WebAssembly fallback; the sources and `hxmc-rebuild` for
  anyone who wants a compiler of their own
  ([packaging.md](docs/plans/packaging.md)).
- **Divergent additions only where they never change output**: the module
  cache on disk, fast macros, libraries from `node_modules`, anything that
  makes builds faster.
- **The target's goals**: live reload on every platform, or hooks for it;
  more low-level capabilities, to optimize the std and programs that need
  it; a collector that can run between frames; debugging.

## Goals

- **A faithful port.** The compiler behaves exactly like the reference
  compiler of its pinned upstream commit: byte-identical HXB and target
  output, the same `--interp` runs, display and server answers.
- **Native code and WebAssembly with no external toolchain.** hxmc's own
  code generator and linkers: no C compiler, assembler, system linker or
  SDK, on every target, cross-compiling included.
- **No C of our own.** The runtime and the collector are Haxe calling the
  system's APIs directly; only third-party C (the C library, mbedtls,
  libuv) is linked.
- **Performance, small binaries and fast builds** are core values, measured
  on every change: run time, peak memory, executable size, build time.
- **One implementation of each thing.** One runtime for every target, one
  math library; no second variant behind a define.

The app and GUI stack that grew here while the target was shaped (windows,
GPU, text, UI, 3D, the web packages) is a separate, experimental project,
[universe](https://github.com/benmerckx/universe); hxmc does not depend on
it.

## Now

- Upstream: follow the pinned commit forwards, each bump with the
  conformance lanes, the fuzzer and upstream's suites green.
- Real code bases: compile macro-heavy projects, first with Eval, then with
  native or interpreted macros, and turn what breaks into cases.
- Fast macros: the MIR interpreter running macros inside hxmc's runtime
  (PR #15), and the native macros prototype on a real app
  ([compiler.md](docs/plans/compiler.md#code-generation-at-run-time)).
- The module cache on by default, nondeterministic macros handled: landed
  ([compiler.md](docs/plans/compiler.md#cached-modules)).

## Next

- Builds: faster rebuilds and smaller outputs, the central object cache,
  quieter builds ([compiler.md](docs/plans/compiler.md#faster-rebuilds-smaller-outputs)).
- Macro-heavy builds: monomorph transactions, Eval call frames and instance
  layout; then cached macro objects and the shared-AST engine
  ([compiler.md](docs/plans/compiler.md#macro-heavy-builds)).
- Live reload: faster reloads (the last build's program reused, linking
  only what changed), the snapshot hooks and the swap host in hxmc's std so
  any program carries its data, the Windows dev loop's cold first edit, an
  iOS device ([dev-loop.md](docs/plans/dev-loop.md)).
- A collector that knows about frames: collecting between frames,
  incremental old-generation marking, an aging survivor space, escape
  analysis, the longest pause as a CI budget
  ([runtime.md](docs/plans/runtime.md#frames-and-pauses)).
- Debugging: a Windows PDB, Mach-O `__unwind_info`, variables, DWARF for
  WebAssembly; then a sampling profiler and symbolised crash reports
  ([codegen.md](docs/plans/codegen.md#debugging-information)).
- Low-level Haxe: methods on structs, specialized generics, value enums,
  allocators ([lowlevel.md](docs/plans/lowlevel.md)).
- Size and startup on the web: link-time DCE, then lazily loaded wasm
  modules ([targets.md](docs/plans/targets.md#webassembly)).
- Background work: an isolate-style API for work off the main thread
  ([runtime.md](docs/plans/runtime.md#background-work)).

## Later

- The collector: a memory limit, a mark-region old generation
  ([runtime.md](docs/plans/runtime.md#the-collector-longer-term)).
- WebAssembly threads; WasmGC as a browser-focused second path
  ([targets.md](docs/plans/targets.md#webassembly)).
- Android and iOS: several ABIs per APK, release signing, icons; device
  signing on iOS ([targets.md](docs/plans/targets.md#android),
  [targets.md](docs/plans/targets.md#ios)).
- A GUI subsystem define on Windows, a dynamic musl mode on Linux
  ([targets.md](docs/plans/targets.md#windows)).
- Compact strings ([runtime.md](docs/plans/runtime.md#compact-strings-latin-1--utf-16)).
- Direct system calls on Linux ([runtime.md](docs/plans/runtime.md#direct-system-calls-on-linux)).
- The libm branch: correctly rounded math ([math.md](docs/plans/math.md#later-the-libm-branch)).
- The `hxmc` haxelib; verified native builds ([packaging.md](docs/plans/packaging.md)).
