# Lean performance checkpoint

Branch: `perf/hxmc-lean`. Original baseline: `5b713c4f`.

The branch does **not** complete the lean plan's single-IR migration, and
has not established a major whole-compiler speedup. Keep that distinction
when reporting the focused runtime improvements.

## Retained changes

- Fix the overflow in small Bytes allocations.
- Add the checked compilation profile and optimized/checked differential
  fuzzing, including dynamic native-array and standard-library accesses.
- Remove register-allocation scratch arrays and per-instruction rewrite
  allocations; use a prefix sum for loop-depth accounting.
- Share unchanged StringBuf snapshots; detach before mutation. Preserve
  stage0's two-slot buffer layout and old inline addChar behavior.
- Use checked word operations in the compiler's byte buffer.
- Use dense local-type arrays and unboxed SSA lookup results in the shared
  SSA builder (`ce394caf`).
- Add reproducible cold-build measurements (`make lean-stats`).
- Register runtime TLS declarations even when accessed only by symbol.
- Keep root facts outside structured bodies and reuse liveness masks.
- Compact obsolete MIR value-table entries before backend processing.
- Pack the MIR instruction's eight boolean flags into one word.

The SSA change alone was compared over three alternating pairs, compiling
the same current source with the compiler immediately before and after
that change. Median wall time was 11.77 -> 11.59 seconds; CPU time was
19.42 -> 19.17 seconds; peak RSS was 1,212,832 -> 1,215,964 KiB. Outputs
were byte-identical. This is a small change, close to timing noise.

An earlier three-pair whole-branch comparison with the original baseline
(`bin/lean-stats-NBH8ma/results.json` in the development workspace) gave
11.53 -> 11.70 seconds wall, 19.04 -> 19.21 seconds CPU, and 1,217,244 ->
1,216,104 KiB peak RSS. That comparison predates the final StringBuf
compatibility, TLS, checked-library and SSA commits. It establishes no
compiler-wide improvement. Repeat `make lean-stats` for the final revision;
do not present focused buffer timings as compiler speedups.

At checkpoint `68c4bee9` the compiler binary was 21,067,440 bytes versus
21,177,912 at the original baseline (110,472 bytes smaller). Production
Haxe source counts are 59,403 compiler + 43,782 runtime = 103,185 lines,
18 more than the baseline's 103,167. Net source reduction has not been
achieved. The earlier benchmark comparison produced unchanged json and
mandelbrot executable sizes, with alloc and nbody each one 4 KiB page
larger; see the recorded results rather than assuming all sizes improve.

The focused benchmarks in `hxmc/test/micro` were rerun after the final
StringBuf compatibility fix, with matching stdout in every pair:

| Workload | Baseline median wall | Current median wall | Peak RSS baseline -> current |
| --- | ---: | ---: | ---: |
| Buf word writes, reads and patches | 0.30 s | 0.22 s | 16,656 -> 16,660 KiB |
| 8192 unchanged 1 MiB StringBuf snapshots | 3.40 s | <0.01 s | 266,256 -> 3,216 KiB |

The snapshot result is below GNU time's resolution; do not quote a speed
ratio. These are narrow workloads, not whole-program speed estimates.

## Whole-branch refresh after MIR compaction

Three alternating pairs against the original baseline, compiling the same
current compiler sources with each variant's std, gave the following
medians. Raw data: `bin/lean-stats-r3IrmP/results.json`.

| Self-build | Original baseline | Current |
| --- | ---: | ---: |
| Wall | 11.42 s | 11.46 s |
| CPU | 20.00 s | 20.17 s |
| Peak RSS | 1,209,688 KiB | 1,221,164 KiB |
| Running compiler binary | 21,177,912 bytes | 21,059,208 bytes |

This still establishes no whole-compiler speed or peak-memory win. The JSON
benchmark's median peak RSS fell from 126,360 to 105,240 KiB (16.7%); its
CPU was 0.39 -> 0.37 seconds. Nbody was 0.75 -> 0.72 seconds CPU and
mandelbrot 0.38 -> 0.39 seconds. Their timing differences are small.

