# Code generation and optimizations

The pipeline as built: [docs/hxmc.md](../hxmc.md), "Pipeline".

## Object-level Mir

[#34](https://github.com/benmerckx/hxmc/issues/34): two levels of Mir, so
that objects are optimized as objects before they become memory, by one
optimizer for native code, linear wasm and WasmGC. The plan's stages: 0
WasmGC kept alive in CI (`make wasmgc-check`); 1 types on Mir values; 2
object operations from `MirBuild`, lowered right away (byte-identical);
3 escape analysis at the object level; 4 inlining, type-test folding and
devirtualization up, barriers and roots placed after optimization; 5
WasmGC from object-level Mir; 6 WasmGC's go/no-go again; 7 an
optimization tier for #15's interpreted macros.

### Built: stages 1 and 2

- **Types on values** (`MIns.vty`): the IR's type of what a value holds
  (`Ir.typeOf`: a class instance, an array and its element kind, a
  closure's signature, an enum or a constructor, Dynamic, a struct value,
  a scalar), given by `MirBuild` to what it makes from an expression, to
  parameters and to the locals' phis; the inliner copies it. Nothing reads
  it yet; dumps show it.
- **Object operations** (`Mir.Op` from `NullCheck` on, their static part
  `OInfo`): `New` (class instances, enum values, closures, boxes,
  anonymous objects, empty Arrays, `Mem.alloc`'s), `NewDyn` (`Mem.alloc` of
  a run-time size), `InitField`, `GetField`, `SetField`, `FieldAddr`,
  `EnumTag`, `TypeTest`, `Box`, `Unbox`, `VirtualCall` (selector dispatch:
  interfaces too), `ClosureCall`, `AnonGet`, `AnonTest`/`AnonStore`,
  `AnonCall`, `ArrayLength`/`ArrayGet`/`ArraySet`/`ArrayPush`,
  `NewArray`/`ArrayInit`, the NativeArray ones, `RefStore`
  (`Mem.setRefBarrier`) and `NullCheck` (explicit null tests). `MirBuild`
  (`MirWriter`: the instruction helpers and SSA variables, shared) makes
  them; `MemLower` lowers them to the memory-level Mir every back end
  takes, after the object-level passes (stage 3): layouts, the nursery's
  bump allocation and its stubs, write barriers with the release store
  (the arm64 publication fence, `MIns.release`), inline caches, null
  tests, the shadow stack around cold sites' slow paths. An operation whose
  lowering branches and meets again ends its block: the code after it is
  in its continuation (`OInfo.cont`), the lowering's last block, where a
  cold site's references get their phis (one value per edge from
  `MemLower`, the reloaded one on the slow path).
- **Byte-identical at stage 2** ([#41](https://github.com/benmerckx/hxmc/pull/41)):
  every target's output was what it had been, the lowering run right after
  `MirBuild`. It wrote what the single pass wrote: its blocks and frame slots were
  numbered and ordered among `MirBuild`'s as that pass made them, and the
  continuation got a phi for each variable read there, as the lowering's
  last block did: the instruction helpers' rules look at their operands (a
  phi is not a constant), and so do the null tests (a phi is not known to
  be fresh). Value numbers do not reach the output; block numbers, block
  order, frame slots and phi order do. Stage 3 dropped that reproduction
  (one implementation: the lowering runs after inlining now).
- **Cost**: the port's build by the tool, one thread, nothing cached
  (2026-10-22, a machine shared with other work, the best of three): the
  Mir phase (building, lowering, inlining, escape analysis, the
  optimizer) 4.40 to 4.68 s of CPU (+6%), the whole build 18.8 to 19.4 s
  (within the noise of the runs).

### Decisions

- **Anonymous structures and Dynamic: several operations, Dynamic by
  name stays calls.** `AnonGet` (with the shape hint of an object
  literal of the static type), a write as `AnonTest` (a branch: the inline
  cache's entry has a slot of the field's kind) and `AnonStore` in its
  hit block, its miss path ordinary code (the value boxed, then
  `hx_anon_set_slow`), and `AnonCall` (a method or a closure in a field).
  One generic operation with a shape hint would only move the switch into
  every pass. Dynamic access by name (`hx_dyn_get`, `hx_dyn_set`,
  `hx_dyn_call_field`, by field id when the name is a literal) stays calls
  of the runtime: no object-level pass can do more with them than let the
  object escape, and WasmGC calls the same runtime functions (`hxmc.rt`
  over `Repr`). A shape hint for writes ("Structural field writes", below)
  becomes a field of `AnonTest`.
- **Exceptions and safe regions stay memory-level until WasmGC needs
  them.** `try` is the handler record in a frame slot, `setjmp`, `rt_hcur`
  and `rt_exn`; `throw` a call of `rt_throw`; a blocking C call's safe
  region calls of `rt_blocking_enter`/`rt_blocking_leave`. No object-level
  pass needs to see through them: a function with `try` is not inlined
  (`Inline.candidate`) and its handler's locals live in memory. Stage 5
  made a try region operations for WasmGC only (`MirBuild.gc`: a `Try`
  terminator, the handler's `Catch`, the locals the handler reads
  `VarGet`/`VarSet`; `throw` the IR's own statement in an `IrNode`):
  natively nothing needed them, and the native code stays as it was.
- **`@:hxmc.struct` values and the by-value C ABI: memory-level only.** A
  struct value is the address of its memory (typed `TStruct` in
  `MIns.vty`); `MirBuild` builds C calls and entries from C with structs
  by value (`cCall`, `cEntry`, `CAbi`) as memory code, and `Sroa` replaces
  frame slots (on object-level Mir since stage 4). Struct values as objects (scalar
  replacement of the value itself, methods on structs:
  [lowlevel.md](lowlevel.md)) are a later step none of #34's stages need.
- **`Facts.checkRawAddresses` stays on the IR.** It checks
  `hxmc.unsafe`'s raw heap addresses against the GC points, which are the
  IR's (`Roots`, cold sites) as long as `MirBuild` places the roots. Stage
  4 keeps that placement and only takes away, after optimization, the
  slot stores nothing reads and the frames left unread (`Frames`), which
  makes no raw address safer or less safe: the check stays where the GC
  points are decided.
- **What stays memory-level in `MirBuild`**: the shadow-stack frame and
  the rooted locals' slots (stage 4 prunes them after optimization:
  `Frames`), globals, `hxmc.unsafe`'s
  intrinsics (opaque memory operations inside object-level functions, as
  the plan has it), C calls, and strings' inline helpers (`String.length`,
  `charCodeAt`, `hx_str_eq`, `StringBuf.addChar`): no object-level pass
  needs them before WasmGC, where they become operations or runtime calls.
  The IR's casts are unchecked: no operation (a value keeps the type of its
  first definition).

