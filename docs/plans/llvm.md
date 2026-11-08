# LLVM as an optional back end (experimental)

`-D hxmc.llvm[=O1|O2|O3|Os]` compiles each module's
functions through LLVM: memory-level Mir, after `MemLower` and the passes on
it, is written as textual LLVM IR (`hxmc/src/hxmc/LlvmGen.hx`), an external
clang compiles it for the target's triple, and the object it writes is read
back (`MachOReader`, `ElfReader`, `CoffReader`) and appended to the module's
object. hxmc's own linkers link as before. `-D hxmc.llvm-rt`
takes the runtime's modules too. The `.ll` files are kept
in `<out>.hxmc/llvm/`.

clang: `-D hxmc.llvm-clang=<path>`, else `clang` on the path. Every flag falls back to its environment variable, upper case with
underscores (`hxmc.llvm-rt`: `HXMC_LLVM_RT`), so that a test harness can
set it for every build it runs; a define wins. Apple's clang (Xcode's
command-line tools) has every back end hxmc targets, so it writes Mach-O,
ELF and COFF objects, cross-compiling from macOS. `-D hxmc.llvm-flags=<args>` adds
arguments (for example `-mllvm ...`). `-D hxmc.llvm-cpu=<cpu>` is the oldest CPU the program runs on, clang's `-mcpu`
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

`-D hxmc.llvm-release` is both of:

- `-D hxmc.llvm-consts`: the program-wide numbers (type indices, field
  ids, global offsets, class spans) as constants, from the data (DataGen)
  instead of extern_weak symbols loaded through the GOT;
- `-D hxmc.llvm-whole`: the whole program one LLVM module (cross-module
  inlining, interprocedural analyses), one clang process.

Either compiles LLVM's code after the data (Driver.llvmPending; the data
gets the symbols the code refers to from `LlvmGen.refs`), so its objects
are not cached, and a function's inline caches are global symbols.

## Profile-guided optimization

`-D hxmc.llvm-pgo=gen` compiles LLVM's code instrumented (`-fprofile-generate`)
and links the clang's profile runtime (`libclang_rt.profile_osx.a`, macOS
only); the program writes `default.profraw` (or `LLVM_PROFILE_FILE`, `%p`
for one per process) when it exits. `xcrun llvm-profdata merge -o
app.profdata *.profraw`, then `-D hxmc.llvm-pgo=app.profdata` compiles with
the profile (its size and time in the cache key). Best with
`-D hxmc.llvm-release`.

