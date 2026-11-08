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

## Rejected IR experiments

Two experiments were measured and removed rather than retained behind
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
