# The dev loop: the target's mechanism

Save a file, see the change. The target's part of it, which hxmc keeps:
`hxmc dev` (the dev server and the resident compiler), swap hosts (a build
as a library a host process loads, so the process and what it holds
survive a new build) and snapshot hooks (a build hands data to the next).
What runs on top, state libraries and fast refresh by key, a UI's windows
and GPU contexts kept across swaps, lives in libraries: universe's
`@hxmc/os` is the first (<https://github.com/benmerckx/universe>, its
`docs/plans/dev-loop.md` and `docs/dev.md`). Built: [docs/dev.md](../dev.md).

## Principles

- **A reload is a fresh start with state carried over**, never a patch of
  live code. The new build runs from its own `main`; what survives is data
  (the snapshot) and the host's handles. So a reload behaves exactly like a
  cold start with the same values, on every target (native, linear wasm,
  WasmGC), and there are no stale vtables, closures or half-migrated
  objects.
- **The last good build keeps running** while the new one has errors.
- **Zero cost in release**: everything is under `-D hxmc.dev` and
  `-D hxmc.dev-host`.
- **Measured**: edit-to-run latency is tracked like build time.
- **Hooks, not a framework**: the protocol, the snapshot and the host's
  loading are documented, so any library (a UI, a game loop, a server) can
  plug in, and live reload works on every platform or can be driven from
  outside.

## 1. Live reload (built)

`hxmc dev [build.hxml]` (and `npx haxe --dev ...`):

- Watches the class paths, libraries' sources and hxml files the build
  names.
- Keeps the compiler resident (the compilation server: typed modules,
  lowered bodies and compiled objects in memory; a no-change rebuild of a
  small program is about 0.4 s). Rebuilds only what changed.
- Runs the program and talks to it over a small protocol (a TCP connection
  natively, a WebSocket in the browser): `reload`, `assets`, `error`, `ok`;
  a program that does not answer is restarted.
- Next for speed: reusing the last build's program for the modules not
  typed again (rather than replaying their bodies into a new one), and
  linking only what changed.

## 2. Snapshot hooks (built)

Before a swap the running build writes its snapshot (a string; the file
`HXMC_DEV_SNAPSHOT` natively, the page's imports `hxmc_dev` in the
browser), and the new build reads it at its start. What goes in it, and how
values are keyed and checked against a changed type, is the state
library's (universe's `hxmc.dev.Hot`). Next: the hooks in hxmc's std, so
that a program without a library can carry data too.

## 3. Swap hosts (built for Linux, macOS, Windows, Android, the iOS simulator)

A small host owns what must survive (a window, a GPU device, native views,
a socket); each build is a module the host loads, with its own runtime and
heap, given the host's handles at start. Swap: the old build snapshots and
disposes, returns from main (its heap given back: `Gc.releaseHeap`), the
host loads the new module and starts it from the snapshot. Nothing of the
old build's heap or code is reachable from the new one.

- **Desktop.** Shared libraries hxmc writes: ELF in the glibc mode, Mach-O
  dylibs, Windows DLLs (`-D hxmc.shared`, `-D hxmc.exports`,
  `-D hxmc.dll-base`), with a fresh name per build.
- **Android.** The dev APK is the host; a new build's library is sent into
  the app's private files and `dlopen`ed there.
- **iOS.** In the simulator the app `dlopen`s each new dylib. On a device
  code must be signed: whether a dylib signed with the developer identity
  loads in a debug build is the first thing to verify; else the fallback is
  the program as wasm run by an interpreter in the host (PR #15's MIR
  interpreter is a candidate), and a restart is the last resort.
- **Browser.** The page instantiates the new module against the same
  canvas and device; what an instance registered with the page is dropped
  with it.

## Windows: the first edit is a cold build (found Oct 19)

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
- (A library's build macro that rebuilds the same data on every cold build,
  as the theme's did, is the library's to cache.)
- A Windows dev-loop test asserting the second edit is well under the
  first.
## 4. Styles and assets without a rebuild

The protocol reserves `assets`: data a running build takes without a new
build (styles, images, fonts). What it carries is the library's.

## Testing

`make dev-check`: `hxmc dev` on a console program through edits and a
compile error, the compilation server's builds against fresh ones. Next:
a swap host test without a UI library (a build that hands a counter over
through the snapshot, natively as a shared library and in the browser), so
the hooks are tested in hxmc on every platform.

## Who builds what

- hxmc: `hxmc dev`, the compilation server's work, the protocol and the dev
  server, the snapshot file and imports, shared libraries and DLLs, the
  tests above.
- Libraries (universe): the host's handles (windows, GPU, views), the state
  primitives and fast refresh, styles without a rebuild.
