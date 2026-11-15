# Native code as fast as LLVM's

Goal: the native back end's code as fast as `-D hxmc.llvm=O2` and
`-D hxmc.llvm-release` (LLVM unnecessary for release builds), at native
compile times (at most +10% build time) and in little code. Main target:
tsc-haxe (tshx, back2dos/tsc-haxe branch `tshx-opt`) built by hxmc, which
LLVM with PGO runs 1.25x faster than native on t3code-server
([hxmc#19](https://github.com/benmerckx/hxmc/issues/19)). No PGO as the
lever: a plain cold build should get there.

Method: measure, take LLVM's code of the hottest functions where native
loses as the oracle, name the transformation it did, port the largest,
one per commit with numbers; revert what gains nothing.

## Progress (2026-11-15, second session, WSL2)

Measured with `perf stat` (user-mode counters work under WSL2; sampling
is throttled, so per-function shares are rescaled to the counted totals):
tshx on ts6-compiler declarations, medians of 7 interleaved runs, the
machine loaded by other work (cycles inflated alike):

| | instructions | cycles | task-clock | .text |
| --- | --- | --- | --- | --- |
| native, start (6c0efe21) | 10.63 G | 10.20 G | 2919 ms | 16.41 MB |
| native, now | 9.72 G | 9.63 G | 2772 ms | 14.77 MB |
| LLVM per module | 9.96 G | 8.97 G | 2542 ms | 13.10 MB |
| LLVM release | 9.80 G | 9.08 G | 2547 ms | |

Native now executes fewer instructions than either LLVM build; the rest of
the gap (about 7% of cycles) is the front end: `stalled-cycles-frontend`
2.67 G against 2.12 G (all of the cycle difference), L1i misses 58.6 M
against 44.4 M, iTLB misses 1.2 M against 0.67 M, branch misses +9%. The
code is 13% larger; 2.5 MB of it is slow paths (cold blocks), laid out at
each function's end, between the hot code.

Commits (each with its numbers): Regalloc follows unallocated hints
(-1.0%); x64 ZExt of a load is a copy (-1.4%); Frames merges inlined
callees' frames into the function's (-3.6% instructions, -8.6% code);
x64 loop rotation after allocation (-0.94%); Regalloc lifetime holes
inside a block (-1.4%); x64 SExt of a non-negative zero-extended value
is a copy (-0.1%); Opt.lowered's `(x << 32) >>> c` rule (-0.17%); x64
`and 0xff/0xffff` as movzx (-0.09%). The WIP commit (index shift fold,
sinking into slow paths): make quick ok, -0.2%, kept. tshx's cold build:
54.5 s CPU against 55.3 s before (no cost). Output identical throughout;
make quick on each, make check once (all lanes but arm64/qemu and wine,
not installed; the Windows corpus run natively instead: 373/373).

Tried and left out (each built, measured on tshx, reverted):

| | instructions | cycles | code | why out |
| --- | --- | --- | --- | --- |
| inline every function called once in its module | -0.65% | ~0 | +7.6% | copies stay for other callers; "nothing else reaches it" would have to be in each module's cache key |
| loop rotation at forward jumps too | -0.2% | ~0 | +0.9% | taken branches only -25 M |
| loop rotation of heads up to 4 or 8 instructions | -0.25% | -0.6% (noise) | +0.6% | taken branches only -7 M |
| slow paths out of line (a `.cold` part per function after the object's functions, branches patched, unwind and line records of their own) | 0 | -0.45% (noise) | +0.2% | L1i misses unchanged (61.7 M -> 61.1 M): the cold blocks were at each function's end already |
| block layout by chains of likely successors (in loop, not equal, not cold) | +1.3% | 0 (9 runs) | +3.3% | taken branches only -21 M |
| the same at conditional branches only; true successor first | +0.5% | +1.4% | | true-first: taken branches +70 M (false-first, reverse postorder's, is the better default) |
| spill cost per sqrt(length) instead of per length | -0.17% | +3% | -0.3% | more spills in loops |
| a compressed reference's null test and equality on the 32-bit word | +0.18% | | | both forms then live where the reference is used otherwise too |
| LICM of Ints in loops with calls | +0.03% | -0.7% (noise) | | |
| a critical edge's constant phi copies set before the branch, no edge block (`p == null ? 0 : p.f` without the jump over the null's arm) | +0.77% | 0 | -0.7% | taken branches only -1.3 M |
| `-D hxmc.frame-pointers=0` (rbp allocatable) | -4.5% | -0.5% | -1% | not worth profilers' and debuggers' stack walks |
| tshx without its `-D hxmc.inline=48,128,6,120,4` (hxmc's defaults) | +7.7% | +4.6% | -48% | |
| `48,128,6,120,3` / `24,128,6,120,4` | +0.8% / +3.1% | 0 / +1.2% | -10% / -23% | code size alone is not the cycles |

HaxeBenchmarks (GapBench, then perf stat interleaved where the wall times
looked worse): no regression; alloc -10% instructions (-2% cycles), nbody
-2.7%, binarytrees -0.4%, mandelbrot identical, formatter and the
self-compile about 1% faster. make check at HEAD: 27/29 (arm64/qemu and
wine not installed); fixpoint byte-identical.

What the rest of the gap is (Zen 2 counters, native against LLVM per
module): 2.135 G branches against 2.241 G, but 1.134 G taken against
0.950 G (+19%): about 212 M unconditional jumps against 134 M (calls and
returns nearly equal: 139 M returns against 131 M) and about 90 M more
taken conditional branches; 2.13 G 32-byte fetch windows against 2.00 G
for fewer instructions (longer encodings on average); decoder redirects
27.6 M against 20.7 M. Spills are not it (stack loads executed: 144 M
against 140 M); the taken branches are spread over every function (the
largest excess, StringMap.get, 6.6 M). Next, by these numbers: why native
code takes more unconditional jumps (LLVM's block placement with tail
duplication and its IR-level loop rotation shape loops and joins before
isel; hxmc lays out reverse postorder and fixes only loop heads of
compares after allocation), and denser encodings (bytes per executed
instruction).

## Status (2026-11-15, handoff)

Started on Windows (Ryzen 5 3600) with tshx under WSL2; moved to a Linux
machine because the Makefile's tiers do not run there, WSL's perf has no
call graphs (`task-clock:u` flat profiles only) and run-to-run noise was
about 15%.

### tshx, ts6-compiler declarations (WSL2, one interleaved series of 7)

| | wall min | wall median | build |
| --- | --- | --- | --- |
| native | 3.24 s | 3.34 s | 41 s |
| LLVM per module | 2.76 s | 3.15 s | 59 s |
| LLVM release | 2.59 s | 2.88 s | 245 s |

Output identical in every mode. LLVM release without PGO is 1.16x
(median) to 1.25x (min) faster: about the issue's LLVM + PGO gain, so the
gap is static code quality, not the profile.

Flat profile, native (self time): Gc.minorCompact 3.1%, Flow.getTypeAtFlowNode
2.9%, SymbolTableImpl.get 2.6%, Gc.drainMinor 2.4%, Gc.forwardRemembered
2.2%, hxmc_zero 1.5%, NameResolver.Resolve 1.4%, Scanner.Scan 1.3%,
StringMap.get 1.2%; a long flat tail (the top 60 functions are about 55%).
The collector is about 10%; the rest is spread wide, so the gains are in
code everywhere (isel, register allocation, inlining across modules), not in
a few kernels.

### HaxeBenchmarks, native (Windows, best of 5; `GapBench`)

alloc 0.94 s, bcrypt 2.09, binarytrees 0.64, json 0.41, mandelbrot 0.28,
mandelbrot_anon 0.28, nbody 0.91, sha256 0.17, sha512 0.07, formatter
4.93; self-compile 6.43 s (the tool built in 14.4 s cold). The LLVM
columns were not measured cleanly.

### Missed transformations found so far

From formatter's hottest function (`TokenTree.internalFilterCallback`,
22% of its samples), native machine code against the Mir:

1. A reference store's element (`setPtr`): the index shifted (`shl 3`) and
   then accessed at scale 1, because the barrier's slot address shares the
   shift: `movsxd; shl r10,3; mov rax,[r9+r10]` where `[r9+rdx*8]` does.
2. The slot address (`add base, idx<<3`) is computed on the fast path, but
   only the barrier's cold slow call reads it.
3. A shadow-stack slot stored and reloaded at once at a loop's entry
   (`mov [rdi+8],rcx; mov rcx,[rdi+8]`).

1 and 2 are the commit "WIP" on this branch (`Opt.indexed`: an index `y << k`,
k of 1 to 3, at scale 1 becomes `y` at scale 2^k; `Opt.sinkCold`: a cheap
pure value used only in one slow-path block moves there). The tool builds
with them; nothing else is checked yet: run the tiers and measure, or
revert.

## Setup

- Benchmarks: `bin/gap/runner` (HaxeBenchmarks/benchmark-runner at
  `Bench.RUNNER`'s commit) and `bin/gap/libs` (`Bench.LIBS`); copy
  `libs/formatter/src` to `runner/cases/formatter_noio/data`. Then
  `bin/hxmc/hxmc -cp hxmc/test -cp haxe/test --run GapBench` (options at
  its top; clang: `HXMC_LLVM_CLANG`; results merge into `bin/gap/gap.json`).
- tshx: `git clone -b tshx-opt https://github.com/back2dos/tsc-haxe`;
  built as its `tools/targets.sh` target `hxmc` does (`HXMC_HOME` this
  checkout), adding `-D hxmc.llvm=O2 -D hxmc.llvm-rt [-D hxmc.llvm-release]`
  for LLVM. Workload: `git clone --depth 1 -b v7.0.2
  https://github.com/microsoft/TypeScript upstream`, `node
  scripts/processDiagnosticMessages.mjs src/compiler/diagnosticMessages.json`
  in it (else thousands of errors), then `tshx -p tsconfig.json` with
  tsc-haxe's `tools/gate/realworld.sh` ts6-compiler config (65 errors
  expected, from `"types": []`). Interleave the binaries' runs; compare
  stdout and every output file.

## Next

1. On Linux: re-measure the table above (perf stat, at least 7 runs, a
   quiet core), and the LLVM columns of `GapBench`.
2. Check or revert the WIP commit (`make quick`, `make check`, fixpoint).
3. Oracle diffs: `perf annotate` the top 30 of tshx's functions in native
   and LLVM release builds (`-D hxmc.symbols`), name each difference,
   rank by summed self time.
4. Candidates to rank against the diffs: cross-module inlining of small
   accessors (release mode's main structural advantage), live-range
   splitting around calls in Regalloc (linear scan without splitting
   spills whole intervals), program-wide numbers as immediates where the
   native code loads them, and the collector's copy loops.
