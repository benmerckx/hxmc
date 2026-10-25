# Scoped memory applied to hxmc's own code

Where hxmc itself allocates, what scoped memory (docs/plans/lowlevel.md,
"Scoped memory") can take over, in what order, and what each step
measured. Each item is kept only if it wins; the ones that did not are
described with the reason.

## Measurements (before)

Linux x86-64, 4 cores. The self-build is the tool building itself (cold
module cache, `make bin/hxmc/hxmc`'s arguments); tsc-haxe is the Go port
of the TypeScript compiler built natively by hxmc, checking and emitting
the TypeScript 6 sources; the formatter build is MirBench's formatter
workload (json2object's macros under Mir macros, cold). Allocations by
type come from a census build (`-D hxmc.census`, `RT_CENSUS=1`), GC times
and peak RSS from `RT_STATS=1` and `/usr/bin/time`, instructions and
callers from callgrind (one thread: `-D disable-parallelism` does not stop
the code generator's threads, callgrind runs them one at a time).

| | self-build | tsc-haxe check | tsc-haxe full | formatter |
| --- | ---: | ---: | ---: | ---: |
| wall / user | 13.2-14.3 s / 19.1-19.7 s | | 5.8 s / 5.3 s | 0.51 s |
| allocated | 12.7 GB, 322M objects | 829 MB | 1.34 GB | 188 MB |
| GC | 340-350 minor, 1.6 s; no major | | 83 minor, 0.65 s | 13 minor, 0.05 s |
| promoted | 1.3 GB | | 450 MB | 36 MB |
| live at exit | 502 MB | 311 MB | | 32 MB |
| peak RSS | 1.51-1.55 GB | 680 MB | 523 MB (855 MB census build) | 105 MB |
| instructions | 101.6 G | | | |

The self-build's peak RSS is promoted garbage: the old generation holds
1.3 GB at the end against 500 MB live, and no major collection runs
before the 3 GB limit. What is promoted is what the code generator's
threads hold when a minor collection comes: the graphs of the functions
being compiled.

### Self-build: allocations by type

| type | objects | MB | B/object |
| --- | ---: | ---: | ---: |
| NativeArray (three element kinds) | 56.5M | 4037 | 52-253 |
| Array | 49.1M | 1123 | 24 |
| hxmc.MIns (Mir instructions) | 4.6M | 809 | 184 |
| hxmc.LIns (target instructions) | 4.4M | 636 | 152 |
| String | 13.2M | 615 | 49 |
| core.TExpr | 15.1M | 462 | 32 |
| closures (all kinds) | ~40M | ~1000 | 16-48 |
| Ref<p>, Ref<i> (captured locals' boxes) | 21.5M | 328 | 16 |
| Data<raw> (bytes, StringBuf) | 1.5M | 179 | 128 |
| Int boxes | 9.4M | 144 | 16 |
| core.UnificationContext | 1.2M | 137 | 120 |
| haxe.ds.IntMap, StringMap | 4.2M | 193 | 48 |
| hxmc.x64.Mem, OInfo, MBlock, LBlock | 3.5M | 256 | 56-184 |

### Self-build: instructions

| part | instructions |
| --- | ---: |
| code generation (`Driver.compileFunc`, per function) | 42.8% |
| - register allocation | 16.4% |
| - MirBuild (object-level Mir) | 6.0% |
| - instruction selection | 4.8% |
| - Opt | 4.7% |
| - emission | 3.7% |
| - MemLower | 3.0% |
| filters (analyzer, DCE...) | 21.7% |
| typing | 19.8% |
| zeroing allocation buffers (`hxmc_zero`, `rep stosb`) | 12.9% |
| minor collections (`Gc.drain`) | 5.2% |

Callgrind counts each byte of a `rep stosb` as an instruction: the
zeroing's 12.9% is the 12.7 GB allocated, a byte each, and costs far less
time than that share (the TLAB is zeroed in the L1 cache). Allocation is
otherwise inline; the slow paths that allocate the most (by the zeroing
charged to them) are array growth (`hx_apush_slow`, 1.9 G; its own 3.3 G
instructions), then `new LIns`, `new MIns`, `hx_arr_new_n` (array
literals and copies), `Str.concat`, `TExpr`, `IntMap.grow`.

### tsc-haxe

Full emit: String 205 MB, NativeArray 193 + 111 MB, Data<raw> 112 MB
(StringBuf storage growing, 2.5 KB each), Array 61 MB, the printer's
state objects (TextRange 46 MB, CommentState 33 MB, PrinterState 26 MB,
SourceMapState 20 MB). The program's own structures; what hxmc can change
is the runtime's (strings, StringBuf, arrays).

### Ranking

By allocation volume and what scoped memory can reach:

1. The back end's per-function graphs (MIns, LIns, blocks, OInfo, their
   arrays: about 2.5 GB of the self-build's 12.7 GB, and most of what is
   promoted). Scoped values cannot be fields of GC objects, and the passes
   are objects holding the graph in fields (`new Opt(mf)`,
   `new Regalloc(lf, ...)`): putting the graph on a data stack means
   rewriting the passes as functions over a scoped context passed down,
   or a new kind of object (below, "Decisions").
2. Array growth and small arrays: the most allocating slow path. A
   runtime matter (growth policy, literal sizes), not scoped memory.
3. Strings: concatenation chains make an intermediate string per `+`;
   StringBuf's storage regrows (tsc-haxe's Data<raw>).
4. Closures and captured locals' boxes (1.3 GB): the port's style
   (`haxe/src`), which the porting rules keep.
5. Byte buffers (Buf, object writers): under 200 MB; the same field rule
   as 1.
6. The module cache: its encoding is 0.5-0.7 s of a cold self-build,
   reading it back 30 ms and checking it 120 ms warm.
7. The unsafe surface (`@:hxmc.unsafe`, raw memory, `Ptr`): the OS and
   C layers hold 219 of the std's 626 `@:hxmc.unsafe` uses and some 800
   lines of raw memory access. Not an allocation volume: what the scoped
   C boundary (item 5) takes over.

## Order

Chosen by effort and impact (the owner left it open), revised as the
owner's decisions came:

1. String concatenation (item 4, first part): small, every target, the
   largest allocator of tsc-haxe and a common one of the compiler.
2. The scoped C boundary and the POSIX layers on it (item 5): the largest
   unsafe surface, each area a self-contained change; the owner's
   priority when time is short.
3. The other runtime hot spots (item 4): haxe.Json, inflate and CRC-32;
   Array growth tried.
4. The old generation's limit (the owner's GC change): small, the
   self-build's peak RSS.
5. Scope-bound classes (item 1, the owner's option B): the general
   feature; the back end where it wins (below, "Decisions").
6. The Windows layers on the boundary (item 5), then WASI (tried), byte buffers
   (item 3) and the module cache as Images (item 2): the least volume
   for the most change.

## Items

### String concatenation chains (item 4)

`a + b + c + d` made a string per `+`: FnLower now lowers a chain of `+`
on Strings to `hx_str_concat3`/`hx_str_concat4` (four at a time, one
string), each operand converted where the binary chain converts it
(the first two after both are evaluated, the others right after their
own); String operands are passed as they are (the runtime reads null as
"null"), where each was wrapped in `hx_str_or_null` before.

| | before | after |
| --- | ---: | ---: |
| microbenchmark (2M chains of 5-7 operands) | 330-370 ms | 204-222 ms |
| self-build allocated | 12.70-12.72 GB | 12.62 GB |
| self-build wall / peak RSS | 13.2-13.9 s / 1.51-1.55 GB | 13.1-14.3 s / 1.54-1.57 GB (noise) |
| self-build GC | 344-350 minor, 1.59-1.61 s | 338 minor, 1.57-1.67 s |
| tool's text | 17,300,089 B | 17,162,745 B (-0.8%) |
| tsc-haxe full: allocated / wall | 1303 MB / 5.75-5.87 s | 1302 MB / 5.77-5.88 s |
| tsc-haxe's text | 7,514,031 B | 7,511,439 B |
| LOC | | +80 (FnLower 59, Str 19, symbols 2) |

Kept: smaller code everywhere and the chains themselves 40% faster; the
compiler and tsc-haxe build few chains in their hot paths.

### haxe.Json's strings and StringBuf.addSub (item 4)

The JSON benchmark (HaxeBenchmarks' json: the formatter's schema
stringified and parsed 500 times) spent 27% of its instructions in
`JsonPrinter.quote` (a call per unit into the StringBuf) and 11% in
`JsonParser.parseString` (a loop of `nextChar`). hxmc's std now has its
own `JsonPrinter` and `JsonParser` (upstream's, with one change each):
`quote` is one runtime call, `StringBuf.addJsonString`, which copies the
runs without an escape whole; `parseString` skips the units up to a
quote, a backslash or a 0 (the hxmc end of input) with `Str.jsonRun`.
Both scan four units at a time in linear memory (one 64-bit load, the
lanes tested together; unit by unit on WasmGC). `StringBuf.addSub` copies
the range instead of making the substring first.

| | before | after |
| --- | ---: | ---: |
| json benchmark (best of 8) | 0.44 s | 0.39 s |
| instructions | 4.01 G | 3.40 G (-15%) |
| allocated | 284 MB | 275 MB |
| LOC | | +100 (runtime), two std files copied from upstream |

Not scoped memory: the buffer is a GC object (a StringBuf) and the
strings are the program's; the cores are the runtime's, over its
representation (both heaps).

### Inflate and CRC-32 as a scoped core (item 4)

`hxmc.NativeZip` (the compiler's ZIP reader; DEFLATE and CRC-32) was
unsafe code over raw addresses, and on WasmGC copied its input into
linear memory and its output back. It is now scoped code over views of
the Bytes (one core, two faces): the decoder's state a scoped struct,
the Huffman tables `Fixed` buffers of the frame, a block's codes decoded
with the stream's state in locals, back-references and stored blocks
copied by `Slice.copyBytes` (memmove; the engine's array copy).

| | before | after |
| --- | ---: | ---: |
| inflate, 464 KB (best of 8), native | 145 ms | 128 ms |
| CRC-32, 20 × 464 KB, native | 29 ms | 31 ms |
| inflate, WasmGC | 144 ms | 233 ms |
| CRC-32, WasmGC | 41 ms | 26 ms |
| `@:hxmc.unsafe` / raw-memory lines / `Ptr` lines | 9 / 71 / 13 | 0 / 0 / 0 |

Kept: faster natively, no unsafe code left, no copies through linear
memory on WasmGC; inflate on WasmGC is 60% slower (the engine's checked
array accesses where linear memory had raw loads), a cost of WasmGC's
representation.

### The passes' per-function tables (item 1): not worth moving

The tables a pass builds for one function and drops (`MFunc.ints`: the
frame's offsets and slots in Frames, Escape's sites, Opt's dead-code
marks, Inline's numbering) are 0.16% of the self-build's instructions,
their allocation and filling included (callgrind, inclusive); most are
fields of the pass objects, which scoped values cannot be. Not moved.

### Array growth (item 4): not kept

`hx_apush_slow`, an Array push that grows its storage, is 3.2% of the
self-build's instructions with what it calls (its callers are the IR
builders' pushes: MirWriter.add and edge, the instruction selectors,
BlockDefs.set). Growing from 4 elements instead of 2 (twice the capacity
each time either way): the formatter build's instructions 5.529 G →
5.510 G (-0.3%), the self-build's allocation +0.5% and its wall time
the same within noise (13.03 against 13.11 s median of 3). Not kept.

### The scoped C boundary (item 5)

A C function may take a view of scoped memory: a `Slice<T>` or `Str`
parameter passes its address and its length (docs/plans/lowlevel.md,
"The scoped C boundary"), a `Ref<T>` its address; `@:hxmc.retains`
marks a function that keeps a pointer, to which the checker passes no
scoped memory; scoped code may call C in a safe region (it then blocks).
Then the OS layers move onto it, area by area, their raw versions gone:

| area | `@:hxmc.unsafe` | scoped | raw-memory lines | `Ptr` lines | benchmark (best of 12) | program's text |
| --- | ---: | ---: | ---: | ---: | --- | ---: |
| POSIX files, processes, environment (PosixSys, Posix, SysCore) | 14 → 2 | 0 → 10 | 69 → 17 | 89 → 46 | 200k exists, isDirectory, getCwd, getEnv: 305 → 304 ms | +1.7 KB of 180 KB |
| POSIX sockets (PosixNet, NetCore, Posix) | 25 → 4 | 0 → 21 | 59 → 19 | 44 → 25 | 100k select, setTimeout, host, setFastSend: 158 → 158 ms | +2.0 KB of 223 KB |
| inflate and CRC-32 (NativeZip) | 9 → 0 | 0 → 2 | 71 → 0 | 13 → 0 | above | |
| Windows files, processes, environment (WinSys, Win32, SysCore) | 23 → 12 | 0 → 7 | 80 → 20 | 92 → 50 | SysNatives, SafeRegionRoots, NetNatives, ScopedCBoundary under wine | |
| Windows sockets (WinNet, Winsock, NetCore) | 29 → 11 | 0 → 18 | 68 → 21 | 29 → 13 | SysNatives, SafeRegionRoots, NetNatives, ScopedCBoundary under wine | |
| the calendar (Date, MemRepr's dates, LibC's time functions, Ssl's certificate dates) | 20 → 2 | 0 → 2 | 21 → 3 | 11 → 0 | 200k dates' fields, offset, toString, now, new: 230-270 ms both | +1.0 KB of 109 KB |

(Raw-memory lines: lines calling `Mem` other than the target's constants
`os`, `target`, `arm`, `platform`; `Ptr` lines: lines naming the type.)
The structures C fills are `Fixed` buffers of the frame read through
`hxmc.scoped.LE` (little-endian scalars of a byte view, one range test
each); with `ImageIO`'s byte-by-byte checked reads, function calls each,
select was 30% slower. The self-build does not call these layers in its
hot paths. Across the std, `@:hxmc.unsafe` uses went from 626 to 542
(the runtime gained three small ones: Str.jsonRun, Gc.viewTouch,
DataStacks.object).
The calendar's struct tm is a 64-byte `Fixed` C fills (the nine ints
first on every target), its time_t an 8-byte one; what stays unsafe is
the date object's slot (`Date.ms`) and Math.random. Its fields, offset,
text and times are the same as before in three time zones natively, on
wasm32 and under wine.

The Windows layers are built here for windows-x86_64 and windows-arm64,
run here under wine (the corpus' system, process, network and boundary
cases) and by CI (its Windows corpus and the port's self-compile). What
stays unsafe there: the process table and the non-blocking sockets'
table (malloc'ed, under spin locks), the heap's Bytes touched before a
call, the hostent the resolver returns. On Windows the boundary touches
each view's pages before the call (`hx_view_touch`, reading them: a
view may be of a literal): WinRt commits the data stacks' pages on a
fault in user code, which a fault in the kernel never makes. The
Windows layers are typed under WasmGC too (never run there), so their
views' addresses go through `SysCore.viewAddr` and `refAddr`.

WASI's layer stays as it was. Tried (its paths as scoped code over UTF-8
on the data stack, `WasiApi`'s calls taking views, a `Ref` parameter
32-bit on wasm32), it passed natively, on wasm32 and the port as wasm32,
but `Wasi`'s path functions and `WasiApi`'s Int pointers are also the API
programs call themselves, under WasmGC too (tsc-haxe's go.OsWasi, the
WasmGC check's WasiPaths), over linear-memory C strings that views
cannot express there; a scoped copy beside them would duplicate them.

### The old generation's limit (the owner's GC change)

The self-build's peak was promoted garbage: no major collection ran
under the tool's first old-space limit of 3 GB, so the 1.3 GB promoted
stayed against 0.5 GB live. The collectors already set the next limit
from what a major collection leaves live (natively three times, on
wasm32 twice); that factor is now `RT_OLD_GROWTH` (percent; 300 and 200
by default), and the tool's first limit is 768 MB. A copying major
collection peaks at what the old space holds plus what is live, so the
first limit decides the peak more than the factor. Self-build (cold
module cache, `RT_STATS=1`; peak RSS, wall, the major collections):

| first limit / growth | peak RSS | wall | majors |
| --- | ---: | ---: | --- |
| 3072 MB / 300 (before) | 1.55-1.58 GB | 12.6-15.1 s | none |
| 1024 MB / 300, 250, 200 | 1.65-1.66 GB | 14.0-14.9 s | one, 1.0-1.1 s |
| 768 MB / 300 (after) | 1.22-1.24 GB | 12.9-14.3 s | one, 0.6-0.8 s |
| 768 MB / 250 | 1.24 GB | | one |
| 512 MB / 300 | 1.98-2.01 GB | | two, 2.3-3.5 s |
| 640 MB / 200, 896 MB / 300 | 1.36-1.46 GB, 1.40 GB | | |

Interleaved, before against after (three runs each): wall 13.20 against
13.50 s (median), user 19.2 against 19.5 s, peak RSS 1.56 against 1.23 GB
(-21%). Two major collections cost more than they save: each peaks at
its own old space plus what is live, and the live size grows through
the build. Unchanged: tsc-haxe (its programs' default first limit is
256 MB and it runs no major collection: peak 529 MB at any factor), the
formatter build (75 MB promoted, no major collection), the benchmarks'
programs (no default changed: binarytrees and alloc built with the
collector before and after run the same collections, 313 minor and none
major, 263 minor and 3 major; medians 0.77 against 0.81 s and 1.74
against 1.76 s, the binaries' layout differing). The compilation server keeps its 4 GB
(`--server`): it holds every module between builds, not measured here.

### The back end's graphs (item 1): what is promoted

Whether the back end's per-function graphs are worth scoped memory
depends on what a minor collection copies out of the nursery: an object
that dies young costs its allocation only (bump and the TLAB's zeroing),
one that is promoted costs a copy, old-space room and, at the end, the
peak RSS (no major collection runs). The census build now counts the
objects minor collections copy, by type (`promoted by minor collections`,
Gc.copyTo and the scan's inline copy). Self-build:

| type | promoted MB | of its allocation |
| --- | ---: | ---: |
| all | 1339 | 10.6% of 12.6 GB |
| NativeArray (three kinds) | 386 | 9.6% |
| core.TExpr, its TExprDefs, TVar, Pos, Expr | ~375 | most of the typed AST (live until lowered) |
| hxmc.MIns | 97 | 12% |
| Array | 59 | 5% |
| String | 54 | 9% |
| hxmc.LIns | 42 | 6.6% |
| hxmc.Reloc, Symbol (the output) | 32 | |
| hxmc.OInfo, MBlock, LBlock | ~15 | |

The back end's own objects are about 160 MB of the 1339 promoted (12%),
and most of its 2.5 GB dies young. Against what is live at exit (500
MB), about 840 MB of what was promoted is garbage: the back end's
objects 155 MB of it (with their arrays, a share of the 287 MB of
NativeArrays), the typed AST's copies about 190 MB (the analyzer's), the
rest arrays and strings of every phase: the graphs of the functions
being compiled when a collection comes, four threads at a time. An index IR for Mir and Lir (a scalar
instruction record in a Grow, operand lists in a pool, GC-referencing
fields as ids into program tables, handle abstracts at the call sites)
would take about 2 GB of allocation and 150 MB of promotion away, a few
percent of the GC's work, for a rewrite of every pass of both IRs (MirBuild,
Opt, Escape, Sroa, MemLower, Frames, Fold, both instruction selectors,
the register allocator, both emitters, InterpGen, wasmgc's MirGen). The
register allocator's scratch tables are already reused per thread (no
allocation per function). Not started: at best a fifth to a third of the
promoted garbage and a few percent of the GC's time, for the largest
rewrite of the plan (below, "Decisions").

### Scope-bound classes (item 1, the owner's option B)

Built as a general feature (docs/plans/lowlevel.md, "Scope-bound
classes"): `@:hxmc.scopeBound` classes, objects with identity on the
data stack of the scope that makes them (on WasmGC ordinary objects
under the same checks), holding scalars, struct values, scoped values
and each other, never GC references; the root checker treats an object
as fresh memory of its scope, a method's object as its last parameter,
and what a constructor or method allocates into its object as the
object's. Tests: the corpus' `ScopedBound` natively, on wasm32 and under
Mir's `--run`, `GcCheck` on WasmGC, collections minor and major while
objects are live; ten `reject/ScopedBound*` cases (a GC object's field, a
static, Dynamic, a closure's capture, a method as a value, a loop
body's object kept outside, a method storing from a loop, GC code's
result, a GC reference field, a subclass).

Measured on binary trees (`make bench-scoped`'s `Trees`: n trees of
depth 16 built, walked and dropped, one of depth 14 kept; median of 5,
peak RSS; Linux x86-64, the same VM):

| n | scope-bound | GC | scope-bound, wasm32 | GC, wasm32 | scope-bound, WasmGC | GC, WasmGC |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 200 | 0.37 s, 3 MB | 0.46 s, 206 MB | 0.41 s | 0.49 s | 0.79 s | 0.86 s |
| 1000 | 1.79 s, 3 MB | 2.32 s, 267 MB | 1.79 s | 2.09 s | 3.29 s | 3.25 s |

(Node's own memory on wasm32 and WasmGC: their RSS is the engine's.) An
object's allocation is the data stack's bump and its words zeroed by
stores; with `memset` (a call on wasm32) the wasm32 version was 12%
slower than GC objects, with stores 14% faster.

The back end's passes: not converted (conservative, below,
"Decisions"). The passes are GC objects that hold the function's graph
in their fields (`Escape`, `Sroa`, `Opt`, `Frames`, `Fold` hold the
`MFunc`; `IselBase` the `LFunc` and the `MFunc`), and the two that build
Mir share a base class (`MirWriter`, for `MirBuild` and `MemLower`), as
the instruction selectors do (`IselBase`); a scope-bound object is
held by no GC object and has no subclass. So the first step is the
whole of one IR: Lir (`LIns`, `LBlock`, `LFunc`: about 5,000 lines of
the selectors, the allocator and the emitters of both targets, with
symbols as indices into a per-thread table, the blocks' lists as
`Grow`s, the selectors' state passed instead of inherited), or Mir
(more passes, and Mir macros keep compiled functions across builds,
`interp/BundleCache.hx`). By the census their gain is bounded: Lir's
objects are 0.67 GB of the 12.6 GB allocated and 45 MB of the 1.34 GB
promoted, Mir's 0.93 GB and about 0.11 GB (with their arrays somewhat more);
a minor collection's cost is what it copies, so all of both would save
about a sixth of the 1.5 s of minor collections, Lir alone 3-5% of it (under 0.1 s of 13 s, below
this VM's noise), and peak RSS no more than what they promote. The
measured allocation hot spot of the back end is elsewhere: Array
growth (`hx_apush_slow`, 3.2% of the self-build's instructions, its
callers the IR builders' pushes).

## Decisions for the owner

- The back end's graphs (item 1): the owner chose scope-bound classes
  (a class allocated in a scope, linearly on the data stack, on WasmGC an
  ordinary object with the same checks; it may hold scoped values, is
  never stored in the GC heap, and is checked as a scoped value rooted at
  its scope), then the passes as scope-bound objects over the function's
  scoped storage, the instructions' GC references as ids into long-lived
  tables. Built as a general feature first, then applied pass by pass,
  each step measured and kept only if it wins. The feature is built
  ("Scope-bound classes": binary trees 23% faster natively, 14% on
  wasm32, 3 MB against 267 MB). Its first step on the back end is a
  whole IR (Lir or Mir) with its passes restructured (no GC object may
  hold the graph, no subclassing), for a gain the census bounds under
  this VM's noise: not started, the conservative choice; for the owner
  whether to go ahead with Lir anyway.
- The self-build's peak RSS (1.5 GB against 500 MB live) is promoted
  garbage the old generation never collected (the limit is 3 GB): the
  owner approved a major collection when the old generation grows well
  past the live size measured after the last major one (a factor tuned
  by measurement, with a floor), on the native and wasm32 collectors.
  Done ("The old generation's limit"): the factor was already there
  (three times, twice on wasm32) and a factor of two cost more; the
  tool's first limit, 768 MB, took the peak from 1.56 to 1.23 GB. The
  compilation server keeps its 4 GB (it holds every module between
  builds; not measured here): lower it too?
- WASI's layer on the boundary (tried, not kept: "The scoped C boundary"):
  `WasiApi` and `Wasi`'s path functions are also an API programs call,
  under WasmGC too; converting it means a second, view-taking
  declaration of the same imports for WasiSys (the same signatures on
  wasm32, so they can coexist) and the paths' code kept twice, or those
  programs moved to the views.
