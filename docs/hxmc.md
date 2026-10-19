# hxmc internals

## Pipeline

hxmc turns a typed Haxe program into a native executable with its own code
generator and linker: no C compiler, assembler or system linker at build time.

```
typed AST --(ir.Lower)--> hxmc IR --(ir.Reach)--> --(Prep: ir.Facts)--> --(MirBuild)--> Mir (SSA) --(Inline, Sroa, Opt)-->
    --(x64|a64 Isel)--> LIR --(Regalloc, Emit)--> Obj (per module, cached) | --(wasm/WasmGen)--> wasm
    --(DataGen: tables, strings)--> Obj --(Link: ELF | LinkPE | LinkMachO | LinkWasm)--> executable
```

| File (`hxmc/src/hxmc/`) | |
| --- | --- |
| `Main.hx`, `Options.hx`, `Driver.hx` | the tool: runs the port's compiler with a generate hook, compiles every module (in parallel, cached) and links; `--server` keeps the compilation server resident |
| `HaxeMain.hx` | `haxe` with hxmc built in (the npm package): `--custom-target hxmc=<out>` |
| `ir/Ir.hx`, `Lower.hx`, `FnLower.hx` | the IR (structured statements in A-normal form, explicit GC points) and the lowering of the filtered typed AST |
| `ir/Reach.hx` | the functions the program can run (Reachability, below): the others are not compiled |
| `ir/Facts.hx`, `Prep.hx` | the program-wide facts: names, layouts, type indices, field ids, no-GC functions, cold sites, GC points, as symbols |
| `UpToDate.hx`, `Fingerprint.hx`, `LowerCache.hx` | rebuilds: the whole build skipped when nothing changed, each module's object reused when its fingerprint is unchanged, lowered bodies reused by the server |
| `Mir.hx`, `MirBuild.hx`, `Opt.hx`, `Inline.hx`, `Sroa.hx` | the SSA IR, its construction, inlining, scalar replacement of frame slots (struct values), value numbering, store forwarding, LICM, dead code |
| `Lir.hx`, `Regalloc.hx`, `x64/`, `a64/` | instruction selection, linear-scan allocation, encoders (checked against llvm-mc: `EncCheck`), emission |
| `Unwind.hx`, `Dwarf.hx` | unwind tables from the emitters' frame records (`.eh_frame`, `.pdata`/`.xdata`, `__eh_frame`), `-debug`'s DWARF lines (Debugging, below) |
| `Obj.hx`, `ElfWriter.hx`, `*Reader.hx`, `Link*.hx`, `MkRt.hx`, `DataGen.hx` | objects, the linkers (static ELF, `LinkDyn.hx` dynamic ELF against glibc; PE with imports written directly; Mach-O with an ad-hoc signature), the runtime-object builder, the program's data |
| `wasm/` | wasm32-wasi: structured code from Mir, the linker, exception handling with `exnref` (or the legacy instructions) |
| `Target.hx`, `Abi.hx`, `CAbi.hx` | per-target facts; how each C ABI passes structs by value |
| `MkStd.hx` | hxmc's std merged with the Eval originals (the macro context shares the program's class paths; a custom target gets no `_std` directory in the reference compiler) |
| `macro/` | native macros, a prototype (`haxe` built with `-D hxmc.jit`, Linux x86-64; `-D hxmc.macros=native\|verify`): macro classes compiled by hxmc and linked into the running compiler, behind the macro engine seam `haxe/src/macros/MacroEngine.hx` ([plans/compiler.md](plans/compiler.md), "Native macros") |

Conventions: references live across a GC point are shadow-stack slots
(cold sites spill only on the slow path); `try` is `rt_handler` with the C
library's `_setjmp`; calls follow the target's C ABI; a `@:hxmc.struct`
value is the address of its memory (a frame slot, an object's inline
field, memory behind a `Ptr`), copied on assignment (also through Haxe's
inliner and analyzer: hooks set by `ir/CInterop.install`), its result written
where a hidden last argument says ([plans/lowlevel.md](plans/lowlevel.md),
"Struct values"); thread-locals use
local-exec TLS on Linux, `_tls_index` on Windows, the TLV template on macOS;
program-wide numbers (type indices, field ids, offsets) are absolute symbols
resolved by the linker, so a module's code does not change when the numbering
does.

## Debugging

