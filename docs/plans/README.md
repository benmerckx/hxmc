# Design docs

Open designs and decisions, with their reasoning, by area. What is next
and in which order: [ROADMAP.md](../../ROADMAP.md). What is built:
[docs/hxmc.md](../hxmc.md), [docs/using.md](../using.md),
[docs/testing.md](../testing.md).

The plans about the app and GUI packages (ui, view, web, theme, 3d,
document, native-or-drawn, syntax, ui-next, graphics) moved with them to
[universe](https://github.com/benmerckx/universe) (its `docs/plans/`).

| | |
| --- | --- |
| [compiler.md](compiler.md) | the module cache, the central object cache, macro-heavy builds, native macros and code generation at run time |
| [runtime.md](runtime.md) | the collector, stack maps, compact strings, system calls, TLS and the event loop |
| [codegen.md](codegen.md) | escape analysis, debugging information (PDB, `__unwind_info`, variables, wasm DWARF), small codegen items |
| [targets.md](targets.md) | WebAssembly (and WasmGC), Android, iOS, shared libraries, Linux and macOS items |
| [dev-loop.md](dev-loop.md) | the dev loop's mechanism in the target: `hxmc dev`, swap hosts, snapshot hooks (built: [dev.md](../dev.md)) |
| [haxe-versions.md](haxe-versions.md) | parked: any Haxe version per project, 4.0 onwards, the compiler generated from upstream's OCaml (ml2hx, PR #5; the draft PR #9) |
| [packaging.md](packaging.md) | npm, haxelib, verifying native builds |
| [math.md](math.md) | LibM and the libm branch |
| [lowlevel.md](lowlevel.md) | C interop, native memory, manual memory, struct values |
