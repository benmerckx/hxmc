# The dev loop: live reload and fast refresh

Save a file, see the change, keep where you were. Four steps, each useful on
its own; the first two give most of it. Steps 1 and 2 are built, and step
3 in the browser, natively (Linux, macOS, Windows), on Android and on the
iOS simulator: [docs/dev.md](../dev.md) (how to use them, the primitives
as built, the protocol, the times measured; on an iOS device a new
build's dylib cannot be loaded, and the wasm fallback is not built).

## Principles

- **A reload is a fresh start with state carried over**, never a patch of
  live code. The new build runs from its own `main`; what survives is data,
  restored by key. So a reload behaves exactly like a cold start with the
  same values, on every target (native, linear wasm, WasmGC, JavaScript),
  and there are no stale vtables, closures or half-migrated objects.
- **State that cannot be carried is reset, visibly**: a type that changed, a
  signal that was removed, a value that does not serialize. It is logged,
  never guessed.
- **The last good build keeps running** while the new one has errors; the
  errors show in an overlay in the app and in the terminal.
- **Zero cost in release**: the dev client is linked only with `-D hxmc.dev`.
- **Measured**: edit-to-pixels latency is tracked like build time.

## The primitives: state libraries plug in

Fast refresh is built on a small, public layer, `hxmc.dev.Hot` (in
packages/os, so it has no view or ui dependency), and hxmc's own signals and
UI engine are only its first clients. Any state library (a store, another
signal library, an ECS, a game's world) uses the same calls, so it gets fast
refresh without hxmc knowing about it.

- **Lifecycle.** `Hot.onSnapshot(f)`: contribute values before a swap.
  `Hot.onDispose(f)`: release what this build owns (effects, timers,
  sockets, GPU buffers) before the new build starts. `Hot.reloading`: true
  while the new build starts from a snapshot (false on a cold start).
- **Storage.** `Hot.save(key, value, type)` and `Hot.load(key, type)`:
  values kept across one reload by key; `load` returns null when the key is
  missing or its type changed. Values go through `haxe.Serializer` by
  default; a library can pass its own encode and decode for values that do
  not serialize as they are.
- **Types.** `Hot.typeOf<T>()` is the compiler's hash of a type's shape
  (fields and their types, recursively), computed at compile time, so a
  changed type is never restored into the new one.
- **Keys.** `Hot.here()` is a macro giving the static identity of the place it
  is written (the enclosing type and function, and the variable it is
  assigned to); `Hot.scope(name, f)` nests a dynamic part (a component
  instance, a list item's key) for everything keyed inside `f`. A library's
  primitive calls these once, so its users write nothing.
- **Everything else is built on these**: `signal(...)` in packages/view keys
  itself with `Hot.here()` inside the renderer's `Hot.scope` per component
  instance; `Hot.keep(key, init)` is a one-line helper over `load` and
  `onSnapshot`; the UI engine saves focus, scroll and selection by node key.
- **Documented with an example**: a small store written as a third-party
  library would be, made reload-safe in a few lines, and tested in CI like
  the signals.

The dev server's protocol (`reload`, `assets`, `error`, `ok`, and the
snapshot it hands to the new build) is documented too, so editors and other
tools can drive the loop.

## 1. Live reload

`hxmc dev [build.hxml]` (and `npx haxe --dev ...`):

- Watches the class paths, libraries' sources and assets the build read
  (the module cache already records them, macros' file reads included).
- Keeps the compiler resident (the compilation server: typed modules,
  lowered bodies and compiled objects in memory; a no-change rebuild of a
  small program is about 0.4 s today). Rebuilds only what changed: retype the
  changed modules (early cutoff on unchanged interfaces), recompile their
  functions, relink.
- Runs the program and talks to it over a small protocol (a pipe or Unix
  socket natively, a WebSocket from a dev server in the browser): `reload`,
  `assets`, `error`, `ok`. In the browser the dev server serves the page and
  swaps the island's module; natively it restarts the process.
- A dev profile may skip optimisations that cost build time but not
  correctness, only where measured to help.

Targets: a counter-sized app under 500 ms from save to pixels, the gallery
under 1.5 s. Measured as built ([dev.md](../dev.md#times)): 0.45-0.56 s for
the counter (the browser under 0.5 s, natively 0.52-0.56 s), 0.9-1.14 s for
the gallery. What is left for the counter, natively: the process starting
again (0.12-0.14 s, most of it the GL driver and the window: step 3 keeps
them), Haxe's DCE and module checks each build (0.1 s), and hxmc's lowering
replay, analyses and link over the whole program (0.18 s): reusing the last
build's program for the modules not typed again (rather than replaying
their bodies into a new one), and linking only what changed, are the next
steps there.

## 2. Fast refresh: state carried by key

- **Keys.** Every `signal(...)` in a component gets a key: the component
  instance's path in the tree (parent path plus position or its `key` prop,
  so list items keep their own state) plus the signal's static name: the
  variable it is assigned to (`var open = signal(false)` → `open`), else its
  order in the component. Names, not line numbers, so edits around a signal
  keep its key. The markup and reactive macros (packages/view) assign the
  static part at compile time.
- **State outside components** (models, stores, app-level values) opts in
  with a key of its own: `Hot.keep("cart", () -> new Cart())`, or uses the
  primitives above directly.
- **Snapshot and restore.** Before a swap the running program serializes its
  keyed values (`haxe.Serializer`) with each value's type hash from the
  compiler; the new build's signals read their value back by key when
  created, if the type hash matches. Closures, native handles and other
  non-data values are reset.
- **Disposal.** The old build's effects run their cleanups and its
  resources (timers, sockets, its GPU buffers) are released before the new
  one starts; what the host owns (window, GPU device) stays in step 3.
- **Focus, scroll and selection** are state of the UI engine, restored by
  node key the same way.

## 3. No reloads: the new build swapped in, on every target

A save never reloads the page or restarts the app, on desktop, in the
browser or on a phone: the window, the canvas, the GPU device, native views
and the page stay; only the program's code and heap are replaced. The
snapshot protocol of step 2 is the only thing that crosses: the old build
snapshots and disposes, the new one starts from the snapshot. Nothing of the
old build's heap or code is reachable from the new one, so there are no
stale closures or type data, and the runtime need not be shared.

- **Host and program.** A small dev host owns what must survive: the window
  (or canvas, or Android/iOS view), the GPU device and surface, native views,
  fonts and the event pump. The program is a module the host loads: it
  carries its own runtime and heap, and gets the host's handles at start (the
  same entry points hxmc.os uses today, given handles instead of creating
  them). Release builds are unchanged: the host exists only under
  `-D hxmc.dev`.
- **Swap.** Snapshot, dispose (the program releases its GPU buffers,
  textures, pipelines, timers, listeners and native views; the host checks
  nothing it handed out is left), unload, load the new module, start it from
  the snapshot. The last frame stays on screen until the new build's first
  frame, so nothing flashes.
- **Browser.** The page instantiates the new wasm module (streamed) against
  the same canvas, GPU device and DOM root; `imports.mjs` tracks what each
  instance registered (listeners, callbacks, observers, audio nodes) and
  drops it with the old instance.
- **Desktop (Linux, macOS, Windows).** The host executable loads the program
  as a shared library (`dlopen` / `LoadLibrary`) with a fresh name per build;
  the old one is closed once it has disposed. Needs Mach-O dylibs and Windows
  DLLs beyond today's glibc `-D hxmc.shared`.
- **Android.** The dev APK is the host (NativeActivity, the window, EGL, the
  JNI views); it is installed once. A new build's `libapp.so` is sent by the
  dev server over the network (or `adb push`) into the app's private files
  and `dlopen`ed there, which Android allows for an app's own files. No
  reinstall, no activity restart.
- **iOS.** The dev app is the host (UIKit, Metal layer, native views). In the
  simulator it `dlopen`s each new dylib. On a device, code must be signed: the
  dev server signs each dylib with the developer identity already used for
  the app (CodeSign.hx) before sending it, as device hot-reload tools do;
  whether iOS accepts that for a debug build on a device in developer mode
  is the first thing to verify. If it does not, the fallback on a device is
  the program as wasm run by an interpreter in the host (slower, for UI
  work only), and a restart is the last resort.
- **Done when** each target's dev-check edits a running program twice and
  shows the window, surface and GPU device are the same objects, state is
  kept, and no reload or restart happened; and the swap's time is measured
  next to step 1's.

### Windows: the first edit is a cold build (found Oct 19)

Measured building a small widget app against main (69d3f39) under
`Shadcn.sheet`: dev.mjs alternates `-D hxmc.dll-base` between two values
so the new DLL never lands on the old one's addresses. As a define it is
part of the compilation server's signature, so the server keeps two caches
and the first build under each base is cold: start 5.9 s, first edit 5.4 s,
then about 1 s, and 0.56 s once the base repeats; the server holds two
copies of everything (1.6 GB). The watcher is fine.

- Keep the base out of the server signature (it only matters to the
  linker), or emit relocations and `DYNAMIC_BASE` so no alternation is
  needed at all.
- Cache `Tw.sheet`'s output by the JSON's hash: it spends 0.6 s rebuilding
  the same rules on every cold build.
- A Windows dev-loop test asserting the second edit is well under the
  first.

## 4. Styles and assets without a rebuild

Theme rules are data (and CSS for the DOM renderer): a change to
`shadcn.json`, `extras.json` or the tokens sends new rules and the engine
restyles on the next frame. Images, fonts and icons reload the same way.

Moved up (Oct 19): changed rules and tokens go over `hxmc dev`'s socket
and the running app restyles in place; a build happens only for code
changes. Target: a colour or spacing edit visible in under 100 ms.

## Testing

CI runs the dev loop: start `hxmc dev` on an example, edit a file, check the
new code shows with the old signal values; change a signal's type and check
it resets with a notice; introduce an error and check the overlay and that
the last build keeps running; drop the connection and check the app recovers.
For each target: native, wasm, WasmGC once it is a browser path, JavaScript.

## Who builds what

- Here: `hxmc dev`, the compilation-server work, the protocol and dev
  server, the `Hot` primitives and their example, the keys in packages/view's macros, snapshot and restore, the host
  and shared libraries (step 3), the tests.
- The UI session: the UI engine's part (focus, scroll and selection by node
  key; disposal of what ui owns; the theme's live update).

## Order

1, then 2, with 4 alongside; 3 last (the costliest: dylibs and DLLs).
