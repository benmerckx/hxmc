# Native code as fast as LLVM's

Goal: the native back end's code as fast as `-D hxmc.llvm=O2
-D hxmc.llvm-release`, at native build times (at most +10%) and in little
code, so that LLVM is not needed for a release build. Main workloads: the
HaxeBenchmarks and tsc-haxe (tshx, back2dos/tsc-haxe branch `tshx-opt`),
which LLVM with PGO ran 1.25x faster than native
([hxmc#19](https://github.com/benmerckx/hxmc/issues/19)). No PGO as the
lever: a plain cold build should get there.

Method: measure, take LLVM's code of the hottest functions where native
loses as the oracle, name the transformation it did, port the largest, one
per commit with its numbers in the message; revert what gains nothing.
The commits' messages hold the measurements of each change.

## Measuring

- **HaxeBenchmarks**: `bin/gap/runner` (HaxeBenchmarks/benchmark-runner at
  `Bench.RUNNER`'s commit) and `bin/gap/libs` (`Bench.LIBS`), with
  `libs/formatter/src` copied to `runner/cases/formatter_noio/data`. Then
  `bin/hxmc/hxmc -cp hxmc/test -cp haxe/test --run GapBench` builds each
  case cold in each mode (native, LLVM per module, LLVM release), runs
  them interleaved and merges the results into `bin/gap/gap.json` (options
  at its top; clang: `HXMC_LLVM_CLANG`). Per change, compare two tools on
  the same cases, interleaved, by instructions and cycles (Linux: `perf
  stat`; macOS: `/usr/bin/time -l`'s instructions retired and cycles
  elapsed; a VM without counters: `valgrind --tool=cachegrind
  --cache-sim=no`). Wall times of a few percent are noise on a loaded
  machine; a 10 ms case (sha512) moves by 5% with the layout alone.
- **tshx**: built as its `tools/targets.sh` target `hxmc` does (`HXMC_HOME`
  this checkout). Workload: TypeScript v7.0.2 (`node
  scripts/processDiagnosticMessages.mjs
  src/compiler/diagnosticMessages.json` first), `tshx -p tsconfig.json`
  with tsc-haxe's `tools/gate/realworld.sh` ts6-compiler config (65 errors
  expected). Compare stdout and every output file.
- A tool built while its sources are being edited takes the edit in, and
  the module cache is keyed by the sources, not the binary: give an
  experiment's tool its own `HXMC_CACHE`.

## Where it stands

x86-64 (Linux and Windows), against LLVM release built from the same
sources: native within 4% on every HaxeBenchmark, faster on formatter
(0.91x) and binarytrees; tshx 9.86 G instructions against 10.37 G, wall
time within noise of it; native builds 1.1-2.5 s against 4-18 s.

arm64 (Apple M4), G cycles, medians of 9 interleaved runs (cycles: the
machine was loaded, wall times inflated alike); main is 62d476f, LLVM
release built from this branch:

| | main | native | LLVM release | native / LLVM |
| --- | --- | --- | --- | --- |
| alloc | 1.466 | 1.227 | 1.240 | 0.99 |
| bcrypt | 7.584 | 6.304 | 5.949 | 1.06 |
| binarytrees | 1.414 | 1.199 | 1.036 | 1.16 |
| json | 0.615 | 0.519 | 0.511 | 1.02 |
| mandelbrot | 1.099 | 0.865 | 0.829 | 1.04 |
| nbody | 1.463 | 1.456 | 1.448 | 1.01 |
| sha256 | 0.299 | 0.299 | 0.269 | 1.11 |
| sha512 | 0.034 | 0.032 | 0.033 | 0.97 |
| formatter | 9.623 | 9.199 | 9.685 | 0.95 |

The port's self-compile to HXB (the same archive): 10.92 G cycles with
main's tool, 10.52 G with this branch's (-3.8%; instructions -8.9%). The
tool's cold build: 10.8 s CPU against main's 10.3 s (+5%), the binary
+3.1%.

## Open items

1. **sha256 on arm64** (LLVM 1.1x): LLVM folds a rotation into its user
   (`eor w, w, w, ror #n`) and keeps the W array's tests out of the
   rounds; ours copies each loaded word once more (`ldr w1; mov x19, x1`).
2. **binarytrees on arm64** (LLVM 1.1x): every thread-local access is
   `add x16, base, #hi12, lsl 12; ldr [x16, #lo12]` with hi12 0 (the
   linker could relax it to one load), and the write barrier's `dmb ishst;
   str` where LLVM's `stlr` publishes.
3. **tshx's taken branches** (x86-64): 1.08 G against LLVM's 0.95 G and more
   32-byte fetch windows; per-function `br_inst_retired.near_taken` native
   against LLVM to name the shapes (joins, loop exits, cold-path jumps).
4. **Regalloc without splitting**: a value live across a loop spills whole
   (Str.hashSlow's `s`), which is why Opt.promoteSlots stops at loop
   headers; no shrink-wrapping either (a function saves its callee-saved
   registers on every way when one rare way calls: hx_apush_slow,
   NArray.view, Dyn.dynEq; hxmc_barrier_slow and Arr.resize were split by
   hand).
5. **Jump threading** of a join of phis and a comparison that an edge into
   it decides: the decoder pattern -21%, but the compiler built with it
   miscompiled itself; find that first (its own HXMC_CACHE).
6. **GapBench's self-compile through LLVM** fails on macOS (`dyld: Symbol
   not found: _.Lsec10$__compact_unwind`, on main too): the LLVM-built
   tool's compact unwind section symbol.

## Tried and left out

Built, measured, reverted (x86-64, tshx unless named):

| | result | why out |
| --- | --- | --- |
| inline every function called once in its module | -0.65% instructions, cycles ~0, code +7.6% | copies stay for other callers |
| slow paths out of line (a `.cold` part per function) | cycles within noise, L1i misses unchanged | the cold blocks were at each function's end already |
| block layout by chains of likely successors | +1.3% instructions | taken branches only -21 M |
| loop rotation at forward jumps, or of heads up to 4-8 instructions | -0.2%, code +0.6-0.9% | taken branches barely moved |
| spill cost per sqrt(length) | cycles +3% | more spills in loops |
| a compressed reference's null test on the 32-bit word | +0.18% | both forms live then |
| `-D hxmc.frame-pointers=0` | -4.5% instructions, -0.5% cycles | not worth profilers' stack walks |
| Regalloc rematerializing spilled constants | -0.02% | few constants spill |
| LoopVersion.tryStrings for a string dereferenced before the loop | -0.44% instructions, cycles +1.2% | the copies' code |
| JsonPrinter's fields by id | json +13.5% | the lookup by name is faster |
| Opt.promoteSlots through every join | +5.8%, code +8.6% | linear scan without splitting spills them |
| an Array's first capacity 4, not 2 | -0.11% | peak RSS +1.05% |
| arm64: a table row's base + displacement at the base's definition, not before the loop | json, formatter, binarytrees +0.4-1.7% | made on every call, also when the loop does not run |
