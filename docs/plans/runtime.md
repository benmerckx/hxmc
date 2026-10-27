# Plans: runtime and collector

Open work on the runtime (`hxmc/std/hxmc/rt`) and its collector. What is
built: [hxmc.md](../hxmc.md#runtime-in-haxe).

## Collector

The collector is precise, generational and copying, which fits Haxe's
allocation patterns. Its weak points:

- **Major pauses grow with the live heap.** Incremental or concurrent
  marking of the old generation, as Go does.
- **Medium-lived objects.** A minor collection promotes whatever survives
  it once, so the old space fills with objects that die soon after (9% of
  what tink_json allocates). An aging survivor space keeps them young.
- **Peak memory.** A copying major collection needs a to-space. A
  mark-region (Immix-style) or mark-compact old generation removes it and
  lets objects be pinned in place, which simplifies C interop.
- **A memory limit**, like Go's `GOMEMLIMIT`: collect harder near a cap.
- **Nursery sizing.** The port types itself 8% slower at 32 MB than at
  16 MB, so the single-thread ceiling is 16 MB, yet its front end promotes
  less at 32 MB. A per-program ceiling or the aging space would get both.

What the self-build's heap looks like (census, cold module cache): 12.0 GB
allocated, 1.24 GB promoted, 570 MB live at exit. Promoted: NativeArrays
363 MB, the typed AST about 280 MB, the back end's objects about 150 MB.
The back end's per-function graphs mostly die young, so moving them out of
the collected heap would save little.

## Frames and pauses

For UI and graphics programs, the collector should know about frames:

- an idle-time hook: after a frame is presented, run a minor collection or
  a slice of major work;
- incremental old-generation marking and the aging space (above);
- escape analysis to cut allocation ([codegen.md](codegen.md#escape-analysis));
- the longest pause as a CI metric with a budget, on a program that draws
  frames.

## Background work

- Images decoded and long text shaped off the main thread.
- An isolate-style API: run a function elsewhere and await its result, on
  threads natively and web workers in the browser. WebAssembly threads
  ([targets.md](targets.md#webassembly)) come forward if it needs them.

## Direct system calls on Linux

With the runtime in Haxe, static Linux executables could call the kernel
directly, as Go does, and drop musl. Windows and macOS keep their system
libraries.

## TLS and the event loop

- **System TLS** on Windows (SChannel) and macOS (Security.framework)
  instead of mbedtls: smaller, OS-managed certificates. Linux keeps
  mbedtls. Not TLS in Haxe: it needs audited constant-time cryptography.
- **libuv** replaced by an event loop in Haxe over epoll, kqueue and IOCP,
  only if libuv's size or build becomes a problem (`eval.luv`'s API is
  libuv-shaped).
- **Completion-based I/O** (io_uring, IOCP) for an async core in Haxe: the
  groundwork (off-heap buffers, `syscall`, `@:hxmc.blocking`) and what is
  left are in [io.md](io.md).

## Stack maps instead of the shadow stack

Tried and reverted (e91b276): up to 5.6% fewer instructions on some
benchmarks, but slower on others and on the port, and WebAssembly needs
the shadow stack anyway. Worth trying again only with per-call-site
liveness, frame records only where needed, and a walk that skips frames
not resumed since the last minor collection.

## Tried, not kept

- Array growth from 4 elements instead of 2: no gain, more allocated.
- The passes' per-function tables outside the collected heap: 0.16%.
- Inflate with its state in locals: faster natively, slower on WasmGC (since
  removed: worth measuring again).
- The write barrier testing the value's youth before its slow call: within
  noise, 2.6% more code.
