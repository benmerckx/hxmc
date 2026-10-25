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

Chosen by effort and impact (the owner left it open):

1. String concatenation (item 4, first part): small, every target, the
   largest allocator of tsc-haxe and a common one of the compiler.
2. The scoped C boundary and the POSIX layers on it (item 5): the largest
   unsafe surface, each area a self-contained change; the owner's
   priority when time is short.
3. The other runtime hot spots (item 4): StringBuf's storage, then
   haxe.Json, the regex engine's match state, inflate and SSL buffers.
4. The back end (item 1): the function-local tables of the passes (work
   lists, visited sets, numbering) on scoped memory where a function
   builds and drops them; the graphs themselves need a decision (below).
5. Byte buffers (item 3), then the module cache as Images (item 2): the
   least volume for the most change; the same field rule as 1 for the
   buffers.

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

## Decisions for the owner

- The back end's graphs on scoped memory need either the passes rewritten
  as functions over a scoped context (every pass of Mir and Lir, both
  targets), or objects that may hold scoped values because they live in
  a scope themselves (a scope-bound class: allocated on the data stack,
  never stored in the GC heap, checked as a scoped value is). The second
  keeps the passes' shape. Until decided: only function-local tables.