Alloc was noisy: three pairs gave 1.47 -> 1.77 seconds CPU. A follow-up
used warmups, one CPU affinity, alternating order and nine pairs: median
wall 1.49 -> 1.55 seconds, CPU 1.48 -> 1.55 seconds, and peak RSS
786,244 -> 786,248 KiB. The longer run narrows the apparent slowdown to
4.7%, but does not establish an allocation-speed improvement. Keep this
result visible; raw pairs are `alloc-repeat.json` in the same directory.
The isolated compaction comparison produced identical alloc executables.

Relative to the original baseline, JSON and mandelbrot executables remain
245,184 and 179,432 bytes; alloc grows 179,928 -> 184,024 bytes, and nbody
183,432 -> 187,528 bytes. All four output checks passed.

## Non-mutating root facts

The next IR cleanup deletes `SCold`, its global site numbering and the
preparation pass that rewrote every function body. Roots now records the
references at each cold site outside the body, indexed by list and position.
Two occurrences of the same statement object remain distinct. Fingerprints
and the inlining cost model keep the previous cold-site cost, so this
representation change preserves generated code.

Three quiet alternating pairs against `68c4bee9`, compiling the same current
source and std with fresh caches and four backend workers, gave:

| Self-build | Before | After |
| --- | ---: | ---: |
| Median wall | 11.33 s | 10.67 s |
| Median CPU | 18.61 s | 17.93 s |
| Peak RSS | 1,215,360 KiB | 1,216,148 KiB |
| Compiler binary | 21,067,440 bytes | 21,055,040 bytes |

Wall time fell 5.8%, CPU 3.7%; peak memory is effectively unchanged. These
are three local samples, not an established large compiler-wide improvement.
All three pairs produced byte-identical self-built executables. JSON,
alloc, nbody and mandelbrot executables also remained byte-identical at
245,184, 184,024, 187,528 and 179,432 bytes respectively, including their
output checks. Raw results: `bin/lean-stats-Er8el9/results.json` in the
development workspace.

Production sources fall by 16 lines to 59,387 compiler + 43,782 runtime =
103,169 lines (still two above the original branch baseline). The quick
tier now includes a root-facts regression: the input stays unchanged,
shared statements have independent sites, and a repeated analysis agrees.
It runs under `RT_VERIFY=1` with a 64 KB nursery. All eight quick lanes,
the cold/warm/cache-off fixpoint, and 25 x64/arm64/wasm crosshost outputs
passed. Direct AST-to-SSA construction remains unfinished.

The broader `make check` completed 23/25 lanes successfully, including
the 16 KB nursery, glibc, shared libraries, JNI, Mach-O, legacy wasm EH and
debug-info checks. The arm64 and Windows execution lanes failed with QEMU
and Wine absent from the environment; they are not validated execution
targets here. Crosshost still compared their generated arm64 code.

## Reusing liveness masks

Root liveness now owns one working mask per statement sequence. Nested
sequences copy their borrowed input; ordinary statements update their
owned mask. Loop targets and exception-handler requirements stay unchanged
while a body is analyzed. This removes copies at most statements and
reuses the bitset union's change flag for loop convergence.

Three alternating self-build pairs against `8fc9525c` produced identical
executables. Median wall was 11.91 -> 11.70 seconds, CPU 19.08 -> 18.93
seconds and peak RSS 1,214,120 -> 1,213,992 KiB. These timing and peak
differences are small. Median allocation reported by the runtime was
10,962 -> 10,927 MB; there is no major whole-program memory win here.
The compiler stays 21,055,040 bytes; the four benchmark executables remain
byte-identical at the sizes listed above. Production Haxe source falls
one further line to 103,168 total. Raw pairs are under
`bin/lean/ir-migration/owned-{before,after}-{1,2,3}.log`.

The root-facts regression now covers loops and handler requirements too.
Validation: 8/8 quick lanes, the byte-identical fixpoint, 25/25 crosshost
comparisons, 200 optimized/checked fuzz programs (seed 3000), and 100
Eval/native fuzz programs (seed 5000). A focused `make check` on TryGc,
DeepGc, NativeArrayLiteral, BigInit, Regress and ObjectMapGc passed 23/25
lanes; QEMU and Wine are still absent. Direct AST-to-SSA remains unfinished.

## Compacting MIR value tables

