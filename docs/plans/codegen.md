# Plans: code generation

Open work on the optimizer, the back ends and debugging information. The
pipeline as built: [hxmc.md](../hxmc.md#pipeline).

## Escape analysis

Built: intraprocedural scalar replacement on object-level Mir
(`Escape.hx`): objects, enum values, closures called in place and boxes
that never leave their function become their fields. Left:

- **Stack allocation** for objects passed to calls that do not keep them:
  a constructor or method that is not inlined (the largest group in the
  port), `Std.string`. Needs per-function summaries of which parameters
  escape, and the object in the frame as a root region the collector
  scans.
- **Returned objects** (factories such as `rect(w, h)`, `Some(x)`): results
  replaced by their fields, or inlining driven by the result's escape.
- **Objects merged with null at a phi** (`var x = null; if (c) x = new X()`):
  materialize at the merge (partial escape analysis).
- **Nested objects** beyond what the second pass catches; arrays (growth
  goes to the runtime).
- **Structural writes to an object of unknown shape**: `SAnonSet` has no
  shape hint, unlike `anonGet`.
- **The analysis' cost**: the screen still lets through many allocations
  that escape.

## Allocation folding

Built (`Fold.hx`): consecutive allocations of constant size share one
room test and bump. Left: allocations after a merge, and those of a size
known only at run time (`Bytes.shared` does Bytes' by hand). Folding across
calls that cannot collect was measured and not kept: no speed gain, a
larger port.

## Debugging

Built: frame pointers, unwind tables, DWARF lines with `-debug`, call
stacks ([hxmc.md](../hxmc.md#debugging)). Next, in order:

- **Windows PDB** (CodeView): Visual Studio and WinDbg read no DWARF. An
  MSF container (PDB info, TPI/IPI, DBI with a module per object, S_GPROC32
  and C13 lines, the symbol hash tables) referenced by an RSDS debug
  directory entry. Line tables and functions without types make
  breakpoints and backtraces work. References: llvm's `pdbutil` and
  `lld-link`.
- **Mach-O `__unwind_info`**: libunwind and lldb search `__eh_frame`
  linearly. Compact entries in DWARF mode give ld64's binary search table.
  The frame-pointer encodings need callee-saved pairs right below the
  record, which the arm64 layout does not keep.
- **Variables**: `DW_TAG_formal_parameter` and `variable` with locations
  (register allocator intervals, frame slots, shadow-stack slots), types
  from the layouts, a language number; `DW_TAG_inlined_subroutine` for
  inlined calls; columns.
- **DWARF for WebAssembly** in custom sections, for browsers' and
  wasmtime's debuggers.

Then:

- **A sampling profiler**: a timer signal (a suspending thread on Windows)
  recording frames with the call-stack walk, names resolved after the run.
  It feeds a frame timeline for UI programs.
- **Crash reports** for faults other than null accesses (SIGSEGV
  elsewhere, SIGBUS, stack overflow): walk from the faulting frame and
  print names, async-signal-safe.
- **Stacks without frame pointers** and with inlined frames: an unwinder
  over the unwind tables, inlined entries in the table.
- **Stacks on WebAssembly**: a shadow call stack (a cost on every call), or
  under JavaScript hosts the engine's `Error().stack` mapped through the
  name section.
- **perf**: `--call-graph dwarf` unchecked; code generated at run time would
  register its FDEs with `__register_frame`.

## Smaller items

- Thread-locals: inline macOS's TLV thunk call (one per function today);
  trim Windows arm64's three loads per function.
- For math: a switch on small integers as a jump table, if-conversion
  (cmov), splitting live ranges around rare calls.
- Devirtualization finds little; type-test folding is done in `Escape`.
