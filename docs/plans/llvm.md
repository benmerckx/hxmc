# LLVM as an optional back end (experimental)

`-D hxmc.llvm[=O1|O2|O3|Os]` (or `HXMC_LLVM=1`) compiles each module's
functions through LLVM: memory-level Mir, after `MemLower` and the passes on
it, is written as textual LLVM IR (`hxmc/src/hxmc/LlvmGen.hx`), an external
clang compiles it for the target's triple, and the object it writes is read
back (`MachOReader`, `ElfReader`, `CoffReader`) and appended to the module's
object. hxmc's own linkers link as before. `-D hxmc.llvm-rt`
(`HXMC_LLVM_RT=1`) takes the runtime's modules too. The `.ll` files are kept
in `<out>.hxmc/llvm/`.

clang: `HXMC_CLANG`, else `clang` on the path. Apple's clang (Xcode's
command-line tools) has every back end hxmc targets, so it writes Mach-O,
ELF and COFF objects, cross-compiling from macOS. `HXMC_LLVM_FLAGS` adds
arguments (for example `-mllvm ...`).

## Why Mir after MemLower

It is SSA over i32, i64 and double, with explicit loads, stores, calls and
the shadow stack: almost one LLVM instruction per Mir instruction, and the
collector's roots are already in memory (frame slots linked from `rt_sp`),
so LLVM's register allocation cannot hide a reference from it. hxmc's own
passes (inlining, escape analysis, SROA, allocation folding) still run
first; LLVM adds its scalar and loop optimizations, instruction
scheduling and register allocation.

## The mapping

- Addresses are i64; each load and store turns one into a pointer
  (`inttoptr`), alignment 1 (the hardware's unaligned accesses).
- Program-wide numbers (`Const` with a symbol: type indices, field ids,
  offsets) are the address of an `extern_weak` global turned into an
  integer: LLVM must assume nothing of it, not even that it is not null.
  The linker resolves them through the GOT.
- `setjmp` is a `returns_twice` call. The values live into a handler block
  go through volatile frame slots, stored where they are made and read
  where code reachable from a handler uses them: longjmp does not restore
  the registers LLVM may have reused after setjmp.
- Thread-locals on Apple: `hxmc_tls_base()` (declared `memory(none)`, so
  LLVM calls it once per function) plus the variable's offset in the TLS
  template, a word of the module's object the linker fills in
  (`RSecRel32`), as the native code does. Elsewhere LLVM's own TLS access
  (local-exec on Linux).
- `MirWriter.special` calls (atomics, float32 conversions, floor and ceil)
  are LLVM atomics and intrinsics; `F2I` is `fptosi.sat` (arm64's
  `fcvtzs`).
- Null accesses: LLVM drops a load whose value is unused, so the fault
  that makes a null access throw would not happen. The explicit tests of
  `hxmc.null-checks` are on by default with LLVM.
- Frame records always (`frame-pointer=all`); no unwind tables.
- arm64: no `ldp`/`stp` pairing (`-aarch64-enable-ldst-opt=0`). A pair load
  partly overlapping an earlier pair store defeats store-to-load
  forwarding on Apple's cores: nbody ran 1.75x slower with it.

Functions `LlvmGen.accepts` refuses go through the native back end into
the same object: structs by value in the C ABI (arguments, results,
entries from C), vectors (`hxmc.simd`), Apple arm64 C calls with stack
arguments (packed by size).

## Status (macOS arm64, Apple clang 21, 2026-11-08)

The corpus with the runtime through LLVM: 323/327, also with `RT_VERIFY=1`
and a 16 KB nursery. The four that differ need what the native emitter
records per function (`FuncRec`: unwind operations, lines), which an LLVM
object does not have:

- CallStacks, CallStacksGc: no names or lines for LLVM's functions in the
  call stacks (`StackTable`);
- UnwindTables, ObjCExceptions: no unwind tables (an Objective-C exception
  through Haxe frames).

Benchmarks (`hxmc/test/bench` Check programs, best of 5, runtime through
LLVM at O2, native = this branch without LLVM):

| | native | LLVM | |
| --- | --- | --- | --- |
| nbody | 0.373 s | 0.372 s | 1.00x |
| mandelbrot | 0.263 s | 0.203 s | 1.30x |
| binarytrees | 0.355 s | 0.317 s | 1.12x |
| sha256 | 0.083 s | 0.082 s | 1.01x |

Builds take longer: one clang process per module, in parallel.

## Next

- Function records for LLVM's functions: the symbols and sizes are in the
  object; lines from LLVM's DWARF (`!dbg` from `MIns.pos`), unwind tables
  from its `__compact_unwind`/`.eh_frame` instead of dropping them.
- Alias information: Mir's memory classes (`MIns.mem`) as TBAA, and
  pointers kept as `ptr` through `getelementptr` rather than `inttoptr` at
  each access, so LLVM may keep fields in registers.
- Program-wide numbers without the GOT load.
- The other targets: Linux and Windows objects are written but untested.
- In-process LLVM (its C API through `@:hxmc.c`) instead of a clang
  process per module.