Frame pointers: every function keeps a frame record (x86-64: `push rbp;
mov rbp, rsp`, rbp kept out of register allocation; arm64: the x29/x30 pair,
which Apple's ABI requires), so `perf record -g` (frame-pointer mode),
debuggers and `Mem.frame()` (the caller's record; the corpus case
`FrameChain` walks it) walk the stack; the chain runs through the
runtime's Haxe code and stops in the C library. On x86-64 they are the
default since 2026-10-17 (0.9% more code, no time measurable in the noise of
the self-compile, the tool's build of the port or the benchmarks); `-D
hxmc.no-frame-pointers` (or `HXMC_FRAME_POINTERS=0`, for builds whose
command line is fixed) leaves them out.

Unwind tables, always written (`hxmc/src/hxmc/Unwind.hx`): the emitters
(`x64/Emit.hx`, `a64/Emit.hx`) record what each prologue and epilogue does
to the frame (pushes, the frame pointer's setting, the allocation, saved
registers, and back), with the offsets where each instruction ends
(`Obj.FuncRec`, kept in the cached objects), and each linker writes them in
its format: ELF `.eh_frame` with its search table `.eh_frame_hdr`
(`PT_GNU_EH_FRAME`; with the entries of the runtime object's live C code),
Mach-O `__eh_frame` (no `__unwind_info`: the system's unwinder and lldb read
the DWARF), Windows `.pdata` with `.xdata` (x86-64 `UNWIND_INFO`, the
epilogues recognized by the unwinder; arm64 unwind codes with an epilogue
scope per epilogue; identical ones shared; sorted with the runtime
object's). A function's frame is the same at every instruction of its body:
outgoing stack arguments are part of the frame (no adjustment around calls),
nothing allocates on the stack dynamically, and `hxmc_call_on_stack`, the
stack switch of the main thread, runs on its frame pointer, which unwinders
follow back to the old stack. On arm64 the callee-saved registers are stored
right above the outgoing arguments, where Windows' unwind codes reach them
(at most 504 bytes above sp; beyond that the outgoing arguments are
allocated after the stores). DWARF unwinding (gdb and lldb backtraces
without heuristics, `perf --call-graph dwarf`, C++-style unwinders such as
glibc's `backtrace()`) and Windows' (`RtlVirtualUnwind`, debuggers, crash
dumps, SEH walking through generated frames) need them. They cost, for the
tool itself (24,400 functions): ELF 1.0 MB (5.7% of 17.5 MB; 6.0% on arm64),
Mach-O 0.98 MB (5.1%), Windows 12 (x86-64) or 8 (arm64) bytes per function
in `.pdata` (1.2%) and the shared `.xdata`.

Source lines (`-debug`, or `-D hxmc.lines` alone): positions flow from the
typed AST to the emitted code: the lowering puts a `SPos` statement (file,
line) before each statement's code (`FnLower.stmt`), `MirBuild` gives the
instructions it builds the current one (`MIns.pos`, `SrcPos`; the inliner
copies them, so inlined code has its own file and lines), instruction
selection passes it to the target instructions (`LIns.pos`), and the
emitters record a row where it changes (`FuncRec.lines`, mapped through
branch relaxation). The linkers write DWARF 4 (`hxmc/src/hxmc/Dwarf.hx`):
`.debug_line`, `.debug_info` with a compilation unit per module and a
subprogram per function named by its Haxe name (`pack.Class.field`), and
`.debug_aranges`/`.debug_ranges`; in ELF files, in Mach-O files' `__DWARF`
segment, and in PE files as MinGW's toolchain writes them (with a COFF
symbol table: gdb, lldb and llvm-symbolizer read them; no PDB, so not the
Visual Studio debugger or WinDbg: [plans/codegen.md](plans/codegen.md)). Every pass steps over the
positions, so the code is the same with and without them (DebugCheck
compares the code of both builds); they add 2.7 MB (15.6%) to the tool.
`-debug` also writes the symbol table (`-D hxmc.symbols` or
`HXMC_SYMBOLS=1` alone).

Checks: the corpus case `UnwindTables` compares the system's own unwinders
with the frame-pointer chain from a recursion, a closure the runtime's sort
calls back and after a caught exception (glibc's `backtrace()` in the glibc
mode, `RtlCaptureStackBackTrace` on Windows and under Wine, libunwind's
`_Unwind_Backtrace` on macOS); `hxmc/test/DebugCheck.hx` (in `make check`
and CI's test jobs) builds `hxmc/test/debug/Lines.hx` with `-debug` and runs
gdb in batch mode (lldb without gdb; lldb on macOS): a breakpoint at a Haxe
line, then a backtrace that must name the Haxe functions with the lines of
their calls, as in

```
Breakpoint 1, Lines.inner () at hxmc/test/debug/Lines.hx:10
10			seen.push(depth); // break here
#0  Lines.inner () at hxmc/test/debug/Lines.hx:10
#1  0x0000000000408550 in Lines.inner () at hxmc/test/debug/Lines.hx:9
#2  0x0000000000408550 in Lines.inner () at hxmc/test/debug/Lines.hx:9
#3  0x000000000040859c in F_Lines_inner__sclos ()
#4  0x0000000000408467 in Lines.outer () at hxmc/test/debug/Lines.hx:20
#5  0x0000000000408295 in Lines.main () at hxmc/test/debug/Lines.hx:29
#6  0x0000000000408141 in hx_main_body ()
#7  0x0000000000408241 in hxmc_call_on_stack ()
#8  0x000000000040df06 in hxmc.rt.Start.runMain () at .../hxmc/rt/Start.hx:92
#9  0x000000000040817a in main ()
```

and checks every target's tables with readelf, llvm-readobj and
llvm-dwarfdump.

## Runtime in Haxe

Runtime in Haxe: most of the runtime is Haxe compiled with the program
(`hxmc/std/hxmc/rt`: strings, Dynamic access, reflection, arrays, bytes,
dates, inflate, the POSIX and Windows system layers, and Math: musl's libm
ported, `LibM.hx`, with the same results on every target), written with a
small internal API (`hxmc.unsafe`: `Ptr`, `Mem` loads, stores, allocation
and symbols, `Atomic`; `@:hxmc.c` and `@:hxmc.rt` externs of C functions,
`@:hxmc.noGc` functions, `@:hxmc.export`/`@:hxmc.host` implementations of
runtime functions, `@:hxmc.callback` functions C calls,
`@:hxmc.threadLocal` statics; the compiler rejects an address from `Mem.addr`
live across a GC point outside `@:hxmc.noGc` code, `Facts.checkRawAddresses`). The collector, threads and the stop-the-world
handshake, startup and `rt_throw` are Haxe too (`Gc.hx`, `Threads.hx`,
`Start.hx`; the heap census with `-D hxmc.census`): no C of hxmc's own is
linked, only the C library, mbedtls and libuv ([plans/lowlevel.md](plans/lowlevel.md),
"The runtime without C of our own"). The nursery's size adapts (unless
`RT_MINOR_KB` fixes it; Gc.hx): it starts at 4 MB, doubles after a minor
collection that promoted more than a 16th of what was allocated since the
previous one and halves after 8 that promoted less than a 64th, between a
floor of 4 MB per thread that allocated in the last cycles (at most 32 MB)
and a ceiling of 16 MB per such thread (at most 256 MB). Programs whose
objects die young keep a nursery that stays in the caches; the port typing
or compiling macro-heavy code grows it to 16 MB, which keeps medium-lived
objects out of the old space (6-17% faster, up to 31% less peak memory);
parallel phases get a larger one, so their threads stop for fewer
collections and promote less of what they are working on (the tool's
parallel code generation: 256 MB). Threads take at most 64 KB of it at a time
(their TLAB, zeroed while it fits in the cache; `RT_TLAB_KB`), in fresh
pages up to a 2 MB boundary, so that no two threads fault in the same
transparent huge page. With `-D hxmc.gc-prefault` (the compilers' builds
pass it: `COMPILER_ARGS`), on Linux, once the old space passes 64 MB, a
helper thread faults in its pages ahead of the minor collections, which
would otherwise wait for the kernel to zero each fresh page they copy into
(`RT_PREFAULT=0`: no helper). It trades CPU time for wall time: the
HaxeBenchmarks' alloc takes 7.6% less wall time and 20% more CPU time with it. `RT_STATS=1` prints the resizes and what was promoted. A change of the runtime's
interface or of the IR's conventions needs a tool that knows it: build once
against the previous runtime first, or bootstrap again.

## Reachability

Haxe's default DCE (`-dce std`) keeps every field of a user class, and the
lowering makes every method of each class it sees (method tables reach them
by name: structural and Dynamic access, `Reflect`). `hxmc/src/hxmc/ir/Reach.hx`
then keeps what the program can run, a rapid type analysis over the IR before
anything is compiled: from `main`, the exported functions and `@:keep` methods,
a function is live when live code calls it or makes a closure of it, a static
initializer when live code uses a static it sets (as the lowering already
initializes only the classes whose statics it meets), and a method when live
code instantiates its class or a subclass and either dispatches on its
selector or can look its name up. Names looked up: those of structural and
Dynamic access (a structural read only where the field's type is a
function's or Dynamic: a method unifies with no other), literals passed to
the runtime's lookups or to functions
passing them on (`Reflect.field(o, "x")`, `Reflect.getProperty`'s
`"get_" + field`), and names from the runtime's own tables (`Reflect.fields`,
`Type.getInstanceFields`), which name only what the tables keep; a name
computed any other way keeps every method of the instantiated classes.
Dropped: the functions, their entries in the method tables (so
`Type.getInstanceFields` lists the methods kept, as with `-dce full`), the
dispatch rows of selectors no live code calls, the types of dead closures.
The dispatch rows themselves (DataGen: a row per selector, indexed by type)
are laid over each other, as a call reads only the entries of the classes
implementing the selector. Closures share a type when their signatures and
captures' representations are the same (the code is in the object), only
the signatures of methods in the tables have a bound-method type and
trampoline, only closures' signatures a dynamic-call one, and a closure
capturing nothing is an object in the data, made once (Prep.staticClosures),
not allocated where it is used. The tool: 16.8 MB instead of 18.4; ui's
counter example (with the ui changes of the same work): 1.21 MB instead of
1.77. `HXMC_STATS=1` prints the live
functions (and where a name is computed) and the data's parts;
`HXMC_REACH_WHY=<pack.Class.method>` the chain that keeps a function;
`HXMC_REACH=0` keeps everything. WasmGC uses the same analysis (WasmGC
below).

## Native arrays

`hxmc.NativeArray<T>` (`hxmc/std/hxmc/NativeArray.hx`) is fixed-size storage
with a single GC allocation: a header, a length/kind word and packed
elements. Bool uses 1 byte, Int 4, Float and Int64 8, and reference elements
8 bytes. Nullable numbers and Dynamic use reference storage. Concrete
indexing lowers to direct loads/stores in `MirBuild`, without bounds,
growth or storage-kind checks; references keep the generational write
barrier. The collectors skip the length/kind word in reference arrays.
Copies preserve the runtime layout even in erased generic code; reference
copies retain the bulk write barrier. Array conversions copy.

A NativeArray whose element type is Dynamic (`Dynamic`, `Any`, an
abstract over them, an erased type parameter) may hold storage of any
kind: its accesses test the kind inline (reference storage directly) and
go through `rt/NArray.hx` otherwise. Haxe lets any NativeArray be seen so,
and lets `Vector<Int>` and `Vector<Null<Int>>` alias. Storage taken as a
typed NativeArray (from a Dynamic-typed one, from a Dynamic, between Int
and Null<Int>) is checked once there (`hx_narray_view`), and a mismatch
throws, as a cast does on HL and the JVM; a `cast` is not checked. A
NativeArray made for an erased type parameter is a wrapper (a NativeArray
of one reference) of reference storage: the first typed view converts the
storage to its kind if needed and the wrapper keeps pointing at the result,
so generic code and typed code share it (HL's `ArrayDyn` does the same); a
view of another kind later throws.

An array of no elements cannot change: typed code that makes one gets the
program's empty array of its kind (`MirBuild.EMPTY_ARRAY`, static data as
string literals are, defined by `DataGen.emptyArrays`), so `new Vector(0)`
allocates nothing; the runtime does not refer to those, so that a tool that
does not define them can still build it. A copy of an empty array is itself,
and any empty array serves as the view of any kind.

`hxmc/std/haxe/ds/Vector.hx` shadows the reference standard library on the
hxmc target and implements `haxe.ds.Vector<T>` as an abstract over
`hxmc.NativeArray<T>`. Indexing, length and construction inline to the same
operations as NativeArray. `toData`/`fromData` share NativeArray storage;
`toArray`/`fromArrayCopy` copy. `MkStd` keeps the upstream
Vector for Eval and macros in the merged `bin/hxmc/std`. `make bench-arrays`
compares Array, NativeArray and Vector
([measurement notes](../hxmc/test/bench/README.md)).

WasmGC (`-D hxmc.wasm-gc`, below) has the same NativeArray over the engine's
arrays: one of a known element type is the bare GC array of its kind (i32,
f64, i64, eqref, Bool i8), its accesses
`array.get`/`array.set`/`array.len`, `blit` of one kind `array.copy`
(`FuncGen.narray`); the empty arrays are one immutable global per kind. One
of a Dynamic element is an `eqref`: reference storage is accessed inline
(`br_on_cast`), other kinds and the wrapper (a struct of its storage and
whether a view took it) through `Helpers.na*` and `rt/gc/GcNArray`, which
has `rt/NArray`'s views, wrappers, copies, defaults and errors. There the
engine checks every index too: an access out of bounds that the define
leaves untested traps.

`-D hxmc.native-array-outofbounds` decides what an index out of bounds
does, at code generation (`Lower.bounds`, `FnLower.nativeRead`): not
defined, nothing is tested (the result is unspecified, as Haxe leaves it);
`throws`, an access tests its index (one unsigned comparison, negative
indices too) and throws `haxe.exceptions.ArgumentException` with the
position of the access; `silent`, a read out of bounds gives the element
type's default (0, false, null) and a write does nothing. The test is IR,
so the collector's roots account for the throw, and the optimizer drops a
test a dominating one decides (`v[i] += x` tests once with `throws`).
The std's own loops use `unsafeGet`/`unsafeSet`, which are never tested;
`blit` copies so when both ranges are in bounds, else element by element
with the define's accesses. Dynamic indexing follows the define too
(`Dyn.dynAget`, WasmGC's `GcDyn.aget`; an error when it is not defined). The define is registered
for `haxe --help-defines` by `hxmc.Defines`, leaving `haxe/src` unchanged.

## Module cache

The compilation server's HXB module cache, made durable
(`hxmc/src/hxmc/ModuleCache.hx`, `ModuleStore.hx`; on by default,
`HXMC_MODULE_CACHE=0` or `-D hxmc.no-module-cache` off; through `haxe` and
the tool, for every target): a successful build writes its typed modules
(HXB chunks, dependencies, file and check policy) into a store in the user
cache directory (`$XDG_CACHE_HOME/hxmc` or `~/.cache/hxmc`, macOS
`~/Library/Caches/hxmc`, Windows `%LOCALAPPDATA%\hxmc\cache`; `HXMC_CACHE`
overrides; one that cannot be written is not used), in `modules/<tool>/`
for each build of the tool: an index per working directory, class paths
and std (`<key>.idx`), the modules' HXB in blobs (one pack per build that
writes some, `b/<name>.pk`, written beside the rest of the build), read only
for the modules a build restores, and the compiled objects (`o/`, `ObjectStore.hx`:
named by the hash of their lowered IR, shared by every output; per output
the list of objects its last build used and its up-to-date record; the
objects stay next to the output, in `<out>.hxmc/`, only where the cache
directory cannot be written); once a day a build removes the tool
directories, indexes and object lists unused for 14 days and the packs and
objects nothing names. The cap (1 GB, `HXMC_CACHE_SIZE`) holds as builds
write: a build that wrote adds its bytes to `modules/size.txt` (one line
appended; one that wrote nothing reads nothing), and when the sum passes
the cap it trims at once, down to 80%: the other tools' directories first,
then indexes and object lists least recently used first, each pack or
object with the last one naming it. Removals tolerate builds running
beside (a tool directory is renamed before it is removed; a pack or object
found missing is typed or compiled again) (`CacheDir.hx`, checked by
`hxmc/test/CacheCheck.hx`). An index keeps variants of each module, each
with the defines it read (its file's conditions, its macros'
`Context.defined`, and those the compiler read in the build that typed
it): a build restores the variant whose reads have its values, so a define
only some modules read leaves the others (the std) good. Several
variants can match, for a module whose typing depends on defines only
through its dependencies (GLBackend inlines `BytesPtr`, whose file reads
`-D hxmc.wasm-gc`, and calls the functions `GL`'s build macro makes for the
target; Std depends on the runtime): of those, the one typed with the
build's defines (its context's signature) is restored, and a variant typed
with other defines is kept beside one with the same reads (at most four
per module), so builds that alternate (WasmGC, linear, native) each
restore their own (`make gfx-cache-check`). The server's
checks decide which modules are good, lazily, for the modules the build
loads, also those a restored module's HXB names (decoded from the store
only once checked, else typed from source); beyond them, a module's file
is compared by content hash where its date or size changed, its path
must still resolve to it (shadowing), and each dependency must have the hash it had when the module was typed: the
hash of its interface (`ModuleInterface.hx`: its declarations without the
bodies of functions whose type is written out; positions only for the
expressions kept, which inlining copies), or of its whole content across
contexts (a macro's code runs). A module typed again whose interface did
not change leaves its dependents restored (early cutoff: a body edited in
a central module of the port types that module again, not its
dependents); an edit undone restores the earlier variant (a module a macro
defined, with no file of its own, the variant whose dependencies are as
they were: the one typed with the variant restored for the module whose
macro defines it). A restored module that refers to one typed again reads
that module's fields once they exist: one read while a class of a module it
depends on, or of its cycle, is being built is typed from its source too,
and the fields Haxe makes in a later pass (an interface's property
accessors) are made before it reads them. Modules built by
macros are restored too; the state macros keep between calls is tracked:
the static variables of macro classes (not the std's) the macros run in a
module's typing use are kept with it (a registry an `@:autoBuild` fills
for another macro, a counter naming generated types). Such a module is
restored while no macro of the build uses that state; a macro that uses
it after such a module was restored makes the build run again, those
modules typed (`HXMC_MODULE_CACHE_RETYPE`), and an edited one has the
others that keep state there typed from the start. A class's build (its
fields made, its build macros run, lazily, when first asked for) is part of
the typing of its module, whichever module's typing asks for it. A callback a macro
registers while a module is typed (`onGenerate`, `onAfterTyping`,
`onAfterGenerate`) makes that module typed every build. Not used for
display requests, the server itself, several compilations, init macros,
deprecated defines, HXB libraries or output, WASI; such a callback
registered outside the typing of a module, or a macro defining something,
makes the build write nothing. The output is the same as
without the cache (`make test-module-cache`; `make fixpoint`: the tool
building itself with the cache cold, warm and off): the cache also keeps
the modifiers of unbound monomorphs and what the sort of the types walks
of each module before the filters, which HXB does not keep. What a macro's
result depends on beyond the sources is learned from the macro std's
natives (`EvalStdLib.volatileHook`, `fileHook`, `envHook`), for the module
being typed when the macro runs (the one the static-variable tracking
names). A call whose result changes from run to run (`Date.now`,
`Sys.time`, `Sys.cpuTime`, `Timer.stamp`, `Math.random`, `Std.random`,
sockets, `sys.net.Host`, `sys.Http`, `sys.ssl`, `Sys.command`,
`sys.io.Process`, `Sys.getChar`, eval.luv's network, processes, signals,
time, random, file system and system information) makes the module
typed every build, its macros run again; its dependents stay restored
through its interface as parsed, unless the call was where they copy the
result (an inline or macro field, a field whose type is not written out,
a build macro): then its interface counts as new every build. A file a
macro reads (`File.getContent`, `getBytes`, `read`; `FileSystem.exists`,
`isDirectory`, `stat`, `readDirectory`, `fullPath`) is a read of the module
kept with what the macro saw (the content's hash, the listing, whether it
exists, the status, the full path), as an environment variable it reads
(`Sys.getEnv`, `Sys.environment`, eval.luv's `Env`) is with its value: the
module is restored while they are the same (a file touched but not changed
leaves it), its interface is its whole content (they may change it), and a
variant per value is kept (`registerModuleDependency` keeps working, the
file then both a dependency and a read; a macro reading its module's own
file adds nothing). `@:hxmc.noCache` on a type, or
`-D hxmc.no-cache=<package, module or library directory,...>` (read without
entering the key), makes a module typed every build, its dependents with
it; `HXMC_MODULE_CACHE_LOG=1` says why a module was typed (`Clock typed
every build (macro called Date.now at src/Macros.hx:4)`, `Data dirty: ...
(data.txt, read by a macro)`), `HXMC_STATS=1` counts the modules typed from
source and those typed every build. A module whose types share a path
(an abstract whose implementation class `@:native` renamed to it, processed
in the macros' context: eval's `mbedtls.SslAuthmode`) is not kept: HXB names
a type by its module and name. Plans: [plans/compiler.md](plans/compiler.md)

## Targets

Targets: Linux (static ELF with musl's members; with `-D hxmc.libc=glibc`, an
executable dynamically linked against the system's glibc: PT_INTERP, DT_NEEDED,
imports with the symbol versions of glibc 2.17 bound at load time, a
generated `_start` calling `__libc_start_main`; runtime objects of their own,
`<target>-glibc`, the runtime's Haxe code the same), Windows (PE over the UCRT,
imports written from the import libraries), macOS (Mach-O against
libSystem, ad-hoc signed), each on x86-64 and ARM64, Android (a shared
library of position-independent code against Bionic, in an APK hxmc writes:
Android, below), iOS and its simulator on ARM64 (macOS's Mach-O and
runtime, in an app bundle hxmc writes: iOS, below), and wasm32-wasi (the
whole runtime in Haxe; exception handling with `exnref`, or with
`-D hxmc.wasm-eh=legacy` the legacy `try`/`catch_all`/`rethrow`, which node 22
runs without flags and wasmtime not at all; run with
`node hxmc/bootstrap/wasi.mjs m.wasm` or `wasmtime run -W exceptions=y --dir . m.wasm`;
no threads, sockets or processes). mbedtls 2.28 and libuv 1.48
(`hxmc/deps/deps.sh`) become `ssl.o` and `uv.o`, linked only into programs that
use `sys.ssl` or `eval.luv`. Environment for development: `HXMC_OPT=0`,
`HXMC_INLINE=<flat>,<loop>,<runtime>`, `HXMC_SYMBOLS=1`, `HXMC_SIZE_STATS=1`,
`HXMC_DUMP=<function>`, `HXMC_MAP=<file>` (Windows), `HXMC_FRAME_POINTERS=0`,
`RT_MINOR_KB` (a fixed nursery), `RT_TLAB_KB`, `RT_OLD_MB`, `RT_PREFAULT`, `RT_STATS`, `RT_VERIFY`,
`RT_STACK_MB` (wasm32: the shadow stack; WebAssembly, Memory).

## Android

`-D hxmc.target=android-arm64` (phones) or `android-x86_64` (emulators):
Android 10 (API 29) and later, the first with ELF thread-locals in Bionic.
The output is the program's shared library (`lib<name>.so`), or with an
output ending in `.apk` an APK holding it as `lib/<abi>/libmain.so`, which
the framework's `NativeActivity` loads (no Java, no `classes.dex`, no SDK or
NDK at build time):

```sh
haxe -cp packages/os/src -cp packages/gfx/src -cp packages/gfx/examples -main Cube \
  --custom-target hxmc=bin/cube.apk -D hxmc.target=android-arm64 -D hxmc.android-package=org.example.cube
adb install -r bin/cube.apk
adb shell am start -n org.example.cube/android.app.NativeActivity
adb logcat -s hxmc        # what the app prints (stdout and stderr)
```

| Option | |
| --- | --- |
| `-D hxmc.android-package=<id>` | the application id (default `org.hxmc.<the output's name>`) |
| `-D hxmc.android-label=<text>` | the launcher's label (the output's name) |
| `-D hxmc.android-version=<n>`, `-D hxmc.android-version-name=<text>` | `versionCode` (1), `versionName` (1.0) |
| `-D hxmc.android-min-sdk=<n>`, `-D hxmc.android-target-sdk=<n>` | 29 (the floor: ELF TLS), 35 |
| `-D hxmc.android-permissions=<names>` | `uses-permission`s (`INTERNET`: `android.permission.INTERNET`; a name with a dot as it is); none by default |
| `-D hxmc.android-key=<file>`, `HXMC_ANDROID_KEY` | the debug key's file (default `<cache>/android/debug-key`, made on first use) |
| `-D hxmc.exports=<names>` | what the library exports besides `ANativeActivity_onCreate` |

The shared library (`LinkDyn.hx`, shared with `-D hxmc.shared` in the glibc
mode, `hxmc/test/SharedCheck.hx`): ET_DYN at address 0; the code was
pc-relative already (program-wide numbers are absolute symbols, not
addresses), so an address in data becomes an `R_*_RELATIVE` relocation (the
read-only data holding one moves to the writable segment), an import a GOT
slot bound at load time (`BIND_NOW`; calls through a stub), a library's
variable its slot too (the address computation that names it, adrp+add or
lea, made a load of the slot; the runtime takes `environ`'s address once,
`Start.hx`, since a load cannot be rewritten so); thread-locals as on macOS:
generated code calls `hxmc_tls_base` once per function, a stub the linker
writes that returns the module's TLS block for the thread (TLSDESC on arm64,
the general dynamic model's `__tls_get_addr` on x86-64, where Bionic has no
TLSDESC; initial-exec is refused for a dlopen'ed library); 16 KB segments
(Android 15's pages); `DT_HASH`, `DT_SONAME`, the exports (`Abi.exports`:
`ANativeActivity_onCreate`) in `.dynsym`, every other symbol hidden; section
headers (Bionic's linker reads `.dynamic` and `.dynstr` through them).

Bionic: the runtime's C library calls are imports of `libc.so`, `libm.so`
and `libdl.so` with Bionic's symbol versions (`LIBC`, `LIBC_N`, ... `LIBC_Q`):
the runtime objects `android-arm64` and `android-x86_64` hold the table of
everything those libraries export to API 29 apps, made by `mkrt.sh` from
Bionic's version scripts (their arch and `introduced=` tags), and
compiler-rt's helpers; `deps.sh` fetches Bionic's headers at a pinned AOSP
commit, against which mbedtls and libuv are compiled (`sys.ssl` and
`eval.luv` link; not exercised on a device yet) and `Layouts.hx` reads the layouts (Bionic's pthread types,
`_SC_PAGESIZE` 39). The runtime's differences: `__errno`, `__cxa_atexit` with
the library's `__dso_handle` (Bionic's `atexit` is crtbegin's), `environ`'s
address (`Mem.target()` 9 and 10: `Mem.target() >= 9` is Android, `Mem.os()`
is Linux's). Other libraries (`libandroid.so`, `liblog.so`, `libEGL.so`) are
imported unversioned; `@:hxmc.lib("libEGL.so.1")` names `libEGL.so` there.

The app (`packages/os`, `hxmc.os.android`): the export
`ANativeActivity_onCreate` (no-GC Haxe, `Activity.hx`, what the NDK's
`android_native_app_glue` does in C) sets the activity's callbacks, sends
stdout and stderr to logcat (tag `hxmc`) and starts the program's thread,
where the runtime starts (the generated `main`) with an `ALooper` watching
a pipe of the callbacks' commands; the callbacks run on the UI thread, which
the runtime does not know, and wait for the ones whose state the program
must take (a window created or going, an input queue, pause, destroy).
`AndroidWindow` is the activity's window behind `Window`, `App.run` polls
the looper (input queue: touches as in the browser, `hxmc.os.TouchDrag`:
a tap a click, a drag `Scroll`s at where it started that glide when let
go, keys as X11 KeySyms), draws only with a window and not paused,
and sleeps in the looper otherwise; a window taken by the system is
`Surface.lost` (gfx lets go of its EGL surface first) and a `Suspend`
event, a new one `Resume`. `packages/gfx`'s GL back end is EGL's default
display on the `ANativeWindow`, GLES 3.0 from `libGLESv3.so`.

The APK (`hxmc/src/hxmc/android/Apk.hx`): `AndroidManifest.xml` in binary
XML (`Axml.hx`: `hasCode="false"`, `NativeActivity` with
`android.app.lib_name`, `extractNativeLibs="false"`, the configuration
changes the activity keeps, a framework theme; no `resources.arsc`), the
library stored and aligned to 16 KB (the rest to 4 bytes: what `zipalign -P
16` does), then the APK Signature Scheme v2 block, ECDSA P-256 with SHA-256
in plain Haxe (`P256.hx`, RFC 6979's deterministic nonces, so an APK signs
the same way each time; the self-signed certificate `Der.hx` writes) with a
debug key kept in the user's cache directory, so reinstalls keep their
signature. The cube's APK: 296 KB (arm64; its library 279 KB), 280 KB
(x86-64); a hello world's library 108 KB and 92 KB.

Views and Java (no Java compiler or SDK either): JNI is bound in Haxe
(`packages/os`, `hxmc.os.android.Jni`: `JNIEnv` and `JavaVM` are function
tables behind a pointer, bound by the same build macro as COM's vtables,
`hxmc.os.VTable`; Java's methods called with the `*A` variants, an array
of `jvalue`; classes found through the activity's class loader; a Java
exception thrown again as a Haxe one with its text). Views live on Java's
main thread, which the runtime did not start: `MainThread` hands it
functions through a pipe its looper watches (`run` waits, handling the
activity's commands meanwhile), the first of which makes it a Haxe thread
(`NativeThread.attach`, `hxmc/std/hxmc/rt/Threads.hx`: a record and a
shadow stack, safe whenever it is back in Java), and runs frames from
Choreographer (`AChoreographer_postFrameCallback64`). Java calls back
through a few classes in a `classes.dex` that hxmc writes
(`hxmc/src/hxmc/android/Dex.hx`: a minimal DEX 035 writer, the pools
sorted as the runtime requires, the map, the SHA-1 signature and Adler-32
checksum, and a reader that checks that structure; `Glue.hx`: the classes,
written as Dalvik instructions): `org.hxmc.Glue`, one listener for every
kind of widget (click, text, checked, progress, editor action, layout
change, surface holder, key), whose methods call one static native,
registered with `RegisterNatives` (`hxmc.os.android.Glue`); and
`org.hxmc.Activity`, a `NativeActivity` that gives back the surface and the
input queue NativeActivity took, so that its window draws views. Apk adds
`classes.dex` (`hasCode="true"`) when the program uses the Glue, and
makes `org.hxmc.Activity` the activity, in the system's
`Theme.DeviceDefault.DayNight`. `packages/ui`'s `hxmc.ui.native` has an
Android backend on that (`AndroidBackend`: `android.widget`'s views in an
`AbsoluteLayout`, laid out by ui's flexbox in dp, measured by the views;
accessibility is the views'): NativeForm's APK (`AndroidNativeTest`) is
1.91 MB (arm64), 1.81 MB (x86-64), most of it ui's core; `classes.dex`
3 KB.

Mixing GPU and native views: a GPU view among views is a `SurfaceView`
(`hxmc.os.android.ChildSurface`) whose holder's callbacks make its surface
the `ANativeWindow` of an `hxmc.os.Surface`, as the activity's window is in
the GPU-only case: gfx's GL back end makes its EGL surface on it, lets go
of it in `surfaceDestroyed` (`Surface.lost`) and makes one on the next, on
the main thread's frames; `hxmc.ui.native.android.GpuView` is the node
for it in a `NativeHost`, laid out like the others. A native control in a
drawn window only for text: `Window.startTextInput` on Android
(`hxmc.os.android.TextInput`, enabled by ui's `UiWindow`) focuses a hidden
`EditText` in NativeActivity's window and shows the soft keyboard; what the
input method composes comes as `TextEditing`, what it commits as
`TextInput` (the field emptied again); keys still come through the input
queue, which the system serves before the focused view. A program that
never takes text keeps neither (nor `classes.dex`).

Checks: `hxmc/test/ApkCheck.hx` (`make android-check`: the zip, the
manifest read back, the library's ELF, the signature's digest and
signature, `classes.dex` read back by `Dex.check`; `zipalign`, `aapt`,
`apksigner`, `dexdump` where installed), `make shared-check`, and on a
device or emulator (`make android-device-check`; CI: an x86-64 emulator)
`packages/gfx/test/android.sh` and `packages/ui/test/android-native.sh`
(the form's own checks on the device, uiautomator's accessibility dump,
taps and text typed through the input method) and `android-mix.sh` (the
cube in a `GpuView` among views, its surface taken by Home and given back;
the soft keyboard for a drawn window, keys, a composition and a commit),
`packages/os/test/android-touch.sh` (a fling in a drawn scroll box, which
glides on), android.sh also a drag held on the cube and a fling; `make
touch-check` runs `TouchDrag`'s own test on the host. Not yet: one ABI per APK,
release signing (a keystore), icons and resources, the clipboard
([plans/targets.md](plans/targets.md#android)).

## iOS

`-D hxmc.target=ios-arm64` (devices) or `ios-sim-arm64` (the simulator on
Apple silicon): iOS 15 and later. Darwin is macOS's: the same libSystem,
struct layouts and runtime objects as `macos-arm64` (`Mem.os()` 1,
`Mem.target()` 3; `Mem.platform()` 1 or 2 tells iOS and the simulator
apart, for packages), Mach-O with the iOS or the simulator's platform in
`LC_BUILD_VERSION` (minimum 15.0, SDK 18.0), TLV descriptors as on macOS,
the system's frameworks (UIKit, Foundation, Metal, ...) loaded by their
install names from dyld's shared cache. The output is an executable, or with
an output ending in `.app` an app bundle, `.ipa` the bundle zipped (no
Xcode or SDK at build time):

```sh
haxe -cp packages/os/src -cp packages/gfx/src -cp packages/gfx/examples -main Cube \
  --custom-target hxmc=bin/Cube.app -D hxmc.target=ios-sim-arm64 -D hxmc.ios-bundle-id=org.example.cube
xcrun simctl install booted bin/Cube.app
xcrun simctl launch --console-pty booted org.example.cube   # what the app prints
```

| Option | |
| --- | --- |
| `-D hxmc.ios-bundle-id=<id>` | `CFBundleIdentifier`, the code signature's identifier (default `org.hxmc.<the output's name>`) |
| `-D hxmc.ios-name=<text>` | the home screen's label (the output's name) |
| `-D hxmc.ios-version=<n>`, `-D hxmc.ios-version-name=<text>` | `CFBundleVersion` (1), `CFBundleShortVersionString` (1.0) |
| `-D hxmc.ios-min-version=<major.minor>` | `MinimumOSVersion` and the build version's minimum (15.0, the floor) |
| `-D hxmc.ios-entitlements=<file>` | entitlements (an XML plist) signed with the code |

Why 15.0: `UILaunchScreen` (the screen's own size without a storyboard) is
iOS 14's, current Xcodes and the App Store start at 15, which runs on every
device since the A9; nothing here needs more.

The bundle (`hxmc/src/hxmc/ios/Bundle.hx`): `<name>.app` holds the
executable `<name>`, `Info.plist` (XML, `Plist.hx`: the bundle id, the
executable, an empty `UILaunchScreen`, the platform, `MinimumOSVersion`, the
orientations) and `_CodeSignature/CodeResources` (the other files' SHA-1 and
SHA-256 with codesign's default rules). The executable's code signature is
written by the linker (`hxmc/src/hxmc/CodeSign.hx`, shared with macOS, where
it is the linker-signed ad hoc signature ld64 writes): for a bundle, ad hoc,
identified by the bundle id, its CodeDirectory's special slots binding the
`Info.plist`, an empty requirement set and `CodeResources` (and the
entitlements), as `codesign -s -` signs, which `codesign --verify` accepts
and the simulator runs. An `.ipa` is the bundle under `Payload/`, stored,
the executable with mode 0755. The cube's executable: 269 KB, its `.ipa`
273 KB; a hello world's 134 KB; IosTest's 651 KB.

The app (`packages/os`, `hxmc.os.uikit`): UIKit wants `UIApplicationMain`
on the main thread before any window, and it never returns. A program
that uses the os package has `UIKitApp`'s export `hxmc_ui_main`, which
hxmc's generated `main` runs instead of the program's body (DataGen, on
the big stack the body would have had): it makes the app delegate's class
at run time and calls `UIApplicationMain`; once the app has launched, a
timer on the main run loop runs the program's body (its static
initializers, then `main`) inside UIKit's loop, and `App.run` turns that
loop itself without waiting (`CFRunLoopRunInMode`, as SDL does). Nothing
runs before the body that needs a static's initializer. `UIKitWindow` is
the one `UIWindow`, its root view controller's view an `HxmcView` (a
`UIView` subclass made at run time, `+layerClass` `CAMetalLayer`): gfx's
Metal back end draws to the layer as on macOS (Surface kind `Cocoa`).
Touches (the first finger down) are as on Android and in the browser
(`hxmc.os.TouchDrag`: a tap a click, a drag `Scroll`s with
`Mods.TOUCH`, a glide when let go); the view's size
and the safe area (`Window.safeTop`, `safeLeft`, `safeBottom`,
`safeRight`, in pixels) are measured in `layoutSubviews` and
`safeAreaInsetsDidChange` (a Resize event when either changes,
ScaleChange when the scale does); the app delegate's background and
foreground callbacks are Suspend and Resume (no frames are drawn in the
background: iOS refuses GPU work there; the layer stays, so the Surface is
not lost). `UIPasteboard` is the clipboard and the trait collection the
dark mode. Not yet: keys and text input (a `UIKeyInput` view, as macOS's
text view), multiple touches, UIScene (the app delegate's lifecycle is
what the declared SDK gets).

Checks: `hxmc/test/IosCheck.hx` (`make ios-check IOS_TARGET=ios-arm64|ios-sim-arm64`:
the bundle, `Info.plist` read back, the Mach-O's header and load commands,
the code signature's CodeDirectory with its page hashes and special slots
recomputed, `CodeResources`; `llvm-objdump` where installed, `codesign` and
`plutil` on a Mac), and on a Mac with Xcode `make ios-sim-check`
(`packages/gfx/test/ios.sh`: `codesign --verify`, a new simulator booted,
IosTest installed and launched with its stdout in a file, the cube headless
on the simulator's Metal against `cube.png`, frames in the window and its
pixels lit, a tap posted on the Simulator's window (`SimTap.hx`, an hxmc
program for macOS) as MouseDown and MouseUp, a fling (SimTap's quick drag)
as scrolls at where it started that glide on, a screenshot, Settings and back
as Suspend and Resume; CI's `ios` and `ios-simulator` jobs, the latter on
an iPhone 17 simulator of iOS 26.2, Xcode 16.4's runner). Devices need
what is left ([plans/targets.md](plans/targets.md#ios)): a signature by the
developer's certificate (a CMS blob over the CodeDirectory), the
provisioning profile (`embedded.mobileprovision`) and its entitlements
(`application-identifier`, `com.apple.developer.team-identifier`,
`get-task-allow`, also in DER), the designated requirement; `CodeSign.Identity`
is where they go.

## WebAssembly

WebAssembly is the seventh target, described with the others under Targets above; the playground and the npm fallback run the port as a wasm32-wasi module.

Programs in the browser: a package whose externs are imports of a module
(`@:hxmc.lib("hxmc_gfx")`) ships an `imports.mjs`, whose default export maps
a host to import objects, possibly asynchronously (gfx requests the WebGPU
adapter and device before `main`); `packages/os/browser.mjs` merges them,
gives WASI preview 1 without a file system and runs `_start`. JavaScript
objects live in its handle table, Haxe sees integers. The runtime stays
intact after `_start` returns, and JavaScript calls a `@:hxmc.callback` by
its index in the exported `__indirect_function_table` (corpus case
`WasmCallback`): `@hxmc/os`'s canvas window runs its loop from
`requestAnimationFrame` that way, paused while the canvas is out of view.

### Memory

A wasm32 module's linear memory only grows, and browsers (phones above all,
and several islands on one page) refuse it early, so the runtime
(`hxmc/std/hxmc/rt/wasm/Heap.hx`, `Gc.hx`) takes only what it uses: the
nursery's region is as large as the nursery (4 MB, then doubled by the
adaptive sizing up to 32 MB: grown in place when it is the last region,
else moved to a new one right after a minor collection, when it is empty;
it stays as it is when memory cannot grow); the old space is chunks of 1 MB
taken as objects are promoted (`RT_OLD_MB`, 32, is when the first major
collection comes, not a reservation); the shadow stack is `RT_STACK_MB`
(4 MB; `wasi.mjs` sets it from node's `--stack-size`, as deep as node's
stack: 64 MB for the compiler under `--stack-size=65500`). There is no guard
page: the first time a frame goes deeper than the shadow stack has been
since the last collection (the slow path that raises `rt_sp_hw`), it is
compared with the end, `rt_sp_limit`, and an overflow exits with "stack
overflow: the shadow stack's 4 MB are full". A browser's wasm stack (about
1 MB) runs out first: a recursion of frames of a few references fills 1 MB
of shadow stack where node's 8 MB stack is full at 2 to 4 MB. Memory
memory.grow gave is zero, so only what was handed out before and freed is
zeroed (`Heap.freshFrom`: the highest the regions reached): the nursery, the
shadow stack and the 64 KB granule table cost address space, not pages,
until they are used. When memory.grow fails the runtime writes "out of
memory: linear memory is N MB, growing it by M MB failed" and exits;
`packages/os/browser.mjs` turns a RangeError of the browser's (a new
instance's memory, an ArrayBuffer) into "out of memory: the browser refused
N MB ...", which the islands' loader shows (`data-error`).

The examples' memory (`memory.buffer.byteLength`, Chromium with a phone's
emulation, after they start and after a few seconds of taps; the playground's
compiler after `--version` and after running a hello world with `--interp`),
and the renderer's resident memory (the examples page alone: about 108 MB):

| | before | after | renderer RSS before | after |
| --- | --- | --- | --- | --- |
| gfx-cube | 98.3 MB | 10.3 MB | 229 MB | 134 MB |
| ui-counter | 101.6 MB | 21.6 MB | 240 MB | 151 MB |
| ui-gallery | 100.8, then 105.5 MB | 20.8 MB | 252 MB | 169 MB |
| os-tone | 98.3 MB | 10.3 MB | 232 MB | 135 MB |
| hih (playground) | 99.6, then 111.6 MB | 11.6, then 28.6 MB | 381 MB | 221 MB |

Before, every instance reserved and zeroed the nursery's largest size (32
MB) and a 64 MB shadow stack at startup.

### WasmGC (-D hxmc.wasm-gc, an experiment)

With `-D hxmc.wasm-gc` (and `-D hxmc.target=wasm32-wasi`) the IR after Lower
becomes a WasmGC module instead (`hxmc/src/hxmc/wasmgc/`): Haxe's values live
in the engine's collector, with no shadow stack or barriers. What is
emitted is what the reachability above keeps (method-level, by name), run
twice: before and after each function's body goes through `IrOpt`, so a
function inlined everywhere is dropped (the runtime's exports are live
where this target's code calls them: `GcGen.runtimeCalls`). `IrOpt`:
inlining where it lets scalar replacement turn objects
that never escape into locals (the IR's counterpart of Mir's `Inline` and
`Sroa`, which this path never reaches; V8 inlines small functions of a
WasmGC module itself). A reference has the wasm type its IR type proves
(classes, strings, arrays, enums, closures, Bytes: `GcModule.keyOf`), else
`eqref` cast where it is used; a local that is only ever cast to one type
gets it (`FuncGen.refine`, a second emission); one set from a Dynamic
value (Haxe's unchecked conversions) gets none, as linear memory may hold
a value of another type there. All types are in one recursion
group, so the class hierarchy is wasm's subtyping (`instanceof` is
`ref.test`; leaf classes are final types); methods have their own typed
signatures, virtual and interface calls go through a funcref table indexed
by class and selector holding wrappers of the table's signature; closures
are structs whose first field is a typed function reference (`call_ref`);
array accesses and structural field accesses test the expected kind or
layouts inline before falling back to the runtime (an Array's or a
String's methods called structurally: `gc_anon_call`); `hxmc.NativeArray`
(and so `haxe.ds.Vector`) is the engine's bare array of its kind (Native
arrays, above); Ints of -128...1023 are
boxed once; literals of 24 characters and more come from passive data
segments; exceptions are the legacy try/catch instructions. The natives of
strings, StringBuf, arrays, Bytes, BytesBuffer and Date are the linear
runtime's own (`Str`, `Arr`, `Bytes`, `Date`: `@:hxmc.anyHeap`), written
over `hxmc.rt.Repr`, the representation chosen at compile time:
`MemRepr` over `Mem` in linear memory, `hxmc.rt.gc.GcRepr` here, over
intrinsics (`hxmc.rt.gc.W`, expanded by `FuncGen.host`); the rest of
this runtime is `hxmc/std/hxmc/rt/gc` (Dynamic's comparisons, reflection
over Meta's tables, the system over the host, what linear memory's
generated code does inline), whose `@:hxmc.wasmgc` classes and the
`@:hxmc.anyHeap` ones are the only ones whose `@:hxmc.host` functions are
bound; Math's transcendental functions, float
formatting and parsing are the host's (`hxmc/bootstrap/wasmgc.mjs`, which
runs a module under node; `packages/os/browser.mjs` gives the same host in
a browser). So is the system (`GcSys`): files whole and by descriptor
(positions kept by the host, node's fs having no seek), directories in the
order the system lists them, the shell, processes (`sys.io.Process`: a
worker thread of the host runs them, the module waiting for each answer,
so their streams behave as natively; a command that cannot be run exits
127), and the collector's API (`GcCollector`: collections are the
engine's to start, finalisers never run); there are no sockets and no
`Sys.getChar`. There is one thread (the module sees
`NUMBER_OF_PROCESSORS=1`, and the port runs its parallel passes
sequentially): a thread created (`GcThreads`) runs, to its end, when a
running one waits for what nothing else would end (a lock, a queue, a
condition or a park, without a timeout), then the wait is tried again, so
fork-join works (the port reads a process's two streams so, calling
haxelib for `-lib`), threads that interleave with others do not. The
atomics are a NativeArray of one element; `hxmc.NativeZip` is the same
decoder, over copies of the Bytes in the linear memory (below). Reflection
reaches the statics of a class used as a value (`Lower.reflectStatics`:
their names by class index, read and written by
`Meta.staticGet`/`staticSet`, a method as a closure; `hxmc.ir.Reach`
takes `GcNative.find`'s names as it takes `Dyn`'s), copies objects
(`Reflect.copy`), tests a type known at run time only
(`GcNative.isOfType`: a switch on the class's id; an interface, which has
none, gets -1 minus its index in its type value), and calls the methods of
Arrays and Strings through Dynamic as through structural types
(`gc_anon_call`); calling what is not a function throws. The port builds
so (`make wasmgc-port`) and passes the conformance lanes as the port
(`make test-wasmgc-port`, docs/testing.md).

A program that uses `hxmc.unsafe` or C functions gets a small linear
memory besides (a hybrid module, `GcModule.memory`): `Mem`'s loads and
stores, `Ptr`, frame areas (`Mem.stack`, a struct's slot: a stack pointer
global, each frame given back on return and where an exception is
caught), C string literals in a data segment, malloc's heap
(`hxmc.rt.wasm.Heap`, `@:hxmc.anyHeap`), `Arena` and `CString` work on
it as in linear memory. It is exported as `memory`, with the
`@:hxmc.callback` functions in `__indirect_function_table`, so the
packages' imports (`imports.mjs`) and `browser.mjs` treat the module as
a linear one: `@:hxmc.lib` externs are imports with wasm32's C ABI
(pointers as i32 into that memory, floats as f32). A Bytes stays an array
of the collector; where it crosses to C, `hxmc.unsafe.BytesPtr` copies
it through the linear memory (in linear memory: its own address, no
copy); strings cross as UTF-8 through it (`Repr.utf8To`,
`Repr.octetsAt`). A `@:hxmc.struct` class whose fields are all final is
an object here (a value that cannot change needs no copies); the others
live in the linear memory. Statements after one that always leaves, and
the branch an if on a constant does not take, are dropped before
emission (`IrOpt.live`: what follows `if (Mem.os() == 3) {...; return;}`
is another target's, as Mir drops it). The name section is written with
`-debug`, `-D hxmc.symbols` or `HXMC_SYMBOLS=1`, as linear memory's.
`make gfx-web-check` and `ui-web-check` run their browser tests on such
builds too. A runtime function
not covered yet fails the build with its name; `HXMC_GC_SURVEY=1` lists
every such construct of a program instead (`=2` also writes the module,
those functions trapping). `make wasmgc-check` compares `hxmc/test/wasmgc`'s
programs (`Unsafe.hx`: the linear memory), and the corpus cases
`GcCheck.CASES` that need nothing WasmGC lacks, with their native output (a
program's `// define:` lines apply to both builds); `make wasmgc-bench`
adds the linear-memory build: times, peak RSS, sizes.

## Origin

hxmc began as the second back end of hxc, the C target this repository had
until 2026-10-14; its IR, runtime and std came from there, and its corpus's
golden files are hxc's outputs. Plans: [ROADMAP.md](../ROADMAP.md) and
[plans/](plans/README.md); the low-level API and C interop design: [plans/lowlevel.md](plans/lowlevel.md).
