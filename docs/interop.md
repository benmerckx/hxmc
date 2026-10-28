# C interop and low-level Haxe

How hxmc programs call C, pass memory to it, use struct values, and reach
the system beyond the std. For library authors who bind a C library or
write code that must not allocate. These APIs exist only on hxmc. Open
work is in [plans/lowlevel.md](plans/lowlevel.md).

## C interop

### Declaring C functions

```haxe
import hxmc.unsafe.*;

@:hxmc.struct @:publicFields class Rect { var x:Int32; var y:Int32; var w:Int32; var h:Int32; }

@:hxmc.lib("SDL2")                    // the library that provides the symbols
@:hxmc.c extern class SDL {
  @:native("SDL_Init") static function init(flags:UInt32):Int;
  @:native("SDL_RenderFillRect") static function fillRect(r:Ptr, rect:Ptr<Rect>):Int;
}
```

`@:hxmc.c` on an extern class makes its functions C functions, named by
their Haxe names or `@:native`. `@:hxmc.c("name")` on one function does the
same for that function.

| Metadata | |
| --- | --- |
| `@:hxmc.c`, `@:hxmc.c("name")` | a C function, called directly in the target's C convention |
| `@:hxmc.lib("name")` | the library: `lib<name>.so` (or a full name such as `libGL.so.1`), a DLL, a dylib; a wasm import module |
| `@:hxmc.link("path")` | an object or archive linked with the program (also `-D hxmc.link=`) |
| `@:hxmc.fast` | the call stays in the running state: no collection runs during it, so it may take addresses of GC objects. It must be short and must not block or call back |
| `@:hxmc.blocking` | the call runs in a safe region entered at the call site ([Blocking calls](#blocking-calls)); on a field it overrides its class' `@:hxmc.fast`; on a Haxe function it is `@:hxmc.kernel` too |
| `@:hxmc.kernel` | a kernel: a Haxe function that never touches the GC heap, memory-safe unless also `@:hxmc.unsafe`, checked, whose calls enter no safe region ([Kernels](#kernels)) |
| `@:hxmc.varargs(n)` | a variadic function with `n` fixed arguments |
| `@:hxmc.indirect` | a call through a C function pointer, the first argument |
| `@:hxmc.struct` | a class with C layout, used as a value ([Struct values](#struct-values)) |
| `@:hxmc.opaque` | a C type only ever behind a `Ptr` |
| `@:hxmc.callback` | a static function C can call ([Callbacks](#callbacks)) |
| `@:hxmc.export("name")` | a function exported under that name (shared libraries) |
| `@:hxmc.unsafe` | a function that never touches the GC heap ([Unsafe code](#unsafe-code)) |

Types (`hxmc.unsafe`): `Int8` .. `Int64`, `UInt8` .. `UInt64`, `Float32`,
`Float`, `Bool` (one byte), `Ptr<T>` (a raw address; `Ptr` alone is
`void *`), `CString`, `Slice<T>`, and `@:hxmc.struct` classes.

A call that is not `@:hxmc.fast` enters a safe region, so other threads may
collect meanwhile. Pass it native memory, not GC objects.

### Blocking calls

Collections stop the world: they wait until every other thread is at an
allocation or in a safe region. A thread waiting in C (`read`,
`io_uring_enter`, `GetQueuedCompletionStatusEx`) must be in one, or other
threads' collections wait for it.

- **Every extern call not `@:hxmc.fast`** runs in one already.
- **`@:hxmc.blocking`** says so explicitly, and works where a function is
  also declared `@:hxmc.fast` elsewhere, as the runtime declares `read`,
  `write`, `poll`, `nanosleep` and `Sleep`: the call site enters and leaves
  the safe region, evaluating the arguments before it. It takes no GC
  references.
- **`@:hxmc.blocking` on a static Haxe function**: its
  calls run in a safe region, for GC-free jobs (a loop over native memory)
  that would otherwise stall other threads' collections until their next
  GC point. It is [`@:hxmc.kernel`](#kernels), checked as such, plus
  the region: calls from GC code enter one, calls between such functions
  enter no new region. A call through a closure, or of an `inline` one
  (Haxe inlines the call away), runs outside a region: still correct, only
  not safe for collections.
- **`hxmc.unsafe.Blocking.enter()` and `leave(region)`** enter and leave
  it by hand, around fast calls in a loop or a long loop without a GC
  point. Between them: no allocation, no heap object, no address of one;
  leave on every path. Prefer the metadata.

With `RT_VERIFY=1`, an allocation inside a region ends the program with
"allocation in a safe region" (`SafeRegionAlloc`); without it, it goes
unnoticed until a collection on another thread moves what it uses.

Regions nest: `enter` returns the state it found and `leave` takes it
back, so an inner region, a `@:hxmc.blocking` call or a call not
`@:hxmc.fast` inside a region leaves it as it was; only the outermost
`leave` ends it. (A callback's wrapper still leaves the region for the
Haxe code C calls, and enters it again on return.)

```haxe
var region = Blocking.enter();
while (!done(job)) step(job);    // no allocation, no GC object
Blocking.leave(region);
```

```haxe
@:hxmc.c extern class Io {
  @:hxmc.blocking static function read(fd:Int, p:Ptr, n:Int64):Int64;
}

@:hxmc.unsafe @:hxmc.blocking static function checksum(p:Ptr<UInt8>, n:Int):Int {
  var s = 0;
  for (i in 0...n) s = (s * 31 + p[i]) & 0xFFFFFF;
  return s;
}
```

`BlockingCalls` checks it on the native targets: two threads wait on empty
pipes while the main thread collects. `NestedRegions` checks the nesting,
`BlockingFunctions` the Haxe functions, `reject/Blocking*` the rule.

### Kernels

`@:hxmc.kernel` on a static Haxe function (or on a class: each of its
functions) marks a kernel: a function that is GC-free, and memory-safe
unless also `@:hxmc.unsafe` (the safe subset, below).
GC-free means it never touches the GC heap, which the compiler checks by
construction, on the lowered body:

- no allocation and no GC point (as `@:hxmc.unsafe`, the chain of calls to
  the first one named);
- no value of a GC type anywhere: parameters, result, locals, every
  expression (string literals are static data, allowed);
- calls only of `@:hxmc.kernel` or `@:hxmc.blocking` functions and of C or
  runtime functions that are no GC point (`@:hxmc.fast` or
  `@:hxmc.blocking` externs, `Mem`, `Atomic`); no call through a closure,
  a method or a structural field.

Unlike `@:hxmc.blocking`, a call of it enters no safe region. So one
kernel serves both paths: called on the main thread like any function, and
called inside a region its caller entered (a job pool's worker, between
`Blocking.enter` and `leave`), where other threads collect meanwhile.
`@:hxmc.blocking` on a Haxe function is `@:hxmc.kernel` plus a region
entered by calls from GC code; a kernel may call a blocking one
(the region nests).

```haxe
@:hxmc.unsafe @:hxmc.kernel static function checksum(p:Ptr<UInt8>, n:Int):Int { // raw memory: also unsafe
  var s = 0;
  for (i in 0...n) s = (s * 31 + p[i]) & 0xFFFFFF;
  return s;
}

checksum(buf.ptr, buf.length);              // on this thread, no region
var region = Blocking.enter();              // a worker: other threads collect meanwhile
checksum(buf.ptr, buf.length);
Blocking.leave(region);
```

**The safe subset.** Without `@:hxmc.unsafe`, a kernel is
memory-safe too, checked on its typed body before it is lowered (so
whatever Haxe inlined into it counts as its own code, at the call's
position):

| | Allowed | Rejected |
| --- | --- | --- |
| values | Int, Float, Bool, `I64`, hxmc.unsafe's C scalars (`UInt8` ...), enum abstracts and abstracts over these, `@:hxmc.struct` values | GC types; raw memory: hxmc.unsafe's other types (`Ptr`, `IoBuffer`, `Arena`, `CString`, `Slice`) and abstracts over them |
| calls | static `@:hxmc.kernel` and `@:hxmc.blocking` functions, struct constructors (their bodies checked as the caller's), `Math`, `Std.int`, `Struct`'s constants | `Mem`, `Atomic`, `Callback`, C functions; methods, closures, structural fields |
| casts | unchecked casts between scalars | any other unchecked cast |
| statics | reads | writes, also of a struct static's fields |
| other | locals, loops, `switch` | closures, `throw`, `try`, `untyped` |

A GC type is one the lowering represents as a reference: class instances,
`String`, arrays, anonymous objects, `Dynamic`, closures, enum values (also
argument-less ones; an `enum abstract` over Int is the GC-free spelling),
`Null<Int>` and the like (boxed), an erased type parameter (`@:generic`
functions are checked per specialization). `@:hxmc.unsafe` on an inline
function does not carry into the copies Haxe inlines: an inline helper
over raw memory is rejected in safe code. Each error names the rule:

```
Kernel.hx:12: Kernel.sum: the parameter p has the raw type hxmc.unsafe.Ptr<hxmc.unsafe.UInt8> (kernel: raw memory needs @:hxmc.unsafe)
Kernel.hx:14: Kernel.sum: a write of the static total (kernel: statics are read-only in kernels)
```

`@:hxmc.kernel` plus `@:hxmc.unsafe` keeps the freedom of raw memory, as
above: the escape hatch for trusted code. `KernelFunctions` (unsafe) and
`KernelSafe` check both paths, `reject/Kernel*` the rules. The design:
[plans/io.md](plans/io.md#kernels).

### Spans

`hxmc.Span<T>` and `hxmc.ReadOnlySpan<T>` are checked views of memory for
kernels: an address and a number of elements, a value of two words.
`T` is a C scalar (`UInt8`, `Int8`, `UInt16`, `Int16`, `Int`, `UInt32`,
`Int64`, `Float32`, `Float`, `Bool`) or a `@:hxmc.struct`. A `Span`
converts to a `ReadOnlySpan`, never back.

| | |
| --- | --- |
| `s.length` | the number of elements |
| `s[i]`, `s[i] = v` | element i, checked; writing only through a `Span` |
| `s[i].x = v` | a struct element's field, in place (a `Span` only); `var e = s[i]` copies |
| `s.sub(pos, len)` | elements pos .. pos + len - 1, the same memory, checked; the same type |
| `s.reinterpret()` | the same bytes as elements of another type: `var f:Span<Float> = bytes.reinterpret()`, length * size(T) / size(U) of them |
| `dst.blit(pos, src, srcpos, len)` | a copy between spans, overlapping too, checked |
| `s.fill(pos, len, v)` | v in elements pos .. pos + len - 1, checked |
| `s.load(i)`, `s.store(i, v)`, `s.compareExchange(i, expected, replacement)` | atomic accesses of element i, checked as `s[i]`: of `Int`, `UInt` (`Int32`, `UInt32`) and `Int64` elements; sequentially consistent, so a load acquires and a store releases. `compareExchange` writes replacement if the element holds expected and returns what it held. A `ReadOnlySpan` has `load` only |

A failed check cannot throw in kernels (a throw allocates): the
program ends with exit code 2 and a message on stderr:

```
hxmc: span index 3 out of range [0, 3) at Kernel.hx:10 (Kernel.at)
```

The checks are on in every build. `-D hxmc.span-checks=0` drops the
element checks (as Burst's release builds do); ranges (`sub`, `blit`,
`fill`, the spans GC code lends) stay checked. An element check is an
unsigned compare and a branch; a span's two words stay in registers through
a loop. Measured ([plans/io.md](plans/io.md#bounds-checks)): one to one and a half
instructions per access, 1.15 to 1.45 times a raw loop's time natively,
1.1 to 1.2 on wasm32; without the checks, as fast as raw access.

**Checks a loop proves are dropped**, and the loop is then as fast as raw
access ([plans/io.md](plans/io.md#checks-a-loop-proves)). The compiler
recognizes these patterns:

- `s[i]` in `for (i in 0...s.length)` or in `while (i < s.length) { ...; i++; }`
  with i starting at 0;
- `s[i]` in `for (i in 0...n)` after the length was tested against n
  (`if (n > s.length) return ...`), or through another span of a length
  tested equal (`if (b.length != a.length) return ...`);
- a sub-span's own loop (`var m = s.sub(p, k); for (i in 0...m.length) m[i]`);
- a table's index masked below a length tested first
  (`if (t.length < 256) return ...; t[x & 0xFF]`).

Other accesses keep their check, as do counters that may start below 0 or
step by more than 1. `SpanLoops` names the checks left in each of its
kernels (the corpus's `// span-checks:` line).

**Where spans exist: only in kernels**, as parameters, locals and
results of `@:hxmc.kernel` and `@:hxmc.blocking` functions. Never a field,
a static, a struct's field, an element, a capture, a type parameter's
value. GC code makes one only as a direct argument of a call of a
kernel, which lends the memory for that call, and such a call's result
is not a span:

```haxe
@:hxmc.kernel static function adler(s:ReadOnlySpan<UInt8>):Int { ... }

var sum = adler(ReadOnlySpan.ofBytes(bytes));                       // no copy
var e = Png.decode(ReadOnlySpan.ofIoBuffer(file), Span.ofIoBuffer(rgba), Span.ofIoBuffer(scratch));
```

| Made by | The callee |
| --- | --- |
| `ofBytes(b, ?pos, ?len)` | a kernel that never enters a safe region (not blocking, calls nothing that does): a collection would move the `Bytes` |
| `ofIoBuffer(buf, ?pos, ?len)` | any kernel, `@:hxmc.blocking` too |
| `unsafeOf(ptr, length)` | its maker vouches for the memory: `@:hxmc.unsafe` code (a pool's glue), or an argument in GC code |

`ofBytes` and `ofIoBuffer` check their range in the caller
(`haxe.io.Error.OutsideBounds`). The call's other arguments are evaluated
first and the spans' addresses taken last, so nothing collects in between.
During the call only kernel code runs on the thread: it reaches no GC
point (a `Bytes` stays where it is) and frees nothing (no C, no raw memory
without `@:hxmc.unsafe`), so the memory outlives every span of it. An
`IoBuffer` keeps one owner: freeing it on another thread while a call uses
it is the owner's error, as before. A job pool owns its buffers: it
allocates them, lends them for a job's duration (on its worker, inside the
region it entered) and frees them after. Two spans over the same memory
may be passed to one call; safe code cannot hand a span to another thread.
Each error names the rule:

```
Main.hx:8: Main.main: the local s has a span type (kernel: spans exist only in kernels: only a @:hxmc.kernel function holds one)
Main.hx:3: the field last has a span type (kernel: spans live in parameters and locals only)
```

Haxe's typer applies no `@:from` in a compound assignment of an element
(as for `Ptr`): `s[i] = s[i] + 1` for a `UInt8` element, `s[i] += 1` for
an `Int` one. A struct parameter is a copy: kernel state that functions
update in place is a struct element of a span (`st[0].pos += n`).

`Spans` (every target) and `SpanOutOfRange` check the API and the failure,
`SpanInflate` a zlib inflate written on spans, over `Bytes` on the main
thread and over IoBuffers on a worker inside its region while the main
thread collects; `SpanAtomics` a worker polling a cancel flag inside its
region while the main thread sets it, and workers counting with
`compareExchange` (on wasm32, without threads, the same calls on one
thread); `reject/Span*` the rules.

### Spans on other targets

The same kernel source compiles for Eval, JavaScript and the other Haxe
targets and behaves the same there. On those targets `hxmc.Span<T>` and
`hxmc.ReadOnlySpan<T>` are views of a `haxe.io.Bytes` (an offset and a
length), and the C scalars, `hxmc.I64` and `Struct.sizeOf` and `alignOf`
are plain Haxe (`hxmc/portable`, which MkStd copies into hxmc's std as
`hxmc-portable`). `@:hxmc.kernel` is ordinary metadata there and nothing
checks it, so check a kernel by building it for hxmc. The `haxe` of
`@hxmc/cli` adds that class path to every build for another target; with
another compiler, pass `-cp <hxmc's std>/hxmc-portable`.

| | On other targets |
| --- | --- |
| `ofBytes(b, ?pos, ?len)` | a view of `b`, no copy; a bad range throws `haxe.io.Error.OutsideBounds`, as on hxmc |
| `ofIoBuffer`, `unsafeOf` | a compile error: `IoBuffer` and `Ptr` exist only on hxmc (`hxmc.unsafe`), so lend a `Bytes` instead |
| a failed check | throws `hxmc.Span.SpanError` with hxmc's message (`span index 3 out of range [0, 3)`) |
| elements | little-endian, as on every hxmc target; stores wrap as C's conversions do |
| `load`, `store`, `compareExchange` | plain accesses: safe code cannot share a span between threads |
| `reinterpret()` | needs the result's span type (`var w:Span<Int> = s.reinterpret()`), which a macro reads |

Element types: every C scalar (`UInt8`, `Int8`, `UInt16`, `Int16`, `Int`,
`UInt`, `Int64`, `Float32`, `Float`, `Bool`) and `@:hxmc.struct` classes
whose fields are scalars. The gaps:

- **Struct elements are objects of their own**, made zeroed when a span is
  reinterpreted as structs. Writes through them stay out of the `Bytes`, and
  a reinterpretation of the same memory as another type does not see them
  (`SpanInflate`'s state and tables do not overlap, so it runs unchanged).
  `s[i]` is the element itself, not a copy, as `@:hxmc.struct` values are
  references on these targets: `s[i].x = v` writes in place, but
  `var e = s[i]; e.x = v` changes the element too. Storing a struct
  (`s[i] = v`, `fill`, `blit`) copies its fields. A struct field that is
  itself a struct is hxmc's only.
- `UInt64` elements and `I64`'s increment operators are hxmc's only.
- `compareExchange` on a `Float` element throws at run time instead of
  failing to compile.

`PortableCheck` (`make portable-check`, CI's `fuzz-exec` job) builds
`SpanInflate` (its paths over `Bytes`; the worker over IoBuffers is
hxmc's) and `SpanPortable` (every element type, the views, struct elements,
the atomic accesses) with the reference compiler, runs them on Eval and as
JavaScript under node, and compares their output with the corpus's golden
files. `hxmc/test/portable` holds the failed checks and the compile errors.

### System calls

`hxmc.unsafe.Linux.syscall(nr, a, b, c, d, e, f)` calls the C library's
`syscall(2)` (musl's in static executables, glibc's with
`-D hxmc.libc=glibc`), for calls without a wrapper such as
`io_uring_setup` (`Linux.SYS_io_uring_setup`). It returns -1 on failure
and `Linux.errno()` the error. It is `@:hxmc.blocking`. Other targets
reject the module at compile time. `LinuxSyscall` checks it on Linux.

### Calls and linking

hxmc emits direct calls in each ABI's convention: System V x86-64, Win64,
AAPCS64 with its Apple and Windows variants, and wasm32's C ABI. Structs
pass by pointer and by value, on every ABI and in both directions,
callbacks included. The corpus cases `FfiStruct` and `FfiAbi` check this
against zig cc on the six native targets.

- **Static linking**: hxmc's linker reads ELF, COFF and Mach-O objects and
  archives, and links them only when referenced.
- **Dynamic libraries**: hxmc writes the import tables itself, with no SDK
  or import libraries. On Linux this needs `-D hxmc.libc=glibc`; a static
  musl executable cannot load glibc libraries such as GPU drivers.

### Native memory

The collector moves objects, so C must not keep pointers into the GC heap.
Give C native memory instead:

```haxe
Arena.scoped(a -> {
  var path = a.cstring(name);            // UTF-8 + NUL
  var buf:Ptr<UInt8> = a.alloc(4096);    // zeroed
  var n = Posix.read(fd, buf, 4096);
});                                      // freed here, also on exceptions
```

`Arena` is a bump allocator over malloc'ed chunks. `scoped` inlines, so no
closure is allocated. `a.slice(T, n)` and `a.makeArray(T, n)` hold struct
values.

`hxmc.unsafe.BytesPtr` hands a `haxe.io.Bytes` to C by its address, valid
until the next GC point: use it in a `@:hxmc.fast` call, or copy C's bytes
into one with `copyIn`.

### I/O buffers

`hxmc.unsafe.IoBuffer` is malloc'ed memory whose address stays valid
until `free`, through collections, safe regions and threads: for I/O that
keeps a buffer's address while the program runs on (io_uring, IOCP's
overlapped reads). It is a value; its owner frees it once the last
operation on it completed. Ownership may move between threads: a buffer
allocated on one thread may be freed on another (a worker fills it, the
main thread frees it). Its memory is the C library's malloc, one heap for
the process (musl, glibc, the UCRT), or the runtime's own on wasm32 (one
thread, no per-thread caches). `IoBufferHandover` checks it.

```haxe
var buf = IoBuffer.alloc(65536);             // zeroed
submitRead(fd, buf.ptr, buf.length);         // the kernel writes there later
...
buf.blitToBytes(0, bytes, 0, n);             // or buf.getBytes(0, n), buf.get(i)
var view = buf.view();                       // a haxe.io.Bytes over it, no copy
buf.free();                                  // view is invalid from here
```

Accessors (`get`, `getInt32`, `getI64`, `getDouble`, their setters,
`fill`, `blit`, `blitFromBytes`, `blitToBytes`) test their range.
`view()` wraps the buffer in a `haxe.io.Bytes` whose data is the buffer
itself: the collector moves the Bytes object, not its data, which is
outside its spaces. `IoBuffers` checks it
through forced collections.

### Callbacks

A `@:hxmc.callback` static function can be called from C. Its address is
`Callback.addr(f)`. hxmc writes the wrapper: it leaves the safe region,
sets up the thread's runtime state, and catches exceptions so they never
unwind through C. An `@:hxmc.unsafe` callback may run on any thread,
including threads the runtime does not know.

### Unsafe code

`@:hxmc.unsafe` marks a function that never touches the GC heap: no GC
allocation, no call that may collect. The compiler checks this and names
the culprit. Such functions get no shadow-stack frame or write barriers.

An address of a heap object (`Mem.addr`) is valid only until the next GC
point. The compiler rejects one that is live across a GC point outside
`@:hxmc.unsafe` code.

### WebAssembly

C functions become imports of the module `@:hxmc.lib` names (`env` by
default), with pointers as i32. An import is its module and its name:
`start` of `@:hxmc.lib("a")` and `start` of `@:hxmc.lib("b")` are two
imports, each with its own signature, and each declaration calls its own.
Declarations of one module and name are one import and must agree on the
signature. Functions the runtime implements in Haxe (`malloc`, `strlen`,
`__errno_location`, ...) are called directly when declared without a
module or with `env`. The module exports `memory`, `_start` and
`__indirect_function_table`.

Natively it is the name alone: a program's C symbols share one namespace
when linked (static linking, and ELF's search of every library loaded), so
the same name in two libraries is one function with one signature, and
signatures that differ are a compile error.

A `@:hxmc.callback`'s address is its index in that table, so JavaScript
calls it with `table.get(addr)(...)`, during an import call or after
`_start` returned. Int and Float parameters are numbers; Int64 and `Ptr`
are BigInt. A struct is the address of its memory; a struct result is
stored at an address passed first. An uncaught exception in a callback
ends the program. Output stays buffered until `Sys.stdout().flush()`.

## Struct values

`@:hxmc.struct` classes are value types:

```haxe
@:hxmc.struct class V2 {
  public var x:Float; public var y:Float;
  public inline function new(x, y) { this.x = x; this.y = y; }
}
class Body { public var pos:V2; }            // inline in the object

static function mid(a:V2, b:V2):V2           // copies in, a copy out
  return new V2((a.x + b.x) / 2, (a.y + b.y) / 2);

var p = body.pos;                            // a copy
p.x += 1;                                    // body.pos unchanged
body.pos.x += 1;                             // in place
var s = arena.slice(V2, 100);                // bounds-checked
s[3].y = 2;                                  // in place
```

- **Where they live**: locals, parameters, results, fields of classes and
  of other structs, statics, behind a `Ptr`, in a `Slice`.
- **Fields**: C scalars, `Int`, `Float`, `Bool`, `Ptr` and other structs.
  GC references are rejected.
- **Semantics**: assignment, arguments and results copy. A field accessed
  through a pointer, a struct field or an object's field is read and
  written in place. `new S(...)` zeroes the memory and runs the
  constructor. `==` compares field by field.
- **Inlining**: an inline function gets its own copy of a struct argument
  it writes to, as a call would.
- **Boxes**: where a reference is needed, the value is copied into an
  immutable box, an allocation on every store or pass (32 B for three
  Floats): `Array<S>` and `Vector<S>` elements, `Map<K, S>` values, a type
  parameter (not `@:generic`), `Dynamic` and `Std.string`, an enum argument
  that escapes, and `Null<S>`: an optional argument `?s:S` when given, a
  `Null<S>` result (boxed even when the caller only tests it for null) or
  local. `arr[i].x = 1` is a compile error: copy out, change, store back.
  In hot paths use a sentinel value (`Size.NONE`) or a `Bool` result with
  an out parameter instead of `Null<S>`, an overload instead of `?s:S`, a
  `Slice<S>` instead of `Array<S>`, `@:generic` or `inline` for generic
  code. The list and the reasons: [hxmc.md](hxmc.md#where-struct-values-are-boxed).
- **Closures** may take and return struct values, but not capture a
  struct local.
- **Performance**: scalar replacement keeps struct math in registers;
  `acc = acc + d * 0.5` over three-double vectors is three `fadd`s.

Not yet: instance methods (an abstract over the struct carries methods and
operators meanwhile), value enums, `@:generic` containers of structs, GC
references in structs.

The corpus cases `StructValues`, `StructInline`, `StructInlineOpt` and
`reject/Struct*` cover this on all seven targets.

## Processes and files beyond the std

`hxmc.NativeSys` is the system layer under `Sys`, `sys.io` and
`sys.FileSystem`. Its functions take and return descriptors and process
ids; `sys.io.FileInput` and `FileOutput` wrap a descriptor. It also has
what the std's API cannot express:

```haxe
var env = NativeSys.environment();            // a copy of this process's
env.set("RUST_LOG", "debug");
env.remove("TOKEN");
var fds = [0, 0, 0];                          // stdin, stdout, stderr
var pid = NativeSys.processRun("cargo", ["build"], fds, "crates/app", env);
```

| Function | |
| --- | --- |
| `processRun(cmd, args, fds, ?cwd, ?env)` | `cwd`: the child's working directory; one that cannot be entered creates no process. `env`: the child's whole environment, replacing this process's; the program is looked up on its `PATH` (Windows: this process's). Null: this process's |
| `environment()` | a copy of this process's environment as a map (on Windows with the `=C:` entries `Sys.environment` skips) |
| `processSignal(pid, sig)` | sends `SIGTERM`, `SIGINT`, `SIGKILL` (constants of `NativeSys`) or another signal number (those differ between Linux and macOS); false when the process is gone. A process a signal ended exits with 128 + its number. Windows has no signals: each is `TerminateProcess` with that exit code (no Ctrl+C for one process) |
| `processExitFd(pid)` | Linux: a pidfd (`pidfd_open`, kernel 5.3+), readable once the process exits, to poll with other descriptors instead of `processWait(pid, false)` each round; close it with `fileClose`, reap with `processWait`. -1 elsewhere: macOS's kqueue `EVFILT_PROC` and Windows' process handle are not exposed yet. The pid is `processRun`'s result (`Process.getPid()`) |
| `processKill(pid)` | `sys.io.Process.kill`: `SIGKILL`; on Windows `TerminateProcess` with exit code 0, as upstream |
| `statTimes(path)` | `[atime, ns, mtime, ns, ctime, ns, size]`, one stat for a watcher: seconds (`FileSystem.stat`'s, whose Dates hold whole seconds on hxmc) and nanoseconds, from `st_mtim` and the like (macOS `st_mtimespec`), Windows' `GetFileTime` (100 ns; ctime is the creation time, as `stat`'s), WASI's filestat; null when the path cannot be stat'ed |
| `fileSetBlocking(fd, blocking)` | `O_NONBLOCK` on or off; on Windows pipes only (`PIPE_NOWAIT`); false where it cannot |
| `fileRead`, `fileWrite` | bytes read (0 at the end) or written, -1 on an error, `WOULD_BLOCK` (-2) when a non-blocking descriptor is not ready (`EAGAIN`; on Windows reads only). `sys.io.FileInput` and `FileOutput` throw `haxe.io.Error.Blocked` then. With other threads running, a blocking descriptor is waited for in a safe region first; a non-blocking one is not |

Processes do not exist on wasm32-wasi.
