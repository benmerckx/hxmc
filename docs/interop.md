| `@:hxmc.unowned` of an Objective-C object | `__unsafe_unretained`: the id itself, stored and read as it is, nothing at dealloc ([Unowned fields](#memory)) |
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
| `@:hxmc.c`, `@:hxmc.c("name")` | a C function, called directly in the target's C convention; on a static `var`, a C variable ([C variables](#c-variables)) |
| `@:hxmc.lib("name")` | the library: `lib<name>.so` (or a full name such as `libGL.so.1`), a DLL, a dylib; a wasm import module |
| `@:hxmc.link("path")` | an object or archive linked with the program (also `-D hxmc.link=`) |
| `@:hxmc.fast` | the call stays in the running state: no collection runs during it, so it may take addresses of GC objects. It must be short, must not block, and calls back only callbacks that never collect (`@:hxmc.unsafe`: [Callbacks](#callbacks)) |
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

### C variables

```haxe
@:hxmc.c @:hxmc.lib("shapes") extern class Shapes {
  @:native("shapes_count") static var count:Int;  // read and written
  static final shapes_name:CString;               // read only (a `const`)
  static var shapes_origin:Point;                 // a @:hxmc.struct
}
```

A static `var` of a `@:hxmc.c` class (or with `@:hxmc.c` on the field) is
the C variable of its name, its `@:native` name or `@:hxmc.c("name")`, in the
program, a linked object, the `@:hxmc.lib` library or the
`@:hxmc.framework` (a framework's constants: `NSFontAttributeName`, whose
value only AppKit knows). A read loads it, an
assignment stores it, both at its address, so C and Haxe see each other's
writes. Its type is a scalar, `Ptr`, `CString` or a struct: a struct read is
a copy, `v.x = 1` writes its field in place and `v = s` all of it. Declare a
`const` one `final`: the store would fault. One of an Objective-C type
(`NSString *`) is read as a borrowed id; hxmc does not store one (C
would hold it strongly: ARC retains and releases such stores).

The address is a word of the program's data that the loader fills, as C's
GOT entries: a bind on macOS, an `R_*_64` relocation on Linux, the import's
slot on Windows (a DLL's variable). WebAssembly imports no variables.

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
- GC values only as loans (below), and none at all in a kernel that
  enters a safe region (`@:hxmc.blocking`, or one that calls one): other
  threads collect meanwhile;
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
| values | Int, Float, Bool, `I64`, hxmc.unsafe's C scalars (`UInt8` ...), enum abstracts and abstracts over these, `@:hxmc.struct` values; GC values as loans | raw memory: hxmc.unsafe's other types (`Ptr`, `IoBuffer`, `Arena`, `CString`, `Slice`) and abstracts over them |
| calls | static `@:hxmc.kernel` and `@:hxmc.blocking` functions, struct constructors (their bodies checked as the caller's), `Math`, `Std.int`, `Struct`'s constants, `Mem`'s functions of values (`ult`, `udiv`, `urem`; the bit casts `f64Bits`, `bitsF64`, `f32Bits`, `bitsF32`) | `Mem`'s other functions, `Atomic`, `Callback`, C functions; methods, closures, structural fields |
| casts | unchecked casts between scalars | any other unchecked cast, and one to a proof (below) |
| statics | reads | writes, also of a struct static's fields |
| other | locals, loops, `switch` | closures, `throw`, `try`, `untyped` |

**Loans.** A kernel that enters no safe region may be lent GC values:
nothing collects while it runs, so nothing moves or frees what it was
handed (`Span.ofBytes`' rule, for every GC type). It holds them in locals,
passes them to kernels, returns them and compares them with `null`; it
never stores one (it has no write barrier) and never reads inside one by
a field, an index or an operator. What is inside is read through a view: a
kernel that knows the layout and gives it out checked, as `hxmc.rt.StrView`
does a string's (its length, its width, its units as a `ReadOnlySpan`).
The views are the trusted part, `@:hxmc.unsafe`; what reads through them
is checked. A view's functions are inlined where they are called, as the
inline representation calls they stand for were, and a kernel called at
one place of its module is inlined there whatever its loops (`KernelOnce`):
a kernel per width, as `count1` and `count2`, costs no call.

```haxe
@:hxmc.kernel static function count(s:String, u:Int):Int
  return StrView.isOne(s) ? count1(StrView.units1(s), u) : count2(StrView.units2(s), u);
```

**Proofs.** A view can hand out a value that vouches for something, so
that the view reads with it unchecked: `hxmc.rt.TypeView`'s `TypeIndex`
is an index of a row of the type table, which `TypeView.kind(t)` and
`sup(t)` read without a bound check. Such a type is an abstract marked
`@:hxmc.proof` (or an abstract over one), and only `@:hxmc.unsafe` code
makes one. A safe kernel holds, passes, compares and returns a proof;
it never casts to one, nor takes another value where one is expected (a
`Dynamic` unboxed). GC code could make one from anything, so only
kernels and `@:hxmc.unsafe` code call a function that takes a proof, and
such a function is no value (no closure, no reflection). No static, no
struct field and no span element is a proof: GC code writes those, and a
span of bytes reinterpreted would make them.

```haxe
@:hxmc.proof abstract Slot(Int) to Int {}

@:hxmc.kernel @:hxmc.unsafe class Slots { // the view: the one place that makes a Slot
  public static function of(i:Int):Slot return cast(i & 7);
}

@:hxmc.kernel static function slot(i:Int):Int
  return Slots.of(i);  // `return (cast i : Slot)` is rejected
```

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
`KernelSafe` check both paths, `KernelProofs` proofs, `KernelBits` Mem's functions of values, `reject/Kernel*` the rules. The design:
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
| `s.getI64(i)`, `s.getI32(i)` | the 8 or 4 bytes from element i on as one integer (little-endian, any alignment), checked as `sub(i, 8 / size(T))`: of elements of 1, 2, 4 or 8 bytes (a string's units a word at a time) |
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
  (`if (t.length < 256) return ...; t[x & 0xFF]`);
- a window: `c[i + k]` and `d[k]` comparing d's m units at each i, after
  `if (m < 1 || m > c.length) return ...`, with `k < m` and i counting up
  from a value tested `>= 0` while `i < c.length - m + 1`, or down from
  one tested `<= c.length - m` while `i >= 0` (`SpanWindows`).

A test of two lengths at once counts as two (`if (n > a.length || n >
b.length) return ...`). A range (`sub`, `fill`, `blit`, a word) is proved after
`if (p < 0 || p > s.length - k) return ...` for a constant k, or `... ||
k < 0 || p > s.length - k` for any (`SpanRanges`); in a loop stepping a
word at a time, `while (i < n - 8) { s.getI64(i); ...; i += 8; }` (a word
at `i + d` too when `n - c` leaves room for it), and at `n - 8` after `n >=
8` (`SpanWords`).

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
files. `hxmc/test/portable` holds the failed checks, the compile errors
and spans of private structs.

### System calls

`hxmc.unsafe.Linux.syscall(nr, a, b, c, d, e, f)` calls the C library's
`syscall(2)` (musl's in static executables, glibc's with
`-D hxmc.libc=glibc`), for calls without a wrapper such as
`io_uring_setup` (`Linux.SYS_io_uring_setup`). It returns -1 on failure
and `Linux.errno()` the error. It is `@:hxmc.blocking`. Other targets
reject the module at compile time. `LinuxSyscall` checks it on Linux.

The system's random bytes, `getentropy(3)` and `getrandom(2)`, are C
library functions for an `@:hxmc.c` extern (or the C a program links): in
the static mode musl's, on Android Bionic's, on macOS libSystem's
`getentropy`. glibc 2.17, the floor of `-D hxmc.libc=glibc`, has neither:
use `syscall` there. `LinuxEntropy` checks them in the static mode.

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
`Callback.addr(f)`. hxmc writes the wrapper: it leaves the caller's safe
region and enters it again on return, sets up the thread's runtime state,
and catches exceptions so they never unwind through C. A `@:hxmc.fast` call
has no safe region: a callback it calls must be `@:hxmc.unsafe` (it never
collects); another one ends the program with a message, as the call's
caller holds references a collection would not update. An `@:hxmc.unsafe`
callback may run on any thread, including threads the runtime does not know.

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
signatures that differ are a compile error. Declarations of a variadic
function (`@:hxmc.varargs(n)`) may differ in their variadic arguments,
which each call passes its own, as C allows (`syscall` with three
arguments and with six), when they agree on `n`, the fixed arguments and
the result, and no variadic argument is a struct; on WebAssembly, one
import, they agree on all of it.

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
- **Layout**: C's, the variables in declaration order. DCE keeps every
  variable of a struct it keeps (`-dce full` too), named in code or not.
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

## SIMD vectors

`hxmc.simd`'s nine 128-bit types (`F32x4`, `F64x2`, `I8x16`, `U8x16`,
`I16x8`, `U16x8`, `I32x4`, `U32x4`, `I64x2`) are struct values of 16 bytes
kept in vector registers (SSE4.1 on x86-64, NEON on arm64, simd128 on
wasm32), with WebAssembly simd128's operations and results on every
target, and a scalar implementation with the same results on the Mir
interpreter, Eval, JavaScript and other Haxe targets:

```haxe
import hxmc.simd.*;

@:hxmc.kernel static function gain(s:Span<UInt8>, n:Int, g:Float) {
  var k = F32x4.splat(g), lo = F32x4.splat(-1), hi = F32x4.splat(1);
  var i = 0;
  while (i + 4 <= n) {
    (F32x4.loadSpan(s, i * 4) * k).clamp(lo, hi).storeSpan(s, i * 4);
    i += 4;
  }
}
```

- **Operations**: arithmetic (wrapping; `addSat`/`subSat` saturating),
  `min`/`max` (NaN-propagating) and `pmin`/`pmax`, `mulAdd` (not fused),
  comparisons to masks, `select`, constant-index shuffles and swizzles,
  widening and saturating narrowing, conversions (truncating,
  saturating), `sum`, `any`, `all`, `bitmask`.
- **Memory**: `load`/`store` on `Bytes` (checked), `loadSpan`/`storeSpan`
  on spans in kernels, `loadPtr`/`storePtr` (`@:hxmc.unsafe`); unaligned,
  16 bytes or the low 8 or 4.
- **As values**: the struct rules. Boxed in an `Array`, a `Map`, a type
  parameter's slot, `Null` and `Dynamic`; passed to Haxe functions by
  address.
- **In C signatures**: C's native vector type (`__m128`, `float32x4_t`,
  `vector_size(16)`), in a vector register (System V, AAPCS64; by address
  on Win64, result in xmm0); on wasm32 by address. At most eight, none
  variadic.
- **Requirements**: an x86-64-v2 machine (SSE4.1) for a program that uses
  them; a WebAssembly engine with simd128.

The design, every semantic decision, the ABIs and the benchmarks:
[plans/simd.md](plans/simd.md). The corpus cases `SimdOps`, `SimdValues`,
`SimdExamples`, `SimdFfi` and `reject/Simd*`.

## Objective-C

On macOS and iOS, Objective-C classes are declared as extern classes and
used as Haxe classes: messages, properties and initializers are typed, and
Haxe classes can extend them. The SDKs' frameworks are declared in
generated libraries ([below](#the-sdks-declarations)); the examples here
declare their own. Open work and the reasons behind the design:
[plans/objc.md](plans/objc.md).

```haxe
import hxmc.objc.Selector;

@:hxmc.lib("/usr/lib/libobjc.A.dylib") @:hxmc.objc extern class NSObject {
  static function alloc():NSObject;
  function init():NSObject;
  @:hxmc.framework("Foundation")                    // a category of another framework's
  function description():NSString;
}
@:hxmc.framework("AppKit") @:hxmc.objc extern class NSView extends NSObject {
  static function alloc():NSView;                   // statics are not inherited
  function initWithFrame(frame:Rect):NSView;
  var frame(get, set):Rect;                         // a property
  function get_frame():Rect;                        // frame
  function set_frame(v:Rect):Rect;                  // setFrame:
  var flipped(get, never):Bool;                     // read-only
  @:selector("isFlipped") function get_flipped():Bool;
  function addSubview(view:NSView):Void;            // addSubview:
  function convertPoint(point:Point, fromView:Null<NSView>):Point;  // convertPoint:fromView:
  function hitTest(point:Point):Null<NSView>;
}

class RowView extends NSView {                      // a Haxe class AppKit calls
  final onClick:() -> Void;
  public function new(frame:Rect, onClick) {
    super.initWithFrame(frame);                     // self = [super initWithFrame:frame]
    this.onClick = onClick;
  }
  override function get_flipped() return true;     // AppKit sees it
  override function hitTest(point:Point):Null<NSView>
    return inside(frame, point) ? this : null;
}

var v = NSView.alloc().initWithFrame(new Rect(0, 0, 100, 20));
v.frame = new Rect(0, 0, 50, 20);
row.addSubview(v);
if (command == Selector.of("moveDown:")) ...
```

### Declarations

| | |
| --- | --- |
| `@:hxmc.objc` | an extern class (its extern subclasses too) is an Objective-C class: its values are `id`s; `@:hxmc.objc("Name")` or `@:native` names it at run time. On a Haxe class extending one: an Objective-C class written in Haxe ([below](#objective-c-classes-in-haxe)) |
| `@:hxmc.framework("AppKit")` | the class is the system framework's (`/System/Library/Frameworks/AppKit.framework/AppKit`; on Mac Catalyst, iOS's frameworks are `/System/iOSSupport`'s: [hxmc.md](hxmc.md#mac-catalyst)); `@:hxmc.lib("path")` names another library. Per class, not inherited (a subclass is often another framework's) |
| `@:selector("a:b:")` | a method's selector, instead of the derived one |
| `@:hxmc.framework("Foundation")` on a member | declared by a category of another framework: that framework is loaded when the member is sent (a class's reference loads only its own) |
| `@:getter("isX")`, `@:setter("setX:")` | the accessors of a property written as a plain `var`, instead of `x` and `setX:` (Haxe's own metadata, read as Flash reads it) |

- **Selectors** follow from the names: a method's name, then each
  parameter's name after the first, each with a colon:
  `setObject(o, forKey)` is `setObject:forKey:`, `count()` is `count`.
- **Initializers** are what they are in Objective-C: `C.alloc()`, then an
  instance method of the init family on its result:
  `NSString.alloc().initWithContentsOfFile(path, enc, null)`. No `new`
  (an error says so): initializers taking the same types
  (`initWithString:`, `initWithContentsOfFile:`) keep their own names, a
  failable one returns `Null<C>`, and they are inherited as methods are.
  `alloc` is declared by each class (statics are not inherited). An
  inherited initializer needs no redeclaring for its result's type: a
  message of the init family gives an object of the receiver's class, as
  clang's related result type has it (`NSTextField.alloc().initWithFrame(r)`
  is an `NSTextField`).
- **Properties** are `var x(get, set)` with extern accessors: `get_x()` sends
  `x`, `set_x(v)` sends `setX:` and returns `v` (the setter returns nothing),
  `@:selector` on an accessor names another (`getter=isFlipped`).
  `(get, never)` makes one read-only. A Haxe class extending the class
  overrides `get_x` or `set_x`, and Objective-C calls the override. A plain
  `var x` works too (reading sends the getter, writing the setter; `@:getter`,
  `@:setter`), but cannot be overridden. A `static var` is a class property
  (`NSScreen.mainScreen`), a static method a message to the class.
- **Types** in messages are those of C calls: scalars, `Ptr`, `@:hxmc.struct`
  values (by value, both ways), Objective-C classes (`id`), Haxe classes
  extending them (their `id`), `Selector`. `Null<NSView>` is an `id` whose
  nil is `null`, never a box.
- **`Selector.of("name:")`**: a selector as a value, from a string literal.

### Calls

A message is `objc_msgSend` called in the C types of the method, a static
one's receiver the class object, in a safe region (Cocoa calls back into
Haxe from inside messages). Nothing is looked up by name at run time: the
program has clang's `__objc_classrefs` (bound by the loader, which loads
the framework) and `__objc_selrefs` (made unique by libobjc when it maps
the image, which `__objc_imageinfo` asks for), so `otool -ov` reads a
program as it reads clang's. On x86-64, a message whose result is a struct over 16
bytes is sent with `objc_msgSend_stret` (`objc_msgSendSuper_stret`), as
the ABI has it.

A method (or property) declared `@:hxmc.fast` is sent without a safe region,
as a fast C function is called: about 2 ns instead of 8 on Apple Silicon. It
must be short and must not block (other threads' collections wait for
it). It must not call back into Haxe either, as a fast C call must
not ([Callbacks](#callbacks)): a method of a Haxe class Objective-C calls
from it ends the program with a message, so `containsObject:`, which sends
`isEqual:` to the objects it holds, is no fast message when they may be
Haxe objects.

A variadic method is declared with its named parameters, then `...rest`
(`arrayWithObjects(firstObj:Null<NSObject>, ...rest:NSObject)`: `rest` is
no piece of the selector); a message passes the arguments listed for it as
a variadic function's (on Apple's arm64, on the stack), objects only for
now, and `nil` after them when the method is `@:hxmc.nilTerminated`
(`NS_REQUIRES_NIL_TERMINATION`). A spread array (`...xs`) is an error: its
length is not the call's.

### Haxe classes extending Objective-C classes

A Haxe class whose superclass is an Objective-C class is an Objective-C
class too, registered at its first construction (under libobjc's lock,
as `@synchronized`, for threads registering at once). Its constructor makes
its Objective-C object by calling one of the superclass's initializers,
`super.initWithFrame(frame)` (`[[C alloc] initWithFrame:frame]` of the
new class), or `init` before its body when it calls none. Each instance is two objects: the Haxe object, which holds
the `id` in a hidden field, and the Objective-C object, whose instance
variable leads back to it.

- **Methods** Objective-C can call: the class's own instance methods whose
  types C has. An override of an Objective-C method takes its selector and
  types; a new method's selector is derived from its names (a delegate's
  `control(control, textView, doCommandBySelector)` is
  `control:textView:doCommandBySelector:`). Calls from Haxe are Haxe calls.
  Objective-C may call them on any thread: one the runtime did not start
  (an `NSThread`, GCD's workers) is attached at its first call, as a
  block's.
- **Made by Objective-C** (`[[C alloc] initWithCoder:coder]` of a nib, a
  document controller, a factory such as `+errorWithDomain:code:userInfo:`):
  the initializer the constructor calls on super (`init` when it calls none)
  is the class's own, which, sent to an object Objective-C allocated, runs
  the constructor with the initializer's arguments, making the Haxe object
  of that object (its field initializers too); its constructor's
  parameters must be the initializer's (their C types). A subclass without
  a constructor of its own has its superclass's. The object is paired with
  its Haxe object before the initializer runs, so methods the superclass's
  initializer sends find it. A method sent to an object made with another
  initializer, which runs no Haxe constructor, ends the program with a
  message. An initializer returning another object than its receiver
  (class clusters) is not supported in a Haxe constructor.
- **`dealloc`**: an override runs once, as a finaliser
  (`hxmc.rt.Gc.finalise`), when the object is unreachable from both sides:
  its fields and its Objective-C object still there, on a thread that
  allocates or runs the finalisers. It is no Objective-C method:
  Objective-C's own `dealloc` runs afterwards, when a later collection
  releases the object, as ARC's does; `super.dealloc()` to Objective-C is an
  error (to a Haxe superclass's override, a call). Not at exit, as in
  Objective-C.
- **Class methods** (`+`): a static implementing one an Objective-C
  superclass declares (`+cellClass`, `+description`) or one of a protocol
  the class adopts (a static of the extern interface, which Haxe allows
  there: `+supportsSecureCoding`, `+readableTypesForPasteboard:`) is its
  class's, on the metaclass, with the declaration's selector and types; a
  subclass's static of the name overrides it, and subclasses inherit it.
  Other statics are Haxe's only. A protocol's class method has no receiver:
  sending it to the protocol is an error. `hxmc.objc.ObjCClass.of(C)` is the
  class object of C (an `Id`), for APIs that take classes and send them
  class methods (`readObjectsForClasses:options:`, `restorationClass`).
- **`super.f(...)`** to an Objective-C method sends `objc_msgSendSuper`,
  looked up from the Objective-C superclass (`super.set_frame(v)` in an
  override of `set_frame`); struct results come back both ways.
- **Exceptions**: a Haxe exception leaving a method Objective-C called is
  raised as an Objective-C exception ([Exceptions](#exceptions)).
- **Hierarchies**: a Haxe class extending such a class is an Objective-C
  class of its own, registered after its superclass's; the class
  allocated is the instance's own, whichever constructor calls the
  initializer.
- **Passing** an instance where an `id` goes passes its `id`; `cast` turns
  an `id` of such a class back into its Haxe object (unchecked).
- **Ownership** of results is ARC's: a method of the `copy`, `mutableCopy`
  or `new` family (`copyWithZone:`) returns its result retained, the
  caller's to release.

### Objective-C classes in Haxe

A Haxe class declared `@:hxmc.objc` and extending an Objective-C class is
an Objective-C class and nothing else: its objects are Objective-C objects,
`id`s as an extern class's are, without a Haxe object beside them (no
peer, no toggle reference). It is what Objective-C would write, for code
that makes many of them and wants no second heap's object per instance.

```haxe
@:hxmc.objc class Field extends NSTextField implements NSTextFieldDelegate {
  @:hxmc.weak var props:Null<Attrs>;             // a Haxe object kept alive elsewhere
  @:hxmc.weak var buddy:Null<NSView>;            // Objective-C's __weak
  var count:Int;                                 // an instance variable
  var label:Null<NSString>;                      // strong, as ARC's
  override function initWithFrame(r:CGRect):Field {
    super.initWithFrame(r);                      // self = [super initWithFrame:r]
    delegate = this;
    return this;
  }
  override function respondsToSelector(s:Selector):Bool
    return s != Selector.of("controlTextDidEndEditing:") && super.respondsToSelector(s);
  public function controlTextDidChange(n:NSNotification) {
    count++;
    if (props != null) props.changed(stringValue);
  }
  override function dealloc() trace('gone after $count edits');
}

var f = Field.alloc().initWithFrame(r);          // an id, as NSTextField's
```

- **The class** is registered at its first use (its class object: `alloc`,
  a type test, `ObjCClass.of`), as a peer class's, under its name
  (`@:hxmc.objc("Name")`, else its path with underscores), after its
  superclass when that is one too. Apple's systems only.
- **Making one** is Objective-C's: `C.alloc().init...(...)`, a `C`
  without a cast. No Haxe constructor (an error). The compiler declares
  the class's `alloc` (`public extern static function alloc():C;`, as an
  extern class declares its own: statics are not inherited) unless the
  class does, and types a message of the init family to an object of an
  Objective-C class as clang does: its result is of the receiver's class
  (Objective-C's related result type: `init`, then anything but a
  lowercase letter), so `C.alloc().initWithFrame(r)` is a `C`, not the
  `NSView` `initWithFrame:` is declared to return. An
  initializer is a method of the init family, an override or the class's
  own (`initWithCount(n)`), that calls `super.initX(...)` and returns
  `this`. That call is `self = [super initX:...]`: `this` is its result
  from then on, so a superclass's initializer returning another object (a
  class cluster's) is followed. As ARC's, an initializer consumes its
  receiver and returns its result retained.
- **Methods**: each instance method is a method of the Objective-C class
  (`class_addMethod`), `this` its receiver. An override, or a method a
  protocol declares, takes that method's selector and types; a new one's
  selector follows from its names ([Declarations](#declarations)). Their
  types are messages' (an error otherwise). A call, from Haxe too, is a
  message: a subclass's override answers it, Objective-C's own subclasses'
  too; `super.f(...)` sends `objc_msgSendSuper`. A method as a value and a
  dynamic method are errors.
- **Statics** with a body are Haxe's, called as Haxe statics; one that
  implements a class method a superclass or protocol declares is also the
  class's (`+`), as a peer class's. An `extern` static is a message to the
  class.
- **Fields** are the object's instance variables (`class_addIvar`), read
  and written in its memory (`this.count`, `other.count`). They start
  zeroed, as Objective-C's: an initializer on a field is an error (nothing
  would run it; set it in an initializer method).

| Field | |
| --- | --- |
| a number, `Bool`, `Ptr`, `Selector`, a `@:hxmc.struct` value | stored as C stores it (a struct's fields written in place) |
| an Objective-C object (`Null<NSString>`, a `Block<F>`) | strong, as ARC's: a store retains the new value and releases the old one (`objc_storeStrong`); dealloc releases it |
| `@:hxmc.weak` of an Objective-C object | `__weak`: `objc_storeWeak` on the variable itself (the object does not move); a read is nil once the object is gone, borrowed (`objc_loadWeakRetained`, autoreleased: read it in a pool on a thread without a run loop); destroyed at dealloc |
| `@:hxmc.weak` of a Haxe value (an object, a function) | a slot of the collector's weak table ([hxmc.md](hxmc.md#the-collector)): the object moved with it, null once it is collected; freed at dealloc |

  A weak field is `Null<...>`. Any other Haxe value is an error: an
  Objective-C object cannot own a Haxe value (yet); hold it weakly and keep
  it alive elsewhere.
- **`dealloc`** is the class's own, always: the `dealloc` the class
  declares (if any) runs first, then its instance variables let go (strong
  ones released, weak ones destroyed, slots freed, each left zero), then the
  superclass's (`super.dealloc()` is an error). Not `.cxx_destruct`, which
  ARC's instance variables use: the runtime calls it only for a class whose
  image says it has one, never for a class made at run time. A dealloc that
  the runtime's own releases send, where Haxe code cannot run (the
  collector's, of an id a dead Haxe object held; `Peers.detach`'s), is put
  off: the thread sends it again at its next allocation, or when
  `hxmc.rt.Gc.collect` returns, or as it ends, in an autorelease pool of its own (what it
  autoreleases, such as a view's subviews, goes then, not with whatever
  pool the thread has); the object stays, deallocating (weak references to
  it nil), until then.
- **Values**: as an extern class's. `Std.isOfType` and `Std.downcast` are
  `isKindOfClass:` messages; an array, a closure, `Dynamic` or a type
  parameter bound to `Id` hold its ids as any ([Memory](#memory)).
  `Reflect` and `Type` see what they see of an extern class.
- **Allowed**: protocols (adopted, with `@:optional` methods left out and
  `respondsToSelector:` overrides), a peer class extending such a class
  (its methods messages, its instance variables reached through the id),
  one such class extending another. A Haxe interface is an error.

### Protocols

A protocol is an extern interface declared `@:hxmc.objc` (`("Name")` for
its name at run time). Its values are `id`s, its methods messages, as a
class's; an interface it extends is a protocol it adopts.

```haxe
@:hxmc.objc extern interface NSXMLParserDelegate extends NSObjectProtocol {
  @:selector("parser:foundCharacters:") @:optional function foundCharacters(parser:NSXMLParser, s:NSString):Void;
}
class Collector extends NSObject implements NSXMLParserDelegate {
  public function foundCharacters(parser:NSXMLParser, s:NSString) ...
}
parser.delegate = new Collector();
```

- **Implementing** one: a Haxe class extending an Objective-C class (any
  other is an error) adopts it: its Objective-C class conforms to it
  (`class_addProtocol`) and to those it extends, and a method implementing
  one of the protocol's takes its selector and types, as an override does
  (an own `@:selector` that differs is an error). The protocol objects are
  the runtime's (`objc_getProtocol`); one no image declares is made, empty.
- **Optional methods** (and properties) are `@:optional` (the typer's
  semantics of a Java interface's `default` methods): a class may leave
  them out, and then
  Objective-C sees no such method (`respondsToSelector:` says no, which is
  what Cocoa asks of a delegate). Calling one from Haxe sends the message,
  which a subclass may answer, else is Objective-C's "unrecognized
  selector".
- **Tests**: `Std.isOfType(x, P)` and `Std.downcast` of an Objective-C
  object are `conformsToProtocol:` for a protocol, `isKindOfClass:` for a
  class: messages, as Objective-C asks them (a proxy forwards them).

### Lightweight generics

A type parameter bound to an Objective-C type (`hxmc.objc.Id`, any object,
or a class or protocol) holds `id`s: in a message, in Haxe code generic
over it (`class Box<T:Id>`), in an `Array<T>`. An extern class takes them as
Objective-C's lightweight generics, with Haxe's defaults where none is
given:

```haxe
@:hxmc.objc extern class NSArray<ObjectType:Id = Id> extends NSObject {
  static function arrayWithObject<ObjectType:Id>(o:ObjectType):NSArray<ObjectType>;
  function objectAtIndex(i:I64):ObjectType;
  static inline function upcast<T:U, U:Id>(a:NSArray<T>):NSArray<U> return cast a;
}
var strings = NSArray.arrayWithObject(ns("x")); // NSArray<NSString>
var any:NSArray = NSArray.upcast(strings);      // NSArray<Id>
```

- **Id** is any Objective-C object: the root classes and protocols extend
  it. It is no protocol of the runtime's (no class is said to conform to
  it); `Std.isOfType(x, Id)` is true of any object.
- **Variance**: Haxe's type parameters are invariant, as Objective-C's
  mutable collections' (`NSMutableArray<NSString *>` takes no other
  object). An immutable collection, covariant in Objective-C, is widened
  explicitly (`upcast` above): to the immutable class only.
- A static method has none of its class's parameters: it declares its own
  (`alloc<ObjectType:Id>()`, the expected type giving them).

### Blocks

A function type in a message's signature is a block: a parameter, a
result, a property; in a Haxe method Objective-C calls too. Elsewhere (a C
function's parameter, a field, a value) `hxmc.objc.Block<F>` is one: an
`id`, held as ids are, converted from and to a function `F`.

```haxe
@:hxmc.objc extern class NSArray extends NSObject {
  function enumerateObjectsUsingBlock(block:(obj:NSObject, idx:Int64, stop:Ptr) -> Void):Void;
}
@:hxmc.c extern class Dispatch {
  static function dispatch_async(queue:Ptr, block:Block<() -> Void>):Void;
}
arr.enumerateObjectsUsingBlock((o, i, stop) -> sum += i);
Dispatch.dispatch_async(Mem.sym("_dispatch_main_q"), () -> done = true);
```

- **A function made a block** is a heap block, autoreleased as every
  value. Its closure stays alive while the block does (whoever holds it),
  and becomes collectable once Objective-C frees it. The block holds the
  index of the closure's entry in the runtime's table of blocks, a root
  while a block refers to it (the block's copy and dispose helpers count
  them); its invoke, one per signature, finds the closure by it. Null is nil.
  A function capturing nothing (a static function, a lambda reading only
  statics) is a global block instead, in the program's data: one per
  function and signature, never copied nor freed, so making it costs
  nothing (not on a Mir host, which has no static closures).
- **A block made a function** calls the block, holding a reference to it;
  a block made of a Haxe function is that function again. A block on its
  caller's stack (an argument: Foundation passes completion handlers so)
  is copied first, so the function may be kept after the call.
- **Calls** run the closure as a method's entry does: out of the caller's
  safe region, a Haxe exception leaving it raised as an Objective-C one
  ([Exceptions](#exceptions)). A thread the runtime did not start (GCD's
  workers) is attached at its first call.
- **Types**: those of messages, a block's parameter or result of function
  type a block too (a handler given a completion handler, as NSDocument's
  `performAsynchronousFileAccessUsingBlock:`). On x86-64, a struct result
  over 16 bytes is returned through memory (`BLOCK_USE_STRET`).

### Exceptions

```haxe
try {
  NSArray.array().objectAtIndex(5);
} catch (e:NSException) {
  trace(e.name());                          // NSRangeException
}
try {
  view.perform(Selector.of("layoutHaxe")); // a Haxe method throwing MyError
} catch (e:MyError) {}                      // the same MyError, past performSelector:
```

- **An Objective-C exception** reaching a Haxe frame (an `NSException` a
  message raised, `@throw` of any object) is a Haxe throw of the object
  there, as though the message had thrown it: `catch (e:NSException)` tests
  its class (`isKindOfClass:`), `catch (e:Dynamic)` gets it, and
  `haxe.Exception`'s message and `Std.string` are its `description` (an
  `NSException`'s reason). The message's caller is the frame it reaches:
  the unwinder runs Objective-C's cleanups (`@finally`, ARC's releases) up
  to it, and Haxe's handlers take it from there.
- **A Haxe exception leaving a method or block** Objective-C called (or a
  constructor an initializer it sends runs) is raised as an Objective-C
  exception once the method's entry took the caller's state back: an Objective-C object is raised itself, another
  value as an `NSException` named `HaxeException` whose reason is
  `Std.string` of the value. It unwinds Objective-C's frames as their own
  exceptions do (an `@catch` there sees it), and is the Haxe value again in
  the next Haxe frame. Without Foundation (no `NSException`), it is
  reported as an uncaught one and ends the program.
- **Type tests** of an Objective-C class or protocol on a value of another
  type (a caught one, a `Dynamic`) test that it is an Objective-C object
  first: a `String` is no `NSException`.
- **A C callback** (`@:hxmc.callback`) is no method: an Objective-C
  exception reaching a Haxe frame under it is a Haxe throw there too, and
  goes on as Haxe throws do (an `@catch` of the C code calling the callback
  does not see it).
- **Natively**: the program's Haxe functions name a personality routine in
  their unwind tables (`__eh_frame`, with the program's first Objective-C
  reference), which claims an Objective-C exception for the first Haxe
  frame the C++ ABI's search reaches and resumes that frame in the
  runtime's catch. Exceptions of C++ pass through Haxe frames as before.

### Objects of C

```haxe
extern class CGColor implements hxmc.objc.Id {}
extern class CGPath implements hxmc.objc.Id {}
extern class CGMutablePath extends CGPath {}   // a CGMutablePathRef goes where a CGPathRef does

@:hxmc.c @:hxmc.framework("CoreGraphics") extern class CG {
  @:hxmc.retained static function CGColorCreateSRGB(r:Float, g:Float, b:Float, a:Float):CGColor;
  static function CGColorGetAlpha(c:CGColor):Float;
}
```

Core Foundation's types and those built like them (Core Graphics', Core
Text's: `CGColorRef`, `CTFontRef`) are opaque pointers to objects that are
Objective-C objects at run time, of the class `__NSCFType`. An extern class
implementing `hxmc.objc.Id` without `@:hxmc.objc` anywhere in its chain is
such a type: its values are ids, held by Haxe's storage as any (see
[Memory](#memory)), passed to and returned from C functions. It has no class
object: no messages to the class, no `Std.isOfType` (every one is an
`__NSCFType`), and no Haxe subclasses (only a `@:hxmc.objc` class can be
subclassed); extern classes may extend it.

- **Ownership**: a C function's object result is borrowed, as the Get
  rule's (`CGColorGetComponents`); `@:hxmc.retained` marks one the caller
  owns, as the Create rule's (`CGColorCreate`, `CTFontCopyFullName`),
  autoreleased at once as `new`'s and `copy`'s are. Releasing them by hand
  (`CFRelease`, `CGColorRelease`) unbalances the count: hxmc releases what
  it holds.

### Memory

Haxe objects stay collected by the GC; Objective-C objects are reference
counted. Where references cross:

| | |
| --- | --- |
| a local, an argument, a result | borrowed, as an autoreleased object in Objective-C: valid until its autorelease pool is drained (the run loop drains one per event) |
| a field, a static, a closure's capture, a captured variable a closure assigns | holds a reference, as ARC's strong variables: a store retains the new value and releases the old one, the holder's death (the object, the closure, the variable's box) releases it |
| a reference position: `Array<NSView>`, `Map<K, NSView>`, a type parameter, `Dynamic` | the `id`'s one box, holding a reference, released when the box dies (one per `id`, so `==`, `indexOf` and map keys see one object); an instance of a Haxe class extending an Objective-C one is its Haxe object |
| an instance of a Haxe class extending an Objective-C one | as Xamarin's toggle references: while Objective-C retains its object (beyond the Haxe object's own reference), the Haxe object is a root; otherwise it is collected like any other, and its Objective-C object released |

- **Method families**, as ARC names them: `alloc`'s result is kept for the
  initializer that follows; an initializer consumes its receiver, and its
  result, as `new`, `copy` and `mutableCopy` results, comes retained and
  is autoreleased at once, so every value is borrowed alike.
  A Haxe object whose class extends an Objective-C one, becoming an `id`, is retained and
  autoreleased too, so its toggle reference keeps it while a local holds
  the `id`.
- **`==`** on `id`s compares the objects, without boxes.
- **Letting go early**: a paired Haxe object holds its Objective-C object
  until a collection finds the Haxe object dead; one in the old space,
  until a major collection. `hxmc.objc.Peers.detach(o)` gives the object
  up at once (the Haxe object or an `id` of it), for an owner that knows it
  is done with it (a UI library's unmounted view): Objective-C frees it as
  soon as it lets go. Messages through `o` then go to nil; calls Objective-C
  still makes into its class reach `o` while the object lives. An object
  no Haxe object is paired with (an extern class's, an Objective-C mode
  class's) is held by its box, which every Haxe holder of it shares:
  `detach` releases it at once and the box holds nil from then on (the id
  boxed again later gets a box of its own). Without it,
  `RT_PEER_BUDGET` (1000; 0: off) paired objects and boxes gone to the old
  space start a major collection: the collector does not see the memory
  their Objective-C objects hold.
- **Pools**: the run loop drains one per event;
  `hxmc.objc.AutoreleasePool.run(() -> ...)` drains one around a loop of
  many messages or on a thread hxmc started (also when `f` throws). Code
  outside any (`main` before `run`) autoreleases into the program's
  outermost pool, which the runtime pushes around `main` as clang's
  `@autoreleasepool` does, and which drains only when `main` returns. A
  collection releases the ids of dead Haxe objects in a pool of its own, so
  what their deallocs autorelease (a view its subviews) goes with them.
- **Strings**: `hxmc.objc.Strings.toNSString(s)` and `ofNSString(ns)` copy
  unit for unit (both are UTF-16, one byte per unit where every unit
  fits), not through UTF-8: a lone surrogate survives, and a long string
  converts many times faster. Ids are `Ptr` there; `cast` makes one an
  `NSString` of the declarations.
- **Weak fields**: `@:hxmc.weak var owner:Null<NSView>` holds no reference;
  reading it gives nil once the object is gone, so its type must be
  `Null<...>` (as Swift's weak variables are optional). Its variable is a cell
  outside the heap (`objc_storeWeak` keeps the variable's address, and a
  field moves with its object), destroyed with the object.
- **Unowned fields**: `@:hxmc.unowned var parent:NSView` holds the id
  only, as Objective-C's `__unsafe_unretained` and Swift's
  `unowned(unsafe)`: no reference, no cell, nothing when its holder dies.
  For an object the program keeps alive otherwise for as long as the field
  is read, such as a view its window holds; read after the object is gone,
  it is a dangling pointer (a crash, or another object at the same
  address). A short-lived Haxe object (a cursor over a view's subviews)
  holding a strong id keeps the object until a collection finds the holder
  dead; an unowned field does not, at no cost.
  A `-debug` build checks them: each is held weakly instead, and reading
  one that is not `Null<...>` after its object is gone ends the program
  with a message naming the field (`ObjCUnownedCheck`).
- **Cycles** through both heaps (a Haxe object's field holds a view, the
  view holds a Haxe subclass's instance whose field holds the Haxe object)
  are not collected: neither side sees them. Cocoa's delegates are weak,
  which avoids the common one; `@:hxmc.weak` breaks others.

In the compiler an `id` is its own IR type (`TId`): an `i64` at run time,
kept apart from `TI64` so that stores, boxing and equality know it.
In the runtime this is the first kind of foreign objects (`hxmc.rt.ObjCKind`
over `hxmc.rt.Foreign`), which [COM](#com) and [JNI](#java-jni) share
([plans/foreign-objects.md](plans/foreign-objects.md)).

### The SDKs' declarations

Declarations of the SDKs' headers are generated by
[extern-generator](https://github.com/hx-objc/extern-generator), for the
whole macOS and iOS SDKs and Mac Catalyst, and published as libraries in
[hx-objc](https://github.com/hx-objc). A program depends on its target's
library, which brings the shared ones:

| targets | library | brings |
|---|---|---|
| `macos-arm64`, `macos-x86_64` | [apple-appkit](https://github.com/hx-objc/apple-appkit) | `apple-shared`, `apple-shared-mac` |
| `ios-arm64`, `ios-sim-arm64` | [apple-uikit](https://github.com/hx-objc/apple-uikit) | `apple-shared`, `apple-shared-uikit` |
| `macos-catalyst-arm64`, `macos-catalyst-x86_64` | [apple-catalyst](https://github.com/hx-objc/apple-catalyst) | `apple-shared`, `apple-shared-uikit`, `apple-shared-mac` |

`apple-shared` has what the three platforms declare alike,
`apple-shared-uikit` what iOS and Mac Catalyst do, `apple-shared-mac`
what macOS and Mac Catalyst do. A program using only Foundation, Core
Graphics or another framework every platform has depends on its target's
library too: a type is in a shared library only where its declaration is
the same on those platforms, and
Foundation's main classes are not: other frameworks add to them per
platform (`NSString` takes AppKit's drawing methods on macOS, UIKit's on
iOS). The shared libraries are not for use on their own. A program links
only the frameworks whose declarations it uses, however many the
libraries declare.

Matter (`apple-matter`) and macOS's legacy frameworks
(`apple-appkit-legacy`: OpenGL, QuickDraw, ..., and classes deprecated
as a whole) are libraries of their own, for any platform's library to add.

Each library is a Git repository that is also an npm package and a
haxelib, used as `-lib <name>`:

- npm: `npm install -D github:hx-objc/apple-appkit` (hxmc takes an npm
  package with a `"haxe"` field in its `package.json` as a library);
- lix: `lix install gh:hx-objc/apple-appkit`. A lix scope's `.haxerc`
  makes VS Code's Haxe extension start the compilation server with
  `--wait stdio`, which hxmc does not have: in VS Code, use npm;
- haxelib: `haxelib git apple-appkit https://github.com/hx-objc/apple-appkit`
  (its `haxelib.json` names its dependencies by their Git URLs).

## COM

On Windows, COM interfaces are declared as extern interfaces and called as
Haxe interfaces: each method is a typed call through the object's vtable,
failed `HRESULT`s are exceptions, and Haxe classes implement COM interfaces
that native code calls. Open work and the reasons behind the design:
[plans/com.md](plans/com.md).

```haxe
import hxmc.com.*;

@:hxmc.com("{b4db1657-70d7-485e-8e3e-6fcb5a5c1802}")
extern interface IModalWindow extends IUnknown {
  @:hxmc.com.hresult function Show(owner:Ptr):Int;   // slot 3: the HRESULT itself
}
@:hxmc.com("{42f85136-db7e-439c-85f1-e4075d135fc8}")
extern interface IFileDialog extends IModalWindow {
  function SetFileTypes(n:Int, specs:Ptr):Void;      // slot 4: HRESULT, thrown when < 0
  ...
  function Advise(sink:IFileDialogEvents):Int;       // [out, retval] DWORD *pdwCookie
  function Unadvise(cookie:Int):Void;
  function SetOptions(options:Int):Void;
  function GetOptions():Int;
  ...
  function SetTitle(title:String):Void;              // LPCWSTR
  function GetFileName():String;                     // [out, retval] LPWSTR (CoTaskMemFree'd)
}
@:hxmc.com("{9c906818-31d7-4fd3-a151-7c5e225db55a}")
extern interface IDWriteTextFormat extends IUnknown {
  ...
  @:hxmc.com.direct function GetFontSize():Float32;  // STDMETHOD_(FLOAT, GetFontSize)()
}

class Events implements IFileDialogEvents {         // a Haxe object COM calls
  public function OnFileOk(dialog:IFileDialog) trace("ok");
  ...
}

Com.init(SingleThreaded);                           // CoInitializeEx, on each thread
var d = Com.create("{DC1C5A9C-E88A-4dde-A5A1-60F82A20AEF7}", IFileOpenDialog);
d.SetOptions(d.GetOptions() | FOS_FORCEFILESYSTEM);
d.SetTitle("Pick a file");
var cookie = d.Advise(new Events());
var fd = Com.query(d, IFileDialog);                 // QueryInterface: null when it has none
```

The corpus cases `ComCalls`, `ComObjects`, `ComThreads` and `ComDemos`
(the file dialog and DirectWrite, headless) cover this on Windows x86-64
and arm64; `ComElsewhere` the other targets.

### Declarations

| | |
| --- | --- |
| `@:hxmc.com("{IID}")` | an extern interface is a COM interface with that IID; one that extends another COM interface (one only: a vtable extends one) is too. The root is `hxmc.com.IUnknown` |
| `@:hxmc.com.hresult` | the method's `HRESULT` is its result (an `Int`), returned as it is |
| `@:hxmc.com.direct` | the method returns its own result, not an `HRESULT` (`STDMETHOD_(FLOAT, GetFontSize)()`, `STDMETHOD_(void, ...)`): a number, a `Ptr`, a struct or `Void` |
| `@:hxmc.fast` | the call stays in the running state, as a fast C function's ([Declaring C functions](#declaring-c-functions)) |

- **Slots** are the declaration order, after the bases' (IUnknown's three
  first, which are not declared: hxmc counts references itself, and
  QueryInterface is `Com.query`). A slot's name is free: C++'s overloads
  (`IDWriteTextLayout::GetFontSize(pos, ...)` beside
  `IDWriteTextFormat::GetFontSize()`) take other names, and every slot up
  to the last one called is declared.
- **The `HRESULT`** of a method without metadata is tested: one below zero
  is thrown as a `hxmc.com.ComException` (its `hresult`, and the system's
  message, FormatMessageW's). A result other than `Void` is the C
  function's last parameter, a pointer to it (`[out, retval]`): `function
  GetOptions():Int` is `HRESULT GetOptions(FILEOPENDIALOGOPTIONS *)`.

| Type | In C |
| --- | --- |
| numbers, `Ptr`, `@:hxmc.struct` values | as C functions take and return them; a struct by value as the ABI passes it |
| `Bool` | `BOOL`, a 32-bit int (any but zero true), not C's one-byte `bool` (a struct's field stays C's) |
| a COM interface (`Null<IFoo>` too) | `IFoo *`: an argument borrowed (the value's pointer, null for null); a result (`[out, retval]`) owned, the value taking the reference over |
| `String` | `LPCWSTR`: UTF-16 made for the call and freed after it; a result `LPWSTR`, CoTaskMemAlloc's, freed once copied |
| `hxmc.com.BStr` (a `String`) | `BSTR`: SysAllocStringLen's for the call, freed after it; a result's freed once copied (an embedded NUL kept; a null BSTR reads `""`) |
| `hxmc.com.Variant` | `VARIANT`, a struct value ([BSTR and VARIANT](#bstr-and-variant)) |

- **Out parameters** beyond the `[out, retval]` one are pointers to native
  memory (`Ptr<Int32>`, `Ptr<Float>`: a frame's `Mem.stack`, an `Arena`'s),
  read after the call; an interface one's pointer is made a value with
  `Com.adopt(p, IFoo)`.
- **A struct result of a `@:hxmc.com.direct` method** comes back as MSVC
  returns them from C++ methods on x86-64 and arm64: through a pointer
  after `this` (`D2D1_SIZE_F GetSize()` is `D2D1_SIZE_F *GetSize(this,
  D2D1_SIZE_F *ret)`), never in registers as a C function's would.

### Calls

A call gets the interface pointer of the value (a foreign object's, or the
one of a Haxe object's COM object: [below](#haxe-classes-implementing-com-interfaces)),
loads the slot's function from its vtable and calls it in the Win64 or
Windows arm64 C convention with the pointer first, in a safe region (COM
calls back into Haxe from inside calls). Each signature is an indirect C
function, as each Objective-C message's is. A null receiver throws (`E_POINTER`).

### QueryInterface and identity

- **`Com.query(x, IFoo)`** is `QueryInterface`: the value as `IFoo`, or null
  (E_NOINTERFACE). `Com.as(x, IFoo)` and `cast(x, IFoo)` throw a
  ComException instead; `Std.isOfType(x, IFoo)` and `Std.downcast` ask it too.
  A value that is no COM object (a Haxe object implementing no COM
  interface, a string, another native handle) is false, null and null for
  `Std.isOfType`, `Std.downcast` and `Com.query`; `Com.as`, `cast` and
  `Com.ptr` throw (E_NOINTERFACE).
- **Values are per interface pointer**: `==` compares them (one value per
  pointer while it lives, so a map sees one key); two interfaces of one
  object are two values. `Com.same(a, b)` compares the objects (their
  `QueryInterface(IID_IUnknown)`, COM's identity).
- **Objects of C** come from C functions as an `[out]` pointer:
  `Com.adopt(p, IFoo)` takes its reference over (`DWriteCreateFactory`,
  `SHCreateItemFromParsingName`); `Com.wrap(p, IFoo)` makes a borrowed
  pointer a value (which holds a reference of its own); `Com.ptr(x, IFoo)`
  is a value's pointer, borrowed, to pass to C; `Com.iidOf(IFoo)` an IID's
  address (16 bytes of the program's data, one per IID); `Com.guid(text)`
  a GUID's, interned (every character checked). `Com.create(clsid, IFoo)` is `CoCreateInstance`.

### Haxe classes implementing COM interfaces

A Haxe class implementing a COM interface is a COM object too: native code
calls its methods through vtables the compiler made, and the runtime
answers `QueryInterface`, `AddRef` and `Release`.

- **Its COM object** is made at the instance's first use as a pointer (an
  argument of a COM call, `Com.ptr`): a block of the runtime's (its count,
  then a vtable pointer per interface, those an interface's bases share)
  paired with the instance, as a Haxe class extending an Objective-C one
  is. `QueryInterface` answers the interfaces and their bases, `IUnknown`
  the first interface's pointer, the same every time.
- **Its methods**: each slot of each interface is a thunk, a C function
  that finds the Haxe object, makes its arguments Haxe values (a pointer
  the object's value, a string its `String`), calls the method (an
  override of a subclass answers) and stores its result at the
  `[out, retval]` pointer (an interface's pointer `AddRef`ed, a string
  CoTaskMemAlloc's, a `BStr` a BSTR: the caller's). A ComException
  leaving the method returns its `HRESULT`, any other exception `E_FAIL`;
  the method's success `S_OK`.
- **Threads**: native code may call on any thread. One the runtime did not
  start is attached at its first call, as Objective-C's callbacks attach
  theirs; the call leaves the caller's safe region and enters it again.
- **Its value** is the Haxe object: an `IFoo` from COM that is a Haxe
  object's pointer is that object, and a call of `IFoo`'s methods on it goes
  through its vtable as any.
- **Lifetime**: the Haxe object lives while COM holds its object beyond the
  pairing's reference (a toggle reference, the count read in each
  collection: the runtime's own memory, no foreign call), and is collected
  as any once COM let go; its COM object is freed once its count is zero.
  `Com.refCount(x)` reads a count (a diagnostic: a Haxe object's includes
  the pairing's).
- **Restrictions**: a class adding COM interfaces declares a constructor
  (the first to run registers the instance's type's vtables); a generic
  class cannot implement one.

### Apartments and threads

- **`Com.init(apartment)`** (`SingleThreaded` by default, or
  `MultiThreaded`) is `CoInitializeEx` on the calling thread, and
  `Com.uninit()` `CoUninitialize`: every thread that calls COM enters an
  apartment first, as C++ code does. The runtime calls neither.
- **Releases**: a value's reference is released once a collection found
  the value dead, put off to the thread that made the value (an
  apartment-threaded object's `Release` belongs to its apartment's thread),
  which runs it in a safe region at its next allocation, when
  `Gc.collect` returns, or as it ends (then: any thread's, as its
  proxies were disconnected).
- **A message loop** that blocks and does not allocate is woken: a
  collection that put releases off for a thread that called `Com.init`
  posts it `Com.WM_DEFERRED` (PostThreadMessageW), on which the loop calls
  `Com.runDeferred()`:

```haxe
while (User32.GetMessageW(msg, Ptr.nil(), 0, 0) > 0) {
  if (Mem.getI32(msg, 8) == Com.WM_DEFERRED) Com.runDeferred();
  else { User32.TranslateMessage(msg); User32.DispatchMessageW(msg); }
}
```

- **Letting go early**: `Com.detach(x)` releases a value's reference now
  (calls through the value throw from then on).

### BSTR and VARIANT

`hxmc.com.BStr` in a signature is a BSTR ([Declarations](#declarations-1));
`Com.bstr(s)`, `Com.ofBstr(p)` and `Com.freeBstr(p)` are the same for C
functions. `hxmc.com.Variant` is a `VARIANT` as a struct value (24 bytes:
its `vt`, then its value), by value or behind a `Ptr` in signatures;
`Variants` makes and reads the common types:

| | |
| --- | --- |
| `Variants.ofInt(i)`, `ofFloat(f)`, `ofBool(b)` | `VT_I4`, `VT_R8`, `VT_BOOL` (`VARIANT_TRUE` -1) |
| `Variants.ofString(s)` | `VT_BSTR`: a BSTR the variant owns |
| `Variants.ofUnknown(x)`, `empty()` | `VT_UNKNOWN` (an `AddRef`ed pointer the variant owns), `VT_EMPTY` |
| `Variants.toDynamic(v)` | an `Int`, `Float`, `Bool`, a copied `String`, a COM value (`VT_UNKNOWN`, `VT_DISPATCH`), null (`VT_EMPTY`, `VT_NULL`); a ComException for another type |
| `Variants.clear(v)`, `clearAt(p)` | `VariantClear`: what it owns given back |

As any struct value, a copy of a variant is its bytes: clear one copy once.

### Other systems

Code using COM compiles for every target (a program's archive is one for
every native target): there, every COM operation (a call through an
interface, a query, an IID, `Com`'s functions) throws a ComException
(`E_NOTIMPL`), so it runs behind a test of the system (`Sys.systemName()`);
a Haxe class implementing a COM interface is a Haxe class only.

In the runtime this is a kind of foreign objects (`hxmc.rt.ComKind` over
`hxmc.rt.Foreign`, [plans/foreign-objects.md](plans/foreign-objects.md)), as
Objective-C is. Declarations from Windows' metadata (win32metadata's
`.winmd`) are a later generator's, as
[extern-generator](https://github.com/hx-objc/extern-generator) is
Objective-C's.

## Java (JNI)

On Linux, Android and macOS, Java classes are declared as extern classes
and called as Haxe classes: each method, constructor and field access is
a typed JNI call with the signature the compiler makes from the Haxe types,
a pending Java exception is thrown as a Haxe one, and Haxe classes
implement Java interfaces that Java calls. Open work, the decisions behind
the design and the contract with a packager (helder.pack):
[plans/jni.md](plans/jni.md).

```haxe
import hxmc.java.*;

@:hxmc.java("java.lang.Runnable") extern interface Runnable {
  function run():Void;
}
@:hxmc.java("com.example.Player") extern class Player extends JavaObject {
  static var count:Int;                              // GetStaticFieldID(..., "I")
  var name:String;                                   // "Ljava/lang/String;"
  @:overload(function(name:String):Void {})          // (Ljava/lang/String;)V
  function new();                                    // ()V
  function play(track:String, from:Float):Bool;      // (Ljava/lang/String;D)Z
  function onDone(r:Runnable):Void;                  // (Ljava/lang/Runnable;)V
  function scores():Array<Int>;                      // ()[I, copied
  @:hxmc.java.signature("(Ljava/lang/CharSequence;)V") function say(s:String):Void;
  @:hxmc.java.name("volume") function getVolume():Float32;   // ()F
}

class Done implements Runnable {                      // a Haxe object Java calls
  public function new() {}
  public function run() trace("done");
}

Jvm.create(["-Djava.class.path=player.jar"]);       // libjvm, JNI_CreateJavaVM
var p = new Player("ana");
p.onDone(new Done());
try p.play("x.ogg", 0) catch (e:JavaException) trace(e.className, e.javaMessage);
```

The corpus cases `JniCalls`, `JniArrays`, `JniRefs`, `JniPeers` and
`JniThreads` embed a JVM (linux-x86_64 in the glibc mode, with a JDK:
`make jni-check`, [testing.md](testing.md)); `JniElsewhere` runs on every
target; `JniCheck` also loads an hxmc library into `java` and builds it
for Android.

### Declarations

| | |
| --- | --- |
| `@:hxmc.java("pkg.Class")` | an extern class or interface is that Java class (binary names: `java.util.Map$Entry`); `hxmc.java.JavaObject` is `java.lang.Object` (`toString`, `hashCode`, `equals`) |
| `function new(...)`, `@:overload` | constructors (`<init>`); the one a `new` calls is chosen by its arguments' types |
| methods, `static` methods | `Call<Type>MethodA`, `CallStatic<Type>MethodA`; `@:overload`'s alternatives each have their signature, the one the call chose is called |
| `var`, `static var`, `final` | `Get`/`Set<Type>Field`, `GetStatic`/`SetStatic<Type>Field` |
| `@:hxmc.java.signature("(...)R")` | the JNI signature given, rather than made (a `String` passed where Java takes a `CharSequence`) |
| `@:hxmc.java.name("n")`, `@:native("n")` | the member's Java name, when Haxe's differs |
| `@:hxmc.java.proxy("pkg.Name")` | a Haxe class's proxy class ([below](#haxe-classes-implementing-java-interfaces)) |

| Haxe | Java (JNI signature) |
| --- | --- |
| `Int`, `Bool`, `Float` | `int` (`I`), `boolean` (`Z`), `double` (`D`) |
| `Float32`, `Int8`/`UInt8`, `Int16`, `UInt16`, `haxe.Int64` | `float` (`F`), `byte` (`B`), `short` (`S`), `char` (`C`), `long` (`J`) |
| `String` | `java.lang.String`: UTF-16 both ways (`NewString`, `GetStringRegion`: no modified UTF-8), `null` for null |
| a Java class (`Null<C>` too) | `LC;`: its object, a Haxe object implementing the interface, or null |
| `Null<Int>`, `Null<Float>`, `Null<Bool>` | `Integer`, `Double`, `Boolean` (boxed, null for null) |
| `Dynamic`, `Any` | `Object`: numbers and Bools boxed (`Integer`, `Double`, `Boolean`), a String a String, a Java object itself; back, `Integer`, `Short`, `Byte`, `Character` an `Int`, the other numbers a `Float`, a `Boolean` a `Bool`, a `String` a `String`, any other object its value |
| `Array<T>` of the above, `haxe.io.Bytes` | `T[]` (`[I`, `[Ljava/lang/String;`, `[LC;`, `[Ljava/lang/Object;`), `byte[]`: copied at the call, both ways |
| `hxmc.java.JavaArray<T>` | `T[]` itself: no copy ([Arrays](#arrays)) |

### Calls

A call pushes a local frame on the thread's `JNIEnv` (`PushLocalFrame`),
resolves the class (the program's class loader's `loadClass`, else
`FindClass`) and the member ID once into cells of the program's data (a
word each, per class and per name and signature), makes the receiver and
the arguments Java values in a `jvalue` array (references as local
references of the frame), calls in a safe region (Java may call back into
Haxe and block; so are the runtime's own calls of Java code: `valueOf`,
`intValue`, an exception's `getMessage`), makes the result a Haxe value and
pops the frame. No Haxe exception comes between (the conversions run none
of the program's code), so the frame is popped on every exit. The
calls between see a pending exception and do nothing, so the first
failure is the one thrown: a call on null throws a `NullPointerException`,
a missing method or field `NoSuchMethodError` or `NoSuchFieldError`, at
the call.

- **Exceptions**: a pending Java exception after a call is cleared and
  thrown as a `hxmc.java.JavaException`: `className`, `javaMessage`
  (`getMessage`), `message` (`Throwable.toString`), `javaStack` (that line
  and the frames of `getStackTrace`, `\tat ...` each, as
  `printStackTrace` prints them), `throwable` (the `Throwable` itself).
- **`-Xcheck:jni`** passes: every call that may throw is checked before
  the next one.

### Java objects in Haxe

- **One value per object**: a Java object is a box holding a global
  reference (`NewGlobalRef`), one per object while it lives (found by
  `System.identityHashCode`, told apart by `IsSameObject`), so `==` is
  identity and a map sees one key. `Java.same(a, b)` asks `IsSameObject`.
- **Lifetime**: Haxe's storage is Haxe's (fields, closures, arrays, maps,
  `Dynamic`). A box found dead by a collection deletes its global reference
  (put off, run by any thread, attached first: at its next allocation,
  when `Gc.collect` returns, or as it ends); Java collects the object once
  nothing else holds it. `Java.detach(x)` deletes it now (calls through
  `x` throw from then on).
- **`hxmc.java.Weak<T>`** holds a weak global reference
  (`NewWeakGlobalRef`): `get()` is the object while Java has it, null once
  Java collected it. A Java object Haxe no longer holds lives until Java's
  next collection, and `get()` before that gives it a box again.
- **`Java.isInstance(x, "java.lang.Number")`** is `IsInstanceOf`;
  `Java.toString(x)` is `Object.toString`.

### Arrays

An `Array`, `Bytes` or `String[]` parameter is a new Java array copied from
the Haxe one for the call (`Set<Type>ArrayRegion`), a result a new Haxe
array copied from Java's: neither side sees the other's later changes.
`hxmc.java.JavaArray<T>` is a Java array held as it is (a Java object
whose type is `[` and its element's):

| | |
| --- | --- |
| `a.length` | `GetArrayLength` |
| `a.get(i)`, `a.set(i, v)` | an object array's element (`Dynamic`'s conversions) |
| `a.getRegion(t, pos, n, p)`, `setRegion` | a primitive array's elements copied to or from native memory (`t`: 1 boolean ... 8 double) |
| `a.critical((p, n) -> ...)` | the elements in place (`GetPrimitiveArrayCritical`): no Java call and no waiting on a Java thread inside (the JVM may hold its collector meanwhile); allocating is fine (the runtime makes no JNI call of its own until it returns: the deletions a collection puts off wait); a JVM that gave a copy writes it back after |
| `JavaArray.ofInts(n)`, `ofBytes`, `ofDoubles`, `ofObjects(n, "pkg.C")` | new arrays |

### Haxe classes implementing Java interfaces

A Haxe class implementing `@:hxmc.java` interfaces is a Java object too:
Java calls its methods through a **proxy**, a Java class of the glue
(`org.hxmc.proxy.<Haxe path>` unless `@:hxmc.java.proxy` names it,
extending `org.hxmc.Peer` and implementing the interfaces), whose methods
call static natives the runtime registers (`RegisterNatives`) when it makes
the first proxy. hxmc writes the proxies a program needs to a manifest
next to its output (`<output>.jni.json`); a packager writes and compiles
their Java from it ([plans/jni.md](plans/jni.md#the-glue);
`hxmc/test/JniGlue.hx` is the reference generator).

- **Its proxy** is made at the instance's first use as a Java value (an
  argument, a result Java gets), holding the instance's handle; the same
  one while Java holds it. A proxy Java gives back is its Haxe object.
- **Its methods**: each native finds the Haxe object of its handle, makes
  its arguments Haxe values, calls the method (an override of a subclass
  answers) and makes its result a Java value. A thread the runtime did not
  start is attached at its first call; the call leaves the caller's safe
  region and enters it again.
- **Exceptions**: a `JavaException` leaving the method is its `Throwable`
  thrown again; any other is an `org.hxmc.HaxeException` (a
  `RuntimeException`) of its message.
- **Lifetime**: the Haxe object lives while Java holds one of its proxies
  (the peer is a root), and is collected as any once Java collected them
  (`org.hxmc.Peer`'s phantom references, drained by its daemon thread,
  tell the runtime). `Java.proxies(x)` counts them. A cycle through both
  heaps (a Haxe object holding a Java object that holds its proxy) is
  never collected: break it by hand (plans/jni.md, the bridge).
- **Restrictions**: a class adding Java interfaces declares a constructor;
  a generic class cannot implement one; an interface's overloads are not
  implemented (one method per name and signature).

### The JVM and threads

| | |
| --- | --- |
| `Jvm.create(options)` | embeds a JVM: libjvm opened at run time (`dlopen`; `Jvm.libjvm()`: `HXMC_LIBJVM`, else `JAVA_HOME`'s `lib/server/libjvm.so`, `jre/lib/<arch>/server` for Java 8, `libjvm.dylib` on macOS, else `/usr/lib/jvm/default-java`, else the loader's search), `JNI_CreateJavaVM` with the options (`-Djava.class.path=` is `CLASSPATH`'s when none is given); a JVM the process has already is used instead |
| `Jvm.onLoad(vm)` | the program is a library Java loads (`System.loadLibrary`; `-D hxmc.shared` in the glibc mode, Android's `.so`, with `-D hxmc.exports=JNI_OnLoad`): its `JNI_OnLoad` calls this, which keeps the JVM and the loader of the loading code's classes, runs `main` on a thread of its own and waits for it |
| `Jvm.useActivity(activity)` | an Android activity's JVM (`ANativeActivity`'s `vm`) and class loader (the app's, which knows `classes.dex`'s) |
| `Jvm.exists` | whether there is a JVM |

```haxe
@:hxmc.export("JNI_OnLoad") @:hxmc.unsafe static function onLoad(vm:Ptr, reserved:Ptr):Int
  return hxmc.java.Jvm.onLoad(vm);
```

- **Threads**: each thread has its own `JNIEnv`; one that calls Java first
  is attached as a daemon thread (`AttachCurrentThreadAsDaemon`) and
  detached as it ends (a pthread key's destructor). Java's threads calling
  Haxe are attached to the runtime as other foreign threads are.
- **The main thread's stack**: a program that calls Java runs `main` on
  the thread's own stack rather than the runtime's 1 GB one (`RT_STACK_MB`
  still chooses): a JVM checks the stack pointer of each call against the
  stack the system gave the thread, and takes another one for an overflow.
- **Signals**: the runtime's fault handler (Haxe's null accesses) passes
  every other fault to the handler before it, the JVM's when the library
  is loaded into a JVM; `-Xcheck:jni` reports it as a modified handler.
  `RT_NULL_ACCESS=0` installs none.

### Other systems

Code using Java compiles for every target: on Windows and WebAssembly
every Java operation throws a `JavaException`
(`UnsupportedOperationException`), as one does before a JVM is there; a
Haxe class implementing a Java interface is a Haxe class only. Linux's
static mode cannot load libjvm (its executables load no library):
`Jvm.create` throws there, the glibc mode loads it.

In the runtime this is two kinds of foreign objects (`hxmc.rt.JniKind`
over `hxmc.rt.Foreign`: boxes, and peers whose toggle is what their proxies
say: [plans/foreign-objects.md](plans/foreign-objects.md)).

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
| `statTimes(path)` | `[atime, ns, mtime, ns, ctime, ns, size]`, one stat for a watcher: seconds (`FileSystem.stat`'s Dates are made of these times) and nanoseconds, from `st_mtim` and the like (macOS `st_mtimespec`), Windows' `GetFileTime` (100 ns; ctime is the creation time, as `stat`'s), WASI's filestat; null when the path cannot be stat'ed |
| `fileSetBlocking(fd, blocking)` | `O_NONBLOCK` on or off; on Windows pipes only (`PIPE_NOWAIT`); false where it cannot |
| `fileRead`, `fileWrite` | bytes read (0 at the end) or written, -1 on an error, `WOULD_BLOCK` (-2) when a non-blocking descriptor is not ready (`EAGAIN`; on Windows reads only). `sys.io.FileInput` and `FileOutput` throw `haxe.io.Error.Blocked` then. With other threads running, a blocking descriptor is waited for in a safe region first; a non-blocking one is not |

Processes do not exist on wasm32-wasi.
