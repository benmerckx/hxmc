# Plans: the dev loop

Open work on `haxe --dev`: the dev server, swap hosts and snapshots. What
is built: [dev.md](../dev.md).

## Principles

- **A reload is a fresh start with state carried over**, never a patch of
  live code. The new build runs from its own `main`; only data (the
  snapshot) and the host's handles survive. No stale vtables, closures or
  half-migrated objects, on every target.
- **The last good build keeps running** while the new one has errors.
- **Zero cost in release**: everything is under `-D hxmc.dev` and
  `-D hxmc.dev-host`.
- **Hooks, not a framework**: the protocol, the snapshot and the host's
  loading are documented, so any library can plug in.
- **Measured**: edit-to-run latency is tracked like build time.

hxmc owns `hxmc dev`, the protocol, snapshots and shared libraries.
Libraries (universe's `@hxmc/os`) own the host's handles (windows, GPU,
views), state primitives and fast refresh.

## Faster reloads

Reuse the last build's program for the modules not typed again, instead of
replaying their bodies into a new one, and link only what changed.

## Snapshot hooks in the std

The dev host and the snapshot primitives live in a library today. Put them
in hxmc's std so any program, with no library, can carry data across a
reload.

## Windows first edit

dev.mjs alternates `-D hxmc.dll-base` between two values so a new DLL never
loads at the old one's addresses. As a define it is part of the
compilation server's signature, so the server keeps two caches and the
first build under each base is cold (seconds instead of under one), with
everything held twice in memory.

- Keep the base out of the server's signature (only the linker needs it),
  or emit relocations and `DYNAMIC_BASE` so no alternation is needed.
- Add a Windows test asserting the second edit is much faster than the
  first.

## Assets without a rebuild

The protocol reserves `assets`: data a running build takes without a new
build (styles, images, fonts). What it carries is the library's.

## Tests

A swap-host test without a UI library: a build that hands a counter over
through the snapshot, natively as a shared library and in the browser, so
the hooks are tested in hxmc on every platform.
