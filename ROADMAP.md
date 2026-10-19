# Roadmap

Where hxmc is going and in which order. The designs behind each item are
in [docs/plans/](docs/plans/README.md); what is built is in
[docs/](docs/hxmc.md).

## Goals

- **A faithful port.** The compiler behaves exactly like the reference
  compiler of its pinned upstream commit: byte-identical HXB and target
  output, the same `--interp` runs, display and server answers.
- **Native code and WebAssembly with no external toolchain.** hxmc's own
  code generator and linkers: no C compiler, assembler, system linker or
  SDK, on every target, cross-compiling included.
- **Pure-Haxe packages, no C of our own.** The runtime, the collector and
  the packages (`@hxmc/os`, `@hxmc/gfx`, the UI) are Haxe calling the
  system's APIs directly; only third-party C (the C library, mbedtls,
  libuv) is linked.
- **Performance, small binaries and fast builds** are core values, measured
  on every change: run time, peak memory, executable size, build time.
- **One implementation of each thing.** One math library, one runtime for
  every target, one reactive view layer for every renderer; no second
  variant behind a define.

## Now

- `@hxmc/ui`, `@hxmc/text`, native controls: landed; follow-ups in [ui.md](docs/plans/ui.md)
- `@hxmc/view`: signals, markup compiled to direct calls and a renderer contract, merged from `@hxmc/esx` and `hxmc.ui.reactive`; ui renders with it (drawn and native): landed ([view.md](docs/plans/view.md))
- `@hxmc/web`: `@hxmc/view` renderers for the DOM (JavaScript) and static HTML, hydration, islands in JavaScript or WebAssembly, typed calls from JavaScript into wasm modules: landed ([web.md](docs/plans/web.md#hxmcweb-built))
- `site/`, replacing `hxmc/web`: built with web; docs generated from the sources (narrative docs, package READMEs, an API reference read with the compiler), an examples gallery from each package's `examples/`: landed ([web.md](docs/plans/web.md#the-site-site-built))
- The module cache on by default, replacing the types cache ([compiler.md](docs/plans/compiler.md#cached-modules))
- Nondeterministic macros in the module cache: volatile modules, file and environment reads, `@:hxmc.noCache`: landed ([compiler.md](docs/plans/compiler.md#cached-modules))
- gfx: render targets, mip maps, more texture formats: landed ([packages/gfx/README.md](packages/gfx/README.md), what is left: [graphics.md](docs/plans/graphics.md#left))
- Android, step 1: GPU only, `NativeActivity`, the APK writer: landed (`android-arm64`, `android-x86_64`; [hxmc.md](docs/hxmc.md#android), what is left: [targets.md](docs/plans/targets.md#android))
- Android, step 2: native controls through JNI (a DEX writer for the glue, `hxmc.ui.native` on `android.widget`): landed ([hxmc.md](docs/hxmc.md#android))
- Android, step 3: a GPU view among views (`GpuView`), the input method for a drawn window: landed (what is left: [targets.md](docs/plans/targets.md#android))
- iOS, step 1: GPU only, UIKit through the Objective-C runtime, the app bundle and its ad hoc signature: landed (`ios-arm64`, `ios-sim-arm64`; [hxmc.md](docs/hxmc.md#ios), what is left: [targets.md](docs/plans/targets.md#ios))
- The dev loop, steps 1 and 2: `hxmc dev` live reload, fast refresh with state carried by key on public primitives (`hxmc.dev.Hot`): landed ([docs/dev.md](docs/dev.md))

## Next

- The dev loop: faster reloads (the compilation server's HXB reads, lowered bodies kept across it), seamless swaps, styles without a rebuild ([dev-loop.md](docs/plans/dev-loop.md))
- A Canvas ready for documents: paths, gradients, glyph runs, images with their source, host apart from canvas ([document.md](docs/plans/document.md))
- Native or drawn per widget: native text fields by default, platform views in drawn trees, a DOM renderer for the widgets in the browser ([native-or-drawn.md](docs/plans/native-or-drawn.md))
- Unstyled widgets and one theme, `@hxmc/theme`, based on shadcn/ui: its tokens, slots, variants and class lists ([theme.md](docs/plans/theme.md))
- Fixes from building an app on Windows: native fields in scrolled content, the dev loop's cold first edit, a GUI subsystem define, unknown markup attributes as compile errors, widget sizing under the theme, drawn text's weight and sharpness ([ui-next.md](docs/plans/ui-next.md#from-building-an-app-on-windows-oct-19))
- Drawn text fields on desktop: a full input bridge (TSF, `NSTextInputClient`, IBus, `EditContext`), then drawn by default there ([native-or-drawn.md](docs/plans/native-or-drawn.md#drawn-text-fields-on-desktop-an-input-bridge-then-drawn-by-default))
- The widgets mobile apps need: navigation, gestures, lists, app scaffolding, motion ([ui-next.md](docs/plans/ui-next.md#from-building-an-app-on-windows-oct-19), item 5)
- Graphics programs in the playground ([graphics.md](docs/plans/graphics.md#graphics-in-the-playground))

## Later

- Documents: paged layout and `@hxmc/pdf` (PDF, SVG, images) ([document.md](docs/plans/document.md))
- Text shaping for complex scripts: cursive, Indic, mark reordering, `ccmp`/`locl`, bidi embeddings, CFF2 ([ui-next.md](docs/plans/ui-next.md#from-building-an-app-on-windows-oct-19), item 6)
- Escape analysis ([codegen.md](docs/plans/codegen.md#escape-analysis))
- Debugging: a Windows PDB, Mach-O `__unwind_info`, variables, DWARF for WebAssembly ([codegen.md](docs/plans/codegen.md#debugging-information))
- The collector: incremental major marking, an aging survivor space, a memory limit ([runtime.md](docs/plans/runtime.md#the-collector-longer-term))
- Macro-heavy builds: monomorph transactions, Eval call frames and instance layout ([compiler.md](docs/plans/compiler.md#macro-heavy-builds))
- Link-time DCE, so a module's object does not depend on the rest of the program ([compiler.md](docs/plans/compiler.md#central-object-cache-and-quieter-builds))
- Native macros beyond the prototype ([compiler.md](docs/plans/compiler.md#native-macros-prototype))
- C interop: methods on structs, specialized generics, value enums, allocators ([lowlevel.md](docs/plans/lowlevel.md))
- WebAssembly threads; WasmGC as a browser-focused second path ([targets.md](docs/plans/targets.md#webassembly))
- iOS, steps 2 and 3 (native controls via UIKit, mixing), device signing, icons ([targets.md](docs/plans/targets.md#ios))
- gfx: multisampling, bind groups, compute, Vulkan, D3D12; audio input and devices ([graphics.md](docs/plans/graphics.md))
- Compact strings ([runtime.md](docs/plans/runtime.md#compact-strings-latin-1--utf-16))
- Direct system calls on Linux ([runtime.md](docs/plans/runtime.md#direct-system-calls-on-linux))
- The libm branch: correctly rounded math ([math.md](docs/plans/math.md#later-the-libm-branch))
- The `hxmc` haxelib; verified native builds ([packaging.md](docs/plans/packaging.md))
