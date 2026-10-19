# Code generation and optimizations

The pipeline as built: [docs/hxmc.md](../hxmc.md), "Pipeline".

## Escape analysis

Allocate objects that never escape their function on the stack, or
replace them by their fields in registers (scalar replacement): temporary
iterators, small structs and anonymous objects, closures called in place,
boxed values. Go relies on this to keep short-lived objects off its heap.
It removes allocation, write barriers and GC pressure at once, and is
likely the largest remaining gain for allocation-heavy code (alloc,
binarytrees, closure-heavy code, the port's own temporaries), more than
any tuning of the collector. hxmc's SSA IR and inliner make it practical:
inlining first exposes most non-escaping allocations, and scalar
replacement of frame slots already exists for struct values (`Sroa.hx`).
Stack-allocated objects must stay visible to the GC when they hold
references (as roots, via the shadow stack), and must never be stored
where a heap object or another thread can see them.

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