After the last MIR pass, instructions removed from blocks used to remain in
`MFunc.vals`. They retained their objects and left holes in the ids used to
size backend scratch storage. Compaction preserves surviving id order,
rewrites operands, and copies shared operand vectors before renaming them.
It skips functions with fewer than 25% obsolete entries. The regression
covers shared vectors, forward phi operands, negative operand sentinels,
and repeatability.

Three alternating pairs, using one compiler with compaction disabled and
enabled, produced byte-identical self-built executables in every pair.
Median wall was 11.39 -> 11.18 seconds, CPU 19.02 -> 18.87 seconds, and
peak RSS 1,220,244 -> 1,220,224 KiB. These small timing differences do not
establish a major compiler speedup or peak-memory reduction. The JSON,
alloc, nbody and mandelbrot executables were also byte-identical. Raw
measurements are under `bin/lean/ir-migration/compact-values/`.

A self-build with counters reduced the value tables presented to the
backends from 4,379,795 to 3,852,002 entries (527,793 fewer, 12.1%). This
is an aggregate count across functions, not a peak-memory percentage.
The compiler with the final counters is 21,059,208 bytes, 4,168 bytes larger
than `91770d20`. The four benchmark
executables remain at 245,184, 184,024, 187,528 and 179,432 bytes.
Production sources are 59,436 compiler + 43,782 runtime = 103,218 lines:
50 added by this change and 51 above the original baseline. The gain here
is less obsolete MIR storage, not a net source reduction.

Validation so far: all eight quick lanes (298 native cases, again under
GC/tag verification, and 274 wasm cases), 200 optimized/checked fuzz programs
(seed 6000), 100 Eval/native programs (seed 7000), the cold/warm/cache-off
fixpoint, 25 crosshost comparisons including the compiler, and eight cases
through the MIR interpreter. The focused `make check` passed 23/25 lanes,
including 32 further crosshost comparisons; QEMU and Wine are absent.
The focused full tier completed 29/53 lanes, including 73 crosshost
comparisons, another byte-identical fixpoint and 400 threaded stress runs.
Its other lanes require QEMU, Wine, wasmtime or the pinned reference compiler
(and artifacts that reference self-check would create). Both wasm exception
modes built the full port and wrote compiler HXB archives; their reference
comparisons remain unverified. No test expectations or exclusions changed.
A separate native-versus-Wasm comparison of every entry in the generated
compiler HXB archives passed; upstream reference conformance remains
unverified.

## Root-slot initialization analysis

Slot initialization now runs only when liveness found a rooted local.
Within that pass, ordinary assignments update their sequence's owned mask;
branches, loops and handlers retain their separate copies. This removes
per-assignment copies without changing the public analysis API or the
resulting slot layout. Tests cover interfering arguments, disjoint roots,
one-sided and two-sided branch assignments, and handler initialization.
A separate regression keeps safe-region returns visible to liveness even
when the function's summary says it does not allocate.

Three alternating four-worker self-build pairs against `bc7a9ee0` gave
13.95 -> 12.03 seconds median wall and 22.69 -> 20.96 seconds CPU.
These are local samples, not an established general compiler speedup.
Peak RSS was 1,217,852 -> 1,220,824 KiB; reported allocation was
10,939 -> 10,931 MB. There is no meaningful peak-memory or allocation win
in those results. Every pair produced identical executables. JSON, alloc,
nbody and mandelbrot also remained byte-identical at their previous sizes,
with their output checks run under GC verification. Raw results are under
`bin/lean/root-init/final/`.

The compiler remains 21,059,208 bytes. Production source is 59,441 compiler
+ 43,782 runtime = 103,223 lines (five added). Validation: 8/8 quick lanes,
200 optimized/checked fuzz programs (seed 8000), 100 Eval/native programs
(seed 9000), the byte-identical fixpoint and 25 crosshost comparisons.
The focused check tier passed 23/25 lanes, including 32 further crosshost
comparisons; QEMU and Wine remain unavailable.

## Raw-address validation across safe regions

The raw-address validator used to skip every function inferred to have no
ordinary GC points. That inference still permits blocking safe regions,
where another thread can collect and move objects. A raw heap pointer held
across such a region can therefore become stale. The validator now checks
these functions and preserves the opt-out for explicit low-level contracts.
Comments distinguish the allocation summary from the movement guarantees.

