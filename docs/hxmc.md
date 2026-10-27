# How hxmc works

The internals of the hxmc target, for contributors: the pipeline from typed
AST to executable, the runtime and collector, the linkers and each
target's specifics. Using hxmc is in [using.md](using.md); building and
testing it in [development.md](development.md) and
[testing.md](testing.md); open designs in [plans/](plans/README.md).

## Pipeline

hxmc turns the typed program into machine code or WebAssembly with its own
code generator and linkers.

```
typed AST --(ir.Lower)--> hxmc IR --(ir.Reach)--> --(Prep: ir.Facts)--> --(MirBuild)--> object-level Mir --(Inline, Escape, Sroa, Opt, Frames)--> --(MemLower)--> Mir (SSA) --(Fold, DivConst)-->
    --(x64|a64 Isel)--> LIR --(Regalloc, Emit)--> Obj (per module, cached) | --(wasm/WasmGen)--> wasm
    --(DataGen: tables, strings)--> Obj --(Link: ELF | LinkPE | LinkMachO | LinkWasm)--> executable
-D hxmc.wasm-gc: hxmc IR --(ir.Reach)--> --(MirBuild.gc)--> object-level Mir --(Inline, Escape, Opt)--> --(wasmgc.MirGen, GcModule)--> WasmGC module
```

