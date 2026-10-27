# C interop and low-level Haxe

How hxmc programs call C, pass memory to it, and use struct values. For
library authors who bind a C library or write code that must not allocate.
These APIs exist only on hxmc. Open work is in
[plans/lowlevel.md](plans/lowlevel.md).

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
| `@:hxmc.blocking` | the call runs in a safe region entered at the call site ([Blocking calls](#blocking-calls)); on a field it overrides its class' `@:hxmc.fast` |
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
- **`hxmc.unsafe.Blocking.enter()` and `leave()`** enter and leave it by
  hand, around fast calls in a loop. Between them: no allocation, no heap
  object, no address of one; leave on every path. Prefer the metadata.

```haxe
@:hxmc.c extern class Io {
  @:hxmc.blocking static function read(fd:Int, p:Ptr, n:Int64):Int64;
}
```

`BlockingCalls` checks it on the native targets: two threads wait on empty
pipes while the main thread collects.

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

`hxmc.unsafe.BytesPtr` hands a `haxe.io.Bytes` to C: its address natively,
a copy through linear memory on WasmGC. Use it in a `@:hxmc.fast` call or
copy back with `written`/`copyIn`.

### I/O buffers

`hxmc.unsafe.IoBuffer` is malloc'ed memory whose address stays valid
until `free`, through collections, safe regions and threads: for I/O that
keeps a buffer's address while the program runs on (io_uring, IOCP's
overlapped reads). It is a value; its owner frees it once the last
operation on it completed.

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
outside its spaces. Not under `-D hxmc.wasm-gc`. `IoBuffers` checks it
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
default), with pointers as i32. Functions the runtime implements in Haxe
(`malloc`, `strlen`, `__errno_location`, ...) are called directly. The
module exports `memory`, `_start` and `__indirect_function_table`.

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
- **Boxes**: where a reference is needed (`Dynamic`, `Array<S>`,
  `Map<K, S>`, `Null<S>`, an enum argument), the value is copied into an
  immutable box. `arr[i].x = 1` is a compile error: copy out, change,
  store back.
- **Closures** may take and return struct values, but not capture a
  struct local.
- **Performance**: scalar replacement keeps struct math in registers;
  `acc = acc + d * 0.5` over three-double vectors is three `fadd`s.

Not yet: instance methods (an abstract over the struct carries methods and
operators meanwhile), value enums, `@:generic` containers of structs, GC
references in structs.

The corpus cases `StructValues`, `StructInline`, `StructInlineOpt` and
`reject/Struct*` cover this on all seven targets.
