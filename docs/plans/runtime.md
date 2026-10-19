# Runtime and collector

The runtime is Haxe compiled with the program (`hxmc/std/hxmc/rt`), with
no C of hxmc's own: [docs/hxmc.md](../hxmc.md), "Runtime in Haxe", and
[lowlevel.md](lowlevel.md), "The runtime without C of our own". Built
along the way: the adaptive nursery (docs/hxmc.md), the raw-address check
(`Facts.checkRawAddresses`: no address from `Mem.addr` live across a GC
point outside `@:hxmc.noGc` code), mbedtls and libuv linked per target
(docs/hxmc.md, "Targets").

## The collector, longer term

Compared with Go (concurrent non-moving mark-sweep), Swift (reference
counting) and V (Boehm's conservative collector), our precise
generational copying collector is the best fit for Haxe's allocation
patterns. Its weak points and the ideas that address them:

- Major pauses grow with the live heap (a hitch for games and graphics
  with large heaps): incremental or concurrent marking of the old
  generation, as Go does.
- Medium-lived objects: a minor collection promotes whatever survives it
  once, so the old space fills with objects that die soon after (9% of
  what tink_json allocates; [compiler.md](compiler.md), "Macro-heavy
  builds"). An aging survivor space would keep them young.
- Peak memory: the copying old generation needs a to-space during a major
  collection. A mark-region (Immix-style) or mark-compact old generation
  removes it, and lets objects be pinned in place, which simplifies C
  interop (`pin`, lowlevel.md).
- A memory limit (like Go's `GOMEMLIMIT`): collect harder as the process
  approaches a configured cap.
- Nursery sizing, still open: the port at 32 MB types itself 8% slower
  than at 16 MB (so the single-thread ceiling stays 16 MB) while its
  parallel phases like more: the ceiling is 16 MB per allocating thread (up
  to 256 MB) and TLABs at most 64 KB (the tool's cold self-build 11% faster
  and 21% less peak memory than at a shared 32 MB with 2 MB TLABs). A fixed
  16 MB nursery hurt programs whose objects die young (cache misses), which
  is why it grows only on promotion. The tool's front end at 32 MB promotes
  less (its self-build -5% peak memory, same time): a single-thread ceiling
  per program, or an aging survivor space (above), would get that.

### Frames and pauses

For UI and graphics programs the collector should know about frames, and
the items above that bound pauses come forward:

- An idle-time hook: after a frame is presented and before the next is
  due, the collector runs a minor collection or a slice of major work.
- Incremental or concurrent marking of the old generation (above), so
  major pauses stop growing with the heap.
- The aging survivor space (above), so medium-lived objects stop filling
  the old generation.
- Escape analysis ([codegen.md](codegen.md#escape-analysis)), cutting
  allocation at the source.
- The longest pause as a CI metric with a budget (say under 4 ms) on the
  frame benchmarks (the showcase examples,
  [ui-next.md](ui-next.md#showcase-examples)).

## Background work

- Images decoded and long text shaped off the main thread, results
  delivered through signals.
- An isolate-style API: run a function elsewhere and await its result,
  on threads natively and web workers in the browser; WebAssembly threads
  ([targets.md](targets.md#webassembly)) come forward if it needs them.

## Stack maps instead of the shadow stack (tried, reverted)

Tried at e91b276, reverted (git history, "Stack maps: tried and
reverted"): root slots in machine frames, frame records, a descriptor
table per code region, frameless thunks recording the last frame before C
calls. Against the shadow stack: up to 5.6% fewer instructions
(mandelbrot_anon), binarytrees -1.6%, formatter -1.4%, but nbody +0.3%,
sha256 +1.3% and the port +0.8% (its walks cost 0.9 G instructions
against 0.7 G for the shadow stack's scan), 196 KB less code in the port
and 8-12 KB more in small programs. WebAssembly needs the shadow stack
anyway; one root mechanism is simpler. Worth trying again only with:

- Per-call-site liveness (descriptors per return address instead of per
  function): no zeroing of root slots, references in registers across
  calls that only maybe collect; larger tables.
- Frame records only where needed: a function that collects only on a
  slow path pays its record on every call (nbody, sha256); its descriptor
  could give its frame size instead.
- A cheaper walk: frames without references are visited too; frames not
  resumed since the last minor collection hold no young references (a
  watermark).

## Compact strings (Latin-1 / UTF-16)

Strings are UTF-16 (32-bit length, 16-bit code units), as on hxc and
HashLink. Keep UTF-16 *semantics* (O(1) `charAt`/`charCodeAt`/`substr`,
`length` in code units, the same results as JS, HashLink, JVM, C#), but
store a string as Latin-1, one byte per character, when every character
fits, with a flag in the header (as JDK 9's compact strings and V8 do).

- Gains: about half the memory of ASCII-heavy text; UTF-8 I/O of ASCII
  text becomes a copy instead of a conversion.
- Cost: every string operation handles both representations.
- Not planned: UTF-8 semantics. It gives up O(1) indexing or
  Haxe-compatible results (`"😀".length` is 2 on UTF-16 targets) for gains
  the compact representation mostly gets anyway.
- Measured: in the port's self-compile, strings are 5.5 MB live, 1.6 MB of
  which Latin-1 storage would save (under 1% of the heap). I/O-heavy
  programs gain more than the compiler does.

## Direct system calls on Linux

With the runtime in Haxe, static Linux executables could call the kernel
directly (as Go does) and drop musl. Windows and macOS keep going through
their system libraries (kernel32/ntdll, libSystem).

## TLS and the event loop

mbedtls and libuv are built per target and linked only into programs that
use them (docs/hxmc.md, "Targets"). Possible alternatives:

- The system's TLS on Windows (SChannel) and macOS (Security.framework)
  instead of mbedtls: smaller, OS-managed certificates. Linux has no system
  TLS a static executable can use, so mbedtls stays there. Not mbedtls in
  Haxe: TLS needs constant-time, audited cryptography.
- libuv replaced by an event loop in Haxe over epoll/kqueue/IOCP: large,
  and `eval.luv`'s API is libuv-shaped; only if libuv's size or build
  becomes a problem.
- On macOS the runtime objects are linked whole (`ssl.o` is 0.8-0.9 MB):
  see [targets.md](targets.md), "macOS".
