# Low-level Haxe and C interop (design; partly built)

C interop, native memory with lifetimes, and an opt-in subset of scoped
memory, as one design. hxmc-only: these APIs exist only in hxmc builds
(native and WebAssembly); no portable fallback for other Haxe targets is
planned. What is built is in [docs/hxmc.md](../hxmc.md); the other plans
are in [ROADMAP.md](../../ROADMAP.md) and [docs/plans/](README.md).

The three layers build on each other:

1. **C interop**: typed externs called directly in the platform's C
   convention, C structs, pointers.
2. **Native memory with lifetimes** (after Java's FFM API): arenas,
   bounds-checked segments, pinning and handles for the moving GC.
3. **Scoped memory**: values on per-thread data stacks the
   compiler manages, reclaimed at scope end, every reference checked
   against the root that bounds its lifetime; scoped code has the
   properties of `@:hxmc.noGc` (the checked boundary between GC code and
   code that never touches the GC heap) by construction.

The names below are illustrative, except in the last sections: the
runtime's internal subset (`hxmc.unsafe`, the `@:hxmc.*` metadata) is
built, and the runtime uses it to contain no C of hxmc's own ("The runtime
without C of our own").

Status: built are the runtime's internal subset, the first milestone
(externs on the six ABIs and WebAssembly, `Arena`, the checked
`@:hxmc.noGc` rule and the raw-address check), structs by value in C
calls on every ABI ("Calls and linking") and struct values in the
language ("Struct values": locals, parameters, results, inline fields,
statics, `Slice`, scalar replacement) and scoped memory (section 4: data stacks,
the `hxmc.scoped` types, value enums, the root checker, the maps' index as one
core with two faces). Next: the std onto the scoped core, area by area;
instance methods on structs.

## 1. How other languages do C interop

| Family | Examples | How | Trade-off |
| --- | --- | --- | --- |
| Embedded C compiler reads headers | Swift (Clang importer), Zig (`@cImport`, `translate-c`), Kotlin/Native (`cinterop`) | headers imported as native types; inline functions and macros work | seamless, but a whole C front end (tens of MB) inside the compiler |
| Bindings generated offline | Rust `bindgen`, Java `jextract`, Dart `ffigen`, ClangSharp, Clang.jl | libclang turns headers into declarations, checked in | users need no C toolchain |
| Declared signatures, direct calls | Crystal `lib`, Odin/Jai/C3 `foreign`, Julia `ccall`, .NET `[LibraryImport]` and `delegate* unmanaged`, Java FFM downcalls, Go `purego` | the compiler emits native calls from declarations | as fast as native; ABI lowering per platform in the compiler |
| Dynamic FFI at run time | libffi (`ctypes`, JNA, `cffi` ABI mode), LuaJIT FFI (`ffi.cdef` parses C declarations at run time), koffi, Deno FFI | the call is built at run time | flexible; libffi is slow per call, LuaJIT's JIT is not |
| C compiler at run or install time | Bun `bun:ffi` (TinyCC compiles glue at run time, `cc()` compiles C files), `cffi` API mode, Go cgo (system gcc/clang at build time) | C glue compiled on the user's machine | covers macros and inline functions; cgo calls are expensive |
| Compile to C or C++ | Nim, hxcpp, HL/C, hxc | generated code includes headers | free interop, which hxmc gives up by generating machine code |

Also relevant: HashLink's `.hdll` natives (`DEFINE_PRIM` with type
signatures), for a possible HashLink-native compatibility layer (heaps),
and the WebAssembly component model (WIT, canonical ABI).

hxmc's choice: declared signatures with direct calls (family 3), with
declarations written by hand, parsed from C declaration text, or generated
from headers offline (family 2), plus an optional embedded tcc at build
time for the C that cannot be declared (family 5, at build time only).

## 2. C interop

### Declarations

```haxe
@:hxmc.lib("SDL2")                              // the library providing the symbols
extern class SDL {
  @:hxmc.c("SDL_Init") static function init(flags:UInt32):Int;
  @:hxmc.c("SDL_CreateWindow") static function createWindow(title:CString, x:Int, y:Int, w:Int, h:Int, flags:UInt32):Ptr<SDL_Window>;
  @:hxmc.c("SDL_RenderFillRect") static function fillRect(r:Ptr<SDL_Renderer>, rect:Ptr<SDL_Rect>):Int;
}

@:hxmc.struct class SDL_Rect { var x:Int32; var y:Int32; var w:Int32; var h:Int32; }
@:hxmc.opaque class SDL_Window {}            // only ever behind a Ptr
```

- C declaration text, LuaJIT-style: a small C *declaration* parser in Haxe,
  used from a macro, turns pasted declarations (`int SDL_Init(Uint32
  flags);`, structs, enums, typedefs, function pointers) into the externs
  above. No preprocessor, no libclang.
- Full headers: a development-time generator over preprocessed headers
  (`zig cc -E` or `clang -E`), output checked into the library.
- Types: `Int8..Int64`, `UInt8..UInt64`, `Float32`, `Float`, `Bool`,
  `Ptr<T>`, `CString`, `@:hxmc.struct` classes (C layout, offsets per
  target), `@:hxmc.opaque`, function pointers (`Callback<F>`).

### Calls and linking

