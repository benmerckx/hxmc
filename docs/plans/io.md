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
  allocated together with its data (`Bytes.shared`) pins its header too. And an operation in flight
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
with that header is a `BytesData` the collector never touches.

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

## Kernels

A job pool runs kernels (a decoder's inner loop over native
memory) on its threads inside a safe region, so that the main thread's
collections never wait for them (helder's jobs: 0.5 ms pauses instead of
35 to 55 ms). Two things stood in the way:

- `@:hxmc.blocking` checks that a function is GC-free but requires
  `@:hxmc.unsafe`, which allows raw pointers: "GC-safe" meant
  "memory-unsafe".
- `@:hxmc.blocking` merged two things: "this function is GC-free" and "a
  call of it runs in a safe region". One kernel could not serve both the
  synchronous path (the main thread, no region) and the job path (inside
  the pool's region).

The design, built in steps (a PR each):

1. the attribute (built);
2. the memory-safe subset (built);
3. spans, checked views of buffers, and where they may
   exist (built);
4. the bounds checks' define and their measured cost (built);
5. a leaf routine of the std moved onto the subset.

### The attribute

**Built**: `@:hxmc.kernel` on a static Haxe function or a class
([interop.md](../interop.md#kernels)) marks a kernel: GC-free, and
memory-safe unless also `@:hxmc.unsafe`. GC-free: no GC point, no value
of a GC type, calls only of kernels (`Facts.kernelCulprit`, on the
lowered body, every build), and its calls enter no region.
`@:hxmc.blocking` on a Haxe function is `@:hxmc.kernel` plus the region
entered by a call from GC code.

The name says what the function is for, not only what it avoids. It is
not `nogc`: `@:hxmc.noGc` is `@:hxmc.unsafe`'s former name, still
accepted, and an attribute that differed from it only in case would
silently mean the other thing.

### The safe subset

**Built**: without `@:hxmc.unsafe`, a kernel is memory-safe.
Checked on the typed AST before lowering (`KernelCheck`), so the errors point at the
expression; what Haxe inlined into the function is checked as its own code:

| Rule | Allowed | Rejected |
| --- | --- | --- |
| values | Int, Float, Bool, `I64`, hxmc.unsafe's C scalars, enum abstracts and abstracts over these, `@:hxmc.struct` values, spans | GC types (below); raw memory: hxmc.unsafe's other types (`Ptr`, `IoBuffer`, `Arena`, `CString`, `Slice`) and abstracts over them |
| calls | static `@:hxmc.kernel`/`@:hxmc.blocking` functions, `Math`, `Std.int`, `Struct`'s layout constants, spans' accessors | `Mem`, `Atomic`, `Callback`, C functions; methods, closures, structural fields |
| casts | unchecked casts between scalars | any other unchecked cast (a struct as another, an Int as a span) |
| statics | reads | writes (also of a struct static's fields) |
| other | locals, loops, `switch`, struct values | closures, `throw`, `try`, `untyped` |

`@:hxmc.kernel` plus `@:hxmc.unsafe` keeps today's freedom: the escape
hatch, for trusted code (a pool's glue, the runtime).

**What "GC type" means**: what the lowering represents as a reference.
Class instances, `String` (literals too: they are objects, if static
ones), arrays and Vectors, anonymous objects, `Dynamic`, closures, enum
values (argument-less ones too: references to static objects; an
`enum abstract` over Int is the GC-free spelling), `Null<T>` of a basic
type (boxed), and an erased type parameter. Constants: `inline` ones are
literals; a `static final` or `static var` of a flat type may be read.
Writing statics is rejected for determinism (two jobs writing one), not for
memory safety: a torn flat value is a wrong value, never corruption.

### Spans

**Built** ([interop.md](../interop.md#spans)): checked views of memory, values of two words (the
address and the length), in `hxmc`: `Span<T>` (writable) and
`ReadOnlySpan<T>`, distinct types; a `Span` converts to a `ReadOnlySpan`,
never back. `T` is a C scalar (`UInt8`, `Int8`, `UInt16`, `Int16`, `Int`,
`UInt32`, `Int64`, `Float32`, `Float`, `Bool`) or a `@:hxmc.struct`.

| | |
| --- | --- |
| `s.length` | the number of elements |
| `s[i]`, `s[i] = v` | element i, range-checked; writing only through a `Span` |
| `s[i].x = v` | a struct element's field, in place (a `Span` only); `var e = s[i]` copies |
| `s.sub(pos, len)` | elements pos .. pos + len - 1, the same memory, range-checked; the same type |
| `s.reinterpret()` | the same bytes as elements of another type, `var f:Span<Float> = bytes.reinterpret()`: length * size(T) / size(U) of them, rounded down |
| `dst.blit(pos, src, srcpos, len)` | a copy between spans (overlapping too), range-checked |
| `s.fill(pos, len, v)` | v in elements pos .. pos + len - 1 |
| `s.load(i)`, `s.store(i, v)`, `s.compareExchange(i, e, r)` | atomic accesses of an `Int`, `UInt` or `Int64` element, range-checked (Atomic's sequentially consistent operations: a job's cancel flag, a shared counter); `load` on a `ReadOnlySpan` too |

**Layout and alignment.** Element i is at the address plus i * size(T),
the size of `T`'s C type (a struct's C layout: `Struct.sizeOf`, a multiple
of its alignment). Nothing requires alignment: an IoBuffer's bytes are
16-byte aligned natively and 8 on wasm32, a `Bytes`' data 8, and `sub` or
`reinterpret` at an odd offset gives misaligned elements, which x86-64,
arm64 (normal memory) and wasm32 (alignment is a hint) load and store
correctly, slower only where an access crosses a cache line. On wasm32 the
address is a 32-bit linear-memory address held in the 64-bit word `Ptr`
uses everywhere; the checks keep every access inside the span, so inside
the memory too.

### Where spans exist: only in kernels

**The rule.** A span is a parameter, local or result of a `@:hxmc.kernel`
(or `@:hxmc.blocking`) function, and nothing else: never a field, a static,
a struct's field, an array element, a closure's capture, a type
parameter's value, `Dynamic`. GC code never holds one: it makes one only as
an argument of a direct call of a kernel, and such a call's
result is not a span:

```haxe
var sum = Adler32.of(ReadOnlySpan.ofBytes(bytes));                     // the synchronous path, no copy
var e = Png.decode(ReadOnlySpan.ofIoBuffer(file), Span.ofIoBuffer(rgba)); // several buffers: several arguments
```

| Made by | Valid for | The callee |
| --- | --- | --- |
| `ofIoBuffer(buf, ?pos, ?len)` | the call | any kernel, `@:hxmc.blocking` too |
| `ofBytes(b, ?pos, ?len)` | the call | a kernel that never enters a safe region (not blocking, calls no function or C function that does: `FuncInfo.blocks`): a collection would move the Bytes |
| `unsafeOf(ptr, length)` | what its maker vouches for | `@:hxmc.unsafe` code: a pool's glue |
| `s.sub`, `s.reinterpret` | as `s` | |

The range of `ofIoBuffer` and `ofBytes` is checked where they are made,
in GC code (`haxe.io.Error.OutsideBounds`). The other arguments are
evaluated first, the spans' addresses taken last, just before the call, so
nothing between the two collects.

**Why not what helder proposed.** Three shapes were weighed:

- *Span types local-only in all code* (`var s = Span.of(buf)` in GC code,
  never stored): leaves `var s = Span.of(buf); buf.free(); s[0]` within
  one function, which only a flow analysis of frees would catch.
- *A generation in each buffer that `free` changes, checked at access*:
  sound, but a load and compare on every access, the cost that made
  helder.scoped lose.
- *A scoped call with a callback and a borrow count*
  (`buf.read(s -> kernel(s))`, `free` fatal while borrowed): sound only
  if the callback stays a closure. Inlined (Haxe inlines a function
  literal passed to an inline function), `outer = s` inside it becomes an
  assignment of the caller's own local, which the compiler cannot tell
  from one inside the scope, and the span outlives it. Not inlined, each
  call allocates a closure, the callback (GC code) may free the buffer
  (hence the count), several buffers need nested callbacks, which may not
  capture the outer span, and a `Bytes` cannot be lent at all (the
  callback may collect).

The call is the scope instead. During a call of a kernel
nothing but kernel code runs on the thread, which cannot free (no C
functions, no raw memory without `@:hxmc.unsafe`), so a buffer cannot be
freed under its span on that thread, by construction: no count, no state
per buffer, nothing per access, nothing at run time but two words per
span. Several buffers are several arguments, and a `Bytes` can be lent
without a copy, as `BytesPtr` lends it today, but checked. What it gives
up: GC code never sees a span. Code that reads a buffer from GC code reads
the IoBuffer or Bytes itself, or is a kernel.

**Soundness.** The claim: whenever safe code reads or writes through a
span, the span's memory is allocated and does not move.

1. *Where spans come from.* A boundary argument (above), `unsafeOf` in
   `@:hxmc.unsafe` code (trusted), or `sub`/`reinterpret` of a span,
   which stay inside its memory.
2. *Where they go.* Only through parameters, locals and results of
   kernels: a kernel has no GC value, so no heap object, array,
   closure, box or `Dynamic` can hold one; struct fields and statics of a
   span type are rejected (a struct may be stored anywhere, also by GC
   code); GC code may not declare a span local or parameter, nor receive a
   span result. An inline function taking a span, called from GC code,
   puts the span into GC code: rejected.
3. *So spans live in the frames of one boundary call.* Every span on a
   thread's stack was made by a boundary call further down the same stack
   (or by trusted code), and dies before that call returns. A
   kernel returns a span only to a kernel caller, and what it returns
   came from its arguments or from trusted code: returned spans are
   derived from spans the caller already holds. (helder's "returned only
   as a sub-view of a parameter" holds without a flow check, because no
   other source exists.)
4. *During the boundary call the memory stays.* The thread runs only
   kernel code. It reaches no GC point, so other threads' collections
   wait for it and a `Bytes` does not move; a `@:hxmc.blocking` callee lets
   them run, which is why `ofBytes` requires one that never enters a
   region. It frees nothing: safe code calls no C function and holds no
   raw handle.
5. *What stays the owner's contract.* An IoBuffer has one owner, as
   before: freeing it on another thread while a call uses it, or making a
   span of one already freed, is the owner's error (`IoBuffer` is
   hxmc.unsafe's). A job pool owns its buffers: it allocates them, makes
   the spans for a job's duration and frees them after.

**Aliasing and races.** Two spans over overlapping memory, also two
writable ones, may be passed to one call: memory-safe, since elements are
flat values and `blit` is a `memmove`. Safe code cannot hand a span to
another thread (no static written, no closure, no heap); only trusted code
(the pool) puts spans on several threads, and its contract is that a
writable span never overlaps another span used at the same time on
another thread. If that is broken, the results are wrong values, never
corruption: a span's address and length are values in the thread's own
frame and registers, and every access is checked against them; only the
elements' bytes race.

### Bounds checks

On in every build, debug or release. A failed check in kernels cannot
throw (a throw allocates); it ends the program with a message naming the
index, the length and the function's position, as an out-of-bounds access
does in Burst's checked builds or a Rust panic with `panic=abort`.

**Built**: `-D hxmc.span-checks=0` drops the element checks (as Burst's
release builds do); ranges (`sub`, `blit`, `fill`, the boundary's) stay
checked (`SpanChecksOff`). An element check is `ult(i, length)` and a
branch to a call in a loop without an exit: the path never joins the
access again, so nothing lives across the call (before that, an axpy took
34 instructions an element instead of 21). A span parameter's two words are
copied into the callee's own slot, which scalar replacement keeps in
registers (the caller's memory would be read again after every store). An
element of a C scalar with an indexed access of Mem's (`getU8At`,
`setF64At` and the like) is reached through it: a scaled address, no
multiply.

**Measured** (`hxmc/test/micro/SpanBench.hx`, 2026-10-28, a shared 4-core
Xeon at 2.1 GHz, buffers of 64 KB in the cache: the cost of the access,
not of memory): a byte sum (loads, Adler-32's inner loop) and a Float axpy
(`y[i] = a * x[i] + y[i]`: two loads and a store, three checks), each raw
(Mem's indexed loads and stores, the fastest raw form) and on spans.

| | sum, raw | sum, span | axpy, raw | axpy, span |
| --- | ---: | ---: | ---: | ---: |
| x86-64, instructions an element (callgrind), checked | 10 | 11 (+10%) | 12 | 16 (+33%) |
| x86-64, instructions an element, `span-checks=0` | 10 | 9 | 12 | 12 |
| x86-64, ns an element, checked (median of 7, three runs) | 0.81-0.99 | 1.03-1.14 | 0.74-0.80 | 1.05-1.17 |
| x86-64, ns an element, `span-checks=0` | 0.79-0.87 | 0.56-0.58 | 0.99-1.40 | 0.75-0.80 |
| wasm32 under node 22, ns an element, checked | 0.54-0.55 | 0.61-0.66 | 0.69-0.70 | 0.73-1.13 |
| wasm32 under node 22, ns an element, `span-checks=0` | 0.55-0.60 | 0.52-0.54 | 0.77-1.05 | 0.77-0.89 |

So a checked access costs one to one and a half instructions: in time 1.15
to 1.3 times the raw loop for the byte sum and 1.4 to 1.45 for the axpy
natively, 1.1 to 1.2 for the sum on wasm32 (the axpy within that
machine's noise). Without the checks a span is as fast as raw access, or
faster (its length stays in a register). The checks are not removed where a
loop proves them yet (`for (i in 0...s.length)`): the next step.

### Inlining, generics, closures

- **Inlining.** An inline function's body becomes the caller's code and is
  checked as such (the error's position is the call's). So an inline
  helper over raw memory (`IoBuffer.get`, a `Ptr` wrapper's) is rejected in
  safe code: call a non-inline `@:hxmc.unsafe @:hxmc.kernel` function
  instead. `@:hxmc.unsafe` on an inline function does not carry into the
  copies Haxe inlines.
- **Generics.** A value of a type parameter is erased to a reference
  (boxed): a GC value, rejected. `@:generic` functions are specialized per
  type and each specialization checked. A span of an unresolved `T` is
  rejected (no element type to access).
- **Closures and dynamic calls** are rejected: making a closure allocates,
  and a call through one, through an interface or a virtual method, or
  through a structural field has a callee the check cannot see.

### Errors

Each names the rule and the expression:

```
Kernel.hx:12: Kernel.sum: the parameter p has the raw type hxmc.unsafe.Ptr<hxmc.unsafe.UInt8> (kernel: raw memory needs @:hxmc.unsafe)
Kernel.hx:14: Kernel.sum: a write of the static total (kernel: statics are read-only in kernels)
Kernel.hx:20: the field last has a span type (kernel: spans live in parameters and locals only)
Main.hx:8: Main.main: a span made outside a call's arguments (kernel: spans exist only in kernels; pass ReadOnlySpan.ofBytes(...) as an argument of a @:hxmc.kernel function)
Main.hx:9: Main.main: a span over a Bytes is passed to Kernel.sum, which lets other threads collect (a safe region) while the Bytes may move (kernel: a Bytes is lent only to a kernel that enters no region; lend an IoBuffer's instead)
Kernel.hx:30: Kernel.reset: a write through a read-only span (kernel: a ReadOnlySpan cannot be written through)
```