Linux (static with musl): the clang's `libclang_rt.profile-<arch>.a` is C
built against glibc, and its file part (stdio, `fileno`, `__strdup`) does
not link with musl's members. Only its writer is linked (InstrProfiling,
Buffer, Writer, Value, PlatformLinux: `memcpy`, `memset`, `calloc`), and
the runtime writes the file (`hxmc/std/hxmc/rt/Pgo.hx`, registered with
`atexit` under `-D hxmc.llvm-pgo=gen`): `lprofWriteData` with a writer
of its own, value profiles (indirect call targets) included.
`LLVM_PROFILE_FILE` takes `%p`, `%h`, `%t` and `%%` (not `%m`:
no merging), default `default.profraw`. The counters are global, so every
thread's count is in it; clang's default increments are not atomic, and
threads that run the same code lose counts (`-D
hxmc.llvm-flags=-fprofile-update=atomic` for exact ones). The linker gives
the writer `__start_<section>`/`__stop_<section>` (Link: the sections of a
name referred to so kept and laid out together), and the reader takes the
global symbols of an ELF COMDAT group as weak (each module defines
`__llvm_profile_raw_version`). `llvm-profdata` of the clang's version
merges (on Linux, conda's `llvm-tools`).

A profile is for the mode it was made in: release mode (`-D
hxmc.llvm-release`: one module, the program-wide numbers as constants)
gives many functions another control flow, so a per-module profile misses
them (tsc-haxe: 2240 of 14728 functions, 32% of the counts, with another
hash; clang's mismatch warnings are off, `-Wno-backend-plugin`).
Release mode with the profile of an instrumented release build.

What hxmc's linker needed for the runtime: BSD archives' index
(`__.SYMDEF`, Archive), universal files (LinkInputs: the target's slice),
64-bit SUBTRACTOR relocations (MachOReader: RPc64, the profile records'
distances to their counters), and ld64's `section$start# LLVM as an optional back end (experimental)

`-D hxmc.llvm[=O1|O2|O3|Os]` compiles each module's
functions through LLVM: memory-level Mir, after `MemLower` and the passes on
it, is written as textual LLVM IR (`hxmc/src/hxmc/LlvmGen.hx`), an external
clang compiles it for the target's triple, and the object it writes is read
back (`MachOReader`, `ElfReader`, `CoffReader`) and appended to the module's
object. hxmc's own linkers link as before. `-D hxmc.llvm-rt`
takes the runtime's modules too. The `.ll` files are kept
in `<out>.hxmc/llvm/`.

clang: `-D hxmc.llvm-clang=<path>`, else `clang` on the path. Every flag falls back to its environment variable, upper case with
underscores (`hxmc.llvm-rt`: `HXMC_LLVM_RT`), so that a test harness can
set it for every build it runs; a define wins. Apple's clang (Xcode's
command-line tools) has every back end hxmc targets, so it writes Mach-O,
ELF and COFF objects, cross-compiling from macOS. `-D hxmc.llvm-flags=<args>` adds
arguments (for example `-mllvm ...`). `-D hxmc.llvm-cpu=<cpu>` is the oldest CPU the program runs on, clang's `-mcpu`
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

`-D hxmc.llvm-release` is both of:

- `-D hxmc.llvm-consts`: the program-wide numbers (type indices, field
  ids, global offsets, class spans) as constants, from the data (DataGen)
  instead of extern_weak symbols loaded through the GOT;
- `-D hxmc.llvm-whole`: the whole program one LLVM module (cross-module
  inlining, interprocedural analyses), one clang process.

Either compiles LLVM's code after the data (Driver.llvmPending; the data
gets the symbols the code refers to from `LlvmGen.refs`), so its objects
are not cached, and a function's inline caches are global symbols.

/`section$end# LLVM as an optional back end (experimental)

`-D hxmc.llvm[=O1|O2|O3|Os]` compiles each module's
functions through LLVM: memory-level Mir, after `MemLower` and the passes on
it, is written as textual LLVM IR (`hxmc/src/hxmc/LlvmGen.hx`), an external
clang compiles it for the target's triple, and the object it writes is read
back (`MachOReader`, `ElfReader`, `CoffReader`) and appended to the module's
object. hxmc's own linkers link as before. `-D hxmc.llvm-rt`
takes the runtime's modules too. The `.ll` files are kept
in `<out>.hxmc/llvm/`.

clang: `-D hxmc.llvm-clang=<path>`, else `clang` on the path. Every flag falls back to its environment variable, upper case with
underscores (`hxmc.llvm-rt`: `HXMC_LLVM_RT`), so that a test harness can
set it for every build it runs; a define wins. Apple's clang (Xcode's
command-line tools) has every back end hxmc targets, so it writes Mach-O,
ELF and COFF objects, cross-compiling from macOS. `-D hxmc.llvm-flags=<args>` adds
arguments (for example `-mllvm ...`). `-D hxmc.llvm-cpu=<cpu>` is the oldest CPU the program runs on, clang's `-mcpu`
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

`-D hxmc.llvm-release` is both of:

- `-D hxmc.llvm-consts`: the program-wide numbers (type indices, field
  ids, global offsets, class spans) as constants, from the data (DataGen)
  instead of extern_weak symbols loaded through the GOT;
- `-D hxmc.llvm-whole`: the whole program one LLVM module (cross-module
  inlining, interprocedural analyses), one clang process.

Either compiles LLVM's code after the data (Driver.llvmPending; the data
gets the symbols the code refers to from `LlvmGen.refs`), so its objects
are not cached, and a function's inline caches are global symbols.


symbols (LinkMachO: the sections of the name laid out together between two
empty ones). The runtime's static initializer (`__mod_init_func`) registers
the write at exit.

The compiler, trained on its own cold self-compile (median of 5, the
self-compile byte-identical to the native-built tool's):

| the tool built | self-compile | cpu |
| --- | --- | --- |
| native | 5.42 s | 7.70 s |
| LLVM, per module | 5.16 s | 7.09 s |
| LLVM, release mode | 5.01 s | 6.95 s |
| LLVM, release mode with the profile | 4.60 s (-15%) | 6.48 s (-16%) |

On another workload (VectorBench compiled, build macros on the interpreter)
the same tools: cpu 0.47, 0.44, 0.43, 0.40 s.

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
- Frame records always (`frame-pointer=all`). Each function gets a
  record (FuncRec, LlvmGen.records): its size (from the symbols' layout),
  with lines its Haxe name and rows from LLVM's line table (debug locations
  from `MIns.pos`, a line-tables-only unit; the object's `__debug_line`
  read back, line 0 left out as the native emitters record none), and its
  unwind information (`uwtable`): a compact unwind frame encoding
  (Unwind.LLVMFRAME) or the CFI of the object's `__eh_frame` rescaled to
  hxmc's CIE (Unwind.LLVMCFI); else Unwind.NONE, left out of the tables.
- A program that reads its stacks (`Program.stacks`) keeps the native
  code's frames: `noinline` and `disable-tail-calls` (LLVM inlines nothing
  more than hxmc did), unless `-D hxmc.llvm-inline`. `-trap-unreachable`
  keeps the return address after a call that does not return in its
  caller. The compiler reads its stacks: its LLVM build then saves 5.6%
  cpu on its self-compile instead of 8%.
- arm64: no `ldp`/`stp` pairing (`-aarch64-enable-ldst-opt=0`). A pair load
  partly overlapping an earlier pair store defeats store-to-load
  forwarding on Apple's cores: nbody ran 1.75x slower with it.

Functions `LlvmGen.accepts` refuses go through the native back end into
the same object: structs by value in the C ABI (arguments, results,
entries from C), vectors (`hxmc.simd`), Apple arm64 C calls with stack
arguments (packed by size).

## Status (macOS arm64, Apple clang 21, 2026-11-08)

The corpus with the runtime through LLVM: 327/327, also with `RT_VERIFY=1`
and a 16 KB nursery and in release mode.

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


- Inlined frames: with LLVM's inlining in a program that reads its stacks,
  the inlined calls' positions as hxmc's inliner gives them (the call's),
  from the line table's inlining information.
- x86-64's compact unwind encodings (LLVMFRAME is arm64's); ELF and COFF
  objects' lines and CFI.
- Alias information, tried (2026-11-08): Mir's memory classes as TBAA
  (`-D hxmc.llvm-tbaa=1`, or a list of classes: tls, frame, const, hdr,
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
  With loop versioning (LoopVersion, merged here): the versioned loops
  have no slow-path calls, and LLVM then hoists the array's field and
  header by itself; the tags still change nothing measurable (VectorBench
  read4 within noise). Loop versioning and LLVM together: read4 of
  Array<Object> 0.51 ns per element (native, no versioning) to 0.185
  (native with versioning 0.29, LLVM without it 0.42); LLVM alone halves
  the plain sequential read (1.12 to 0.6).
- Implicit null checks (LLVM's `make.implicit`, a fault map the runtime
  reads) instead of the explicit tests.
- Larger: the shadow stack's stores and reloads (LLVM's statepoints and
  stack maps), profile-guided optimization.
- The other targets: Linux and Windows objects are written but untested.