### Built: stage 3

The pipeline: `MirBuild` (object-level, `objects`), `Inline`, the closures
called where they are made, `Escape`, then `MemLower` (`lower`), `Sroa`,
`Fold`, `Opt` and the back ends.

- **`Inline` at the object level** (part of stage 4 brought forward:
  escape analysis needs the inlined constructors): templates are
  object-level, their size still counted on their lowering (a second
  build), so inlining decides as it did; an inlined copy's operations are
  lowered in the caller (its inline caches the caller's, its null tests a
  block of their own, as a copy's were), and a copy of a function that
  enters a safe region makes the caller's calls stop keeping its frame
  (`MFunc.blocksHere`, which `MemLower`'s calls follow too).
- **`Escape` at the object level** ("Escape analysis", below): an
  allocation is `New` or `Box`, a field `GetField`/`SetField`/`InitField`,
  a type test `TypeTest`/`EnumTag`; a cold site's references are its GC
  point's arguments and its continuation's phis. Its shape matching is
  gone (the allocation's phi of fast and slow paths, constant offsets into
  the header, the write barrier's tests, the spill areas, the enum tag
  table). What stays memory-level until stage 4 is the shadow-stack frame
  and the rooted locals' slots ("cells"), and `Mem.alloc`'s objects, whose
  words the runtime's Haxe code reads and writes with `hxmc.unsafe`.
  Anonymous objects made in the function now have their structural reads
  and writes folded (their fields are known), and a collapse of trivial
  phis that missed a phi whose operand had collapsed first is fixed.
- **`MemLower` after them**: its blocks follow the function's, its frame
  slots the function's; an operation an object-level pass made without a
  continuation gets one.
- **Measured** (2026-10-22, linux-x86_64, against stage 2, which is main's
  output; a machine shared with other work):

| | stage 2 | stage 3 |
| --- | --- | --- |
| the port: sites replaced | 285 | 334 (no function replaces fewer) |
| the tool: sites replaced | 222 | 253 (no function replaces fewer) |
| `EscapeObjects`, `EscapeEnums`, `EscapeClosures` | 14, 10, 7 | 15, 14, 8 |
| the port's binary | 20,620,064 B | 20,611,872 B |
| the tool's binary | 18,174,704 B | 18,166,512 B |
| type tests folded (`HXMC_STATS`; stage 2 counted each type index load and null comparison of the lowering, stage 3 each object-level test) | port 576, tool 272 | port 561, tool 209 |
| mandelbrot, mandelbrot (anonymous objects), binarytrees | 2.671 G, 2.868 G, 8.889 G instructions | the same |
| the port's self-compile (instructions, callgrind) | 36.955 G | 36.930 G (-0.07%), its HXB the same |
| compile time: the port's build by the tool (one thread, nothing cached; seven runs interleaved, best and median) | Mir phase 3.90 s (median 4.17 s), whole build 17.84 s user | Mir phase 3.67 s (median 4.14 s), whole build 17.54 s user; `Escape` itself 525 to 261 ms |
| the port's build, instructions (callgrind) | 102.22 G | 102.05 G (-0.17%) |

Where the Mir phase's instructions went (callgrind, the port's build;
about 21.7 G in all, so 1 G is about 0.19 s of it): `MirBuild` 8.98 G
became `objects` 6.71 G and `lower` 4.01 G (`MemLower` 3.60 G); `Escape`
2.85 G (with the closure-call pass) became 1.25 G; `Inline` 1.16 G became
0.82 G; the inline templates 0.42 G became 0.77 G (each built twice, its
size counted on its lowering); `Opt` 7.52 G became 7.60 G.

What stage 4 is expected to take off the Mir phase, from those numbers:
`Opt`'s value numbering, loop-invariant code motion and condition
propagation on object-level Mir (about half the instructions of the
lowered Mir, 2.05 M against 3.99 M on the port), with only `Fold` and dead
code elimination after `MemLower`: about 2.5 G (0.45 s), and `MemLower`
then lowers less; the byte-identity scaffolding left (a phi per variable
read across blocks, removed again by `removeTrivialPhis`, 0.57 G): about
0.3 G; templates judged on their object-level size, one build each:
0.35 G; fewer barriers and roots after optimization: in register
allocation and instruction selection rather than the Mir phase, as many as
the sites removed. `Escape`'s shape matching is already gone (above).

### Built: stage 4

The pipeline: `MirBuild` (object-level, `objects`), `Inline`, the closures
called where they are made, `Escape`, `Sroa`, `Opt`, `Frames`, then
`MemLower` (`lower`), `Fold`, `Opt.lowered` and the back ends. The output
changes from here (no byte-identity with stage 3).

- **`Opt` on object-level Mir**, before `MemLower`: value numbering, store
  forwarding, loop-invariant code motion and condition propagation see
  objects. A field read (`GetField`) is a load of its field's class (by
  offset, as the lowered loads were), a field write (`SetField`,
  `InitField`) a store a later read of the field takes the value of, an
  Array's length and elements and a NativeArray's elements loads of their
  classes; type tests, enum tags and field addresses are pure; an
  operation that may collect or call (an allocation, a box, a virtual or
  structural call, an array store or push, a reference element read)
  writes every class but immutable memory, as a call does. A null test
  dominated by one of the same value, or by a branch on its comparison
  with null, goes (`condProp`), and a branch on that comparison is
  decided. An operation's continuation stays as `MemLower` needs it
  (`Opt.contOf`: no block merge or jump threading takes it apart; what a
  pass puts between an operation and its jump starts the continuation).
