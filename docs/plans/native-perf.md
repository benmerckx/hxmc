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

## Progress (2026-11-15, third session, WSL2)

Commits since the second session's notes, each with its numbers in its
message (user instructions, `perf stat`, outputs identical, make quick on
each):

| commit | what | gain |
| --- | --- | --- |
| 942c5bff, b0607ba4 | returns without jumps: short return blocks copied into their jumpers, an epilogue per return (`-D hxmc.dup-returns=0`: off) | tshx -0.5% instructions, -4.5% taken branches, -2.6% cycles |
| 875ecb51 | Regalloc's loop depths from the Mir's loop nest | tshx -0.12% |
| 049651c9 | x64: a 32-bit operation's upper half is zero; ZExt/SExt of such a copy | bcrypt -14.6% |
| 70817c25 | Opt.indexed: `sext(x + c)`, `sext(x \| c)` into the displacement (Opt.upTo) | bcrypt -12.8% |
| af6a0889 | x64: `x * 2.0` is `x + x`; a compared double not folded | mandelbrot -4.5% |
| c5465ba0 | x64: a counter Opt.nonNegative proves is zero-extended | tshx -0.08% |
| 6cc621f1 | MemLower: Dynamic unboxed to Int/Bool/Float inline, the runtime call on a slow path | json -3.1% |
| 944d4667 | Opt.lowered: a constant repeated in its block is the first; `-1 - x` is `~x` | json -3.3% |
| cdee5bb9 | Dyn.nameIs: a loop per string width | json -2.2% |
| c3942000 | Opt.indexed: base/index split before the scale fold | json -0.5% |
| ed69514b | Str.range: narrowed while tested (MemRepr.narrowFits) | json -3.0% |
| e068816b | Names.lock/unlock inline | json -0.15% |
| e7b4ee9a | every program enum with arguments compact (Lower.autoCompact; `-D hxmc.compact=0` off) | an enum tree: peak RSS 388 -> 176 MB, 1.31 -> 0.80 s |
| 84084c89 | x64 FOPM: a double's add/sub/mul/div takes a single-use load as memory operand | nbody -7.0% |
| aa1c7514 | MemOps.compare: 16 bytes a round | alloc -3.2% |
| d0f4c966 | Layout: after a block leaving its loop on one side, the side staying in the loop next | alloc -1.7%, tshx taken branches -0.2% |
| fe536a4d | Gc: young objects of more than 8 words copied 4 words a round | alloc -10.0%, cycles -7.1% |
| fd1ad66b | Names.strOf inline; Names.nameOf (fidName's body) inline in Dyn.fid | json -0.3% |
| 98519622 | MemRepr.narrowFits inline into Str.range, its one caller | json -0.6% |
| 461a6eb1 | x64: a 4-byte store of a constant, then of 0 after it (an object's header): one 8-byte store | tshx -0.12%, .text -1.6%; binarytrees -1.0%, cycles -2.5% |
| 3f0ed860 | LoopVersion.tryStrings: a small loop without calls reading a string's length gets a copy entered when the string is not null (its length and width loads move out); Opt: redundancy elimination again after LICM moved something | tshx -0.25% |
| 9fef2714 | the same copy entered only for a string of a byte per unit when the loop reads its width (the width tests known in the copy) | tshx -0.17%, cycles -0.7% |
| 1072edcc | Opt.fold: a symbol's or a frame slot's address compared with null is known | tshx -0.14%, .text -0.9% (6070 such tests, 40 left) |

Where it stands (Linux x86-64 under WSL2, the machine loaded by other
work: instructions are reliable, cycles within a few percent):

| | native | LLVM release (O2) | |
| --- | --- | --- | --- |
| tshx instructions | 9.64 G | 9.80 G | native fewer (LLVM per module 9.96 G) |
| tshx cycles (9 interleaved runs) | 11.19 G | 10.85 G | native +3.1% (per module 10.70 G) |
| json instructions | 3.18 G | 2.87 G | +11% |
| alloc instructions | 3.59 G | 3.40 G | +5% |

Later the same day, LLVM release at O2 and at O3 rebuilt with the day's
runtime (which made LLVM's code faster too: tshx 9.80 -> 9.60 G
instructions), cycles (instructions for tshx), medians, outputs identical:

| | native | LLVM O2 | LLVM O3 |
| --- | --- | --- | --- |
| tshx instructions | 9.637 G | 9.604 G | 9.470 G |
| tshx cycles (7 runs) | 10.198 G | 9.882 G (native +3.2%) | 9.740 G (+4.7%) |
| tshx .text | 14.98 MB | 12.53 MB | 12.91 MB |
| alloc | 3.254 G | 3.244 G | 3.192 G |
| json | 1.714 G | 1.482 G (+16%) | 1.464 G |
| nbody | 4.448 G | 4.451 G | 4.483 G |
| mandelbrot | 1.003 G | 1.000 G | 1.000 G |
| sha512 | 0.058 G | 0.050 G | 0.049 G |
| bcrypt | 7.465 G | 7.254 G (+2.9%) | 7.232 G |

O3 is within 2% of O2 everywhere. Per function (tshx, cycles sampled
against LLVM O2 after the commits above, 8.29 G against 8.11 G: +2.2%),
the largest excesses: NameResolver.Resolve 160 M against 73 M,
SymbolTableImpl.get 206 against 154, Scanner.scanIdentifier 97 against
47 (LLVM unswitches its inner loop on the string's width: a loop per
width), ECMALineStartsSeqIterator.advance 95 against 45 (its loop now as
LLVM's), Gc.forwardRemembered 222 against 182 (memory-bound in both),
MemberLayout.indexOf 113 against 85, StringMap.get 97 against 73.

Windows wall times (GapBench, before json's, nbody's and alloc's commits):
native faster on formatter (11-17%), sha256, binarytrees; bcrypt 0.99x of
release; mandelbrot 1.05x, json 1.13-1.21x, nbody 1.03-1.08x, alloc
1.06-1.10x, sha512 1.07-1.13x slower. tshx's cold build: about 54 s CPU,
unchanged. make check 27/29 (arm64/qemu and wine not installed), the
Windows corpus natively 373/373, fixpoint byte-identical (crosshost not
run: no second host).

The remaining tshx gap is the front end, as in the second session: taken
branches 1.08 G against 0.95 G, more 32-byte fetch windows. json's: the
string and field-name paths (Str.sbAddJson, jsonRun, jsonPlain,
Dyn.overflowSet, Dyn.findField, Names.fidName). alloc's: Gc.drainMinor
(the copy loop, now unrolled, and its scan) and hxmc_zero.

Also tried and left out this session (built, measured, reverted):

| | gain | why out |
| --- | --- | --- |
| Regalloc rematerializes a spilled constant at its uses (no slot, no reload) | tshx -0.02%, json -0.08%, .text -80 bytes | few constants spill; 40 lines |
| cold blocks split out of line, several block-layout variants, wider loop rotation, forward dup-tests, jump duplication of short blocks, loop alignment | under noise or more code | see the second session's table |
| once-inlining for all functions, runtime inline limits for json | | code size, no cycles |
| a string's width test in charCodeAt with the one-byte side as the false (fall-through) one | tshx +0.14% instructions, .text the same | the layout did not change |
| a Bool boxed inline in MemLower (rt_bool_boxes + 8 + 16 * b) | json, formatter unchanged | json's boxes are made elsewhere |
| LoopVersion.tryStrings also for a string dereferenced before the loop (the copy entered for one byte per unit only) | tshx -0.44% instructions, .text +0.18% | cycles +1.2% (15 runs): the copies' code |
| a shadow-stack slot's load after its store in the block forwarded in Opt.lowered (after Frames' merge) | tshx -0.01%, .text -3 KB | rare |
| the remembered set's slots touched 8 entries ahead (a load, as a prefetch would) in Gc.forwardRemembered | tshx +0.64% instructions; cycles -6.7% and +1.4% in two series | not measurable here: memory-bound functions move by 25% from run to run under WSL's load; worth a prefetch op on a quiet machine |

Windows, the merged branch (07ced548: this session's and the Linux
session's commits), natively: the corpus 373/373; GapBench wall times
(best of 5) against LLVM release: formatter 0.91x, binarytrees 0.98x,
alloc 1.00x, mandelbrot 1.00x, sha256 1.01x, json 1.02x (1.13-1.21x in the
morning), bcrypt 1.02x, nbody 1.03x, sha512 1.04x; native builds 1.1-2.5 s
against 4-18 s.

## Next

1. On a Linux machine (quiet core, perf with call graphs): `make check`
   (arm64 lanes if qemu is there), `make fixpoint`, `make crosshost`;
   re-measure tshx and GapBench against LLVM release at O2 and O3, 7+
   interleaved runs.
2. tshx's taken branches: per-function `ex_ret_brn_tkn` (or
   `br_inst_retired.near_taken`) native against LLVM, name the shape of
   the largest excesses (joins, loop exits, cold-path jumps).
3. json: Str.sbAddJson/jsonRun/jsonPlain against LLVM's code; the
   field-name lookup (Dyn.findField, Names.fidName).
4. alloc: Gc.drainMinor's scan and hxmc_zero against LLVM's.
