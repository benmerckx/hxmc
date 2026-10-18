# ml2hx initial results

Measured on 2026-10-18, Linux x86-64, starting from hxmc `6ea2ca1` and upstream
Haxe `fef28473708b3f2364796c159d9f5144c1cf9f68`.

**Scope:** the compiler remains the existing port with three modules replaced
by generated sources and ABI adapters. These results do not establish that the
whole compiler can be generated or that an old compiler has been fully ported.

## Validation

| Check | Result |
| --- | --- |
| Exact regeneration of committed sources | pass |
| Generator behavior tests | 7/7, including native OCaml golden comparison |
| Generated module algorithms and adapters | pass on Eval, JS and native hxmc |
| Semantic fixture | native OCaml = Eval = JS = native hxmc output |
| Current upstream implementation files parsed | 297/297 |
| Full generated-module compiler build | pass |
| HXB conformance against official pinned nightly | 279 pass + 7 expected failures, all 286 agree |
| Macro HXB conformance against official pinned nightly | 66/66 |
| Display requests against official pinned nightly | 679/679 |
| Server harness | 566 case requests passed; local process cleanup hung, no complete suite result |

The semantic fixture covers operand and binding evaluation order, short circuit
operations, shared references, record updates, reuse of a partial application,
100,000 self tail calls, constructor patterns/guards, byte strings and 63-bit
integer limits. CMT input is restricted to the native 64-bit frontend because
JS cannot faithfully unmarshal native-width integers.

The server harness was also tried on the official compiler's Eval host; the
edit scenarios agreed through the final edit case, then cleanup similarly
stalled. This is not counted as a full server pass. CI runs the unchanged
server harness in its normal GitHub runner environment.

## Historical coverage

All listed generated modules execute successfully on both Eval and JS. The
matrix does not build complete historical compiler binaries.

| Haxe release | Implementation files parsed | Modules generated | Notes |
| --- | ---: | ---: | --- |
| 4.0.5 | 192/192 | 1 | server config; ring absent |
| 4.1.5 | 205/205 | 2 | server config and ring |
| 4.2.5 | 214/214 | 2 | server config and ring |
| 4.3.7 | 227/227 | 2 | server config and ring |

The 4.x rings lack the newer `find` function. The tests select that assertion
from actual generated exports, not a fabricated compatibility implementation.
Exact commits and results: [ml2hx-history.json](data/ml2hx-history.json).

## Quick benchmark against the current port

Both native binaries were built by the same hxmc tool. Each compiles identical
input sources, in a fresh process, with parallelism disabled and module caching
disabled. The filesystem is warmed equally; run order alternates. Values below
are medians of five measured runs after one warmup per binary and case. GNU
time supplies process CPU time and peak RSS; node measures elapsed time with a
higher-resolution clock for the small case.

| Input to HXB | Current port | Generated-module port | Generated/current | Peak RSS, both |
| --- | ---: | ---: | ---: | ---: |
| Small program | 0.026 s | 0.026 s | 0.989× | 28.0 MiB |
| Compiler sources (`haxe/src`) | 5.755 s | 5.653 s | 0.982× | 639.6 MiB |

Binary sizes: 19,668,192 bytes current, 19,673,232 bytes generated-module port
(+5,040 bytes, about 0.026%). The small timing differences are noise-sized;
there is no measurable regression in this slice. These mostly cold-process,
warm-filesystem measurements are not a compilation-server benchmark, nor a
JS/WASI frontend comparison.

Raw samples, CPU times and memory: [ml2hx-benchmark.json](data/ml2hx-benchmark.json).
Reproduce with `make port port-generated && make ml2hx-bench`. Set
`ML2HX_TIME` when GNU time is not at `/usr/bin/time`, and `ML2HX_BENCH_N` to
change the sample count (minimum three).

Larger migrations still need profiling. The initial implementation intentionally
uses conservative curried closures and boxed 63-bit arithmetic; moving hot
compiler code onto those representations may have a different cost. There is
not enough migrated code here to estimate whole-port optimization effort.
