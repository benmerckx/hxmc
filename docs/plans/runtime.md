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
  frame benchmarks (a program drawing frames: universe's showcase
  examples are candidates).

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

Built. Strings keep UTF-16 *semantics* (O(1) `charAt`/`charCodeAt`/`substr`,
`length` in code units, the same results as JS, HashLink, JVM, C#), stored
as one of two types, as V8's one-byte and two-byte strings
(`hxmc.rt.Types`, [heap-layout.md](heap-layout.md#strings)): `T_STRING1`
(17) a byte per unit, every unit below 0x100, and `T_STRING` (16) UTF-16.

- Either type may hold a string whose units all fit in a byte (as in V8):
  no result depends on the type, only the time it takes. Equality,
  comparison, hashing (FNV-1a over the units, as before) and search take any
  pair; a pair of each type compares unit by unit.
- What makes strings makes one-byte ones where every unit fits: the
  literals (`DataGen`), UTF-8 decoding (its counting pass notes a lead byte
  of 0xC4 or more, or a malformed byte), substrings (a two-byte string's
  range narrowed when it fits), numbers, `charAt`, `fromCharCode`, case
  mapping (but the upper cases of U+00B5 and U+00FF), StringBuf (one-byte
  storage until a unit above 0xFF comes, then widened; `toString` narrows a
  two-byte buffer whose units fit), Windows' wide strings. A concatenation
  with a two-byte string is two-byte.
- Code generation (`MirBuild`): `charCodeAt` loads the type and branches,
  `StringBuf.addChar`'s inline path takes a unit below 0x100 into one-byte
  storage with room (one comparison tests both), string equality is
  unchanged (the lengths, then `hx_str_eq_slow`, which compares the types).
- WasmGC keeps UTF-16 strings (`GcRepr`'s one-byte operations are its
  two-byte ones).
- Not planned: UTF-8 semantics. It gives up O(1) indexing or
  Haxe-compatible results (`"😀".length` is 2 on UTF-16 targets) for gains
  the compact representation mostly gets anyway.

Measured (Xeon E-2356G, 6 cores / 12 threads, Linux 6.1; the port's
self-compile to HXB, pinned to one core, 8 interleaved runs on a quiet
machine, medians; HXB identical):

| | UTF-16 | compact | |
| --- | --- | --- | --- |
| instructions | 31,845.7 M | 32,205.3 M | +1.1% |
| cycles | 16,551 M | 16,546 M | 0.0% |
| time (task clock) | 3,779 ms | 3,775 ms | −0.1% |
| peak RSS | 657 MB | 638 MB | −2.9% |
| allocated | 5,209 MB | 4,969 MB | −4.6% |
| minor collections | 327 (0.85 s) | 312 (0.71 s) | |
| live strings at exit | 17.6 MB | 13.6 MB | −23% |
| the port's executable | 20,826,176 B | 20,621,376 B | −1.0% |

The instructions added are the lexer's: a branch per unit read
(`Lexer.token`, `mIdent`, `startsAt`, about +240 M), well predicted;
copies, decoding and the collector take fewer (`memcpy` −89 M,
`Gc.drainMinor` −77 M, `Str.ofUtf8` −63 M). Programs that embed text gain
most: 4.0 M units of source as 257 literals make an executable of 4.74 MB
instead of 8.28 MB (−43%).

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
