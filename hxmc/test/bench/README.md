# Array, NativeArray and Vector microbenchmark

```sh
make bench-arrays
make bench-arrays ARRAY_BENCH_ARGS="65536 256 9 bin/vector-bench/results.json"
```

The arguments are element count, passes per sample, number of samples, and
an optional JSON output path (defaults: 65536, 128, 7). The executable is
`bin/vector-bench/m`: run it directly to keep the build out of a
measurement, or pinned to a CPU (`taskset -c 2 bin/vector-bench/m ...`).
Each sample should last at least several milliseconds.

`VectorBenchMacro` generates separate, concretely typed functions for
`Int`, `Float`, `Int64`, `Bool`, `String`, class instances, anonymous
objects, `Null<Int>` and `Dynamic` (a generic `Array<T>` benchmark would
measure boxed storage even for numbers). `Dynamic` holds integers;
`Null<Int>` alternates integers and null.

The workloads use the same loops and values for all three containers:

- `read`: indexed sequential traversal, accumulating a checksum.
- `read4`: four independent accumulators, so that one addition chain does
  not bound the read throughput.
- `write`: sequential stores of one of two values, alternating each pass.
- `update`: read each element, toggle between the two values, store it.
- `alloc`: construct a fresh container and fill every element each pass.

Arrays are sized with `resize(n)`, native arrays with `new NativeArray(n)`,
vectors with `new Vector(n)`. Strings, objects and boxed values are made
before timing and reused: they are old or static by then, so reference
stores skip the barrier's helper call (a store of a young object into an
old container still needs it). Every container gets a warmup, samples
rotate which container runs first, and checksums are compared after every
sample. Results are median nanoseconds per element visited; the ratio is
Array time over Vector time (above 1 favors Vector).

## Measurements (2026-10-17)

Linux x86-64, Xeon E-2356G, CPU 2, no bounds checks; 65536 elements, 256
passes, medians over 14 samples. **Array / NativeArray / Vector**, ns per
element:

| Element | Read4 | Write | Update | Allocate + fill |
| --- | ---: | ---: | ---: | ---: |
| Int | 0.533 / 0.373 / 0.373 | 0.501 / 0.288 / 0.288 | 0.867 / 0.536 / 0.536 | 0.689 / 0.385 / 0.388 |
| Float | 0.427 / 0.267 / 0.267 | 0.543 / 0.288 / 0.288 | 1.058 / 0.590 / 0.590 | 0.823 / 0.465 / 0.467 |
| Bool | 0.695 / 0.533 / 0.534 | 0.540 / 0.288 / 0.288 | 0.987 / 0.735 / 0.430 | 0.763 / 0.310 / 0.311 |
| Object | 0.688 / 0.427 / 0.427 | 2.993 / 0.548 / 0.573 | 2.898 / 0.914 / 0.858 | 1.477 / 0.763 / 0.766 |
| Null<Int> | 2.021 / 1.781 / 1.991 | 2.769 / 0.653 / 0.653 | 3.897 / 1.935 / 2.178 | 1.326 / 0.891 / 0.889 |

Dependent-sum reads (`read`) are mostly tied with Array.

With `-D hxmc.native-array-outofbounds=throws` or `silent` (each access
tests its index), these loops take 10–50% longer than unchecked, the
dependent reads (`read`) none: Int write 0.29 → 0.43 (throws) / 0.33 ns
(silent), update 0.44 → 0.60 / 0.65 ns, still faster than Array's 0.55 and
0.95 ns (2026-10-17; build the benchmark with the define to compare).
