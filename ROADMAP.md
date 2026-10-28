# Roadmap

Where hxmc is going, in order. The designs behind each item are in
[docs/plans/](docs/plans/README.md). The direction was set in
[#10](https://github.com/benmerckx/hxmc/issues/10).

## Direction

- **Follow Haxe.** The compiler stays a faithful, hand-written port of
  upstream and moves forward with it. Trust comes from the tests:
  conformance lanes, the fuzzer, upstream's suites and real code bases.
- **Native code and WebAssembly with no external toolchain**, on every
  target, cross-compiling included. No C of our own: the runtime and the
  collector are Haxe.
- **Distribution through npm.**
- **Additions only where they never change output**: the module cache,
  faster macros, libraries from `node_modules`, anything that makes builds
  faster.
- **Measured on every change**: run time, peak memory, executable size and
  build time.

## Now

- The 0.1.0 release: npm packaging ([packaging.md](docs/plans/packaging.md)),
  the release gate ([testing.md](docs/testing.md#ci)), these docs.
- Mir macros: a native tier for hot macro code
  ([compiler.md](docs/plans/compiler.md#mir-macros)).

## Next

- Faster rebuilds and link-time DCE ([compiler.md](docs/plans/compiler.md#faster-rebuilds)).
- Macro-heavy builds: monomorph transactions, Eval call frames ([compiler.md](docs/plans/compiler.md#macro-heavy-builds)).
- The dev loop: faster reloads, snapshot hooks in the std, the Windows first edit ([dev-loop.md](docs/plans/dev-loop.md)).
- A collector that knows about frames ([runtime.md](docs/plans/runtime.md#frames-and-pauses)).
- Debugging: PDB, `__unwind_info`, variables, DWARF for wasm ([codegen.md](docs/plans/codegen.md#debugging)).
- Low-level Haxe: methods on structs, specialized generics, value enums ([lowlevel.md](docs/plans/lowlevel.md)).
- WebAssembly size and startup ([targets.md](docs/plans/targets.md#webassembly)).
- Background work off the main thread ([runtime.md](docs/plans/runtime.md#background-work)).

## Later

- Collector: a memory limit, a mark-region old generation ([runtime.md](docs/plans/runtime.md#collector)).
- WebAssembly threads ([targets.md](docs/plans/targets.md#webassembly)).
- Android and iOS: the linker's part of store release, e.g. device signing ([targets.md](docs/plans/targets.md#ios)); the packaging is a packager's.
- A GUI subsystem on Windows, a dynamic musl mode on Linux ([targets.md](docs/plans/targets.md#windows)).
- Direct system calls on Linux ([runtime.md](docs/plans/runtime.md#direct-system-calls-on-linux)).
- Correctly rounded math ([math.md](docs/plans/math.md)).
- The `hxmc` haxelib; verified native builds ([packaging.md](docs/plans/packaging.md)).
- Any Haxe version per project: parked ([haxe-versions.md](docs/plans/haxe-versions.md)).