The previous compiler accepted both new rejection cases: a pointer held
across manual region transitions, and one held across a call that enters a
region. The fixed compiler rejects both. A positive case retains ordinary
no-GC address helpers and verifies that an explicit unsafe contract remains
available. This change does not claim to make explicitly unsafe code safe.

Validation passed all eight quick lanes (301 native and GC-verification
cases, 277 Wasm cases), 100 optimized/checked fuzz programs (seed 10000),
100 Eval/native programs (seed 11000), and 28 focused crosshost comparisons.
The focused check tier passed 23/25 lanes, including 36 further crosshost
comparisons; QEMU and Wine are absent. The full tier passed 29/53 lanes,
including 82 byte-identical crosshost comparisons, 400 native thread stress
runs and the byte-identical cold/warm/cache-off fixpoint. Its remaining
lanes require QEMU, Wine, wasmtime or the unavailable pinned reference
compiler and artifacts derived from it. No exclusions were weakened.
Logs are under `bin/lean/raw-region/final/`.

The compiler remains 21,059,208 bytes. The timing samples above measure
the root-initialization optimization independently; they do not establish
a combined branch speedup or a peak-memory reduction. The single-IR
migration described below remains unfinished.

## Compact MIR instruction flags

The eight independent boolean fields on every MIR instruction now share
one word. Inline accessors preserve the existing reads and writes, including
clearing individual flags without changing the others. There is no extra
allocation or pointer indirection. An isolated native layout probe measured
184 -> 160 bytes per instruction, including its header (13% smaller).

Three alternating four-worker self-build pairs against `8916a55f`, using
the same current source and std with fresh caches and module caching off,
produced byte-identical executables. Medians were 13.39 -> 13.17 seconds
wall, 23.01 -> 21.62 seconds CPU and 1,214,808 -> 1,217,908 KiB peak RSS.
Runtime-reported cumulative allocation was 10,937 -> 10,839 MB. Thus the
instruction representation is smaller and these local samples use 6.0%
less CPU, but there is no peak-memory win or established general speedup.
The resulting compiler grows 21,059,208 -> 21,064,144 bytes. Raw pairs and
the layout probe are under `bin/lean/mir-flags/`.

JSON, alloc, nbody and mandelbrot binaries are byte-identical to `8916a55f`
at their previous sizes, with matching output checks under GC verification.
Validation passed all eight quick lanes (301 native, 301 GC-verification
and 277 Wasm cases), 100 optimized/checked fuzz programs (seed 12000),
100 Eval/native programs (seed 13000), 52 focused crosshost comparisons
in check, and 118 crosshost comparisons in full. The compiler rebuilt
byte-identically with caches cold, warm and disabled. Check passed 23/25
lanes and full 29/53; failures require the absent QEMU, Wine, wasmtime or
pinned reference compiler and its derived artifacts. The native thread
stress lanes passed all 60 check and 400 full runs. No exclusions changed.
Production source grows by 23 lines to 59,467 compiler + 43,782 runtime =
103,249 lines; net source reduction remains unmet.

## Whole-branch refresh after packed flags

A fresh three-pair comparison against the original `5b713c4f` baseline,
after the validation jobs finished, still establishes no whole-compiler
speed or peak-memory improvement. Raw data:
`bin/lean-stats-41jiTy/results.json`.

| Self-build | Original baseline | Current |
| --- | ---: | ---: |
| Median wall | 12.93 s | 13.27 s |
| Median CPU | 21.76 s | 22.84 s |
| Peak RSS | 1,211,228 KiB | 1,210,888 KiB |
| Running compiler binary | 21,177,912 bytes | 21,064,144 bytes |

The wall and CPU medians are 2.6% and 5.0% worse in this run. Current
self-build CPU samples span 19.73 to 24.40 seconds; these noisy samples
do not establish a consistent regression either. Keep the adverse medians
visible, and do not add together improvements from isolated experiments.

JSON again uses 126,360 -> 105,240 KiB peak RSS (16.7% less), with
0.45 -> 0.42 seconds CPU. Alloc is 1.86 -> 1.90 seconds CPU with flat peak
RSS; nbody is 0.85 -> 0.82 seconds and mandelbrot 0.44 -> 0.44 seconds.
All four output checks passed. Their executable sizes match the earlier
whole-branch refresh: JSON and mandelbrot unchanged, alloc and nbody each
one 4 KiB page larger than the original baseline. The single-IR migration
remains unfinished.

