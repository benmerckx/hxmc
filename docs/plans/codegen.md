# Code generation and optimizations

The pipeline as built: [docs/hxmc.md](../hxmc.md), "Pipeline".

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

`hxmc/src/hxmc/Escape.hx`, on Mir after inlining and before `Sroa` and `Opt`
(`HXMC_ESCAPE=0` turns it off; `HXMC_ESCAPE_LOG=1` says, per allocation
analyzed, whether it is replaced and else why not). What it replaces:

- objects MirBuild allocates inline (`MirBuild.alloc`: class instances,
  anonymous objects, enum values, closures, the boxes of captured
  variables), recognized by the allocation's shape (the phi of the fast
  path's address and the slow path's stub call), and the runtime's boxing of
  an Int, Float or Int64 into a Dynamic (`hx_box_int`, `hx_box_float`,
  `hx_box_i64`, read back by `hx_unbox_*`);
- when every use of every alias is a field read or write at a constant
  offset (the header's type index included), a null test, the write
  barrier, a store into a shadow-stack slot or cold-site spill area, or an
  unboxing. Aliases are the value, its copies, phis of aliases only, and
  what is loaded back from such slots ("cells": the store reaching each
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
- fields holding references (the type's pointer map, from `Facts`) are not
  SSA values, which a collection would leave pointing at an object's old
  place, but new slots of the function's shadow-stack frame (a function
  without a frame keeps such objects); the others are SSA values, phis
  inserted as `Sroa` does;
- closures called where they are made: an indirect call through a closure
  whose function is known (made in the function, or loaded from a slot that
  only holds closures of that function) becomes a direct call, inlined when
  the closure does not certainly escape otherwise and the function is of the
  same module (its body and its callees' are in the module's key); then the
  closure is an object like any other;
- again after a replacement: an object stored into a replaced object's field
  lands in a frame slot, and may go in turn (phase 1 otherwise keeps an
  object stored into another);
- frames left holding only nulls are not pushed.

Before that, the type index of any alias is known, escaping or not: inline
caches' tests, enum switches (`Escape.ctorTags`: a constructor's tag; the
enum tag is in `ENewEnum`'s fingerprint) and null tests on it fold, so their
slow paths, which take the object, go first. A screen keeps the analysis to
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
- Structural field writes: `SAnonSet` has no shape hint (`anonGet` has one),
  so writes to an anonymous object go through an inline cache and escape.
- The analysis' cost (the screen still lets through many allocations that
  escape: phis with loaded values, stores of reloaded values).

## Debugging information

Built (docs/hxmc.md, "Debugging"): frame pointers by default on x86-64;
unwind tables always, from the emitters' frame records (`Unwind.hx`): ELF
`.eh_frame` and `.eh_frame_hdr` (with the runtime object's C code), Mach-O
`__eh_frame`, Windows `.pdata`/`.xdata` for x86-64 and arm64; with
`-debug`, DWARF 4 lines and subprograms from the typed AST's positions on
ELF, Mach-O and PE, and a COFF symbol table on Windows. Checked by
`UnwindTables` (the system unwinders against the frame-pointer chain) and
`DebugCheck` (gdb/lldb, readelf, llvm-readobj, llvm-dwarfdump). Left:

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
the roadmap. After them: a sampling profiler with symbols, and symbolised
crash reports on every target; the profiler feeds a frame timeline
(frames, layout, GPU, collections) for UI programs.

## Smaller items

- Thread-locals: inline macOS's TLV thunk call (a call per function
  today) and trim Windows arm64's three loads per function.
- From the math work ([math.md](math.md)): a switch on small integers as a
  jump table (sin/cos/tan's quadrant), if-conversion (cmov), splitting
  live ranges around rare calls.