| File (`hxmc/src/hxmc/`) | |
| --- | --- |
| `Main.hx`, `Options.hx`, `Driver.hx` | the tool: runs the port's compiler with a generate hook, compiles modules in parallel (cached) and links; `--server` keeps a compilation server resident |
| `HaxeMain.hx` | `haxe` with hxmc built in (the npm package) |
| `ir/Ir.hx`, `Lower.hx`, `FnLower.hx`, `LowerQueries.hx` | the IR (structured statements in A-normal form, explicit GC points) and the lowering of the typed AST. A body asks the program's lowering only what `LowerQueries` lists |
| `ir/Reach.hx` | the functions the program can run ([Reachability](#reachability)) |
| `ir/RuntimeSymbols.hx` | the runtime symbols generated code calls by name ([below](#the-symbols-generated-code-calls)) |
| `ir/Facts.hx`, `Prep.hx` | program-wide facts: names, layouts, type indices, field ids, no-GC functions, GC points |
| `UpToDate.hx`, `Fingerprint.hx`, `LowerCache.hx` | rebuilds: the whole build skipped when nothing changed, objects reused by fingerprint, lowered bodies reused by the server |
| `Mir.hx`, `MirWriter.hx`, `MirBuild.hx`, `MemLower.hx` | the SSA IR at two levels. Object-level Mir has objects, fields, arrays, type tests, boxes, closures and virtual calls as operations. `MemLower` lowers it to memory-level Mir: layouts, allocation, barriers, inline caches, null tests, the shadow stack |
| `Cfg.hx`, `Ssa.hx`, `Opt.hx`, `Inline.hx`, `Escape.hx`, `Sroa.hx`, `Frames.hx` | analyses and optimizations: inlining, escape analysis, scalar replacement, value numbering, store forwarding, LICM, dead code, barriers and frame slots nothing needs |
| `Fold.hx`, `DivConst.hx` | allocation folding; division by constants |
| `Lir.hx`, `IselBase.hx`, `Regalloc.hx`, `x64/`, `a64/` | instruction selection, linear-scan register allocation, encoders (checked against llvm-mc: `EncCheck`), emission |
| `Unwind.hx`, `Dwarf.hx`, `StackTable.hx` | unwind tables, DWARF lines, the call-stack table ([Debugging](#debugging)) |
| `Obj.hx`, `ElfWriter.hx`, `*Reader.hx`, `Link*.hx`, `MkRt.hx`, `DataGen.hx` | objects, the linkers, the runtime-object builder, the program's data |
| `wasm/` | wasm32-wasi: structured code from Mir, the linker, exception handling |
| `wasmgc/` | `-D hxmc.wasm-gc` ([WasmGC](#wasmgc)) |
| `Target.hx`, `Abi.hx`, `CallConv.hx`, `CAbi.hx` | per-target facts; one calling convention per ABI; how each C ABI passes structs |
| `MkStd.hx` | merges hxmc's std with the Eval originals into `bin/hxmc/std` |
| `macro/`, `interp/` | the Mir interpreter's encoding and its uses: Mir macros and `--run` ([below](#macros-on-the-mir-interpreter)) |
| `android/`, `ios/` | the APK and app bundle writers |

Conventions:

- References live across a GC point are shadow-stack slots. Cold sites
  spill only on their slow path.
- `try` is a handler record and the C library's `_setjmp`; `throw` calls
  `rt_throw`, which `longjmp`s.
- Calls follow the target's C ABI.
- A `@:hxmc.struct` value is the address of its memory, copied on
  assignment; a result goes where a hidden last argument points.
- Thread-locals: local-exec TLS on Linux, `_tls_index` on Windows, TLV on
  macOS.
- Program-wide numbers (type indices, field ids, offsets) are absolute
  symbols the linker resolves, so a module's code does not change when the
  numbering does.
- A change of the runtime's interface or the IR's conventions needs a tool
  that knows it: build once against the previous runtime first, or
  bootstrap again.

## Runtime in Haxe

The runtime is Haxe compiled with the program (`hxmc/std/hxmc/rt`):
strings, Dynamic access, reflection, arrays, bytes, dates, inflate, the
POSIX, Windows and WASI system layers, the collector (`Gc.hx`), threads and
the stop-the-world handshake (`Threads.hx`), startup and `rt_throw`
(`Start.hx`), and Math (musl's libm ported, `LibM.hx`, the same results on
every target). No C of hxmc's own is linked; only the C library, mbedtls
and libuv, prebuilt per target by zig from `hxmc/deps`.

It is written with an internal API, `hxmc.unsafe` (`Ptr`, `Mem` loads,
stores and allocation, `Atomic`) and metadata: `@:hxmc.c` and `@:hxmc.rt`
externs, `@:hxmc.unsafe` functions (no GC point, checked),
`@:hxmc.export`/`@:hxmc.host` implementations of runtime functions,
`@:hxmc.callback`, `@:hxmc.threadLocal` statics. The user-facing part is in
[interop.md](interop.md).

What is the same across targets is written once and inlined:

- `GcCore.hx`: the object model both collectors read (header, size,
  forwarding, pointer maps).
- `SysCore.hx` for PosixSys, WinSys and WasiSys; `NetCore.hx` for PosixNet
  and WinNet. `Mem.os()` picks the system and folds at compile time.
- `Str`, `Arr`, `Bytes`, `Date` (`@:hxmc.anyHeap`): written over
  `hxmc.rt.Repr`, which is `MemRepr` in linear memory and `GcRepr` on
  WasmGC.

### Object layout

The 8 bytes before an object (`Types.hx`) start with its type index, which
decides the rest:

```
          p-8          p-6                         p-4
record:   [ type:16 ][ slots:16                ][ identity hash:32        ]
array:    [ type:16 ][ words:16 (0xFFFF: more) ][ length:32, in elements ]
string:   [ type:16 ][ words:16 (0xFFFF: more) ][ content hash:32         ]
          then its length (u32 at +0) and its units from +4
forwarded (while the collector copies): type 0xFFFF, the copy in slot 0
```

- The size is the 16 bits at -6, in 8-byte words. An array or string of
  0xFFFF words or more computes it from its length.
- Types 16 to 23 are arrays without references, 24 to 31 arrays of
  references; the rest are records, scanned by their type's pointer map.
- Every heap object has at least one slot (for the forwarding address).
  Empty arrays and `""` are static.

| Type | |
| --- | --- |
| 1 | ArrayIterator |
| 2, 3, 4, 6 | Int, Float, Bool, Int64 boxes |
| 5 | Array: length and kind, then its storage (a NativeArray) |
| 7, 8 | NativeArray of an erased type parameter, open and fixed |
| 11, 12, 13 | captured variables (reference, Int, Float) |
| 14 | type object |
| 15 | Date |
| 16, 17 | String: UTF-16, or one byte per unit when every unit is below 0x100 |
| 18 | slots: a C resource, an AtomicInt cell |
| 19 to 24 | NativeArray storage by element kind: Byte (a Bytes' data) 19, Bool 20, Int64 21, Float 22, Int 23, references 24 |
| 25 | slots of references (thread-local slots, AtomicObject's cell) |
| 26 | a structure's added fields |
| 27 | a C resource with references |
| 28 | Math (its class value) |
| 32 and up | the program's types |

A `haxe.io.Bytes` is an object holding a `NativeArray<Byte>` (`b`); its
`length` is `b`'s (`@:hxmc.lengthOf`). A small Bytes is allocated together
with its data. Arrays have no identity hash.

### The collector

A precise, generational, copying collector (`Gc.hx`; `wasm/Gc.hx` for
wasm32). The nursery is collected by copying into the old space; the old
space by copying into a new region.

- **Nursery size** adapts: it starts at 4 MB, doubles after a minor
  collection that promoted more than 1/16 of what was allocated, and halves
  after 8 that promoted less than 1/64. Floor: 4 MB per allocating thread
  (at most 32 MB); ceiling: 16 MB per such thread (at most 256 MB).
  `RT_MINOR_KB` fixes it, at 16 KB at least: generated code stores into
  objects allocated since the last GC point without a barrier, and
  allocation folding makes objects of up to 4 KB, so these must be young.
- **TLABs**: each thread takes at most 64 KB at a time (`RT_TLAB_KB`), in
  fresh pages up to a 2 MB boundary.
- **Old space**: `RT_OLD_MB` sets the first limit, `RT_OLD_GROWTH` the next
  ones in percent of what a major collection left live (300 natively, 200
  on wasm32). The tool sets 768 MB for a build; the compilation server
  2048 MB and 150%.
- **Prefault** (`-D hxmc.gc-prefault`, Linux): once the old space passes
  64 MB, a helper thread faults in its pages ahead of minor collections.
  The compilers are built with it. `RT_PREFAULT=0` turns it off.
- **Publication**: a store of a reference into an object, array or static
  is a release store (`MIns.release`), so a thread that reads the reference
  also sees the object's initialisation, as OCaml guarantees the reference
  compiler. Upstream's parallel phases rely on it. Free on x86-64; arm64
  emits `dmb ishst` before such stores.

`RT_STATS=1` prints resizes and promotions; `RT_VERIFY=1` fills the free
nursery with a pattern so missed roots show at once, and ends the program
at an allocation inside a safe region (every allocation takes the slow
path then, which checks).

### Strings and dates

Strings are UTF-16 in semantics, stored as one byte per unit when every
unit fits (type 17, as V8's one-byte strings). They cross system
boundaries (files, processes, sockets, the environment, `Bytes`) as UTF-8.
A byte that does not start a well-formed sequence decodes to one unit
U+DC80 to U+DCFF and encodes back to that byte, so bytes read and written
again are unchanged (the corpus' `Utf8Bytes`; the port keeps OCaml's byte
strings this way).

A Date is a runtime type of its own (`T_DATE`) holding milliseconds since
the epoch. `Std.string` reaches `Date.toString` only through
`Date.printer`, which every date's creation sets, so a program that makes
no date has no calendar code. `DateValues` checks dates against the
reference's `--interp`.

### The symbols generated code calls

Generated code calls a fixed set of runtime functions by name, and natively
reads some runtime variables by name. `ir/RuntimeSymbols.hx` lists them
per family of targets (native, wasm32, WasmGC), with where generated code
refers to each.

A program gets the runtime through `hxmc.rt.Runtime`, whose imports differ
by target, and hxmc compiles only what is called. So each build checks,
before lowering, that the modules `Runtime.hx` imports for the target
define every listed symbol, whether this program calls it or not:

```
hxmc: the runtime symbol rt_null_access is defined in hxmc.rt.Faults, which hxmc.rt.Runtime does not import (for wasm32-wasi; MemLower.nullBlock)
```

The rule: `Runtime.hx` imports each module that defines such a symbol,
for every target that needs it. A symbol needed only under a define has
that condition in the list. `MirWriter.call` and `GcModule.exportOf` fail
the build when generated code calls an exported runtime function the list
lacks, so the list cannot fall behind. Not listed: what a linker, the C
library or DataGen defines, and the std's extern implementations
(`String_toUpperCase`), which fail the build of a program that calls a
missing one.

## Reachability

Haxe's default DCE keeps every field of a user class.
`ir/Reach.hx` then keeps only what the program can run, a rapid type
analysis over the IR before anything is compiled. From `main`, the exported
functions and `@:keep` methods:

- a function is live when live code calls it or makes a closure of it;
- a static initializer is live when live code uses a static it sets;
- a method is live when live code instantiates its class (or a subclass)
  and either dispatches on its selector or can look its name up.

Names looked up are those of structural and Dynamic access, literal names
passed to the runtime's lookups (`Reflect.field(o, "x")`), and names from
the runtime's own tables. A name computed any other way keeps every method
of the instantiated classes.

Dropped functions leave the method tables, so `Type.getInstanceFields`
lists the methods kept, as with `-dce full`. Dispatch rows are laid over
each other. Closures share a type when their signatures and captures
match; a closure capturing nothing is static data.

- **Statics through a class value** (`Reflect.field(C, "x")`,
  `Type.getClassFields`, `haxe.rtti.Meta`): a class used as a value gets a
  table of its statics, in Eval's order, kept when live code can have the
  class value. Functions not otherwise live are left out.
- **`Type.createInstance`**: once it is used, each class whose value live
  code can have keeps a constructor entry. A class without a constructor,
  or whose entry was dropped, fails as on Eval (`Instance constructor not
  found`).

`HXMC_STATS=1` prints the live functions and the data's parts;
`HXMC_REACH_WHY=<pack.Class.method>` the chain that keeps a function;
`HXMC_REACH=0` keeps everything.

## Anonymous structures

An object literal's layout is a shape (`ir.ShapeInfo`): slot 0, then its
fields sorted by name, with Int and Bool two to a slot. Structural reads
and writes test the shape's type index or go through an inline cache, else
the runtime (`hx_anon_get_slow`, `hx_anon_set_slow`).

A field the layout lacks (`o.x = 1` on a Dynamic, `Reflect.setField`) goes
in slot 0: an array of (field id, value) pairs in insertion order. Every
reader sees both. `Reflect.fields`, `haxe.Json` and `haxe.Serializer` list
the own fields by name, then the added ones in order. `Std.string` prints
`{ a : 1, b : 2 }`. `Reflect.deleteField` removes added fields only; for an
own field it returns false, because the layout and type index are fixed.
WasmGC keeps added fields in a `GcFields` with the same behaviour.
`AnonFields` checks this against the reference's `--interp`.

## Native arrays

`hxmc.NativeArray<T>` is fixed-size storage in one GC allocation: header,
then packed elements. Bool takes 1 byte, Int 4, Float and Int64 8,
references 8; nullable numbers and Dynamic use reference storage. Indexing
lowers to plain loads and stores; references keep the write barrier.

`haxe.ds.Vector` (`hxmc/std/haxe/ds/Vector.hx`) is an abstract over it.
`MkStd` keeps upstream's Vector for Eval and macros.

- **Dynamic element type**: storage of any kind. Accesses test the kind
  inline. A typed view of such storage is checked once
  (`hx_narray_view`); a mismatch throws, as a cast does on HL. A
  NativeArray made for an erased type parameter is a wrapper whose first
  typed view converts the storage.
- **Empty arrays** are static, one per kind: `new Vector(0)` allocates
  nothing.
- **`NativeArray.literal([a, b, c])`** allocates once and stores each
  element.
- **Bounds**: `-D hxmc.native-array-outofbounds` decides at code
  generation (`Lower.bounds`). The test is IR, so the optimizer drops a test
  a dominating one decides. The std's own loops use `unsafeGet`/`unsafeSet`.
- **WasmGC**: the engine's array of the element kind; the engine checks
  every index, so an untested out-of-bounds access traps.

## Where struct values are boxed

A `@:hxmc.struct` value is the address of its memory in a frame, an
object, a static or native memory ([interop.md](interop.md#struct-values)).
Storage that is not typed with the struct holds references: there the
value is copied into a box, an immutable object (8 bytes of header, then
the struct; 32 B for three Floats), on every store. By design: Array,
Vector, the maps and every type parameter are erased to element kinds that
are scalars or references, and `null` needs a reference.

| Boxed on every store or pass | Not boxed |
| --- | --- |
| `Array<S>` and `haxe.ds.Vector<S>` elements (a read copies out, without allocating) | locals, parameters, results (copied through the frame) |
| `Map<K, S>` values, any `T` of a generic class or function (not `@:generic`) | fields of classes and structs, statics |
| `Null<S>`: an optional argument `?s:S` when given, a `Null<S>` result or local | closures taking or returning `S` |
| `Dynamic`, `Std.string`, string interpolation, `trace` | `Slice<S>` and `Ptr` (native memory: [interop.md](interop.md#native-memory)) |
| an enum argument that escapes its function | a `for` over an array literal of struct values, even with a `continue` or `break` (`FnLower.structLiteralLoop`) |

The box is never written: `arr[i].x = 1` is a compile error (copy out,
change, store back). Escape analysis removes a box that does not leave its
function (an enum value switched on where it is made).

In a hot path:

- **Sequences**: a `Slice<S>` from an `Arena`, or an object with one field
  per element, rather than `Array<S>`; or parallel `Array<Float>`s.
- **Optional values**: a sentinel (`static final NONE = new Size(-1,
  -1)`, tested with a field) or a `Bool` result with an out parameter (a
  struct field of the caller's object, or a `Ptr`), rather than `Null<S>`.
  A `Null<S>` result is boxed even when the caller only tests it.
- **Optional arguments**: an overload or a second function without the
  argument, or the sentinel as the default, rather than `?s:S`.
- **Generic code**: `@:generic` (a copy per type) or an `inline` function,
  whose struct parameters stay structs.

Open: unboxed `Array<S>` storage and `Null<S>` as a presence flag beside
the value ([plans/lowlevel.md](plans/lowlevel.md#struct-values-in-generic-storage)).

## Null access

A read or write through null throws `"Null Access"`: a field, an enum's
tag, an Array, a String's methods, a Vector, Bytes, a map, a call through a
null function, a virtual or interface call. Dynamic access throws the same
(`d.x` too, where Eval gives null). A call of a null Dynamic throws `Cannot
call null`. Where hxmc words it differently from Eval: `field access on
null` for field reads and a String's length (a fault cannot tell those
apart), and a method called directly on null runs until it reads `this`.
`NullAccess` and `NullAccessThreads` check this against the reference.

### Native targets: the fault handler

Generated code reads through references without testing them. A null one
faults near address 0, and the fault handler (`rt/Faults.hx`: `sigaction`
on Linux, Android, macOS and iOS; a vectored exception handler on Windows)
turns the fault into a throw. It does not unwind itself: it changes the
interrupted context so the thread runs `rt_null_access` as if the faulting
instruction had called it, Go's way. Two rules keep this right: `Roots`
roots what a try's handlers read, and `Opt.forwardStores` keeps a store
before an access through a reference not yet dereferenced. With no fault
there is no cost.

A fault counts as a null access only when the hardware reported it, its
address is within 64 KB of 0, its instruction is in the program's image,
the thread is one of the runtime's running Haxe code (not in a safe region
or the stopped-world collector), and the innermost handler is at or above
the faulting frame. Any other fault goes to the previous action: the
process dies of the signal as before, or a host's handler runs. A shared
library puts the previous actions back when it ends. `RT_NULL_ACCESS=0`
installs nothing.

Limits: a large index into a null Vector without bounds tests lands beyond
64 KB and crashes; a fault outside the image (the glibc mode's C library, a
driver) crashes; a fault inside the runtime while it holds a lock would
leave the lock taken.

### Core dumps

The runtime reserves about 35 GB of address space natively (two 16 GB
old-space regions, the nursery, 1 GB stacks for the main thread). On Linux
and Android the reservations are marked `MADV_DONTDUMP`, except what the
program uses: each old-space region up to its limit, the nursery up to its
size, each stack's last 8 MB, and the faulting thread's stacks. Without
this, a crash piped to systemd-coredump wrote tens of gigabytes. The corpus
case `CoreDumpSize` checks it.

### WebAssembly: explicit tests

WebAssembly has no faults to catch, so `-D hxmc.null-checks` (on by default
for `wasm32-wasi`) tests each dereference (`MirBuild.nullCheck`,
`MemLower.nullTest`). The tests share one block per try that calls
`rt_null_access`. WasmGC calls a per-type helper `nn_<t>`. A test is
dropped where the value is known non-null: data at a symbol, an object made
here, a value tested on every path. The cost is about 5% in size and
instructions.

## Maps

`IntMap`, `StringMap` and `ObjectMap` (`hxmc/std/haxe/ds`) are compact
insertion-ordered tables, as in Python and JavaScript: entries appended to
an array, found through an open-addressing index with linear probing, at
most half full, no tombstones. Each index slot holds what is compared
first (the key, a string's cached FNV-1a hash, or an address hash) and the
entry number, so a miss reads only the index.

### Identity maps

`ObjectMap` (also `Map<SomeClass, V>`, maps of anonymous objects and
functions) hashes the key's address, as Go's `map[*T]V` does
(`hxmc.rt.IdHash`). The collector moves objects, so it counts collections
(`hxmc_gc_count`, `hxmc_gc_majors`). Each map records the count it is
current with and checks it first. After minor collections only the keys
that were young when added can have moved; the map lists those and
reindexes them. After a major collection every entry is reindexed. A map
shared by reading threads is updated by the first that finds it stale,
under `hxmc_idhash_lock`. WasmGC has no addresses and hashes with the
header's identity hash instead. `Map<SomeEnum, V>` is upstream's
`EnumValueMap`, not an identity map. `ObjectMapGc` checks maps across
collections; `make bench-micro WHICH=maps` measures them.

## Module cache

The compilation server's HXB module cache, made durable
(`ModuleCache.hx`, `ModuleCacheState.hx`, `WatchedCallbacks.hx`,
`CheckingHxbWriter.hx`, `Skeletons.hx`, `ModuleStore.hx`,
`ObjectStore.hx`, `CacheDir.hx`). Usage: [using.md](using.md#fast-rebuilds).

**The store** is `<cache>/modules/<tool>/`, one directory per build of the
tool:

- an index per working directory, class paths and std (`<key>.idx`);
- the modules' HXB in packs, one per build that writes (`b/<name>.pk`),
  written on a thread beside the build;
- compiled objects (`o/`), named by the hash of their lowered IR and shared
  by every output; per output, the objects its last build used and its
  up-to-date record. `<out>.hxmc/` holds them only where the cache cannot be
  written.

Once a day a build removes what has been unused for 14 days. The size cap
holds as builds write: each build appends its bytes to `modules/size.txt`,
and past the cap it trims to 80%, other tools' directories first. Removal
tolerates concurrent builds. `CacheCheck` tests the store.

**Variants and keys.** An index keeps variants of each module, each with
the defines it read (its file's conditions, its macros'
`Context.defined`, and what the compiler read while typing it). A build
restores the variant whose reads match, so a define only some modules read
leaves the others restored. Up to four variants per module are kept, so
builds that alternate (native, wasm, WasmGC) each restore their own.

**Validation** is lazy, for the modules a build loads. A file is compared
by content hash where its date or size changed; its path must still
resolve to it; each dependency must have the hash it had: the hash of its
interface (`ModuleInterface.hx`: declarations without the bodies of
functions with written types), or of its whole content across contexts.
A module typed again whose interface did not change leaves its dependents
restored (early cutoff). An undone edit restores the earlier variant.

**Macros.** Modules built by macros are restored. Static variables of
macro classes used during a module's typing are kept with it; if a later
macro uses that state, the build runs again with those modules typed
(`HXMC_MODULE_CACHE_RETYPE`). A callback registered during a module's
typing (`onGenerate`, ...) types that module every build. What a macro's
result depends on beyond the sources comes from hooks in the macro std
(`EvalStdLib.volatileHook`, `fileHook`, `envHook`): volatile calls make the
module typed every build; file and environment reads are recorded with
their values. HXB does not keep the modifiers of unbound monomorphs or the
type sort's walks; the cache keeps those too.

**Not cached**: display requests, the server itself, several
compilations, init macros, deprecated defines, HXB libraries and output,
WASI. A callback registered outside a module's typing, or a macro defining
something, makes the build write nothing. A module whose types share a path
(eval's `mbedtls.SslAuthmode`) is not kept.

`make test-module-cache` checks that outputs are byte-identical with and
without the cache; `make fixpoint` builds the tool cold, warm and off.
Open items: [plans/compiler.md](plans/compiler.md#cached-modules).

## Macros on the Mir interpreter

`-D hxmc.macros=mir`, in the native compiler (`haxe` with hxmc built in,
the npm package's: `bin/npm/native/<target>/haxe` for the six native
targets, below; not the WebAssembly one): macros run on the Mir interpreter (`hxmc.rt.Interp`), not
Eval. The macro context is typed for hxmc (its std in front, the hxmc
custom target: `MirMacros.setupPlatform`); a macro function, with what it
reaches, is lowered when a macro first calls it, in bundles the compiler
links into itself (`macro.Loader`), each function compiled for the
interpreter the first time it is called (below), and the std's functions the
compiler has alike (the same fingerprint, from the compiler's own table:
`macro.HostTable`) run as its native code. Macro values are the compiler's
own (`MacroApi.MacroNativeValues`). `-D hxmc.run=mir` runs
`--interp`/`--run` programs the same way, with hxmc's semantics.

A native build of a program that has `hxmc.interp.MirMacros` (the
compiler, `hxmc.HaxeMain`, and the tool) is a Mir host (`Options.mirHost`;
`hxmc.unsafe.Mem.mirHost()`, a constant the lowering folds, is 1 in its
code): every function stays, it carries the host table, the pools and
spare type, signature and global entries (`macro.MirHost`), and the
std's parts for code it loads (`EvalCompat`, the interpreter's `CALLX`)
are compiled in. Other programs lower none of it. There is no build
flavor: on linux-x86_64 this costs the compiler 4.4% raw and nothing
gzipped (plans/compiler.md, "Mir macros").

A bundle for the interpreter carries no native code, so interpreted code
never needs executable memory: its functions are descriptors
(`InterpGen`), its data and dispatch rows are in memory of malloc's, only
64-bit absolute relocations are applied, and nothing is mapped executable
or below 2 GB (the Loader throws if a bundle for the interpreter has code;
`HXMC_MACRO_STATS=1` reports its bytes, `make mir-run-check` checks them).
Every crossing goes through a register image, a buffer of words the
interpreter reads and writes, and functions of the compiler that move it
in and out of the ABI's registers (`interp.InterpAbi`):

- interpreted code calling native code (the compiler's functions, the C
  library) writes each argument where the calling convention puts it
  (`CallConv.place`, at compile time) and calls `hxmc_interp_callout_r`
  (or `_s`, with stack words), which loads every argument register from
  the image, calls, and stores the result registers back (taken as the
  parts of a struct result: `MIns.cRet`). An allocation's slow path calls
  `hxmc_alloc_slow` so; the instruction selections' expansions (atomics,
  float32 conversions) are the interpreter's own operations; the
  compiler's thread-local variables are read and set through accessors it
  carries (`hxmc_tls_get$<name>`, `hxmc_tls_set$<name>`).
- native code calling an interpreted function (a dispatch row, a method
  table, a closure, a maker of `Type.createInstance`, a signature's
  trampoline, a callback the compiler keeps) calls an entry of one of the
  compiler's pools (an integer or a double result, with or without stack
  words: 1024, 256, 128 and 32 entries, ten times the most measured, the
  formatter build's 70; an exhausted pool is an error that names it), which passes its arguments and
  its number to the interpreter (`hxmc_interp_pool_enter`: the function
  the Loader gave that entry, its arguments by the descriptor's parameter
  sources). The Loader gives an entry out the first time a function's
  address is needed (the formatter's macros: 70) and never takes it back.
- the signatures' dyn and bound trampolines are interpreted too, and so
  are the runtime's functions the compiler lacks.

The call-outs, the pools and the accessors are Mir, compiled into the
compiler by the target's own back end (81 KB of code on x86-64: the
pools' entries are 32 bytes each), so a
platform needs no machine code of its own for them: the per-ABI part is
`InterpAbi`'s. Each of those functions takes every argument register,
then stack words, whatever the function behind it takes
(`CallConv.ALL_REGS`): where integer and float arguments take registers
independently (System V x86-64, AAPCS64) that is the convention's own
placement; Win64 assigns them by position (rcx or xmm0 for the first, ...),
and there the entries take both registers of each of the first four
positions, so one pool serves every signature, and the call-outs pass both
from the argument's word (a variadic callee reads a float from the integer
register too). Apple's arm64 packs stack arguments by their C size and puts
variadic ones on the stack, both carried by the image's stack words as
they are; x18, the platform's register on Apple and Windows, is never
allocated. The macro context and `--run` take the compiler's own target.
The native compiler is cross-built for linux-x86_64, linux-arm64,
macos-x86_64, macos-arm64, windows-x86_64 and windows-arm64 (`make
bin/npm/native/<target>/haxe`), and CI's test jobs run it on each target's
machine (the Mir lane): the corpus in it (`Corpus --mir-run`, as `make
mir-run-check`; the cases known to fail there: `Corpus.MIR_RUN_KNOWN`),
the macro cases with Mir macros against the reference (as `make
mir-macros-check`: 66 of 67, Issue11631 uses Eval's `mbedtls`), and a
benchmark macro and the formatter's build timed against Eval
(`MirBench`). The compiler carries the table of its
symbols and its functions' fingerprints and flags as data
(`macro.HostTable`, made at its link: 212 KB on linux-x86_64). Its
symbols are the ones code loaded at run time can name: not the
compiler's own classes' entities, which the macro context and `--run`
programs type again (20,439 of 63,450). A name is found through a
minimal perfect hash (PTHash's: a 16-bit pilot per bucket of the name's
64-bit hash, 21,078 slots) and checked against the 32-bit check of its
slot (a name the compiler lacks: one in 4 billion passes); the value is
32-bit and relative to its own place in the table (the link resolves
it, so the system's loader moves nothing), the kind four bits; the
fingerprints have their own perfect hash. A lookup takes about 0.23 µs,
2,500-7,000 per build. On Windows and macOS, where the C library is
imported from DLLs or bound from libSystem, the table also names the
compiler's imports (`HostTable.imports`: their thunks, or bound in place),
and a C function the compiler imports nothing of is looked up as the
system's loader would bind it (`Loader.systemSymbol`: `dlsym`, or
`GetProcAddress` in the DLL of its `@:hxmc.lib`). `<exe>.syms` is still written next to it, for
people (`RT_CENSUS_WHY`'s globals); nothing reads it.

What macro code sees as on Eval (`hxmc.rt.EvalCompat`: on while macro code
runs, off inside the API's functions): `Std.string` as `EvalPrinting.s_value`
prints (`{a: 1, b: x}`, the fields by their names' OCaml hashes; nesting
below depth 5 as `<...>`; `#fun`, `#closure`, `Class<C>`, `Enum<E>`; a
position as `#pos(file:line: characters a-b)`), `Reflect.fields` in that
order, `Type.getClassName` of a position's class `haxe.macro.Position`. A
caught typing error is a `haxe.macro.Error` with its `childErrors`; `$v{}`
of an integral Float is a Float. A compilation that types the macro context
again (`--next`, the compilation server) starts a new generation of bundles,
as Eval drops its prototypes, and a reused macro context runs its static
initializers again (`EvalMain.doReuse`), in the order of the classes' paths'
hashes as Eval's `static_prototypes#reset` walks them; statics without an
initializer keep their values. A bundle's static initializers run in the
order their classes were handed over (`EvalPrototype.addTypes`). Eval
drops only the prototypes of the types typed again, so a class of the new
generation whose module is the same as an earlier generation's carries
its statics over (`Loader`: the slot of a reference, the value of a
scalar) and does not run its initializer as it loads; this holds when the
macro context is typed again partway through a compilation too. Each
compilation hands over the types of the modules not typed again as other
objects of the same modules, which a generation lowers as the first ones
(`Lower.samePaths`). `Context.error` ends its macro only: the call has no
value, as Eval's `catch_exceptions` makes of `Abort`. `make
mir-server-check` (`hxmc/test/MirServerCheck.hx`, in the Mir lane but on
Windows) compares a server with Mir macros to the reference's through edits.

An uncaught exception of macro code is reported at the line of its
innermost frame of macro code, then each caller's line ("Called from
pack.Class.field", a frame repeated once with its count), the macro
call's position last; a `haxe.macro.Expr.Error` at its position with its
child errors; a callback the compiler calls (`Context.onAfterTyping`, ...)
without a macro call's position. The stacks are the runtime's
(`hxmc.rt.Stacks`, "Debugging"): the macro code is lowered with its lines
as a native build is (`Lower.lines`), InterpGen writes each function's
lines and name into its descriptor (`H_POSITIONS`), and an interpreted
frame links the one it was called from (`Stacks.interpCur`) and keeps the
call it makes. A walk puts each interpreted frame in the place of the
`Interp.exec` running it, so `haxe.CallStack`
(`callStack`, `exceptionStack`) works in macro code, and the frames of
the compiler around it are named through its table of functions and
lines, which a Mir host always has (its own throws record no stack:
`hxmc_stack_flags` 0). While interpreted code runs, a throw that reaches
one of its frames is recorded; the interpreter's catches that pass an
exception on keep that record (`Stacks.rethrowing`). A function without
calls of its own may be inlined, as natively: its throw is at its caller's
line. The lines do not count in a function's size for the cold
path (`COLD_WORDS`: its `Fingerprint` without positions), so the same
functions are optimized as without them. `MirServerCheck` checks the reports (`EXPECTED`). `haxe.Exception`'s
`stack` stays empty in macro code: it would record a stack for each of the
compiler's own exceptions while a macro runs.

The std and the runtime in the macro context: hxmc's std loads all of the
runtime (`Std` imports `hxmc.rt.Runtime`), and a macro reaches few of the
functions of the std's files the macro context loads, so their bodies are
parsed and typed when they are asked for (`interp.MacroRuntime`). A file
of the std (hxmc's, Haxe's: not the program's, whose errors stay where
they are) is parsed without its methods' block bodies (but constructors',
macros', dynamic, extern, abstract, overloaded and generic methods' and
those of abstracts): the lexer passes over the source up to the body's
closing brace (`Lexer.skipBlock`: its strings, comments and regular
expressions, its lines recorded as the rules would; the stream's tokens
when the body has a preprocessor directive), and an empty block at the
body's position stands for it (`ParserEntry.SkippedBodies`), parsed from
the source when the body is typed (positions as a parse of the whole file
gives them). A method of the std whose callers need only its signature
(its type written in full; not a macro, generic, overloaded, a coroutine,
a constructor or an `__init__`, nor of an interface or an extern class)
is not typed with its module (`TypeBinding.lazyBodyHook`): its `cf_expr`
is a function of its typed arguments whose body throws, an inline one's
type stays lazy (an inlined call forces it), and the typing waits in
`TypeBinding.lazyBodies`. Lowering defers such a body, and that of a class
not handed over yet (`Lower.bodyReady`); `MirMacros` has the deferred
bodies typed (`MacroRuntime.typeBodies`: the macro context finalized and
flushed, as for a macro's module, then the expression filters on the
bodies of the classes handed over before:
`MacroContext.lateFieldFilters`), then lowers them. The static
initializers' sort (`Finalization.sortTypes`) types the bodies it walks;
before a context's modules are encoded (the server's
`CommonCache.cacheContext`, the module cache) its bodies are typed
(`TypeBinding.typeLazyBodies`), so an encoded module has them all. A cold
trivial macro types 834 bodies in the macro context, the formatter's
build 926 (1,460-1,490 before; Eval 677 and 711).

A static function of the runtime the compiler has, whose declared
signature is all its callers need (no optional argument; its result's
type written, or no value returned: Void, from whether the source passed
over has a `return` of a value) and that the Mir inliner does not copy
into callers (its fingerprint's flags), is never typed: its body is one
that throws, marked `@:hxmc.hostCode` (`TypeBinding.untypedBodyHook`);
`Lower` makes it a function without body whose facts (no GC point, safe
region) are those of the compiler's code (`Lower.hostCode`), and its body
is never parsed either. `HXMC_MIR_TYPE_RUNTIME=1` types those too;
`HXMC_MIR_LAZY_BODIES=0` parses and types every body with its module.

A function is compiled for the interpreter the first time it is called. A
bundle has a stub of each function it reaches (`InterpGen.stub`: a
descriptor of the function's symbol, its parameters, flags and
parameters' sources from its signature, whose code is `LAZY k`), but for
the static initializers, which its load runs, and the functions whose
calls are no GC point (their callers keep references in registers across
them, which a collection while compiling would leave pointing at what it
moved); most functions a bundle reaches never run (the formatter's
macros: 65 of 212). A descriptor's header holds its parts as 64-bit
offsets from it, so a stub's header can be made its function's: on
`LAZY`, the interpreter calls the compiler back (`Interp.lazyHook`:
`MirMacros.compileLazy`, the call's arguments rooted meanwhile), which
compiles the function as its bundle would have, with its generation's
latest step (each step's `Prep` numbers the program's types again, in
the IR's objects), loads it alone (`Loader.loadLate`: linked against its
generation's bundles, a selector's latest dispatch row) and makes the
stub's header the function's (`Interp.become`); the frame then runs it,
and whatever holds the stub (a call's symbol table, a pool entry, a
static initializer's list) calls the function from then on, with no check
on the interpreter's call path. Macro code's threads take a lock there.
A trivial macro compiles 25 functions instead of 82 (one runs), the json
benchmark 71 instead of 143 (13 run), the formatter's build 105 instead of
212 (65 run): its bundles' bytes 2.8 MB to 0.4 MB, and 1.0 MB compiled
later. `HXMC_MIR_LAZY=0`: every function compiled with its bundle.

Checked with upstream's unit suite: `UpstreamTargets` with the native
compiler as the port (`HAXE_IN_HAXE_PORT="bin/npm/native/<host>/haxe -D
hxmc.macros=mir"`) compiles every target; the suite run (node, python3,
neko) fails one test, the static `Int` below. The differences from Eval:

- Maps iterate in hxmc's order (insertion), Eval's `StringMap` in its keys'
  descending order (an OCaml map), so what a macro generates by iterating a
  map comes in another order (utest's tests run in their declaration
  order); `Map.toString` separates entries with `, ` (Eval: `,`).
- Variable ids: the macro context types hxmc's std and takes other ids
  from the counter the program's typing shares (its bodies typed when
  they are asked for, so when a macro needs them), so names made of ids
  differ (coroutines' `_hx_hoisted<id>`, their stack items, genpy's order
  by them).
- An uninitialised static `Int` reads 0 (Eval: null, Issue11096);
  `String.length` counts UTF-16 units (Eval: code points).
- Not available: `Context.getMacroStack`, macro arguments that are
  functions, Eval's packages (`eval.*`, `mbedtls`); `Sys` in macros is
  hxmc's.
- A generation takes again the spare type entries (`MirHost.SPARE_TYPES`,
  2048), signatures and global slots of the earlier ones' whose facts are
  the same (`macro.Loader`: enums with their constructors, structures,
  closures' types, interfaces, the classes when all of a bundle's are);
  the others take new ones (a trivial macro's edit under a server: none,
  254 types and 94 globals each without that). Bundles are never
  unloaded: each generation's descriptors and data stay in memory (a
  trivial macro's: 21 KB), and so do the pool entries they were given.

Compiled functions are kept across builds (`interp.BundleCache`), in the
module cache's store (`<cache>/modules/<tool>/o/<key>-mir.o`, per build of
the compiler, with the store's limits and trim; the list of a command
line's objects is what the trim keeps): each function a bundle compiles is
an object of its own, under the key of its `Fingerprint` (its lowered IR,
what `MirBuild` reads of the rest of the program, the digests of the
callees the Mir inliner may copy into it) with the compiler's target and
options; what its descriptor depends on besides (which of its calls by
symbol are of interpreted functions) is kept with it and checked before it
is used, and a function using a thread-local variable emulated with an
index of the process's is not kept. A function is looked for when it is
compiled (with its bundle, or when first called: its object then is all
that is loaded, a kept object's string literals named in the latest
step's `Prep`); a bundle names every function's object in its list, so
the trim keeps those a build did not call. The ids of the call sites the lowering writes
into the IR (`Lower.callSites`) are hashes of their positions, so a
function's IR and key do not depend on what was lowered before it. Off with
the module cache (`HXMC_MODULE_CACHE=0`, `-D hxmc.no-module-cache`);
`HXMC_MIR_CACHE=0` turns it off alone, `HXMC_MIR_CACHE=1` on without the
module cache; `HXMC_MACRO_STATS=1` reports the functions found and compiled.
`make mir-cache-check` (`hxmc/test/MirCacheCheck.hx`, in the Mir lane):
every build prints what Eval's macros make it print, a warm build finds
every function, and an edit of a dependency, of a function the inliner
copies, a define and another build of the compiler compile again what they
change; objects that are not theirs (truncated, under another key) are not
used; a method its class brings into a first macro's bundle and that a
later macro first calls is found, its literals with it.

A function whose IR is larger than 8,000 words (its `Fingerprint`'s; the
giant functions macros that write code are made of, json2object's
`DataBuilder`: 9,000 to 73,000) is compiled without the optimizer
(`HXMC_MIR_COLD=<words>`, 0: every function optimized): it costs those most
of their compilation and gains them nothing measurable, as they run a few
times each; compute-bound macros' functions are far smaller (json's and
mandelbrot's: under 3,000 words).

### The native tier

On linux-x86_64, a function of code loaded at run time (Mir macros, `--run`
on Mir) that is called often is compiled to native code (`interp.Tier`):
the interpreter counts each descriptor's calls (a word of its header), and
every `HXMC_MIR_TIER` calls (a power of two, 1024 by default; 0: never) it
gives the function's number (in its flags' upper bits, from `Tier.add`)
and arguments to `Interp.tierHook`. The function is compiled as the
program's own code is (the optimizer on unless it is off for the
interpreter's compilation, Escape too: `InterpSet.nativeNow` makes it
native for that compilation), with its literals, empty arrays and
data bound to its generation's (with the tier, the Loader keeps every data
symbol of a bundle, so the native code has the same objects) and its
allocation stubs (`DataGen.allocStubs`), then loaded
(`Loader.loadNative`): its code right after the code loaded before it
(chunks of 256 KB; the pages it is written to are made writable for that,
executable again once it is relocated), its data beside the bundles'. Its descriptor is then made a
forwarder's (`Interp.become`): an interpreted function of its signature
whose one call is a call-out to the native code. Whatever holds the
descriptor (a call's symbol table, a pool entry, a static initializer's
list) reaches the native code through it from then on; frames running the
interpreted code finish on it. The native code calls interpreted
functions through their pool entries, as the compiler's code does, and the
compiler's functions and thread-local variables directly (the host table
keeps each thread-local variable's offset from the thread pointer on
linux-x86_64, made at the link as a local-exec relocation).

Native code there reaches the compiler's image, the bundles' memory and
itself with 32-bit displacements, as code linked with it would: with the
tier on, every bundle's memory is in a window below 2 GB above the image
(`Loader.alloc`, 0x40000000 to 0x7fff0000; the image is static from 4 MB),
and so is native code, whose null accesses throw as the image's do
(`Faults.addCode`). Nothing there is unmapped, as nothing is unloaded
(nor is it without the tier: bundles' memory is never freed). Once the
window is full, bundles take malloc's memory and the tier stops
(`Loader.full`: nothing is counted or compiled any more); the code loaded
before reaches only what was loaded before it. `HXMC_MIR_TIER_WINDOW=<KB>`
makes the window that small, to test it.

Stacks are the same whichever runs: an uncaught exception's report in a
macro and `haxe.CallStack` in macro code or `--run` name the same frames at
the same lines. The interpreter's frames are named through their
descriptors' lines (`InterpGen`, `Stacks.describeInterp`); native code
loaded at run time is not in the compiler's table of functions and lines,
so `Loader.loadNative` gives `hxmc.rt.Stacks` each of its functions' range,
Haxe name and lines (`Stacks.addMade`, from the records the program's table
is written from, `FuncRec.lines`). A walk goes through those frames as
through the image's, names them as it would the interpreted frames they
replace, and leaves out a forwarder's frame, which has no lines. The
uncaught-exception report keeps the frames of code loaded at run time,
interpreted or not (`Stacks.loaded`). The tier compiles a function with the
optimizer setting its interpreted code had, so the same calls are inlined,
and does not inline the closures a function calls where it makes them
(`Driver`: the interpreter keeps their frames). `make mir-server-check` runs
its uncaught exceptions and a `CallStack` on a server with
`HXMC_MIR_TIER=native` too, against the interpreter's output.

Compiling collects. The hook pushes the function's reference arguments on
the thread's shadow stack before anything is allocated (`Tier.root`,
inline: above the caller's frame, popped with it): what it reads from the
interpreter's registers is no root, and an allocation before it is rooted
may move the object, leaving a stale copy to be copied again
(`MirMacros.compileLazy` roots them the same way; a static array of roots
would be shared by threads calling stubs at once). It compiles only at a GC point: a function whose
calls are none (its callers keep references in registers across it,
`f.noGc && !f.blocks`) is noted without allocating and compiled when a
function that is one is counted. A stub (a function not compiled for the
interpreter yet) is compiled for the interpreter first, so the BundleCache
keeps its object. Nothing is compiled once a second thread has run
interpreted code (`Interp.threads`): another thread's caller reads a
descriptor's header in parts, which `become` rewrites. A function the tier
cannot compile or load (a symbol the compiler lacks, an emulated
thread-local variable, the pools' entries nearly given out: an eighth of
each is kept) stays interpreted. `HXMC_MIR_TIER_LOG=1` (or
`HXMC_MACRO_STATS=1`) names each function compiled and why one stays
interpreted; `HXMC_MIR_TIER_MAX=<n>` compiles at most n, to bisect.
`HXMC_MIR_TIER=native` skips the interpreter where it can: a function is
compiled to native code at its first call (its stub's, `Tier.compileStub`;
the interpreter's code only when that fails, or once a second thread runs
interpreted code; `--run` on Mir then has stubs too), and the functions
whose calls are no GC point, which have no stub, once their bundle is
loaded (`Tier.loaded`: the loader is a GC point); a function the
optimizer is off for (`HXMC_MIR_COLD`) is compiled so natively too. What
remains interpreted is each forwarder's one call-out, the static
initializers (run as their bundle loads) and what the tier cannot
compile. Functions compiled late share the data they define with their
generation (`Loader.share`: an empty array is one object). It pays where
hot code runs in a few long calls (mandelbrot as a macro, nbody), which
the counting tier leaves interpreted until OSR, and costs where much code
runs once (every function called is compiled, optimized).
`HXMC_MIR_TIER=1` compiles every function at its second call, a stress
test: `make mir-run-check` passes so with `RT_VERIFY=1` and nurseries of 16
to 64 KB, but for FrameChain, whose chain then passes through the
interpreter's frames between native ones; `mir-macros-check` and
`mir-cache-check` pass so too.

Measured (Intel Xeon E-2356G, 6 cores / 12 threads, Linux 6.1, the median
of five, tier off / on): json as a macro 2.18 / 0.72 s (Eval 5.3 s; five
functions compiled in 3 ms), `--run` sha256 1.7 / 0.32 s, binarytrees 5.7
/ 3.4 s; the formatter's build (two functions compiled, 1 ms), the trivial
macro and the server's edit unchanged. A loop in one call (mandelbrot,
nbody) is not helped: that needs entering native code in the middle of a
frame (plans/compiler.md, "Mir macros").

Cost (MirBench, wall time, the median of five, Intel Xeon @ 2.10 GHz,
4 vCPUs, module cache off): a trivial macro (`macro 1` called from main,
`--js`) 0.20 s (Eval 0.16 s; 0.28 s while every function reached was
compiled and the std's bodies typed with their modules); the formatter
benchmark built with json2object's macros 0.74 s (Eval 0.61 s; was 0.89
s), compiling the functions json2object's `DataBuilder` is made of (six of
10,000 to 38,000 Mir values, each run once or twice) most of the
difference. With the module cache, which keeps the macro context typed, an
edit of the main module: the trivial macro 0.13 s (Eval 0.07 s), the
formatter 0.19 s (Eval 0.17 s); plans/compiler.md, "Mir macros".

## Targets

| Target | How |
| --- | --- |
| Linux | static ELF with musl's members. With `-D hxmc.libc=glibc` (`LinkDyn.hx`): dynamically linked, `PT_INTERP`, `DT_NEEDED`, imports with glibc 2.17's symbol versions bound at load time, a generated `_start` calling `__libc_start_main`, its own runtime objects (`<target>-glibc`) |
| Windows | PE over the UCRT, imports written directly from the import libraries |
| macOS | Mach-O against libSystem, ad hoc signed (`CodeSign.hx`) |
| Android | a shared library against Bionic in an APK hxmc writes ([below](#android)) |
| iOS | macOS's Mach-O and runtime objects with the iOS platform ([below](#ios)) |
| wasm32-wasi | the whole runtime in Haxe; exceptions with `exnref` or, with `-D hxmc.wasm-eh=legacy`, `try`/`catch_all`/`rethrow` |

mbedtls 2.28 and libuv 1.48 (`hxmc/deps/deps.sh`) become `ssl.o` and
`uv.o`, linked only into programs that use `sys.ssl` or `eval.luv`.
`LinkCore.hx` is shared by the native linkers: resolution, dead sections,
GOT and import slots, placement and relocations.

### Target flags

A custom target starts from upstream's default platform configuration,
which defines `static`, `sys`, `utf16`, `target.unicode` and their
`target.*` forms, and `target.name` = `hxmc`. `TargetFlags.hx` adds
`target.threaded` on the native targets and `target.atomics` everywhere,
once the target is initialized and before init macros run. They are
defines only. wasm32-wasi is not `target.threaded`: creating a thread
throws there (`rt/wasm/Threads.hx`). On WasmGC a created thread runs when
another waits for it (`GcThreads`).

### Android

Android 10 (API 29) and later, the first Bionic with ELF thread-locals.

**The library** (`LinkDyn.hx`, shared with `-D hxmc.shared` in the glibc
mode): ET_DYN at address 0. The code is PC-relative already, so data
addresses become `R_*_RELATIVE` relocations and imports become GOT slots
bound at load (`BIND_NOW`). Thread-locals go through a linker-written
`hxmc_tls_base` stub: TLSDESC on arm64, `__tls_get_addr` on x86-64
(Bionic has no TLSDESC there). 16 KB segments (Android 15's pages).
`DT_HASH`, `DT_SONAME`, only the exports visible, section headers (Bionic's
linker reads `.dynamic` through them).

**Bionic**: the runtime's C calls are imports of `libc.so`, `libm.so` and
`libdl.so` with Bionic's symbol versions. The runtime objects hold the
table of what those export to API 29 apps, made by `mkrt.sh` from Bionic's
version scripts. `deps.sh` fetches Bionic's headers at a pinned AOSP commit
for mbedtls, libuv and `Layouts.hx`. `Mem.target()` 9 and 10 are Android;
`Mem.os()` is Linux's. Other libraries (`libandroid.so`, `liblog.so`,
`libEGL.so`) are imported unversioned.

**The app**: the program exports `ANativeActivity_onCreate` in no-GC Haxe
(it runs on the UI thread, which the runtime does not know); it starts the
program's thread, where the runtime starts.

**The APK** (`android/Apk.hx`): a binary-XML manifest (`Axml.hx`), the
library stored and aligned to 16 KB, then an APK Signature Scheme v2 block,
ECDSA P-256 in plain Haxe (`P256.hx`, RFC 6979 nonces, so signing is
deterministic) with a debug key kept in the cache. A program that uses the
Java glue gets a `classes.dex` (`Dex.hx`: a minimal DEX writer; `Glue.hx`:
`org.hxmc.Glue`, one listener class whose methods call a registered
native, and `org.hxmc.Activity`, a `NativeActivity` whose window draws
views).

### iOS

`ios-arm64` and `ios-sim-arm64` share macOS arm64's libSystem, layouts and
runtime objects (`Mem.os()` 1, `Mem.target()` 3; `Mem.platform()` 1 or 2
tells iOS from the simulator). The Mach-O carries the platform in
`LC_BUILD_VERSION` (minimum 15.0, SDK 18.0). iOS 15 is the floor because
`UILaunchScreen` is iOS 14's and current Xcodes start at 15.

**The bundle** (`ios/Bundle.hx`): the executable, an XML `Info.plist`
(`Plist.hx`), and `_CodeSignature/CodeResources`. The linker writes the ad
hoc signature (`CodeSign.hx`), identified by the bundle id, whose special
slots bind the `Info.plist`, an empty requirement set, `CodeResources` and
the entitlements, as `codesign -s -` does. An `.ipa` is the bundle under
`Payload/`.

**The app**: a program that defines `hxmc_ui_main` (`DataGen.UI_MAIN`) has
the generated `main` run that on the big main stack instead of the body,
and runs the body once the app has launched.

Device signing goes into `CodeSign.Identity`:
[plans/targets.md](plans/targets.md#ios).

### WebAssembly

The playground runs the port as a wasm32-wasi module, and `make crosshost` checks that the tool built as one writes the same bytes as the native tool.

#### Memory

Linear memory only grows, and browsers refuse it early, so the runtime
(`rt/wasm/Heap.hx`, `Gc.hx`) takes only what it uses:

- The nursery's region is the nursery's size (4 MB, sized like the native
  one, up to 32 MB), grown in place or moved after a minor collection.
- The old space is 1 MB chunks taken as objects are promoted; `RT_OLD_MB`
  (32) is when the first major collection comes, not a reservation.
- The shadow stack is `RT_STACK_MB` (4 MB; `wasi.mjs` sets it from node's
  `--stack-size`). The first time a frame goes deeper than since the last
  collection, it is checked against the end; an overflow exits with a
  message.
- The frame stack (`Mem.stack`, below `__stack_pointer`) is a region of the
  same size, checked in every prologue.
- Memory grows by an eighth of its size at a time when that is enough,
  because node collects its own heap after each `memory.grow`.
- Only memory handed out before and freed is zeroed: fresh memory from
  `memory.grow` is zero already.

When `memory.grow` fails the runtime prints "out of memory: linear memory
is N MB, growing it by M MB failed" and exits.

#### WasmGC

With `-D hxmc.wasm-gc` the program becomes a WasmGC module
(`hxmc/src/hxmc/wasmgc/`): values live in the engine's collector, with no
shadow stack or barriers. Each function goes through the native
pipeline's object level: `MirBuild.gc` (no roots; fields by index; what is
memory-level natively stays the IR's own as `IrNode` operations; a `try`
is a `Try` terminator and `Catch`), `Inline`, `Inline.devirtualize`,
`Escape` and `Opt`. Then `MirGen` writes structured control flow, each
value a local of its wasm type, using `FuncGen` for the IR's expressions.
Reachability runs twice: before building the Mir and over what the Mir
still calls (`Uses.summary`).

- **Types**: one recursion group, so the class hierarchy is wasm subtyping
  (`ref.test`; leaf classes final). A reference has the wasm type its IR
  type proves (`GcModule.keyOf`), else `eqref` cast where used.
- **Calls**: methods have typed signatures; virtual and interface calls go
  through a funcref table by class and selector; closures are structs
  whose first field is a typed function reference.
- **Runtime**: `Str`, `Arr`, `Bytes`, `Date` over `GcRepr`; the rest in
  `hxmc/std/hxmc/rt/gc` (Dynamic, reflection over `Meta`'s tables, the
  system over the host). Math's transcendental functions and float
  formatting are the host's (`hxmc/bootstrap/wasmgc.mjs` under node).
- **System** (`GcSys`): files, directories, the shell, processes (run by a
  worker of the host), no sockets, no `Sys.getChar`.
- **Threads**: one. A created thread runs to its end when a running one
  waits on something nothing else would end, so fork-join works.
- **Hybrid module**: a program that uses `hxmc.unsafe` or C functions also
  gets a small linear memory (`GcModule.memory`) for `Mem`, `Ptr`, frame
  areas, malloc and the imports, exported as `memory`. A Bytes crosses to C
  through `BytesPtr`, which copies. A `@:hxmc.struct` class with only final
  fields is an object here.

A runtime function not covered yet fails the build with its name;
`HXMC_GC_SURVEY=1` lists every such construct (`=2` also writes the module,
those functions trapping). The port builds as WasmGC and passes the
conformance lanes ([testing.md](testing.md#the-port-as-a-wasmgc-module)).
Why it is not the browser default yet:
[plans/targets.md](plans/targets.md#wasmgc).

## Debugging

**Frame pointers.** Every function keeps a frame record (x86-64: `push
rbp; mov rbp, rsp`, rbp out of register allocation; arm64: x29/x30, always),
so `perf record -g`, debuggers and `Mem.frame()` walk the stack.
`-D hxmc.no-frame-pointers` (or `HXMC_FRAME_POINTERS=0`) drops them on
x86-64.

**Unwind tables** are always written (`Unwind.hx`), from the frame records
the emitters keep (`Obj.FuncRec`): ELF `.eh_frame` with `.eh_frame_hdr`,
Mach-O `__eh_frame` (no `__unwind_info`), Windows `.pdata`/`.xdata` for
x86-64 and arm64. A function's frame is the same at every instruction of
its body: outgoing arguments are part of it and nothing allocates on the
stack dynamically. `hxmc_call_on_stack`, the main thread's stack switch,
runs on its frame pointer, which unwinders follow back.

**Source lines** flow from the typed AST: `SPos` statements
(`FnLower.stmt`), `MIns.pos` (an inlined copy takes its call's position),
`LIns.pos`, and a row per change in `FuncRec.lines`. Native builds always
record them (call stacks need them); no pass looks at them, so the code is
the same with or without. With `-debug` (or `-D hxmc.lines`) the linkers
write DWARF 4 (`Dwarf.hx`): `.debug_line`, `.debug_info` with a unit per
module and a subprogram per function named `pack.Class.field`,
`.debug_aranges`. In PE files this is MinGW's layout with a COFF symbol
table. `-debug` also writes the symbol table.

**Checks**: the corpus case `UnwindTables` compares the system's unwinders
with the frame-pointer chain. `hxmc/test/DebugCheck.hx` builds
`hxmc/test/debug/Lines.hx` with `-debug`, sets a breakpoint with gdb (or
lldb) and checks the backtrace's Haxe names and lines, then checks every
target's tables with readelf, llvm-readobj and llvm-dwarfdump.

### Call stacks

`haxe.CallStack.callStack()`, an exception's `stack`,
`exceptionStack()` and the report of an uncaught exception all go through
`hxmc.rt.Stacks`.

- **The table**: the linker writes the program's functions, their Haxe
  names and line rows at `hxmc_stacks` (`StackTable.hx`, from the same
  `FuncRec.lines` as `.debug_line`): 16 bytes per function, line rows as
  LEB128 deltas, each string once.
- **The walk** follows frame records while the return address is in a
  function of the table (a small cache, then binary search), so it stops at
  the first C frame. At most 256 frames. Frames without lines and the
  runtime's own are hidden.
- **Cost**: a program gets the table only when `haxe.NativeStackTrace`'s
  `toHaxe` or `toHaxeSkipping` is live after `Reach`. Functions marked
  `@:hxmc.withStacks` are live only then. `hxmc_stack_flags` says what the
  program reads, so one that reads neither walks no stack. A throw records
  only the frames up to the catching try.
- **Mir hosts** (the compiler, the tool) always have the table; their own
  throws record no stack. Interpreted frames have no code of their own:
  the interpreter links them (`Stacks.interpCur`) and a walk puts each in
  the place of its `Interp.exec`.
- **Exceptions**: `haxe.Exception` records its stack where it is made, or
  for a caught value where it was thrown; `stack` leaves out the
  exception's constructors.

Upstream's `TestExceptions.testExceptionStack` and `TestCallStack` pass
natively; `CallStacks` checks against the reference on Linux, Windows
(Wine) and arm64. Not done: WebAssembly (a module cannot read its own
stack), inlined frames, stacks without frame pointers, and the null-access
report's innermost line, which may be the statement before.

## Environment variables

For the tool and the compiler (build time):

| Variable | |
| --- | --- |
| `HXMC_STATS=1` | what the build did and how long it took; live functions |
| `HXMC_OPT=0` | no Mir optimizations |
| `HXMC_INLINE=<flat>,<loop>,<runtime>` | inlining limits |
| `HXMC_ESCAPE=0`, `HXMC_ESCAPE_LOG=1`, `HXMC_ESCAPE_NO=<...>`, `HXMC_ESCAPE_HASH=<lo>-<hi>` | escape analysis off, logged, or bisected (not in the object cache's key) |
| `HXMC_FOLD=0`, `HXMC_FOLD_WHY=1` | allocation folding off, or why an allocation did not fold |
| `HXMC_REACH=0`, `HXMC_REACH_WHY=<fn>` | keep everything; why a function is kept |
| `HXMC_SYMBOLS=1` | a symbol table |
| `HXMC_SIZE_STATS=1` | sizes by part |
| `HXMC_DUMP=<functions>` | print machine code |
| `HXMC_MAP=<file>` | Windows: a link map |
| `HXMC_FRAME_POINTERS=0` | no frame pointers on x86-64 |
| `HXMC_JOBS=<n>` | parallel module compilations |
| `HXMC_RT_DIR`, `HXMC_RT_OBJ` | where the runtime objects are: a list of directories (the npm launcher passes the installed platform packages first), or one object |
| `HXMC_MODULE_CACHE=0`, `HXMC_MODULE_CACHE_LOG=1`, `HXMC_CACHE`, `HXMC_CACHE_SIZE` | the module cache ([using.md](using.md#fast-rebuilds)) |
| `HXMC_GC_SURVEY=1` | WasmGC: list unsupported constructs |
| `HXMC_MACRO_STATS=1`, `HXMC_MIR_*` | Mir macros ([above](#macros-on-the-mir-interpreter)) |

For compiled programs (run time):

| Variable | |
| --- | --- |
| `RT_MINOR_KB` | a fixed nursery size (16 KB at least) |
| `RT_TLAB_KB` | the largest TLAB (64 KB) |
| `RT_OLD_MB`, `RT_OLD_GROWTH` | the old space's first limit, and its growth in percent of what is live |
| `RT_PREFAULT=0` | no prefault helper |
| `RT_STATS=1` | the collector's resizes and promotions |
| `RT_VERIFY=1` | fill the free nursery with a pattern; an allocation in a safe region is fatal |
| `RT_NULL_ACCESS=0` | no fault handler |
| `RT_STACK_MB` | wasm32: the shadow stack's and frame stack's size |
| `RT_REGION_MB` | Windows: the old space's regions (2 GB by default) |
| `RT_CENSUS=1\|2` | with `-D hxmc.census`: the live heap by type at exit (2: after every major collection too), and allocations by type (`RT_CENSUS_TOP`: rows shown) |
| `RT_CENSUS_WHY=<type>` | also a path from a global to the first `RT_CENSUS_WHY_MAX` (8) objects of that type; global `i` is the symbol of value `8 * i` in `<exe>.syms` |
