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
| `processKill(pid)` | `sys.io.Process.kill`: `SIGKILL`; on Windows `TerminateProcess` with exit code 0, as upstream |
| `statTimes(path)` | `[atime, ns, mtime, ns, ctime, ns]`: seconds (`FileSystem.stat`'s, whose Dates hold whole seconds on hxmc) and nanoseconds, from `st_mtim` and the like (macOS `st_mtimespec`), Windows' `GetFileTime` (100 ns; ctime is the creation time, as `stat`'s), WASI's filestat; null when the path cannot be stat'ed |
| `fileSetBlocking(fd, blocking)` | `O_NONBLOCK` on or off; on Windows pipes only (`PIPE_NOWAIT`); false where it cannot (WasmGC) |
| `fileRead`, `fileWrite` | bytes read (0 at the end) or written, -1 on an error, `WOULD_BLOCK` (-2) when a non-blocking descriptor is not ready (`EAGAIN`; on Windows reads only). `sys.io.FileInput` and `FileOutput` throw `haxe.io.Error.Blocked` then. With other threads running, a blocking descriptor is waited for in a safe region first; a non-blocking one is not |

Processes do not exist on wasm32-wasi. On WasmGC the host (node) runs them.