- **What a lowering reads that another may read too becomes operands
  first** (`Opt.operands`), so that it is shared and moved out of loops as
  the lowered Mir's loads were: a write barrier's nursery bounds (its
  last two arguments, `OInfo.young`; a store's own, shared with nothing,
  go back to `MemLower`, which loads them after the store as before), an
  Array's header (kind, length, storage) and widened index for its element
  reads and writes and its pushes (`OInfo.ops`), a NativeArray's widened
  index. `MemLower` reads an Array literal's storage again only after a
  call that may collect (`MemLower.epoch`), and a structural read's cache
  test reuses the type index its shape test read.
- **After `MemLower`**: allocation folding (`Fold`), then `Opt.lowered`:
  the jump threading of the lowered boolean phis (`a && b`, a type test's
  result branched on), block merges, copies, dead code; no value
  numbering, LICM or condition propagation.
- **Write barriers after optimization**: `MemLower` places them, after
  `Opt`, for the stores left; a reference stored into an object allocated
  since the last point where a collection may happen (in the block, or a
  block entered only from it) gets none (`Opt.freshTargets`,
  `OInfo.fresh`; the store still publishes what it stores,
  `MIns.release`). The object must be young: the runtime allocates an
  object of a quarter of the nursery or less there, and the nursery is now
  4 KB at least (`RT_MINOR_KB`), so objects of up to 63 slots qualify.