## Rejected experiments

These experiments were measured and removed rather than retained behind
switches. Three alternating pairs used four backend workers, fresh caches,
module caching disabled, GNU time and runtime allocation statistics.

1. Release structured function bodies after their last compilation or
   inline-template consumer. Exclude resident builds, interpreter builds
   and Mir hosts, whose later consumers need those bodies. Retain versus
   consume produced the same executable in every pair. Median peak RSS
   was exactly 1,218,660 KiB on both sides; wall time was 11.44 -> 11.41
   seconds. It failed the experiment's 10% peak-memory or 5% CPU benefit
   gate: the peak was unchanged, and median CPU improved less than 5%.
2. Move five call ABI fields out of every MIR instruction into a lazy
   payload. Outputs were identical. Median wall time was 11.35 -> 11.88
   seconds, CPU 19.05 -> 19.77 seconds and peak RSS 1,206,104 -> 1,206,232
   KiB. Allocation fell less than 1%. The added accessors and indirection
   did not pay for themselves.
3. Replace structured root placement with conservative reference cells and
   MIR dead-cell elimination. Fix the resulting dead-reference retention
   and changed call-stack inlining; the experiment then passed all eight
   quick lanes, and large objects were reclaimed inside a try in both
   optimized and checked builds. After dead-cell elimination, three pairs
   gave 19.09 -> 19.14 seconds CPU with unchanged peak memory, while the
   generated compiler grew from 21,067,464 to 22,394,568 bytes. Limiting
   clears to paths with later collection reduced it to 22,292,128 bytes,
   still 5.8% larger. The replacement failed to pay for that code growth.
   It is not a production alternative or a completed SSA-root migration.
4. Retire inactive GC worker cohorts after four minor collections instead
   of sixteen. Three paired self-builds produced identical outputs. Median
   wall was 11.67 -> 11.26 seconds and CPU 20.59 -> 18.68 seconds, meeting
   the experiment's 5% CPU threshold. Peak RSS stayed 1,220,484 ->
   1,220,476 KiB. However, median exit RSS rose 958 -> 1,127 MiB and the
   runtime reported 1,188 -> 1,366 MB promoted. The increased resident old
   data did not suit the memory-reduction goal, so the default policy stays
   unchanged. These three local timing samples also overlap; no general
   speed claim follows. Raw data: `bin/lean/gc-cohort-4/self.json` and its
   collector logs. The alternative exists only among ignored measurements.
5. Find rooted locals first, then repeat liveness to construct interference
   only for those locals. Outputs stayed identical and focused tests passed,
   but three pairs gave 24.74 -> 26.14 seconds median CPU and 10,933 ->
   11,026 MB allocated. The second traversal outweighed the smaller graph.
   Raw results and the discarded source are under `bin/lean/root-graph/`.
   A separate no-GC-summary shortcut was also removed: safe-region returns
   can observe moved objects even in a function that never allocates.

## Remaining architectural work

Object MIR already lowers to memory MIR **in place**. The extra
representation to remove is structured `ir/Ir` between the typed AST and
SSA. Renaming or combining MirBuild and MemLower does not remove it.

A complete migration must move these consumers as part of the same series:

- Reachability and reflection analysis currently traverse structured bodies.
- Root analysis computes reference liveness and spills before SSA exists.
- Cache fingerprints and resident lowered-body reuse depend on that form.
- Inline templates currently obtain SSA by rebuilding retained bodies.

The intended endpoint is direct object-SSA construction from typed AST,
SSA-based roots and reachability facts, and cache summaries independent of
a retained structured body. Delete the old statement/expression builders
and consumers once the new path passes the same checks; do not leave two
production lowering paths. This migration remains unimplemented.

The available checks have included the full quick tier, byte-identical
cold/warm/cache-off fixpoints, representative x64/arm64/wasm crosshost
outputs, 200 optimized/checked fuzz programs and 100 Eval/native programs.
Official reference conformance and the complete full tier remain unverified:
the reference download domains are denied here and several external target
toolchains are absent.
