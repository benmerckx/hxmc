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

Where a structural edit's time goes, measured with helder's edit-loop lane
(`bun run test edit-loop`: helder dev on examples/todo kept warm, a
component's body edited; Linux, 4 cores; medians of 9 edits, ms), with
helder's request written in one write (its `Resident` writes the length
and the request apart, which waits for the server's delayed ACK: 45 ms of
its `server` column, 3 ms in one write): typing 200, filters 85, lowering
125, codegen 115 (prepare 60, the modules' keys 12, data 28), link 38, the
dev loop's own 110. A profile of the server (a symbol table,
`HXMC_SYMBOLS=1`, and gdb's stacks every 3 ms) says what each is:

- **Typing**: three quarters is macro code on Eval: helder's markup macro
  for Todo.hx, and its after-typing callbacks (`HostMacro.late` asks every
  class of the program for its metadata, `c.get()`, every build: a
  quarter of the typing). The server's checks of its modules (a stat per
  file, `addModules`' restores) take 25 to 30. Mir macros would run the
  macro code compiled, but helder's compiler is not a Mir host.
- **Filters**: DCE's mark over the whole program (50). Per field, the
  marks of a field whose expression is the same object as the last
  build's could be replayed.
- **Lowering**: every body is lowered again (a replay of the last
  build's bodies saved 10 to 20 ms of a 234 ms server build of a
  380-module program, and was removed). Keeping the last build's program
  for the modules not typed again needs the numbers of globals and
  selectors not to depend on the order of the lowering (names, as `Facts`
  gives them), so that a module typed again changes only its own.
- **Prepare**: `Reach` scans every body (20): its marks could be kept per
  body (they depend on the sinks and the stacks flag); Facts' other
  passes (cold statements, types, names) are smaller.
- **Data and link**: `DataGen` compiles the dynamic and bound trampolines of
  every signature each build (10 of its 28); the link takes the 277
  modules' objects again. A dev build could link the modules compiled into
  a small shared library the dev host loads over the last (the swap host,
  `-D hxmc.shared`), and its data only what they add.
- **The collector**: minor collections and the nursery's zeroing are a
  fifth of a warm build (the old space of a resident compiler is large,
  and most of what a build makes survives it).

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