- **Roots after optimization** (`Frames.hx`): `Roots` still gives the
  rooted locals their shadow-stack slots on the IR, but after `Opt` (which
  takes a stored value back where nothing collects in between) a slot
  store no load can see any more goes (a liveness of the slots over the
  graph; `HXMC_FRAMES_LIVE=0`: only the slots nothing reads), and a frame
  left without loads is not pushed at all (its cold sites push their
  spills on their slow paths); a cold site spills only the references read
  after it (its continuation's phis, `MemLower.spillNeed`). Functions with
  a `try` keep their frames.
- **Inline templates at the object level, built once**: a template's size
  is counted on its object-level Mir, an operation counting what `MemLower`
  makes of it outside slow paths (`Inline.size`, `opSize`, fitted on the
  port's 4,782 templates against their lowering: 1 is judged otherwise at
  the flat limit of 16, 9 at the loop limit of 48).
- **No trivial phis made**: `MirWriter` reads a sealed join's
  predecessors first and makes a phi only where their values differ or a
  read came back to the join (Braun et al.'s marker); `removeTrivialPhis`
  is left with the loops' phis.
- **Measured** (2026-10-22, linux-x86_64, against stage 3, which is
  main's output; a machine shared with other work):

| | stage 3 | stage 4 |
| --- | --- | --- |
| the port: sites replaced | 334 | 333 (`Genswf.build_swf9`'s `GlobalTypePath`: its constructor is no longer inlined, one of the templates judged otherwise) |
| the tool (the same source): sites replaced | 259 | 259 |
| the port: write barriers left out (`Opt.freshTargets`), slot stores and frames dropped (`Frames`) | | 1,206 barriers; 1,680 slot stores, 20 frames |
| the port's binary | 20,611,872 B | 20,427,552 B (-0.9%) |
| the tool's binary (the same source, built by each) | 18,175,200 B | 17,982,688 B (-1.1%) |
| mandelbrot, mandelbrot (anonymous objects), binarytrees | 2.671 G, 2.868 G, 8.889 G instructions | 2.179 G, 2.179 G, 8.889 G |
| the port's self-compile (instructions, callgrind) | 36.930 G | 36.852 G (-0.21%), its HXB the same (HxbCmp, 518 modules) |
| the port's build, instructions (callgrind) | 102.09 G | 98.64 G (-3.4%) |
| compile time: the port's build by the tool (one thread, nothing cached; runs interleaved, best and median) | Mir phase 3.94 s (median 4.21 s), whole build 17.02 s user (median 18.36 s); nine runs | Mir phase 3.64 s (median 3.90 s), whole build 17.25 s user (median 17.65 s) |

Where the Mir phase's instructions went (callgrind, the port's build):
about 21.6 G became 18.9 G (-2.75 G, -13%). `Opt` 7.43 G became 4.80 G
on object-level Mir and 1.09 G after `MemLower` (`Opt.lowered`, mostly the
threading's scan and block merges); `MirBuild.objects` 6.80 G became
6.39 G, its `removeTrivialPhis` 0.61 G 0.16 G; `lower` 4.10 G became
3.41 G; the inline templates 0.73 G became 0.29 G; `Inline` 0.81 G 0.85
G; `Escape` with the closure-call pass 1.23 G 1.22 G; `Frames` is new,
0.35 G; `Fold` 0.42 G 0.44 G; `Sroa` 0.10 G 0.02 G. Outside it, register
allocation 19.09 G became 17.76 G and instruction selection 5.67 G 5.58 G
(fewer barriers and frames); `Layout.order` 0.03 G became 0.27 G (it now
builds the CFG's analyses `Opt` used to leave it).

### Built: stage 5, WasmGC from object-level Mir

The pipeline (`wasmgc.GcGen`): `Reach`, then per function (in parallel)
`MirBuild` in its WasmGC mode, `Inline`, the closures called where they are
made, `Inline.devirtualize`, `Escape`, `Opt`; `Reach` again over what the
Mir still calls; then `MirGen` writes each function into `GcModule`'s
module. `wasmgc/IrOpt` (646 lines) and the IR walker's statements and
second emission (`FuncGen.emit`, `refine`, the control flow, 340 lines)
are gone; `FuncGen` keeps the IR's expressions and leaf statements, which
`MirGen` writes the operations it does not write itself with.

- **`MirBuild.gc`**: no `Prep`, no roots or frame slots; a field is at
  its index (`at`: an Int's or Bool's twice it, as an enum's arguments);
  sites keyed by name in `Escape` (no type indices). What is memory-level
  natively (globals, strings, type values, the runtime's intrinsics and
  host calls, `Mod`/`FMod`/`LDiv`/`LMod`, float to int conversions, field
  addresses, `throw`, `SSetGlobal`, structural writes) is an `IrNode`: the
  IR's expression or statement, its non-literal operands evaluated first
  and standing in it as placeholder locals (`OInfo.ph`), so that WasmGC's
  representation of them stays `FuncGen`'s. A `try` is a `Try` terminator
  (the body and the handler as its targets) and the handler's `Catch`; the
  locals `memLocals` finds the handler reads are `VarGet`/`VarSet`, which
  `Opt` treats as loads and stores of their own class. An if on a
  constant builds only the branch taken (what `IrOpt.live` did: another
  target's code).
- **`Opt`** runs as natively (`operands` aside: a lowering's operands);
  a type test's identity is its class (`Opt.same`: no type indices), and
  an `IrNode` is pure only when it is a literal, a type value or a global
  read.
- **`MirGen`** (extends `FuncGen`): the control flow structured as
  `wasm/WasmGen` structures linear memory's (the dominator tree, merge
  children in blocks, loop headers in loops), a loop's exits after the
  loop rather than inside it at their branch (loops one after another
  nested otherwise, which V8's baseline compiler pays for at every level:
  the port's `--version` took 0.47 s instead of 0.29), a `try` a legacy try
  around its body's dominator subtree whose catch branches to the
  handler's block. Each value a local of the wasm type its operation gives
  it (a phi's: what its operands share; a value used once by the next
  operations that push it, left on the stack instead, `stackify`; values
  made and used in one block share locals by kind); an object made with
  fields (an enum value, a closure, a box, an anonymous object, an Array
  literal) at its last field's initialization (`struct.new`,
  `array.new_fixed`); a field read or write of an untyped value used so
  more than once in a block cast once (`classOperand`); explicit null tests
  (`NullCheck`, `nn_any`) and the operations after them unchecked.
- **Reachability over the Mir** (`Uses.summary`): `Reach`'s second pass
  reads each function's IR with every callee inlined into it (to any
  depth, a closure called where made, a method devirtualized) followed into
  its body, the parameters replaced by the arguments (`findSinks` still
  sees the names passed on), and the calls the Mir no longer makes
  dropped.
- **Inlining**: the native templates and limits (WasmGC's flat 4, loop
  16); in a loop, a callee that an object made here meets (passed one, or
  returning one it makes) up to the native loop limit of 48, judged on
  what `MirGen` makes of it (`Inline.size(f, true)`: no barriers or nursery),
  and looked at again in the next round when an inlined callee made the
  object (`Inline.objectsMeet`). That is IrOpt's rule ("calls inlined where
  that lets scalar replacement happen") on Mir: mandelbrot with anonymous
  objects 1.00 s to 0.72 s.
- **Devirtualization** (`Inline.devirtualize`, both pipelines): a virtual
  call on an object made in the function calls the class's implementation
  of the selector directly (the dispatch row's function), when it is of
  the function's module (its key covers it), then inlined where it may be.
  It finds little: in the port natively none (its binary the size of stage 4's,
  20,427,552 bytes), in the port as WasmGC one.
- **Measured** (2026-10-22, against main's IrOpt path, 143c42b's source;
  node 22, a machine shared with other work; the port's runs medians of 5
  interleaved, HaxeBenchmarks medians of 5):

| | main (IrOpt) | stage 5 |
| --- | --- | --- |
| the port as a WasmGC module | 10,849,453 B (gzip -9 3,804,540) | 9,759,687 B (-10.0%; gzip 3,187,237, -16.2%) |
| its self-compile to HXB (`--interp --no-output`) | 19.35 s, 1026 MB | 17.94 s (-7%), 951 MB; the same archive (HxbCmp, 518 modules) |
| a small compile (`moduleload.TryCatch` to `--interp`), `--version` | 2.38 s, 639 MB; 0.30 s, 116 MB | 2.49 s, 407 MB; 0.31 s, 151 MB |
| the port's WasmGC build by the tool (typing cold) | 10.9 s user, 1,046 MB | 12.3 s user, 1,578 MB (every function's Mir kept until the module is written) |
| allocation sites replaced in the port | (IrOpt's) | 1,019 |
| HaxeBenchmarks, WasmGC s: alloc, bcrypt, binarytrees, json | 2.74, 7.93, 1.07, 0.92 | 2.78, 3.05, 1.10, 0.94 |
| mandelbrot, mandelbrot_anon, nbody | 0.76, 1.00, 1.16 | 0.73, 0.72, 1.23 |
| sha256, sha512, formatter_noio | 0.44, 0.09, 11.23 | 0.28, 0.10, 11.13 |
| their modules, KB | 14, 135, 12, 64, 14, 13, 15, 124, 124, 539 | 14, 135, 12, 65, 14, 14, 15, 125, 125, 558 |

(nbody's runs spread 1.0-1.35 s in both; main's bcrypt was 3.1 s in the
table of docs/plans/targets.md, and 7.9 s here in every run: what IrOpt
did to it on today's main was not looked into, the Mir path does not have
it.) `make wasmgc-check` passes (31 programs); the port as a WasmGC module
compiles itself to the native port's archive.

### Stage 6: WasmGC's go/no-go again

Recorded in [targets.md](targets.md) ("WasmGC", "Object-level Mir and the
call again"): **still not yet** for browser builds. One optimizer now
serves both paths and WasmGC's modules got smaller (the port 10% raw, 16%
gzipped), but what kept the call at "not yet" is unchanged by it: the
benchmarks where WasmGC is behind linear memory (formatter_noio 11.1 s
against 8.4, alloc 2.8 against 1.8: the engine's collector and casts, not
the optimizer), the first frame of large modules, WebKit (not measurable
here: no browser in this environment).

### Stage 7 and what else #34 lists

- **#15's optimization tier for interpreted macros: not built, decided
  against for now.** #15 is an open draft; the tier needs its interpreter.
  The split is there for it: a function's object-level Mir goes through
  `MirBuild.lower` without the optimizer when `o.opt` is off, which is the
  tier's cold path (`HXMC_OPT=0` today, per build); a per-function switch
  is a few lines in `Driver.compileFunc` once #15 lands.
- **Type-test folding**: at the object level since stage 3 (`Escape`: a
  type test or enum tag on an object made here; the port 561).
- **Devirtualization**: built (above), little to find.
- **Exceptions at the object level**: for WasmGC (above); natively
  decided to stay memory-level ("Decisions").
- **`Facts.checkRawAddresses`**: stays on the IR ("Decisions").

## Escape analysis

Allocate objects that never escape their function on the stack, or
replace them by their fields in registers (scalar replacement): temporary
iterators, small structs and anonymous objects, closures called in place,
boxed values. Go relies on this to keep short-lived objects off its heap.
It removes allocation, write barriers and GC pressure at once. Stack-allocated
objects must stay visible to the GC when they hold references (as roots,
via the shadow stack), and must never be stored where a heap object or
another thread can see them.

### Built: phase 1, intraprocedural scalar replacement

`hxmc/src/hxmc/Escape.hx`, on object-level Mir after inlining and before
`MemLower` ("Object-level Mir", above; `HXMC_ESCAPE=0` turns it off;
`HXMC_ESCAPE_LOG=1` says, per allocation analyzed, whether it is replaced
and else why not; `HXMC_ESCAPE_DUMP=<symbol>` prints a function's Mir
before and after). What it replaces:

- allocations (`New`: class instances, anonymous objects, enum values,
  closures, the boxes of captured variables, `Mem.alloc`'s objects of the
  runtime) and boxings of an Int, Float or Int64 into a Dynamic (`Box`,
  read back by `Unbox`);
- when every use of every alias is a field read or write (`GetField`,
  `SetField`, `InitField`; for `Mem.alloc`'s objects `hxmc.unsafe`'s loads
  and stores at constant offsets and `Mem.setRefBarrier`), a null test
  (`NullCheck`, a comparison), a cold site's GC point keeping it on the
  shadow stack across its slow path, a store into a shadow-stack slot, or an
  unboxing. Aliases are the value, its copies, phis of aliases only (a cold
  site's continuation phi among them: the same object after the GC point),
  and what is loaded back from such slots ("cells": the store reaching each
  load is found by SSA construction over the slot; a collection moves an
  object but keeps what the slot refers to, and a replaced object is never
  made);
- allocations meeting at a phi form a group (one layout) replaced by one set
  of variables: the loop-carried objects of mandelbrot. That is right only
  where every use is of the group's latest instance, which is checked (the
  alias's instance and the group's reaching allocation are the same value,
  phis of one block compared coinductively); an object's allocation counts
  from its first use, so its constructor's arguments may read the previous
  instance;
- fields holding references (their types; for `Mem.alloc`'s objects the
  type's pointer map, from `Facts`) are not SSA values, which a collection
  would leave pointing at an object's old place, but new slots of the
  function's shadow-stack frame (a function without a frame keeps such
  objects); the others are SSA values, phis inserted as `Sroa` does;
- closures called where they are made: a `ClosureCall` through a closure
  whose function is known (made in the function, or loaded from a slot that
  only holds closures of that function) becomes a direct call, inlined when
  the closure does not certainly escape otherwise and the function is of the
  same module (its body and its callees' are in the module's key); then the
  closure is an object like any other;
- again after a replacement: an object stored into a replaced object's field
  lands in a frame slot, and may go in turn (phase 1 otherwise keeps an
  object stored into another);
- frames left holding only nulls are not pushed.

Before that, what is known of any alias folds, escaping or not: its type
tests (`TypeTest`; `EnumTag`, the constructor's tag, which is in
`ENewEnum`'s fingerprint), its null tests, and an anonymous object's
structural reads and writes (`AnonGet`, `AnonTest`: its fields are known,
a field of the access's kind is read or written in place, the others take
the slow path), so the slow paths, which take the object, go first. A
screen keeps the analysis to
the allocations that may stay (a use outside slow paths that certainly
escapes: a call, a return, a heap store, a phi with a constant, parameter or
call result) and folds the tests of the others on the spot; `f.allocs`
(counted by MirBuild and the inliner) skips functions that allocate
nothing. Checked by the corpus cases `EscapeObjects`, `EscapeEnums` and
`EscapeClosures` (phis, loops, an exception, two names for one object, a
write after a read, the previous instance, escapes of each kind), every
lane, and `HXMC_ESCAPE_HASH`/`HXMC_ESCAPE_NO` for bisecting a miscompilation
(how the reference fields' rooting was found to be needed: the tool built
by itself crashed under `RT_VERIFY=1` and a 64 KB nursery).

Measured (2026-10-19, against `HXMC_ESCAPE=0` with the same tool):

| | off | on |
| --- | --- | --- |
| the port: sites replaced | | 230 (116 anonymous objects, 81 closures, 18 class and enum instances, 12 Dynamic boxes, 4 captured-variable boxes), 452 type tests folded |
| the port's binary | 19,501,680 B | 19,534,448 B (+0.17%: closures inlined) |
| the tool's binary | 17,107,512 B | 17,148,472 B (+0.24%), 180 sites |
| the port's self-compile (instructions, callgrind) | 36.228 G | 36.220 G (-0.02%), 4,889 MB allocated either way |
| haxe-formatter typed by the port | 4.0846 G | 4.0819 G (-0.07%), 588 / 587 MB allocated |
| mandelbrot (classes) | 9.51 G instr, 4.5 GB allocated, 0.71 s | 2.67 G, nothing allocated, 0.40 s |
| mandelbrot (anonymous objects) | 18.25 G, 6.0 GB, 1.16 s | 2.87 G, nothing, 0.40 s |
| binarytrees, alloc | 8.456 G, 5.701 G | the same (their objects escape) |
| compile time: the port's build by the tool (instructions, one thread, objects not cached) | 60.64 G | 63.45 G (+4.6%: the pass 2.05 G, the closures' inlining most of the rest) |
| compile time: haxe-formatter's build | 4.396 G | 4.328 G (-1.5%: the pass costs 6% of code generation, register allocation saves more) |

The compiler's own allocations nearly all escape: of the allocations
analyzed in the port (those the screen keeps), the reasons were: a phi
with another value (2,400), stored into an array element or a new object
(2,800), into a slot a runtime call takes (640, arrays' growth), into
another object's field (500), a constructor that is not inlined
(`GlobalTypePath`, `Expr`, `TExpr`, `JsonField`, ... about 900), a virtual
call (290), a return (400), layouts that differ at a phi (260), a
structural field write (`hx_anon_set_slow`, 54), not the latest instance (50).

On object-level Mir (stage 3 of "Object-level Mir", 2026-10-22, against
the memory-level pass it replaced): the port 285 to 334 sites (no function
replaces fewer), the tool 222 to 253; mandelbrot, mandelbrot with anonymous
objects and binarytrees the same instructions; the pass's own time on the
port's build 525 to 261 ms.

### Left

- Stack allocation (phase 2): objects passed to calls that do not keep
  them: a non-inlined constructor or method taking `this` (the largest group
  in the port), `Std.string` and friends. Needs per-function summaries of
  which parameters escape (interprocedural), and the object in the frame
  as a root region the collector scans (its header too, for the type).
- Returned objects (factories not inlined: `rect(w, h)`, `Some(x)`): return
  values replaced by their fields (multiple results), or inlining driven by
  the escape of the result.
- Objects merged with null or another value at a phi (`var x = null; if (c)
  x = new X()`): materializing at the merge (partial escape analysis).
- Objects held in replaced objects beyond one level, but by the second
  pass; arrays (any growth goes to the runtime).
- Virtual calls on an object of known type: the type index is known, the
  method table could be read at compile time (devirtualization), then the
  method inlined.
- Structural field writes to an object of an unknown shape: `SAnonSet` has
  no shape hint (`anonGet` has one), so they go through an inline cache (on
  an anonymous object made in the function, they fold).
- The analysis' cost (the screen still lets through many allocations that
  escape: phis with loaded values, stores of reloaded values).

## Allocation folding

Built (`hxmc/src/hxmc/Fold.hx`, on Mir after `MemLower`, `Escape`, `Sroa` and `Opt`
having run on object-level Mir; `HXMC_FOLD=0` turns it off): an allocation of a constant size that
follows another on a straight line, with nothing between them that could
collect or allocate (no call, no use of `rt_young_ptr`), becomes part of
it. One test of the room left and one bump for both; the second's header is
written where the first's object ends, its address the first's plus its
bytes; the first's slow path allocates both (the stub of the summed size)
and writes its own header again (the runtime makes a record of the size it
is given). The second's slow path, its spills and reloads, go: its join's
phis keep the fast path's values. A chain folds into its first allocation
(`Node(Leaf(v), Leaf(v + 1))`: one allocation of 56 bytes), up to 4096
bytes. The objects are separate from the start (each its header); the
collector copies them apart.

Measured (2026-10-21, Xeon E-2356G, against `HXMC_FOLD=0` with the same
tool; the machine loaded by other work): the port folds 8052 allocations
(the tool 6517); its binary is 2.6% smaller (19.89 to 19.38 MB; the tool
17.10 to 16.71 MB); its self-compile runs 0.7% fewer instructions (32.693 to
32.472 G), about 1% fewer cycles.

What stops the others (`HXMC_FOLD_WHY=1`, the port's build, counted where
the code is): a call that may collect (11,028), a merge or a branch with no
allocation after it (8,000), an allocation in one branch (3,168), one after
a merge every way reaches (2,017), a call that cannot collect (3,900, most of
them constructors that do not allocate: `core.Expr`, `haxe.Exception`,
`TExpr`), a size known only at run time first, an allocation after its
length test's merge (1,108: `new Bytes(new BytesData(n))`'s shape).
Measured and not kept: folding across the calls that cannot collect (the
second's header written right after the first's allocation): 952 more
folds (the next stop is mostly a call that collects), the self-compile ±0,
the port 21 KB larger. Left: those after a merge, and those of a size known
at run time (`Bytes.shared` does Bytes' by hand), likely as small.

## Loads out of loops

`Opt.licm` moved only loads that cannot fault (globals, immutable memory at
a symbol, thread-local variables). A load of a field, an array's header or
immutable memory (a NativeArray's length) moves too when the loop does not
write that memory and its object is not null before the loop: just
allocated (`Opt.fresh`: the nursery's bump or the slow path's call, a merge
of those), dereferenced on every way to the loop, or a merge of objects
that are on their edges. A loop that may collect writes every class of
memory but immutable memory (its calls' kill masks): no reference leaves it
to live across a GC point. Measured: a Bytes' `b` in a loop of
`get`/`set`: the loop as fast as over the bare NativeArray (2.669 to 2.563 G
instructions); the self-compile: the same (its loops call, or load what
they write).

## Debugging information

Built (docs/hxmc.md, "Debugging"): frame pointers by default on x86-64;
unwind tables always, from the emitters' frame records (`Unwind.hx`): ELF
`.eh_frame` and `.eh_frame_hdr` (with the runtime object's C code), Mach-O
`__eh_frame`, Windows `.pdata`/`.xdata` for x86-64 and arm64; with
`-debug`, DWARF 4 lines and subprograms from the typed AST's positions on
ELF, Mach-O and PE, and a COFF symbol table on Windows. Checked by
`UnwindTables` (the system unwinders against the frame-pointer chain) and
`DebugCheck` (gdb/lldb, readelf, llvm-readobj, llvm-dwarfdump).

Built since: call stacks (docs/hxmc.md, "Call stacks"). The positions are
recorded in every native build (they change no code), and a program that
reads stacks (`haxe.CallStack`, an exception's `stack`) gets a compact
table of its functions and line rows (`StackTable.hx`, written from the
same `FuncRec.lines` as `.debug_line`), which one runtime facility
(`hxmc.rt.Stacks`) reads: a walk up the frame records checked against the
table, names and lines from it, for `haxe.CallStack`, exception stacks and
the report of an uncaught exception or a null access (with `-D
hxmc.stacks` in every program). Upstream's stack tests pass natively. The
crash-report item is mostly this: what is left of it is below.

Left:

- Symbolised crash reports beyond exceptions: a fault that is not a null
  access (SIGSEGV elsewhere, SIGBUS, SIGILL, an access violation; a stack
  overflow) still ends the process with the system's report; its handler
  could walk from the faulting context's frame pointer and print
  `Stacks`' names (async-signal-safe: no allocation, the table's strings
  written directly). On by default only with the table.
- The sampling profiler: a timer signal (SIGPROF; a thread suspending the
  others on Windows) recording the interrupted frames with the same walk
  (no allocation, the cache of known return addresses), names resolved
  after the run from the table or the symbol table.
- Stacks without frame pointers (`-D hxmc.no-frame-pointers`) and inlined
  frames: an unwinder reading the unwind tables Unwind.hx writes (a CFA
  rule per offset: the emitters' frame records) instead of the frame
  pointers, and the inliner's call sites as inlined entries in the table
  (and `DW_TAG_inlined_subroutine`).
- WebAssembly: no stacks yet (a module cannot read its own stack). A
  shadow call stack (each function pushing an id and the call's line on
  a stack of its own) would give them at a cost to every call; a host
  import reading the engine's `Error().stack` (wasm function indices and
  offsets, which the name section and a code-offset-to-line map would
  name) only under JavaScript hosts.

- Windows PDB (CodeView): the Visual Studio debugger and WinDbg read no
  DWARF. A PDB is an MSF container of streams (PDB info, TPI/IPI type
  records, DBI with a module per object, its symbols S_GPROC32 and its C13
  line subsections, the public and global symbol hash tables, section
  contributions) referenced by an RSDS debug directory entry; llvm's
  `pdbutil`/`lld-link` are the references. Line tables and functions without
  types would make breakpoints and backtraces work.
- Mach-O `__unwind_info`: libunwind and lldb read `__eh_frame` (a linear
  search without an index); compact unwind entries in DWARF mode (each
  pointing to its FDE) would give the binary search table, ld64's form.
  The frame-pointer encodings need the callee-saved pairs right below the
  record, which the arm64 layout does not keep.
- Variables: `DW_TAG_formal_parameter`/`variable` with locations (the
  register allocator's intervals per value; the frame's slots; references in
  shadow-stack slots), types (DW_TAG_base_type, structures for classes from
  the layouts), and a language number: debuggers then print arguments and
  locals. `DW_TAG_inlined_subroutine` for inlined calls (the inliner knows
  the call site: Inline.run), columns (positions have them).
- perf: `perf --call-graph dwarf` (not checked here: no usable perf in the
  development container) and the JIT's frames (native macros: `Jit.hx`
  could register its code's FDEs with `__register_frame`).
- WebAssembly: DWARF in custom sections (`.debug_line` with code offsets)
  for the browsers' and wasmtime's debuggers.

These four (PDB, `__unwind_info`, variables, wasm DWARF) are now Next on
the roadmap. After them: a sampling profiler with symbols (on the stacks'
walk and table above), and the rest of the symbolised crash reports
(faults other than null accesses, above); the profiler feeds a frame
timeline (frames, layout, GPU, collections) for UI programs.

## Smaller items

- Thread-locals: inline macOS's TLV thunk call (a call per function
  today) and trim Windows arm64's three loads per function.
- From the math work ([math.md](math.md)): a switch on small integers as a
  jump table (sin/cos/tan's quadrant), if-conversion (cmov), splitting
  live ranges around rare calls.
