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
arguments (for example `-mllvm ...`). `-D hxmc.llvm-cpu=<cpu>`
(`HXMC_LLVM_CPU`) is the oldest CPU the program runs on, clang's `-mcpu`
on arm64 and `-march` on x86-64 (`apple-m3`, `x86-64-v3`, `native`).
clang's default is the baseline: `apple-m1` on macOS arm64, so tuning
gains little there (an M4 Pro: within noise); x86-64's baseline has no
AVX2.

## Why Mir after MemLower

It is SSA over i32, i64 and double, with explicit loads, stores, calls and
the shadow stack: almost one LLVM instruction per Mir instruction, and the
collector's roots are already in memory (frame slots linked from `rt_sp`),
so LLVM's register allocation cannot hide a reference from it. hxmc's own
passes (inlining, escape analysis, SROA, allocation folding) still run
first; LLVM adds its scalar and loop optimizations, instruction
scheduling and register allocation.

## Release mode

`-D hxmc.llvm-release` (`HXMC_LLVM_RELEASE=1`) is both of:

- `-D hxmc.llvm-consts`: the program-wide numbers (type indices, field
  ids, global offsets, class spans) as constants, from the data (DataGen)
  instead of extern_weak symbols loaded through the GOT;
- `-D hxmc.llvm-whole`: the whole program one LLVM module (cross-module
  inlining, interprocedural analyses), one clang process.

Either compiles LLVM's code after the data (Driver.llvmPending; the data
gets the symbols the code refers to from `LlvmGen.refs`), so its objects
are not cached, and a function's inline caches are global symbols.

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
- Branches to slow paths (`MBlock.cold`, MemLower's) carry branch
  weights (`!prof`), for LLVM's block placement and register allocation:
  binarytrees 1.12x to 1.23x, sha256 1.01x to 1.12x.
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
| nbody | 0.365 s | 0.365 s | 1.00x |
| mandelbrot | 0.265 s | 0.205 s | 1.29x |
| binarytrees | 0.353 s | 0.287 s | 1.23x |
| sha256 | 0.083 s | 0.074 s | 1.12x |

Builds take longer: one clang process per module, in parallel.

The compiler itself through LLVM (all 15834 functions; the Mir macros'
and Mir interpreter's lanes pass as with the native build: the
conformance macro cases 66/67, `Corpus --mir-run` 214/219) writes a
byte-identical self-compile, faster, cold (median of 5):

| the tool | built in | self-compile |
| --- | --- | --- |
| native | 6 s | 5.79 s |
| LLVM, per module | 17 s | 5.32 s (-8%) |
| LLVM, release mode | 91 s | 5.21 s (-10%) |

Release mode changes the small benchmarks little (binarytrees 1.24x to
1.29x, the others within noise).

## Next

For the program's speed, in order:


- Function records for LLVM's functions: the symbols and sizes are in the
  object; lines from LLVM's DWARF (`!dbg` from `MIns.pos`), unwind tables
  from its `__compact_unwind`/`.eh_frame` instead of dropping them.
- Alias information, tried (2026-11-08): Mir's memory classes as TBAA
  (`HXMC_LLVM_TBAA=1`, or a list of classes: tls, frame, const, hdr,
  elem, field, global, callonly; fields and shadow-stack slots one type per
  8-byte slot at a constant offset, as Opt.fieldClass). The corpus passes
  with it, also under GC stress, but no benchmark changed, so it is off by
  default. What keeps nbody's loop reloading `this.bodies` and the
  array's header is not aliasing between accesses but the slow-path call
  of each array access (`hx_aget_p_slow`: it boxes, so it may collect,
  which writes the shadow stack and forwarding headers): LLVM must assume
  it writes everything, and no annotation of it would be true. The native
  code reloads there too. A gain needs the slow paths out of the loops'
  memory state: Mir that versions such loops (bounds and kind checked
  once before the loop), or a GC contract LLVM knows (statepoints, below).
  Typed pointers (`ptr`, `noalias` allocations, `nonnull` after null
  tests) wait for that too.
- Implicit null checks (LLVM's `make.implicit`, a fault map the runtime
  reads) instead of the explicit tests.
- Larger: the shadow stack's stores and reloads (LLVM's statepoints and
  stack maps), profile-guided optimization.
- The other targets: Linux and Windows objects are written but untested.
