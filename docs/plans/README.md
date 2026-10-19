# Design docs

Open designs and decisions, with their reasoning, by area. What is next
and in which order: [ROADMAP.md](../../ROADMAP.md). What is built:
[docs/hxmc.md](../hxmc.md), [docs/using.md](../using.md),
[docs/testing.md](../testing.md).

| | |
| --- | --- |
| [compiler.md](compiler.md) | the module cache, the central object cache, macro-heavy builds, native macros and code generation at run time |
| [runtime.md](runtime.md) | the collector, stack maps, compact strings, system calls, TLS and the event loop |
| [codegen.md](codegen.md) | escape analysis, debugging information (PDB, `__unwind_info`, variables, wasm DWARF), small codegen items |
| [targets.md](targets.md) | WebAssembly (and WasmGC), Android, iOS, shared libraries, Linux and macOS items |
| [graphics.md](graphics.md) | `@hxmc/os`, `@hxmc/gfx`, shaders, audio, UI pointers |
| [3d.md](3d.md) | `@hxmc/3d`, a scene layer for games on gfx: math, scene graph, glTF, PBR, input actions, animation, physics, tooling; the order and what is built |
| [ui.md](ui.md) | `@hxmc/ui`: native controls or a drawn UI, the survey, the design and what is built |
| [ui-next.md](ui-next.md) | `@hxmc/ui`'s handoff: where single-source widgets, layout and drawn fidelity stand, the next steps by priority |
| [theme.md](theme.md) | unstyled widgets, the rule engine and the shadcn-based `@hxmc/theme`: the contract and who builds what |
| [dev-loop.md](dev-loop.md) | live reload and fast refresh: `hxmc dev`, state carried by key, seamless swaps, styles without a rebuild (steps 1 and 2 built: [dev.md](../dev.md)) |
| [haxe-versions.md](haxe-versions.md) | any Haxe version per project, 4.0 onwards: the compiler generated from upstream's OCaml (ml2hx, PR #5), our changes as overlays, hxmc on a stable compiler API |
| [document.md](document.md) | views rendered to PDF, SVG or pixels: the document platform and what today's Canvas must allow |
| [native-or-drawn.md](native-or-drawn.md) | each widget native, drawn or auto: the defaults, platform views in a drawn tree, the browser's DOM renderer |
| [syntax.md](syntax.md) | an idea, to be decided: `.hxv` files with syntax plugins desugared to plain Haxe, components as element blocks, styles as CSS, the tooling it needs |
| [view.md](view.md) | `@hxmc/view`: signals, markup and the renderer contract; what was looked at, chosen and rejected |
| [web.md](web.md) | `@hxmc/view`'s renderers, `@hxmc/web`, the site |
| [packaging.md](packaging.md) | npm, haxelib, verifying native builds |
| [math.md](math.md) | LibM and the libm branch |
| [lowlevel.md](lowlevel.md) | C interop, native memory, manual memory, struct values |