- hxmc emits direct calls in the target's C convention: System V, AAPCS64,
  Win64, Apple arm64 (variadic arguments on the stack, x18 reserved),
  Windows arm64. Structs by pointer, and by value on every ABI: a struct
  argument or result is the address of its memory at the Haxe level (a
  result's in the caller's frame), and the ABI's rules apply in MirBuild
  and the instruction selections, classified in one place per ABI
  (`hxmc/src/hxmc/CAbi.hx`), the parts placed in registers and stack slots
  by one calling convention per ABI, for calls and for the callee's
  parameters alike (`hxmc/src/hxmc/CallConv.hx`). AAPCS64: aggregates of one to four floats or
  doubles in float registers, other structs of up to 16 bytes in one or two
  integer registers, larger ones as the address of a copy, results through
  x8. System V x86-64 (Linux, macOS): each eightbyte of a struct of up to
  16 bytes is SSE (floats only) or INTEGER and takes the next register of
  its class (rax/rdx, xmm0/xmm1 for results), all of a struct's or none;
  larger ones are MEMORY, copied onto the stack, and come back through a
  hidden first argument. Win64: 1, 2, 4 or 8 bytes in an integer register
  (rax for results), others as the address of a copy, results through a
  hidden first argument. wasm32 (clang's C ABI): a struct of one scalar is
  that scalar, others the address of a copy, results stored at a first
  argument. A `@:hxmc.callback` takes and returns structs by the same
  rules (a wrapper stores the parts it receives in its frame and returns
  the result's parts or copies it through the hidden address:
  MirBuild.cEntry); on WebAssembly, where JavaScript calls callbacks with
  hxmc's own convention, a struct is the address of its memory and a
  result is stored at an address given first. Corpus cases `FfiStruct`
  and `FfiAbi` (against zig cc, on the six targets), `WasmStruct` (a
  JavaScript host).
- Static libraries: hxmc's linker reads ELF, COFF and Mach-O objects and
  archives already; per-target prebuilt objects ship in haxelibs, linked
  only when referenced.
- Dynamic libraries: import tables written directly (`DT_NEEDED` on ELF,
  import directory on PE, `LC_LOAD_DYLIB` on Mach-O): no SDK, no import
  libraries. On Linux this needs the dynamic glibc mode (`-D
  hxmc.libc=glibc`: glibc's loader, `LinkDyn.hx`; `@:hxmc.lib("m")` or
  `@:hxmc.lib("libm.so.6")`, a plain name being `lib<name>.so` next to the
  executable); static musl executables cannot load glibc libraries (GPU
  drivers), and an import there is a compile
  error that names the mode.
- WebAssembly: C functions become module imports (WASI or JavaScript):
  the module `@:hxmc.lib` names ("env" by default), pointers as i32;
  one the runtime implements in Haxe (`__errno_location`, `malloc`,
  `strlen`, ...: `hxmc.rt.wasm.Libc`, `Heap`) is a call of that function
  (test: `hxmc/test/cases/WasmImports.hx`). The module exports `memory`, `_start` and `__indirect_function_table`;
  a `@:hxmc.callback`'s address (`Callback.addr`) is its index in that
  table, so JavaScript calls it with `table.get(addr)(...)`, during an
  import call or after `_start` returned (a browser's event loop: the
  runtime keeps its statics and heap between calls; Int and Float
  parameters are numbers, Int64 and Ptr ones BigInt). An exception a
  callback does not catch ends the program (proc_exit); what it prints
  stays buffered until `Sys.stdout().flush()`. Test:
  `hxmc/test/cases/WasmCallback.hx`.

### What declarations cannot cover: optional embedded tcc

`static inline` functions and function-like macros in headers, and small
C glue files a library ships, need a C compiler. Optionally, hxmc embeds
TinyCC (a few hundred KB) and compiles them at build time, as Bun does at
run time: no system toolchain, tcc's modest code quality only matters for
glue. tcc writes ELF and PE for x86-64 and arm64; Mach-O support is
limited, so macOS takes tcc's ELF objects through hxmc's linker or
precompiled glue. Inline C in Haxe source and C++ stay out of scope.

## 3. Native memory with lifetimes (after Java's FFM API)

hxmc's GC moves objects, so C must never keep a pointer into the GC heap
without the runtime knowing. Native memory comes from arenas instead, and
GC objects reach C only through two explicit doors.

```haxe
// Arena.scoped(a -> ...)  freed when the function returns or throws
// Arena.auto()            freed by the GC once unreachable (finalizer)
// Arena.global            never freed
// Segment<T>              a bounds-checked view over arena memory, tied to its arena
// Ptr<T>                  a raw typed pointer: what C takes and returns (unchecked)

function drawBox(renderer:Ptr<SDL_Renderer>) {
  Arena.scoped(arena -> {
    var rect = arena.alloc(SDL_Rect);           // zeroed, native memory
    rect.x = 10; rect.y = 10; rect.w = 100; rect.h = 50;
    SDL.fillRect(renderer, rect.ptr());
  });                                            // freed here, also on exceptions
}

Arena.scoped(arena -> {
  var title = arena.cstring("Hello");           // UTF-8 + NUL, copied once
  var buf = arena.allocBytes(4096);             // Segment<UInt8>
  var n = Posix.read(fd, buf.ptr(), buf.length);
  var text = buf.toString(0, n);                // copied back into a Haxe String
});
```

`Arena.scoped` takes a closure that hxmc inlines when it is called in
place: the arena is a bump allocator in the frame, with no closure or heap
allocation at run time (Haxe has no try-with-resources; this plays that
role).

### The two doors from the GC heap

```haxe
// pin: a GC object stays in place for the duration of a call
var pixels = haxe.io.Bytes.alloc(w * h * 4);
pixels.pin(p -> SDL.updateTexture(tex, null, p, w * 4));
// p must not be kept by C: after the closure the object may move again

// Handle: a stable token for a GC object that C keeps
var h = Handle.of(app);
SDL.addEventWatch(onEvent, h.ptr());
// ... later
h.release();
```

### Long-lived native resources

```haxe
class Window {
  final arena = Arena.auto();                   // freed when the Window is collected
  final handle:Ptr<SDL_Window>;
  public function new(title:String)
    handle = SDL.createWindow(arena.cstring(title), 0, 0, 640, 480, 0);
  public function close() {                     // deterministic cleanup, when wanted
    SDL.destroyWindow(handle);
    arena.close();
  }
}
```

### Callbacks

```haxe
@:hxmc.callback static function onEvent(userData:Ptr<Void>, event:Ptr<SDL_Event>):Int {
  var app:App = Handle.get(userData);           // GC-safe lookup
  app.handle(event.type);
  return 0;
}
```

- Static functions only (no captured state), as Swift's
  `@convention(c)`; state through `void *userData` handles.
- hxmc generates the C-callable trampoline: it leaves the runtime's safe
  region, sets up the thread's runtime state (shadow stack, exception
  handler), calls the function, and catches exceptions so they never
  unwind through C frames.
- Threads created by C attach to the runtime before calling GC code (a
  public attach/detach entry point); `@:hxmc.noGc` and scoped callbacks
  (section 4) need no attachment.

### Safety

- Use after free: a segment checks that its arena is open (an epoch
  compare); release builds may turn the check off.
- Bounds: segments know their length.
- Moving GC: native memory never moves; GC objects reach C only through
  `pin` (scoped) or `Handle` (long-lived).
- Leaks: scoped arenas free on any exit; auto arenas fall back to the GC.
- `Ptr<T>` stays the unchecked escape hatch, like C.

Differences from Java's FFM: struct types over memory give typed field
access compiled to plain loads and stores (Java needs `get`/`set` with
layouts); the scoped closure replaces try-with-resources.

## 4. Scoped memory

