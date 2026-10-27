# Plans: completion-based I/O

What hxmc needs for completion-based I/O backends (io_uring on Linux, IOCP
on Windows), which an event loop in Haxe would build on
([runtime.md](runtime.md#tls-and-the-event-loop)). Such a backend hands the
kernel a buffer's address and an operation, and learns later that it
completed: the address must stay valid in between, and a thread waiting
for completions must not stall other threads' collections. What is built
is in [interop.md](../interop.md#io-buffers).

## Buffers the collector does not move

The collector copies: the nursery into the old space, the old space into
its other region. A `haxe.io.Bytes`' data moves at the next collection, so
the kernel must not hold its address.

Options:

- **Pinning ordinary Bytes** (`pin`/`unpin`, or a non-moving space for
  them). Rejected. A pinned nursery object cannot be copied out, so the
  nursery could no longer be reset by one pointer move; pinned objects in
  the old space would hold back the region flip, or need a mark-region
  old generation ([runtime.md](runtime.md#collector)) first. A Bytes
  allocated together with its data (`Bytes.shared`) pins its header too.
  WasmGC's arrays cannot be pinned at all. And an operation in flight
  across threads would need its pin counted, released on completion.
- **A non-moving space for a buffer kind**: a third space the collector
  scans but never copies, with its own free lists, fragmentation and
  sweeping. Most of a mark-region old generation's work, for one type.
- **Off-heap buffers with an explicit free** (chosen). malloc'ed memory,
  owned by the operation until it completes, moved between threads as a
  value. The collector needs no change. The cost is a copy where data must
  end in a heap `Bytes`, or a view.

**Can a Bytes point outside the heap?** Yes, natively and in wasm32's
linear memory. A `Bytes` holds a `BytesData` (`NativeArray<Byte>`, header
at -8: type `T_BYTES`, words, length). Both collectors forward only
references inside their spaces (`inYoung`, `inFrom`; wasm32's granule
map) and leave the rest, as they do the static empty arrays; the write
barrier remembers only young values. So malloc'ed memory that starts
with that header is a `BytesData` the collector never touches. Not on
WasmGC, where a `BytesData` is an engine array.

**Built**: `hxmc.unsafe.IoBuffer`, a `Ptr` to a 16-byte header (whose
second word is the `BytesData` header) and the bytes. Range-tested
accessors, `blit`, `blitFromBytes`, `blitToBytes`, `getBytes`,
`ofBytes`, and `view()`: a `Bytes` over the buffer without a copy, valid
until `free`. The corpus case `IoBuffers` checks addresses and contents
through forced minor and major collections, with `RT_VERIFY=1` and a
16 KB nursery, on linux-x86_64, linux-arm64, windows-x86_64 and
wasm32-wasi.

**Left**:

- Page-aligned buffers (O_DIRECT, registered buffers): `mmap` or
  `VirtualAlloc` behind the same API.
- A pool of buffers per ring, freed with it, and a debug mode that
  poisons freed buffers (a view used after `free` reads freed memory).
- Optionally a finaliser-backed owner for buffers whose operation was
  cancelled; explicit free stays the rule.

## System calls without a C wrapper

`io_uring_setup`, `io_uring_enter` and `io_uring_register` have no glibc
or musl wrapper.

Findings: the C library's variadic `syscall(2)` is there in both Linux
modes. musl's is in `bin/hxmc/rt/linux-*/rt.o` (`T syscall`); glibc's is
in the glibc objects' import table (`libc.so.6 syscall GLIBC_2.2.5`,
`GLIBC_2.17` on arm64). Both are there because libuv calls it, not
because `mkrt.sh` lists it. `@:hxmc.varargs(1)` with six `Int64`
arguments calls it correctly on both ABIs. A raw `syscall`/`svc #0`
instruction is not needed.

**Built**: `hxmc.unsafe.Linux.syscall(nr, a..f)`, `@:hxmc.blocking`
(io_uring_enter waits), `Linux.errno()`, the io_uring numbers (425 to 427
on every architecture). The module is a compile error on other targets.
`LinuxSyscall` checks getpid, getppid, write, a failing close, and
io_uring_setup with bad arguments (EFAULT, or ENOSYS under qemu and old
kernels) in both modes and on arm64 under qemu.

**Left**: list `syscall` in `mkrt.sh`'s `libc` with the next change of
`hxmc/deps`, so that it stays when libuv no longer needs it (the corpus
case fails first). Direct system calls without musl are
[runtime.md](runtime.md#direct-system-calls-on-linux)'s.

## Blocking calls and the collector

A collection waits until every other thread is at an allocation or in a
safe region (`rt_blocking_enter`/`rt_blocking_leave`).

Findings: an extern call not declared `@:hxmc.fast` runs in a safe region
already (`MirBuild.cCall`; the references live across it are in their
shadow-stack slots). The gap: a function the runtime declares
`@:hxmc.fast` (`read`, `write`, `poll`, `nanosleep`, `Sleep`) could not be
declared otherwise in the same program ("declared both @:hxmc.fast and
not"), and there was no public way to enter the region around fast calls.

**Built**:

- **`@:hxmc.blocking`** on an extern field or class. The call site
  evaluates the arguments, enters the safe region, calls, keeps the
  result, and leaves it (`FnLower.cCall`); the symbol itself is called as
  a fast one, so the runtime's fast declaration may coexist. It takes no GC
  references and cannot be left unbalanced. No safe region on WebAssembly.
- **`hxmc.unsafe.Blocking.enter()`/`leave(region)`**: the runtime's
  markers, for loops of fast calls. The code generator already treats them
  as GC points (references stored before, read back after).
- **Nesting.** `rt_blocking_enter` returns the state it found; the end of
  the region (`rt_blocking_restore` in generated code, `Regions.end` in the
  runtime, `Blocking.leave(region)`) leaves it only when that was RUNNING.
  Chosen over a per-thread depth count: no extra state, one compare on the
  hot path, and a callback's wrapper (Haxe code called from C inside a
  region) still leaves and re-enters with the unconditional
  `rt_blocking_leave`, which a count would have to save and restore.
  Callers that ignore enter's result, as the committed stage0 does, keep
  working. `NestedRegions`.
- **`@:hxmc.blocking` on `@:hxmc.unsafe` Haxe functions**: GC-free jobs
  (a worker's inner loop) run in a region, so they no longer stall other
  threads' collections (measured: 35 to 55 ms stalls on the main thread
  without, 0.3 to 0.6 ms pauses with a region). The body is checked by
  construction: no allocation or GC point, no value of a GC type, calls
  only of blocking-safe functions (`Facts.blockingCulprit`).
  `BlockingFunctions`, `reject/Blocking*`.
- **`RT_VERIFY`**: an allocation inside a region is fatal, with a message
  (`SafeRegionAlloc`).
- **Ownership across threads**: an `IoBuffer` allocated on one thread may
  be freed on another (`IoBufferHandover`).

`BlockingCalls` checks both: two threads wait on empty pipes (`read`,
Windows' `ReadFile`) while the main thread allocates and forces
collections. Declared `@:hxmc.fast` instead, the program hangs in its
first collection.

**Left**: an event loop over io_uring and IOCP using these; a
`Blocking.run(f)` form if loops need it.

**Recorded option: loop safepoints.** Code that is not in a region and
loops without allocating stalls collections until its loop ends. Go
answers this with preemption; the cheap form here is an opt-in
`-D hxmc.loop-safepoints`: a load and branch of `rt_gc_requested` on each
loop back edge (the allocation slow path's test), taken to a safepoint
that stores the live references as an allocation does. It costs a few
percent in tight loops and needs every loop's live references in their
slots at the back edge, so it stays opt-in and unbuilt while regions and
`@:hxmc.blocking` jobs cover the known cases.
