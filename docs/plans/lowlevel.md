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
3. **Scoped memory** (after Goose): values on per-thread data stacks the
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
statics, `Slice`, scalar replacement). Next: scoped memory (section 4:
data stacks, the `hxmc.scoped` types, value enums, the root checker),
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

## 4. Scoped memory (after Goose)

An opt-in subset for low-level code with deterministic memory and no
allocator, after [Goose](https://github.com/aardappel/goose): no heap
allocator, no GC and no lifetime annotations. Every dynamic value lives
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
    trace(Bench.push(4000000));            // scoped call, a scalar result: nothing to copy
    var s:String = Scoped.run(Bench.firstWord(Str.copyOf("hello world")).toString());
  }
}
```

### Types (`hxmc.scoped`)

| Type | What it is | Root of what it yields |
| --- | --- | --- |
| `Grow<T>` | grow-only array: a header (base, length, stack) and its elements on a data stack it owns alone, so `push` is a bounds test and a pointer bump; never moves | `push` returns a `Ref<T>` to the new element, rooted at the Grow; elements read out are rooted at the Grow |
| `Slice<T>` | a view: an address and a length, bounds-checked | the root of what it views |
| `Str` | a `Slice` of UTF-16 code units (strings stay UTF-16 on both faces); a literal converts to one (static data: the global root) | as `Slice`; `Str.copy` makes a fresh one |
| `Ref<T>` | an address of one T (`r.value`, `r.value.x = 1` in place) | the root of the memory it points into |
| `Pool` | a bump region (a `Grow` of bytes) for values whose lifetime is a caller's: `pool.str(s)`, `pool.make(Item)` | the pool |
| `Fixed<T, N>` | a fixed-size array inline in a struct or frame, `N` a constant (`@:genericBuild` with a `@:const` parameter) | the variable holding it |
| `Rel<T>` | a 32-bit self-relative reference (serialization, below) | the array it points into |
| `@:hxmc.scoped` classes | struct values (`@:hxmc.struct`'s representation) whose fields may also be the types above | the union of their fields' roots |
| `@:hxmc.scoped` enums | value enums (below) | the union of their payloads' roots |

T is a scalar (`Int`, `Float`, `Bool`, the C scalars of `hxmc.unsafe`), a
scoped class or enum, or one of the types above.

### Data stacks

A runtime piece next to the shadow stack (`hxmc.rt.DataStacks`, no-GC
Haxe): per thread, up to 16 data stacks, each a reservation with a bump
pointer, made on first use. Natively each reserves 8 GB of address space
(committed as it is touched: `MAP_NORESERVE`, WinRt's commit on touch); on
wasm32, which has no virtual memory, each is a region of the linear memory
(`Heap.regionZero`: pages stay uncommitted until touched), 64 MB unless
`RT_DATA_STACK_MB` says otherwise. Running past the end aborts with a
message (scoped code cannot throw, below), as Goose's guard pages do.

- One stack is the *fixed* one: everything that does not grow (a `Str`
  copy, a `Grow`'s header, a `Pool`'s first block, a struct made for a
  `Ref`) is bumped there.
- A `Grow` claims a stack of its own, which no other value uses while the
  Grow lives: its elements are always on top, so growth is a bump and
  never moves anything. The claim is a bit in the thread's owned mask.
  More growable values live at once than stacks is an abort naming the
  limit (Goose's analysis computes N statically; the dynamic claim is
  simpler and costs a mask test).
- A *mark* (a frame area: the owned mask and each stack's top) is taken
  where a scope that allocates starts; *reset* restores the tops of the
  stacks that were not owned at the mark and the mask: everything the
  scope allocated, Grows it opened included, is freed by a few stores,
  however much it holds.

### Scopes

The scopes that reset are the function body and each loop body (Goose
also resets at every block; a block or branch is not a reset point here,
so the checker is less strict there: see the deviations).

- A scoped function marks on entry and resets at every return if it
  allocates into its own scope (it calls an allocating primitive, or a
  function whose result holds references) and its own result holds no
  references.
- A function whose result holds references (a `Str`, a `Grow`, a struct
  with a `Slice` field) does not reset: what it allocated, its result
  included, belongs to the caller's scope, and the caller's next reset
  frees it. This is how a result is "built in place" here: it stays where
  it was built. The scratch of such a function lives as long (Goose frees
  it; split the scratch into a helper that returns a scalar).
- A loop body that allocates marks at its start and resets at its end and
  at `continue` and `break` of that loop.
- Scoped code cannot throw (it is no-GC code: a throw allocates); an index
  out of range, a stack overrun or a claim past the limit aborts with a
  message. So a scope always ends by a return or the end of its block, and
  the reset is never skipped. GC code that calls scoped code is where
  exceptions are, and `Scoped.run` resets on them (below).

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
  compile-time function value as Goose's blocks; no closure exists at run
  time and none can escape.
- No moves: assignment, arguments and results copy struct values (as
  `@:hxmc.struct`); a `Grow`'s header is not copied (a `Grow` is the
  address of its header), so passing a Grow passes it by reference.
- Statics may hold scoped values whose roots are global only (literals,
  `Fixed` data).
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
Nothing beyond the pilot below is migrated on this branch.

### The root checker

A pass over the typed AST of each scoped function, after Haxe's inlining
(so the `hxmc.scoped` types' inline operations are plain code by then) and
before lowering (`hxmc/src/hxmc/ir/Scoped.hx`, called from the lowering,
so errors carry the source positions the typer gave, inlined code at its
call site). No annotations: every root is inferred.

*Roots.* A root names where memory lives and so how long it lives:

| Root | Lifetime level |
| --- | --- |
| global: literals, statics, addresses from integers or C | 0 (outlives everything) |
| a parameter's: what the caller passed | 1 |
| fresh memory of a scope: the data-stack memory a scope allocated (named after the variable it was first bound to, else "a temporary at line N") | 2 for the function body, 2 + d for a loop body at depth d |
| a frame: `Mem.stack`, a struct local's address | as its scope, never returned |

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
  `Mem.getPtr`, `p[i]`, `p.value`): R ("read back": whatever was stored
  there outlives the container, so the container bounds it, as Goose's
  inexact roots);
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

*Summaries.* Each scoped function gets one, computed from its body on
first use (recursive cycles iterate to a fixed point from empty): which
parameters its result may be rooted at, whether it may be fresh, and which
parameter's roots (or its fresh memory) it stores into which parameter's
memory. A call's result is then rooted at the arguments behind those
parameters plus, if fresh, the caller's innermost resetting scope; each
store constraint is checked with the arguments' roots, or passed on to the
caller's own summary when they are its parameters. This is Goose's
specialization per root, done with summaries: one body per function, and a
caller sees `longer(a, b)` rooted at `a` and `b`.

*Errors* name the root and the destination, at the store:

```
Bench.hx:37: storing a reference rooted at tmp (fresh memory of the loop body at line 35) into w, which outlives it
Bench.hx:52: Bench.link stores its argument x into the memory of dst: x is rooted at inner (line 50), which does not outlive dst's root outer
Bench.hx:61: returning a reference rooted at buf (a frame area), which ends with the function
```

*Not checked:* what `Ptr`, `Mem` and C do with addresses (global roots: the
escape hatch), and data races (scoped memory is per thread; values cross
threads by copy).

### Scoped enums

A `@:hxmc.scoped` enum is a value enum (Zig's tagged union, Goose's fixed
mode): a 32-bit tag and room for the largest payload, inline wherever it
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
payloads are value types (no recursion but through `Ref`/`Rel`). Goose's
variable mode (each value its own constructor's size, sequential arrays)
is left for later: a `Grow` of variable-size elements cannot be indexed,
and Haxe has no syntax to choose the mode at the point of use.

### GC code and scoped code

- GC code calls scoped functions directly. Arguments are scalars, struct
  values and enum values (copies); a `String` becomes a `Str` by copying
  it onto the data stack (`Str.copyOf`). A call whose result holds no
  references needs nothing else: the callee resets its own scope.
- A result holding references (a `Str`, a `Slice`) is read inside
  `Scoped.run(expr)`, a macro that marks, evaluates `expr` and resets
  (also when `expr` throws: GC code can), so what the scoped calls inside
  allocated is freed when the GC code has copied out what it wants:
  `Scoped.run(f(x).toString())`. In GC code, values holding references
  exist only inside such a region: locals declared there, arguments of
  scoped calls, never stored in a field, an array, a static or a closure,
  never the region's result. The checker enforces it in each GC function
  that mentions a type holding references.
- Copies out: `Str.toString()` (a new `String`), `Slice.toArray()`;
  elements are copied, as a value crossing between the two worlds always
  is.

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

1. A view (`Slice<T>`, `Str`): an address and a length. The scoped face
   passes data-stack memory; the GC face passes a view of its buffer's
   payload taken right before the call (`Slice.ofGc`). The core has no GC
   point, so the buffer cannot move while the view is in use, and the
   raw-address check (`Facts.checkRawAddresses`) rejects a view kept
   across an allocation of the GC wrapper. This covers storage of scalars
   and value types: indexes, hashes, text, numbers.
2. Accessors: inline function arguments (compile-time function values,
   inlined), for storage of GC references, whose stores need the write
   barrier: the GC face passes accessors that store through it, the scoped
   face plain ones.

(Haxe's `@:generic` does not do this: a generic function's body is typed
once against its constraint, and an abstract over a buffer satisfies no
structural constraint; inline functions are monomorphised by inlining.)

The pilot on this branch: the maps' index (`haxe.ds.IntMap`'s and
`StringMap`'s open-addressing index with backward-shift deletion,
`MapSlots`) as a scoped core over a `Slice<Int>`, used by the maps (GC
face) and by a scoped hash table (`hxmc.scoped.IntTable`, scoped face),
the old code deleted in the same change; same test results, and measured
for speed (`make bench-micro WHICH=maps`).

Next candidates, in order: `FloatText` (the digits into a `Grow<UInt16>`
or a `StringBuf`'s buffer), `CaseMap`, the string search and comparison
of `hxmc.rt.Str`, then the OS layers' buffers (b).

### Serialization: relative references

Goose's structures built from relative references are their own file
format; the same fits scoped memory:

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

- Native, all six targets: data stacks as reservations (above).
- wasm32: data stacks as regions of the linear memory, same code.
- WasmGC (`-D hxmc.wasm-gc`): scoped code is a compile error ("scoped
  memory needs a linear memory: not available with -D hxmc.wasm-gc").
  A later lowering could keep data stacks in a linear memory beside the
  engine's GC heap (WasmGC modules may have one), struct values and Grows
  as offsets in it, the same checker; struct values there are objects
  today, which would have to change first.

### What Haxe cannot express (and what stands in)

- Const generics only through `@:genericBuild`: `Fixed<Int, 16>` is a
  macro-built struct; there is no type-level arithmetic.
- No moves: values are copied (as in Goose, which leaves moves out too); a
  `Grow` is a reference to its header, which is the cheap way to pass one.
- No `return err from f`: Haxe has neither the syntax nor a cheap
  multi-frame return; scoped code returns error values (a scoped enum)
  instead, and cannot throw.
- No transparent references or `.=`: `Ref<T>` with `r.value`, and
  rebinding is assignment.
- No variable-size values inline in an array (Goose's `u8[][>..]`): a
  `Str` is a view; text that must outlive a function goes into a `Pool`
  or a `Grow<UInt16>` passed in.
- Storage as a type parameter of a generic algorithm (see "One core, two
  faces"): inline functions and their function-literal arguments instead.
- No mode choice at the point of use (Goose's `Shape..`): one
  representation per enum.

### Deviations from Goose, and why

- Dynamic claims instead of a static stack assignment: no whole-program
  analysis of which values grow at once; a mask test per `new Grow`.
- Resets at function and loop bodies only, not at every block: fewer marks
  (a mark is a few stores), and a branch's values may be kept in a
  variable declared before it (Goose rejects that).
- Callee scratch of a function returning references lives until the
  caller's reset: no in-place construction through calls; results stay
  where they were built.
- Summaries per function instead of one body per root: one compiled body
  (Haxe compiles each function once), at the price of precision where a
  function treats its parameters differently on different calls.
- Out-of-range indexes abort, as in Goose; the GC faces keep Haxe's
  behaviour by testing before they call.

### Status

Design (2026-10-25); what is built is recorded here as it lands.

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

### Other Zig and Goose constructs and how they map

| Zig / Goose | Haxe on hxmc | Fit |
| --- | --- | --- |
| `comptime` generics (`fn ArrayList(comptime T: type) type`) | inline abstracts over `Ptr<T>` (the `hxmc.scoped` types), `@:generic` | good |
| `comptime` computation, `inline for`, Goose's function blocks | macros (run in Eval, different semantics), inlining with function-literal arguments, constant folding | partial |
| `defer` / `errdefer` | a macro rewriting `@:defer expr` into cleanup on every exit (try/catch and rethrow: Haxe has no `finally`); scoped code needs none (the reset is the cleanup) | good with a macro |
| error unions, `try`, `catch`; Goose's `return err from` | exceptions in GC code; in scoped code error values (a scoped enum) | acceptable |
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