An opt-in subset for low-level code with deterministic memory and no
allocator (the model is [Goose](https://github.com/aardappel/goose)'s): no
heap allocator, no GC and no lifetime annotations. Every dynamic value lives
inline on a per-thread data stack the compiler manages; growth bumps a
pointer and never moves data; memory is reclaimed when its scope ends; and
every reference has a compile-time *root*, the scope that bounds its
lifetime, which the compiler infers and checks, rejecting escapes with an
error that names the root and the destination. In hxmc this subset lives
next to ordinary GC'd Haxe in the same program: GC code calls scoped code
freely and receives values by copy; scoped code holds no GC references.

This replaces the explicit-allocator dialect planned here before (an
`Allocator` interface passed to every function, containers with `deinit`,
"no borrow checker"): there is nothing to pass and nothing to free, and use
after free is a compile error instead of a debug-build check. What still
applies is kept below: struct values (built), the `@:hxmc.noGc` property
(which scoped code has by construction), the raw-address check, and Arenas
for C (section 3).

The concept is *scoped*: the metadata `@:hxmc.scoped` (classes, enums,
functions), the types of the package `hxmc.scoped`, and in prose "scoped
memory" and "scoped code".

### Syntax

```haxe
import hxmc.scoped.*;

@:hxmc.scoped class Item {                 // a value type: inline in a Grow, a Slice, a struct
  public var key:Int;
  public var val:Int;
  public function new(key, val) { this.key = key; this.val = val; }
}

@:hxmc.scoped enum Shape {                 // a value enum: tag + the largest payload, never allocated
  Circle(r:Float);
  Rect(w:Float, h:Float);
}

@:hxmc.scoped class Bench {
  static function area(s:Shape):Float
    return switch s {                      // ordinary pattern matching
      case Circle(r): 3.14159 * r * r;
      case Rect(w, h): w * h;
    }

  public static function push(n:Int):Int {
    var items = new Grow<Item>();          // grow-only, on a data stack of its own
    var marks = new Grow<Ref<Item>>();
    for (i in 0...n) {
      var e = items.push(new Item(i * 7 % 1000, i % 97));   // a reference to the new element
      if (i % 64 == 0) marks.push(e);      // still valid after any later growth
    }
    var t = 0;
    for (m in marks) t += m.value.val;
    return t;
  }                                        // items and marks freed here: two stores

  // a result holding references: rooted at the argument it views
  static function firstWord(s:Str):Str {
    var i = 0;
    while (i < s.length && s[i] != " ".code) i++;
    return s.sub(0, i);
  }

  static function bad():Str {
    var w:Str = "";
    for (i in 0...3) {
      var tmp = Str.copy("abc");           // fresh memory of the loop body
      w = tmp;                             // error: storing a reference rooted at tmp (the loop
    }                                      //        body, line 37) into w, which outlives it
    return w;
  }
}

class Main {                               // GC code
  static function main() {
    trace(Bench.push(4000000));            // a scoped call, a scalar back: nothing to copy
    var w = Bench.firstWord(Str.copyOf("hello world"));   // a scoped value in a local
    var s:String = w.toString();           // copied out, into the GC heap
  }                                        // main's scope ends: w's memory freed
}
```

### Types (`hxmc.scoped`)

| Type | What it is | Root of what it yields |
| --- | --- | --- |
| `Grow<T>` | grow-only array: a header (base, end, length) on the fixed stack and its elements on a data stack it owns alone, so `push` is a test and a pointer bump; never moves; the value is the header's address (passing a Grow passes it by reference) | `push` and `ref(i)` return a `Ref<T>` to an element, rooted at the Grow; elements read out are rooted at what was pushed |
| `Slice<T>` | a view: an address and a length, bounds-checked; `Scope.slice<T>(n)` makes one on the data stack | the root of what it views |
| `Str` | a view of UTF-16 code units (strings stay UTF-16 on both faces); a literal converts to one (static data: the global root); `Str.copy`, `Str.copyOf(String)` (GC code) copy onto the data stack, `toString()` copies into a String (GC code) | as `Slice` |
| `Ref<T>` | an address of one T (`r.value`, `r.value.x = 1` in place) | the root of the memory it points into |
| `Pool` | a bump region (a Grow of bytes) for values whose lifetime is a caller's: `pool.str(s)`, `pool.slice(n)`, `pool.bytes(n)` | the pool |
| `IntTable<V>` | a table of Int keys: the maps' index (`hxmc.rt.MapIndex`) over slots in a Pool, keys and values in Grows; grows only | the table |
| `Fixed<T, N>` | (not built) a fixed-size array inline in a struct or frame, `N` a constant (`@:genericBuild` with a `@:const` parameter) | the variable holding it |
| `Rel<T>` | (not built) a 32-bit self-relative reference (serialization, below) | the array it points into |
| `@:hxmc.scoped` classes | struct values (`@:hxmc.struct`'s representation) whose fields may also be the types above | the union of their fields' roots |
| `@:hxmc.scoped` enums | value enums (below) | the union of their payloads' roots |

T is a scalar (`Int`, `Float`, `Bool`, the C scalars of `hxmc.unsafe`), a
scoped class or enum, or one of the types above.

### Data stacks

A runtime piece next to the shadow stack (`hxmc.rt.DataStacks`, no-GC
Haxe): per thread, up to 16 data stacks, each a reservation with a bump
pointer, made on first use (a table of their tops, ends and bases, behind
one thread-local; the fixed stack's top, base and end and the owned mask
are thread-locals of their own, so a mark is two loads and a reset a store,
with a call only when stacks were claimed since). Natively each reserves 8 GB of
address space (committed as it is touched: `MAP_NORESERVE`, WinRt's commit
on touch), released when the thread ends (`Threads.exit` calls it through
an address the first use set, so that programs without scoped memory do
not load it); on wasm32, which has no virtual memory, each is a region of
the linear memory (`Heap.regionZero`: pages stay uncommitted until
touched), 256 MB unless `RT_DATA_STACK_MB` says otherwise (the 4 GB of
wasm32 hold a few such). Running past the end aborts with a message, as
guard pages would: scoped code cannot throw, and its failures
(`hxmc.rt.Abort`: an index out of range, a full stack, too many Grows) end
the program with exit status 70. They are `@:hxmc.noReturn`: nothing is
live across their calls (MirBuild ends the block), so a test costs no
registers.

- Stack 0 is the *fixed* one: everything that does not grow (a `Str`
  copy, a Grow's header, a `Scope.slice`) is bumped there.
- A Grow or a Pool claims one of the others for itself (a bit in the owned
  mask): its elements are always on top, so growth is a bump and never
  moves anything. More growable values live at once than 15 is an abort
  naming the limit (a static assignment would need a whole-program
  analysis; the dynamic claim costs a mask test). A stack nobody owns is always
  empty above its base.
- A *mark* is two locals of the frame: stack 0's top and the owned mask.
  A *reset* puts stack 0's top back and empties the stacks claimed since
  (their tops back to their bases): everything the scope allocated, the
  Grows it opened included, is freed by a few stores, however much it
  holds.

### Scopes

The scopes are the function's body, each loop (its condition and body)
and each block in statement position; the checker's levels
are the same. The plan the checker makes says which of them allocate
(FnLower marks those, and only those: a function that allocates nothing
pays nothing).

- A function marks on entry and resets at every return if it allocates
  (it calls an allocating primitive, or a function that leaves memory to
  its caller) and its own result holds no references.
- A function whose result holds references (a `Str`, a `Grow`, a struct
  with a `Slice` field) does not reset its own scope: what it allocated,
  its result included, belongs to the caller's scope, and the caller's
  reset frees it. This is how a result is "built in place" here: it stays
  where it was built. Scratch in such a function's own scope lives as long
  scratch in its loops and blocks does not.
- A loop that allocates marks at the start of each iteration and resets at
  its end and at `break` and `continue`; a block, at its end.
- Scoped code cannot throw (it is no-GC code: a throw allocates), and the
  runtime's faces throw outside their scopes. Other GC code can: a GC
  function whose scopes allocate resets to where it started when an
  exception leaves it, then rethrows (a catch-all around its body), and
  each `try` inside such a function marks where it starts and its catches
  reset to it. A `try` anywhere else marks nothing: an exception reaching
  it has left no scope's memory behind.
- The same lowering applies to GC code that touches scoped values (below).

### Rules of scoped code

A `@:hxmc.scoped` function (or every function of a `@:hxmc.scoped`
class) is checked by the root checker and lowered as a `@:hxmc.noGc`
function:

- No GC allocation, no throw, no try, no calls to GC code, no GC
  references at all (no `String` but literals, `Array`, class instances,
  `Dynamic`, closures, `Null<T>` boxes): the no-GC check (Facts) and the
  checker report the culprit.
- Calls to other scoped functions, to `@:hxmc.noGc` functions (the trusted
  layer) and to C.
- A function-typed parameter only on `inline` functions and macros: a
  function literal passed to one is inlined (Haxe's inliner does it), a
  compile-time function value; no closure exists at run
  time and none can escape.
- No moves: assignment, arguments and results copy struct values (as
  `@:hxmc.struct`); a `Grow`'s header is not copied (a `Grow` is the
  address of its header), so passing a Grow passes it by reference.
- Statics may hold scoped values whose roots are global only (literals).
- A `Str` views a string literal only: `Mem.addr` of any other String is an
  error (it moves with the collector); `Str.copyOf` copies one.
- `Ptr` and `Mem` stay the unchecked escape hatch: an address made from an
  integer or returned by C has the global root. The `hxmc.scoped` types are
  written with them, inline, and the checker follows roots through them
  (below), so their operations need no special cases.

### Relation to `@:hxmc.noGc`

Scoped code has the properties of `@:hxmc.noGc` by construction: no GC
allocation, no safepoints, no shadow-stack frames (it holds no GC
references), so it is safe on threads the runtime does not know (audio and
other C callbacks) and keeps the caller's references in registers.
`@:hxmc.scoped` is therefore implemented on noGc's path, not beside it: a
scoped function is a declared-noGc function (`FuncInfo.declNoGc`, checked
by `Facts.findNoGc`, lowered without frames and safepoints) plus the root
checker and the marks. What scoped adds is safety: noGc code works on raw
`Ptr`/`Mem` memory that nothing checks; scoped code works on typed values
whose lifetimes are checked.

The `@:hxmc.noGc` uses of the std today (649 functions and classes in
`hxmc/std`; with the compiler's and the tests', about 700 mentions), by
what they could become:

| Kind | Files (noGc uses) | Could become |
| --- | --- | --- |
| (a) pure algorithms | FloatText (20), Date (20), LibM (19), Layouts' error tables (2), CaseMap (1), MemOps (1): 63 | scoped code, the GC face a thin wrapper (one core, two faces, below) |
| (b) OS and C layers | Os (35), WinNet (29), wasm/Wasi (27), PosixNet (25), WinSys (24), Uv (19), WinRt (18), PosixSys (14), wasm/Libc (11), WasiSys (10), Ssl (10), NativeZip (9): 231 | scoped code once C calls take scoped values: a `Slice` or `Str` passed to C is data-stack memory, which never moves, so blocking calls need no pinning; the C declarations stay the trusted boundary |
| (c) raw access to GC objects' layouts | Dyn (34), Names (20), Bytes (16), Str (15), Boxes (14), MemRepr (2), IdHash (2), ObjectMap (2), gc/GcDyn (2), Arr (1), NArray (1), gc/GcStr (1): 110 | the algorithms move to the scoped core (comparison, search, hashing, formatting); the shell that reads an object's header, length and payload stays unsafe |
| (d) the trusted core | Gc (60), wasm/Gc (41), Threads (29), wasm/Heap (25), ThreadApi (19), Stacks (18), Faults (17), Census (11), wasm/Threads (5), Start (1), GcPaths (1), wasm/Exit (1), and the primitives of `hxmc.unsafe` and `haxe.atomic` (Arena 4, Callback 2, Ptr 1, AtomicInt 6, AtomicObject 4): 245 | stays unsafe: it implements the collector, threads, the stacks themselves |

Afterwards `@:hxmc.noGc` is the small trusted layer: (d), the object-access
shells of (c) and the C declarations of (b), the only code that touches
raw memory. A rename (`@:hxmc.unsafe`) would say that better, but not yet:
the name is in some 700 places and in the committed stage0, and the
property it checks (no GC point) is still what the code generator relies
on. Once (a) and (b) have moved, an alias `@:hxmc.unsafe` (noGc and allowed
to use `Mem`) with scoped code barred from `Mem` outside the
`hxmc.scoped` std would make the boundary checked; noGc stays accepted.

### The root checker

A pass over the typed AST of each scoped function, and of each GC
function that touches scoped values, after Haxe's inlining (so the
`hxmc.scoped` types' inline operations are plain code by then) and before
lowering (`hxmc/src/hxmc/ir/Scoped.hx`, called by FnLower, so errors carry
the source positions the typer gave, inlined code at its call site). No
annotations: every root is inferred. `HXMC_SCOPED_DEBUG=1` prints the
typed body of a function it rejects, `HXMC_SCOPED_TRACE=1` every
expression's roots.

*Roots.* A root names where memory lives and so how long it lives:

| Root | Lifetime level |
| --- | --- |
| global: literals, statics, addresses from integers or C | 0 (outlives everything) |
| a parameter's: what the caller passed | 1 |
| fresh memory of a scope: the data-stack memory a scope allocated, one root per expression that allocates (named after the variable of the source it was first bound to, else "a temporary"), and per call that leaves memory to its caller | 2 for the function's scope, one more per nested scope |
| a frame: `Mem.stack` | the function's, never returned |

*Values.* Every expression gets a set of roots: the memory it may point
into. Scalars have none; a `Ptr`, an address held as `I64`, and a struct
or enum value holding either carry roots (a struct's are the union of its
fields'). The transfer functions:

- an allocating primitive (`DataStacks.alloc`, a claim): fresh memory of
  the innermost scope that resets;
- `Mem.addr` of a string literal: global; of anything else: an error (a GC
  object);
- address arithmetic, casts and conversions between `Ptr` and `I64`: the
  operand's roots; integer to address: global;
- a load of an address or a struct through an address with roots R (a
  `Mem.getPtr`, `p[i]`, `p.value`): what was stored into that memory.
  Each fresh root records the roots stored into its memory (`held`), so
  the words of a string read out of a Grow are rooted at the string they
  view, not at the Grow. Where that is not known (a parameter's memory,
  whose stores are the caller's; memory handed to the unchecked layer) the
  load is bounded by the memory's own root ("read back": whatever was
  stored there outlives it). What memory holds only
  grows, so the analysis repeats until it is stable;
- a struct literal or constructor call: the union of its arguments'; a
  field of a struct value: the struct's;
- a local variable: what was assigned to it on the paths reaching the
  read (flow-sensitive; branches and loop iterations merge by union, loops
  to a fixed point);
- a call of a scoped function: by its summary, below.

*Rules.* Lifetimes are compared by level; a root outlives a destination
when its level is not deeper.

- Store into a variable (declaration or assignment, also a field of a
  struct local): every root of the value must outlive the variable's
  scope; the variable then holds those roots.
- Store through an address with roots D (a `Grow` push, an element of a
  `Slice`, a field behind a `Ref`, `Mem.set*`): every root of the value
  must outlive every root of D. A parameter's root stored into another
  parameter's memory is not decided here: it becomes a constraint of the
  function's summary, checked at each call.
- Return: global, parameter and fresh roots may be returned (a function
  returning references does not reset, so its fresh memory is the
  caller's); a frame root may not.
- Statics: a store of anything but global roots is an error.

*Summaries.* Each called function gets one, computed from its body on
first use (recursive cycles iterate to a fixed point from empty): which
parameters its result may be rooted at; the fresh memory it may reach, as
regions (at most 8, else one), each with the parameters' roots and the
regions it holds; whether it leaves memory to its caller; and which
parameter's roots (or its fresh memory) it stores into which parameter's
memory. A call's result is then rooted at the arguments behind those
parameters plus one fresh root per region, in the caller's current scope,
holding what the summary says; each store constraint is checked with the
arguments' roots, or passed on to the caller's own summary when they are
its parameters. Specialization per root, done with summaries: one body
per function, and a caller sees `longer(a, b)` rooted
at `a` and `b`, and the words `split(text)` returns rooted at `text`.

*Errors* name the root and the destination, at the store:

```
ScopedLoopEscape.hx:10: Code.bad: storing a reference rooted at tmp (made at line 9, memory of that scope) into w, which outlives it
ScopedCallStore.hx:13: Code.run: Code.put stores its argument s into the memory of its argument g: storing a reference rooted at s (made at line 12, memory of that scope) into memory rooted at g (made at line 10, memory of the function), which outlives it
ScopedParamStore.hx:8: Code.fill: storing a reference rooted at a temporary (made at line 8, memory of that scope) into memory of the caller (g), which outlives it
ScopedGcField.hx:13: ScopedGcField.main: storing a reference rooted at a temporary (made at line 13, memory of the function) into h.s (the GC heap), which outlives it
```

(`hxmc/test/reject/Scoped*.hx`: sixteen such errors, by message and
position; `hxmc/test/cases/ScopedRoots.hx`: what must be accepted.)

*Not checked:* what `Ptr`, `Mem` and C do with addresses (global roots: the
escape hatch), and data races (scoped memory is per thread; values cross
threads by copy).

### Scoped enums

A `@:hxmc.scoped` enum is a value enum (Zig's tagged union): a 32-bit tag and room for the largest payload, inline wherever it
is stored, copied on assignment, never allocated. The typer sees an
ordinary enum, so constructors, `switch`, exhaustiveness and guards work
unchanged; the lowering treats its type as a struct value whose layout is
the tag at 0 and each constructor's arguments from the payload's start
(overlapping), and lowers construction to stores, `TEnumIndex` to a load of
the tag, `TEnumParameter` to a load at the argument's offset. Copies and
`==` go word by word over the whole value (equality is bitwise: two
values are equal when they are the same constructor with the same bits).
Restrictions: no `null`, no identity, no reflection (`Type.enumParameters`
and friends see a box where a reference is needed, as struct values do),
payloads are value types (no recursion but through `Ref`/`Rel`). A
variable-size mode (each value its own constructor's size, sequential
arrays) is left for later: a `Grow` of variable-size elements cannot be indexed,
and Haxe has no syntax to choose the mode at the point of use.

### GC code and scoped code

- GC code calls scoped functions directly and may hold scoped values in
  its locals: `var alive = step(ps, dt); particles = alive.toArray();`.
  A `String` becomes a `Str` by copying it onto the data stack
  (`Str.copyOf`).
- A GC function that touches scoped values (calls a scoped function or an
  allocating primitive, or has a local or parameter of a scoped type: a
  cheap walk finds them) gets the same scopes and marks as scoped code,
  and nothing else does. Its loop bodies are scopes too, so a long-running
  GC loop calling scoped code each iteration does not grow the data
  stack; an exception is caught by a `try` that resets.
- The root checker runs on it with the GC references allowed: scoped
  values holding references may not escape into the GC heap (a field of an
  object, a static, an Array element, Dynamic, a type parameter, a box, a
  closure's capture, a thrown value, the function's result). Copying out
  is the explicit way: `toString`, a value copy.
- The collector never scans the data stacks (they hold no GC references)
  and nothing there moves, so a scoped value held across safepoints stays
  valid.

### One core, two faces

The payoff: the std's and the runtime's algorithms written once, in
scoped code, with the storage a compile-time parameter, then used by both
worlds:

- the scoped face: storage on the data stack (`Grow`, `Slice`), the core
  called from scoped code;
- the GC face: `String`, `Array`, `Map`, `StringBuf`, `Bytes` and
  `hxmc.rt` keep their GC-owned buffers (growth reallocates, as it does
  now) and call the same core on them. Haxe's semantics (null, out of
  range, identity, `Dynamic`, reflection) stay in the GC wrappers; the
  core sees in-range indices and non-null storage. Strings stay UTF-16
  on both faces.

How the storage is a parameter: the core's functions are `inline` and
take the storage as a value of one of two kinds.

1. A view: an address and a size (a `Slice`, a `Str`, or a view of the
   core's own shape). The scoped face passes data-stack memory; the GC
   face passes a view of its buffer's payload taken right before the call.
   The core has no GC point, so the buffer cannot move while the view is in
   use, and the raw-address check (`Facts.checkRawAddresses`, which now
   follows an address into a struct value) rejects a view kept across a
   GC point of the GC wrapper (`hxmc/test/reject/RawView.hx`). This covers
   storage of scalars and value types: indexes, hashes, text, numbers.
2. What only the face knows (the GC face's key comparison: a String's
   `==`, an object's identity; stores of GC references, which need the
   write barrier) stays in the face, between calls of the core: an inline
   function argument (a compile-time function value) would do it where
   Haxe inlines it, but where nothing does (macros run by Mir) it is a
   closure, its call a dynamic call and a GC point under a view.

(Haxe's `@:generic` does not do this: a generic function's body is typed
once against its constraint, and an abstract over a buffer satisfies no
structural constraint; inline functions are monomorphised by inlining.)

The pilot, built: the maps' index. `hxmc.rt.MapIndex` is the
open-addressing index with linear probing and backward-shift deletion,
written once as scoped code over an `IndexView` (the slots' address and
the mask; every slot number is masked in the access, so the accesses need
no bounds test, and a view's size is checked against the mask when it is
made, or is the maps' invariant for the GC face, which would otherwise read
the array's header, another cache line, on every lookup). The GC face is
`haxe.ds.IntMap`, `StringMap` and `ObjectMap` (`MapSlots.index` views the
index's GC array; the core's `next` gives the next slot of a tag, the face
tells the keys apart between calls: no function value, which would be a
closure and a dynamic call where nothing inlines it, as in macros run by
Mir), whose own probe, insert and removal loops are gone; the scoped face
is `hxmc.scoped.IntTable` (slots in a Pool, keys and values in Grows).
Same results in the corpus natively, on wasm32 and on WasmGC (where the
view is the GC array and Haxe's inline constructors make it locals);
`hxmc/test/cases/ScopedTable.hx` checks that both faces give the same
answers. What the core needed of the compiler: `(x & m) & m` folded (Opt),
`@:hxmc.noReturn`. Speed (`make bench-micro WHICH=maps`, ns per operation,
the fastest of 11 rounds, two runs each, the old code and the new built by
the same compiler, Linux x86-64): within the runs' spread, a lookup that
misses faster, a hit at 10,000 keys up to 10% slower in some runs (the
instruction counts went down: the remaining differences follow code
placement):

| | 10k before | 10k after | 1M before | 1M after |
| --- | ---: | ---: | ---: | ---: |
| IntMap get (hit) | 14.5-14.6 | 15.2-16.9 | 78-91 | 76-77 |
| IntMap set (insert) | 37.3-37.5 | 38.9-39.6 | 109-110 | 111-112 |
| ObjectMap get (hit) | 8.7-8.8 | 8.9-9.1 | 155-159 | 157-163 |
| ObjectMap exists (hit) | 8.2 | 9.0-9.1 | 100-105 | 103-106 |
| ObjectMap get (miss) | 5.5 | 4.7 | 57 | 54-55 |
| ObjectMap set (insert) | 23.9-24.4 | 23.6-24.1 | 147-148 | 158 |
| ObjectMap remove + set | 38.8-40.1 | 38.9-40.6 | 375-394 | 382-404 |
| StringMap get (hit) | 10.6-10.7 | 10.9-11.1 | 53-58 | 57-61 |
| StringMap set (insert) | 46.4-46.8 | 46.6-49.9 | 117-123 | 120-122 |

The scoped face against the GC face on the same index (ScopedBench's
`Table`: n random Int keys inserted with updates, then 8n lookups):
IntTable takes about half the time of IntMap (no `Null<Int>` boxes, no
dynamic values) and less memory, below.

The std moves onto the core area by area, each move deleting the code it
replaces (no second implementation stays):

- pure algorithms (a): `FloatText` (Std.string and Std.parseFloat of a
  Float, wasm32's strtod, the runtime's reports; the scoped face
  `Str.ofFloat`, `toFloat`), over `Slice`s on every target, WasmGC too
  (which used the engine's JavaScript forms before, and so printed `-0` as
  `0` and read `0x1p3` as 0), `CaseMap` (`Str.toCase`, its runs on WasmGC
  decoded into the engine's array), `LibM` (Math and Float's %: on WasmGC
  too, where the engine's Math was used; its tables `LibMData`, the trusted
  layer's: read-only data linearly, decoded arrays on WasmGC), the errno
  tables of `Layouts`; `MemOps.compare` compares addresses, the trusted
  layer's, under `Str.matchAt`;
- String's algorithms: `hxmc.rt.TextCore` (search, order, hash, UTF-8
  both ways, integers to text and back) over code units and bytes, whose GC face is String's natives
  (`hxmc.rt.Str`, `Bytes.getString`) and scoped face `hxmc.scoped.Str`
  (`find`, `findLast`, `compare`, `hash`, `utf8`, `ofUtf8`, `ofInt`,
  `toInt`);
  `Bytes.getString` decodes in place (the units counted, the string made,
  the bytes taken again) where it copied them out of the heap first;
- the OS layers' temporary C strings (b): paths, environment variables,
  commands, host names and what `Sys.print` writes are UTF-8 (UTF-16 on
  Windows) on the data stack (`SysCore.cstr`, `wide`: `Str.utf8Of`,
  `Str.copyOf`), where each was a `malloc` and a `free` on every
  return path; the function's scope frees them, on a throw too. A C string
  stored where it outlives its scope (a process's argv, built in a loop)
  stays `malloc`'ed: the checker does not follow raw addresses.

What stays GC code: the natives over GC references (`Array`'s, whose
elements the collector traces and whose `sort` calls back into Haxe;
`Dyn`, `Boxes`), and the trusted core (d).

### Serialization: relative references

Structures built from relative references are their own file format:

- `Rel<T>`: a 32-bit signed offset from the field itself to a T in the
  same `Grow` (0 is null), read as a `Ref<T>` (`r.get()`), set from one
  (`r.set(ref)`: the checker requires the target's root to be the same
  Grow as the field's, exactly: the one rule that needs a root's identity
  rather than its lifetime).
- A structure of value types and `Rel`s in one `Grow` is position
  independent: saving it is writing its bytes (`g.bytes()`), loading is
  reading them into a `Grow` and verifying.
- Per scoped type a generated `verify(bytes, at):Bool` (a build macro on
  `@:hxmc.scoped` classes and enums): every enum tag in range, every
  `Rel` landing on an element start inside the image, every length within
  it; `Grow.fromBytes<T>(bytes)` copies and verifies, and gives an empty
  Grow and `false` on hostile bytes, never a wild reference.

### Targets

- Native, all six targets: data stacks as reservations (above). Tested
  on Linux x86-64; the corpus cases run on every target in CI.
- wasm32: data stacks as regions of the linear memory, same code; their
  size is fixed when made (`RT_DATA_STACK_MB`), as a thread's C stack is.
- WasmGC (`-D hxmc.wasm-gc`): the same scoped code over the engine's
  objects (below).

### Two representations, one core

The std's core runs on every target, so the scoped code itself never
names an address: it uses the scoped abstractions only (`Slice`, `Grow`,
`Str`, `Ref`, `Pool`, `Scope`, the views the cores define over them,
such as the maps' `IndexView`). `Ptr` and `Mem` appear inside those
abstractions' linear-memory representation and in the trusted layer (d),
nowhere else. Each abstraction has two representations, chosen per target
inside the abstract (`#if hxmc.wasm_gc`), the core's code being the same:

| | linear (native, wasm32) | WasmGC |
| --- | --- | --- |
| allocation | bump on a data stack | an object of the engine's heap |
| scope exit | the data stack reset | nothing (the engine's collector reclaims) |
| `Slice<T>` | address, length | GC array, offset, length |
| `Str` | address, length (UTF-16 units) | i16 array (a String's own), offset, length |
| `Grow<T>` | header on the fixed stack; elements on a stack of its own, never moved | header object over a GC array that is reallocated as it grows |
| `Ref<T>` | address | the storage (a Grow's header, or a holder of a Slice's array) and an index: never an address, never dangling |
| scoped class (struct value) | bytes in its holder (frame, element, field) | an object, copied where a struct is copied (below) |
| scoped enum | tag and payload words | the enum value (immutable: nothing to copy), `==` by value |
| `Pool` | a Grow of bytes | a counter (what it makes is an object) |

The root checker runs the same on both: what it proves (nothing outlives
its root) holds whatever the representation; on WasmGC it is what keeps
a program portable to the linear targets, where breaking it is a crash.
`Str` and String share the representation on WasmGC (an array of units),
so the faces convert without copying (`Str.copyOf` there views the
String: it is immutable); linearly a `Str` of a String's units is a view
valid until the next GC point, as the maps' index is.

Struct values on WasmGC: an engine object has identity, a struct value
does not, so where a struct is copied (a variable initialized or assigned
from another place, an argument, a returned place, a field or an element
stored) the object is copied (a shallow copy: its fields are scalars and
scoped values, which are values or views); a value just made (`new`, a
call's result) is not. Haxe's inline constructors already keep objects
whose fields are all final in locals, so the views (`Slice`, `Str`,
`IndexView`) cost no allocation where they do not escape. A struct value
whose fields are all final keeps its inline constructor on every target
(no copy of it can be told from another), so a core returning one from an
inline function (`LibM`'s reduced argument, `FloatText`'s parse result)
leaves it in registers.

Arrays of scoped classes: WasmGC has no inline structs in arrays. The
first representation is an array of the element objects (a Grow's push
stores a copy; `s[i].x = 1` writes the element in place; reading an
element into a variable copies it). Struct of arrays (one GC array per
field, `Ref` = Grow and index) is the next step: no object per element,
the layout the engines optimize.

What a Slice of a Grow sees on WasmGC: the elements as of when it was
taken; after the Grow reallocates, writes through the old Slice are the old
array's (linearly nothing moves). The checker does not tell the two apart;
the std's cores take a Slice of a Grow only to read it.

### What Haxe cannot express (and what stands in)

- Const generics only through `@:genericBuild`: `Fixed<Int, 16>` is a
  macro-built struct; there is no type-level arithmetic.
- No moves: values are copied; a
  `Grow` is a reference to its header, which is the cheap way to pass one.
- No return across several calls: Haxe has neither the syntax nor a cheap
  multi-frame return; scoped code returns error values (a scoped enum)
  instead, and cannot throw.
- No transparent references or `.=`: `Ref<T>` with `r.value`, and
  rebinding is assignment.
- No variable-size values inline in an array: a
  `Str` is a view; text that must outlive a function goes into a `Pool`
  or a `Grow<UInt16>` passed in.
- Storage as a type parameter of a generic algorithm (see "One core, two
  faces"): inline functions and their function-literal arguments instead.
- No choice of an enum's representation at the point of use: one
  representation per enum.

### Design choices, and why

- Dynamic claims instead of a static stack assignment: no whole-program
  analysis of which values grow at once; a mask test per `new Grow`.
- A block in value position (an inlined function's body is one) is not a
  scope: its memory is the enclosing scope's, so an inline function may
  return what it allocated.
- Scratch in the own scope of a function returning references lives until
  the caller's reset: no in-place construction through calls; results
  stay where they were built.
- Summaries per function instead of one body per root: one compiled body
  (Haxe compiles each function once), at the price of precision where a
  function treats its parameters differently on different calls.
- Out-of-range indexes abort; the GC faces keep Haxe's
  behaviour by testing before they call.

### Status

Built (2026-10-25): the data stacks (`hxmc.rt.DataStacks`); `Grow`,
`Slice`, `Str`, `Ref`, `Pool`, `Scope`, `IntTable`; scoped classes and
enums; the root checker with summaries and what memory holds; scopes in
scoped code and in GC code that touches scoped values; native, wasm32
and WasmGC, each abstraction in two representations (the corpus'
`Scoped*` cases natively and on wasm32, `GcCheck`'s on WasmGC, under
Mir's `--run` too; `reject/Scoped*`); the std's cores moved so far (the
migration above). Not built: `Fixed<T, N>`, `Rel<T>` and the generated
`verify`/`fromBytes` (designed above), variable-size enums,
methods on scoped classes (structs have none yet), checking the
`hxmc.scoped` std's own inline functions apart from their callers,
struct of arrays on WasmGC.

Scoped against GC on the maps' index (`make bench-scoped`, `Table`: n
random Int keys inserted with updates, then 8n lookups; `IntTable` against
`haxe.ds.IntMap` over the same core), the median of 5 runs and the peak
RSS, Linux x86-64, 2026-10-25:

| n | scoped | GC | scoped, wasm32 | GC, wasm32 |
| ---: | ---: | ---: | ---: | ---: |
| 1M | 0.31 s, 48 MB | 0.61 s, 67 MB | 0.42 s, 98 MB | 0.84 s, 161 MB |
| 8M | 6.50 s, 219 MB | 9.86 s, 352 MB | 9.73 s, 268 MB | 12.31 s, 565 MB |

### Struct values (built)

`@:hxmc.struct` classes are value types (2026-10-17):

```haxe
@:hxmc.struct class V2 {
  public var x:Float; public var y:Float;
  public inline function new(x, y) { this.x = x; this.y = y; }
}
class Body { public var pos:V2; ... }       // inline in the object

static function mid(a:V2, b:V2):V2           // copies in, a copy out
  return new V2((a.x + b.x) / 2, (a.y + b.y) / 2);

var p = body.pos;                            // a copy
p.x += 1;                                    // body.pos unchanged
body.pos.x += 1;                             // in place
var s = arena.slice(V2, 100);                // hxmc.unsafe.Slice: inline, bounds-checked
s[3].y = 2;                                  // in place
```

- Where they live: locals, parameters and results; fields of classes
  (inline in the object, whole slots, none a reference) and of other
  structs; statics (a block outside the heap); elements behind a `Ptr`
  (`p[i]`, `Arena.makeArray`) and in a `hxmc.unsafe.Slice<T>` (a
  pointer and a length, itself a struct value). Fields are C scalars,
  `Int`, `Float`, `Bool`, `Ptr` and other structs; GC references are
  rejected (the collector scans no struct memory).
- Semantics: assignment, arguments and results copy; a field access
  through a pointer, a struct field or an object's field reads and
  writes in place; `new S(...)` zeroes the memory and runs the
  constructor on it (a struct has a constructor and static functions, no
  instance methods yet: an abstract over the struct carries methods and
  operators, as the shader math types do).
- Representation: the address of the memory (`Ty.TStruct`, an I64 in
  Mir), the ABI rules of C calls applied on top (CAbi). FnLower copies
  scalar by scalar; a local or a temporary is a slot of the frame
  (`Mem_structSlot`); an argument is a copy the callee owns; a result is
  written to the caller's slot, whose address is a last, hidden argument
  (`FuncInfo.sret`). An object's struct field is reached by address
  (`EFieldAddr`) only until the next GC point, which the raw-address check
  (Facts) enforces.
- Scalar replacement (`Sroa.hx`, after inlining): a slot whose address
  is only the base of loads and stores at constant offsets becomes SSA
  values, so struct math in registers: `acc = acc + d * 0.5` over
  three-double vectors compiles to three `fadd`s in the loop. The shader
  math types of `@hxmc/gfx` (`Vec2`..`Vec4`, `Mat4`; universe) are struct values:
  its `test/MathBench.hx` (about a million operations of each
  kind: a running value, a function's arguments and result, objects'
  fields, matrix products) went from 172 MB allocated in 43 minor
  collections and about 52 ms to nothing allocated and about 33 ms (Linux
  x86-64).
- Boxes: where a reference is needed (`Dynamic`, a type parameter: `Map<K,
  S>`, `Array<S>`'s elements, `Null<S>`, an enum's argument, a field of a
  structural type), the value is copied into a box, an object of a class
  named after the struct (`Lower.structBox`), never changed once made;
  taking it back copies it out (null gives zeros; another type fails as a
  cast). Assigning a field of such a copy (`arr[i].x = 1`) is a compile
  error, as in C#: copy it into a variable, change that, store it back.
  `Std.string` of a box is the struct's name; `Std.isOfType`, casts and
  `Type` see the box's class. A struct implements no interface.
- Closures may take and return struct values (by address, as calls do);
  one cannot become `Dynamic` or a function of another type, nor capture a
  struct local (its memory is in the frame).
- Other behaviour: `==` compares field by field (floats as floats);
  struct fields are invisible to reflection and Dynamic access. Haxe's
  inline constructors (a filter that turns objects into locals shared by
  the variables they are assigned to) are kept off struct classes: their
  constructors are ordinary functions for hxmc (`CInterop.install`), which
  Mir inlining and `Sroa` make as cheap.
- Inline functions: a struct argument is the function's own copy, as for
  a call. Haxe's inliner passes a local (or field) argument into the
  inlined body as itself; where the body writes through a struct parameter
  (a field, a compound assignment, an increment, the parameter passed on as
  an abstract's `this`), hxmc's hook (`Inline.copyArgumentHook`, set by
  `CInterop.install`) has it copied into a temporary first, so `bump(a)`
  with `inline function bump(v:V) v.x += 1` leaves `a` as it was, and so
  does a mutating inline method of an abstract over a struct (assigning
  `this` itself still changes the caller's variable, as Haxe's inline
  abstracts do). Reading only, the argument is used in place: no copy (the
  shader math types are immutable, never copied). The analyzer keeps
  copies copies (`AnalyzerTexpr.keepCopyHook`): a struct variable
  initialized from a place is neither fused into its use nor replaced by
  its source (copy propagation), and `a.b.x += 1` does not bind `a.b` to a
  temporary. Programs without struct values compile exactly as before. All
  seven targets (WebAssembly too). Corpus: `StructValues`, `StructInline`
  (and `StructInlineOpt`, with `@:analyzer(optimize)`), `reject/Struct*`.
- Left: instance methods on structs, value enums, `@:generic`
  specialization for containers of structs (boxes cost an allocation per
  element), GC references inside structs, struct locals captured by
  closures.

### What it buys

- The runtime (strings, maps, number formatting, the OS layers) in
  readable, checked Haxe instead of raw `Mem` intrinsics, written once for
  GC code and scoped code.
- No GC pauses where they hurt: audio, per-frame game memory, real-time
  loops; and no allocator either: freeing a structure of a million
  elements is a few stores.
- References that survive growth, inline nested data, deterministic
  memory, next to GC code for everything else.

### Other Zig constructs and how they map

| Zig | Haxe on hxmc | Fit |
| --- | --- | --- |
| `comptime` generics (`fn ArrayList(comptime T: type) type`) | inline abstracts over `Ptr<T>` (the `hxmc.scoped` types), `@:generic` | good |
| `comptime` computation, `inline for`, function blocks | macros (run in Eval, different semantics), inlining with function-literal arguments, constant folding | partial |
| `defer` / `errdefer` | a macro rewriting `@:defer expr` into cleanup on every exit (try/catch and rethrow: Haxe has no `finally`); scoped code needs none (the reset is the cleanup) | good with a macro |
| error unions, `try`, `catch`; returning across calls | exceptions in GC code; in scoped code error values (a scoped enum) | acceptable |
| arbitrary-width and packed integers (`u3`, packed structs with bit fields, varints) | abstracts over `Int` with masking | clumsy |
| overflow as an error, wrapping `+%`, saturating `+|` | Haxe's `Int` wraps; checked and saturating arithmetic as functions or abstracts | acceptable |
| `*const T`, `*T` vs `[*]T`, sentinel slices `[:0]u8` | distinct abstracts (`ConstPtr<T>`, `Ptr<T>`, `Slice<T>`, `CString`) | acceptable |
| no hidden allocations | the no-GC check of scoped and `@:hxmc.noGc` code (Facts) | built |
| `@Vector` (SIMD) | hxmc intrinsics | needs work |
| `anytype` | `@:generic` or macros | good |
| `extern union` / untagged unions (C) | `@:hxmc.union` structs with overlapping fields, for C interop | not built |

## Go's equivalents

Go is GC-only and has no allocator-passing convention, but it has close
equivalents of the GC-interop pieces, mostly for cgo and its own runtime:

| This design | Go |
| --- | --- |
| `Handle` | `runtime/cgo.Handle` (`cgo.NewHandle(v)`, `h.Value()`, `h.Delete()`) |
| `pin` | `runtime.Pinner` (Go 1.21+), plus cgo's rule that C may not keep Go pointers |
| `@:hxmc.noGc` as a checked rule | `//go:nowritebarrierrec`, `//go:nosplit`, `//go:systemstack` and a not-in-heap marker type, enforced by the compiler but only inside the runtime |
| arenas | the experimental `arena` package (`GOEXPERIMENT=arenas`, Go 1.20), on hold indefinitely: use after free and API composition proved hard to make safe in a GC language |
| implicit stack allocation | escape analysis |

Go validates the GC-interop half; its stalled arena experiment is why
segment lifetime checks and the `Debug` allocator are part of this design.

## Effort (estimated)

Calibrated on hxmc so far: the compiler is about 21k lines of Haxe (Mir
construction about 2.3k, the WebAssembly back end 2.3k, each linker
400–700, the optimizer about 1k), the runtime in Haxe about 10k; the
WebAssembly target with its all-Haxe runtime took one agent about 2.5
hours, macOS and Windows arm64 about 2.7 hours, the runtime move about 8.

| Step | Compiler | Std / runtime | Agent time |
| --- | --- | --- | --- |
| 1. C interop basics: types, direct calls on six ABIs and WebAssembly imports, static and dynamic linking | 1.5–2.5k | 0.3k | half a day to a day (new: dynamic ELF output; PE and Mach-O imports generalized) |
| 2. Native memory: arenas, segments, `pin`, `Handle`, callbacks, thread attach | 0.6–0.9k | 1–1.5k | about a day (`pin` in a copying collector needs a non-moving space, in the C and the Haxe collectors) |
| 3. C declaration parser, header generator | | 1.5–2k (macro code) | half a day |
| 4. Manual memory: `Allocator`, `Slice`, containers; struct values | 2–3k | 1.5–2.5k | 1.5–2 days (struct values touch lowering, Mir, all three back ends and the linkers' data) |
| 5. `@:hxmc.noGc` complete, raw-address check | 0.5–1k | | half a day |
| 6. Value enums, `defer` macro, structs by value across C calls, optional tcc | 2–3k | 0.3k | 1–2 days |
| 7. Runtime and collector rewritten in this style | | rewrite | open-ended, optional |

Total roughly 12–18k lines, comparable to hxmc's code generator: about 2
agent-days for steps 1–2 (usable C interop with safe memory), 1–2 weeks
for steps 1–6. Struct values and `pin` are where it could slip.

## First milestone: the basics

C interop basics and a checked way to rewrite hot paths of hxmc's own std,
without most of the design above.

Included:

1. Types: `Ptr<T>`, the scalar types (`Int8`..`UInt64`, `Float32`),
   `CString`, `@:hxmc.struct` with C layout accessed through pointers only,
   `@:hxmc.opaque`.
2. Externs with direct calls for scalars and pointers on the six ABIs;
   static linking of prebuilt objects; user DLLs (PE) and dylibs (Mach-O)
   by generalizing the runtime's existing system imports.
3. `@:hxmc.noGc` complete, plus the raw-address check (built): the tool
   for rewriting std hot paths, already the runtime's style (`Mem`
   intrinsics in non-collecting functions), made a checked rule.
4. Minimal temporary memory: `Arena.scoped(a -> ...)`, a malloc-backed
   bump allocator returning raw `Ptr`s, for strings and buffers passed to
   C.
5. Fast C calls instead of `pin` for now: a call marked `@:hxmc.fast`
   stays in the GC-unsafe state instead of entering the safe region (as
   .NET's `SuppressGCTransition`), so no collection can run and no object
   can move during it. GC objects' memory can be passed directly
   (`Mem.addr(bytes)` to `memcpy`, `qsort`, hashing, codecs). The call must
   be short, must not block and must not call back. Calls that block copy
   their data through a scoped arena instead. Packages hand a Bytes to C
   through `hxmc.unsafe.BytesPtr` (`of`, `written`, `copyIn`): the
   address here, a copy through the module's linear memory under
   `-D hxmc.wasm-gc`, where a Bytes is an array of the engine's collector.

Deferred: `Segment` checks, `Arena.auto`/`Arena.global`, the `Allocator`
family, `Debug`, containers, struct values, specialized generics, value
enums; `pin`, `Handle`, callbacks and thread attach (until a library calls
back); the C declaration parser and header generator (externs written by
hand at first); structs by value across C calls; tcc; `defer`; the rest of the Zig mapping;
step 7.

Estimate: about 2–3.5k lines (types and extern lowering 1–1.5k compiler
lines, fast calls small, the `noGc` check 0.5–1k, the scoped arena a few
hundred lines of Haxe), roughly one agent-day. Each deferred piece can be
added later without redesigning these.

## The runtime without C of our own

Built (2026-10-15): hxmc's std and runtime contain no C written for hxmc.
Only third-party C is linked: the C library (musl's members on Linux, the
UCRT and MinGW-w64's startup objects on Windows, libSystem on macOS),
mbedtls and libuv, as prebuilt objects (`rt.o`, `ssl.o`, `uv.o`; the
latter two only when referenced). `hxmc/deps` keeps the scripts that build
them (`deps.sh`, `mkrt.sh`), `Layouts.hx` (the struct layouts per target,
written as Haxe constants and checked against the C headers when the
objects are built) and `probe.c` (a build-time layout probe, never linked).

### Where the C went (`hxmc/std/hxmc/rt`)

| Was | What it did | Now |
| --- | --- | --- |
| `rtlibc.c` | `memcmp`, `bcmp`, `memset` 8 bytes at a time | `MemOps.hx`: the runtime's comparisons in no-GC Haxe (the C library's own stay for C code) |
| `rthxmc.c` | allocation and barrier slow paths, macOS `hxmc_tls_base`, the Windows crash handler | `GcPaths.hx`; the thread-local base from the linker (`LinkMachO`); `WinRt.hx` registers a no-GC callback with `AddVectoredExceptionHandler` |
| `rt_win.c` | reservations committed on first touch, UTF-8/UTF-16, Win32 and Winsock errors as errno | `WinRt.hx` (`EXCEPTION_POINTERS` through `Ptr`, error tables in `Layouts.hx`) |
| `rt_dyn.c` | field-name table, inline caches, float formatting | `Names.hx`, `FloatText.hx` (WebAssembly's, on every target; per-thread tables as `@:hxmc.threadLocal` statics) |
| `rt.c` | the collector, startup (`rt_init`), `rt_throw`, boxes | `Gc.hx` (nursery with TLABs, copying minor and major collections, remembered sets, finalisers, native handles, `RT_STATS`, `RT_VERIFY`), `Start.hx` (`rt_init`, `rt_run_main`, `rt_throw` calling `longjmp`), `Boxes.hx` |
| `rt_thread.c` | OS threads, the stop-the-world handshake, safe regions, parkers, mutexes, conditions, semaphores, `rt_wait_fd(s)`, main on a 1 GB stack | `Threads.hx` (mutator records, handshake, safe regions, waits on descriptors), `ThreadApi.hx` (`hxmc.NativeThread` on the native targets), `Os.hx` (pthreads or Win32 behind one API) |
| `rt_census.c` | the heap census | `Census.hx`, compiled with `-D hxmc.census` (`RT_CENSUS=1`/`2` at run time) |
| `rt_ssl.c`, `rt_uv.c` | mbedtls and libuv glue | `Ssl.hx`, `Uv.hx` (`hxmc.NativeSsl`, `hxmc.NativeUv`: typed only for programs that use them) |

### The mechanisms

| Need | Mechanism |
| --- | --- |
| C functions called from Haxe | `@:hxmc.c` externs; `@:hxmc.fast` for calls that stay in the running state; `@:hxmc.indirect` for calls through a C function pointer (a native handle's free function) |
| Haxe functions called from C | `@:hxmc.callback` static functions, their address as `Callback.addr(f)`: a no-GC one is callable from any thread (`atexit`'s report, the crash handler, a thread's first function); a GC one leaves the safe region on entry and enters it again on return |
| thread attach | a new thread starts in the no-GC callback `Threads.entry`, which sets up its shadow stack, allocation buffer and mutator record, then calls the GC callback `Threads.run` (whose wrapper leaves the safe region) for the job |
| thread-local and exported statics | `@:hxmc.threadLocal("symbol")` (the collector's `rt_young_ptr`, `rt_sp`, ...: TLS symbols DataGen writes in each format), `@:hxmc.export("symbol")` on scalar statics that generated code reads by symbol |
| OS structures | opaque memory of the target's size (`pthread_mutex_t`, `pthread_cond_t`, `SRWLOCK`, `CONDITION_VARIABLE`, `uv_*_t`): constants of `Layouts.hx`/`UvLayouts.hx`, generated from the headers by `Layouts.hx` and `probe.c` |
| startup | the C library's entry calls the generated `main`, which calls `rt_init` and `rt_run_main` (Haxe) |
| the main thread's big stack | `Mem.callOnStack(top, fn)`: a few instructions per instruction selection (x86-64, arm64); Windows: a fiber whose entry is a GC callback |
| exceptions | `_setjmp` for `try`; `rt_throw` calls the C library's `longjmp` |
| the runtime's reports | formatted in Haxe (`Os.Report`, `FloatText.fixed` for `%.Nf`) and written with `write`: no `printf` |
| C string literals | `Mem.cstr("...")`: a NUL-terminated byte string in read-only data, shared per literal |
| tables | `Mem.words("<hex>", digits)`: 8-byte words in read-only data, shared per literal (LibM's musl tables) |
| float bit patterns | `Mem.f64Bits(v)`, `Mem.bitsF64(b)`: register moves |
| the safe region's markers | `rt_blocking_enter`/`rt_blocking_leave` stay calls by symbol so that Facts tells the functions that enter one (they must be `@:hxmc.collects` and root what they hold: `Gc.pushRoot`) |

Cost, measured against the C runtime (the benchmarks, the port compiling
itself, a hello world): collection times, thread handshakes and run times
within noise, executables as small or smaller on all six targets. Typing
the runtime's modules with every program would make builds slower; they
are kept between builds instead, typed (the module cache,
`hxmc/src/hxmc/ModuleCache.hx`), which makes a hello world build faster
than with the C runtime.

## Order

1. C interop: `Ptr`, `CString`, `@:hxmc.struct`, `@:hxmc.opaque`, direct
   calls (scalars and pointers), static and dynamic linking.
2. Native memory: arenas, segments, `pin`, `Handle`, callbacks with
   trampolines, thread attach.
3. The C declaration parser; the header-based generator.
4. Scoped memory: data stacks, the `hxmc.scoped` types, scoped structs
   and enums, the root checker, the cores with two faces (struct values
   and `hxmc.unsafe.Slice` done: "Struct values").
5. `@:hxmc.noGc` as a public, complete rule, including the raw-address
   check.
6. Structs by value across C calls (done on every ABI, callbacks
   included: "Calls and linking"); the optional embedded tcc.
7. The runtime, and eventually the collector, rewritten in this style
   (done for the runtime's internal subset: "The runtime without C of our
   own").
