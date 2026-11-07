# Focused compiler/runtime measurements

These isolate individual changes. They do not measure whole-compiler speed.
Use `make lean-stats` for the whole-program comparison.

Build with the compiler and standard library being measured, from the
repository root (the environment must point `HAXE_STD_PATH` at
`haxe/upstream/std` and `HXMC_RT_DIR` at `bin/hxmc/rt`):

```sh
mkdir -p bin/micro
bin/hxmc/hxmc bin/micro/buf -cp hxmc/src -cp hxmc/test/micro \
  -main BufBench -cp bin/hxmc/std --custom-target hxmc
bin/hxmc/hxmc bin/micro/snapshot -cp hxmc/test/micro \
  -main StringBufSnapshotBench -cp bin/hxmc/std --custom-target hxmc
/usr/bin/time -f '%e %U %S %M' bin/micro/buf
/usr/bin/time -f '%e %U %S %M' bin/micro/snapshot
```

For a baseline comparison, preserve that revision's compiler, merged std,
and (for BufBench) `hxmc/Buf.hx` on an overlay class path that takes
precedence over the current `hxmc/src`. Alternate baseline/current runs
at least three times without other builds competing for CPU. Compare
stdout exactly; report median wall/CPU time and peak RSS. GNU time's
hundredth-second resolution is insufficient to quantify very fast runs.

BufBench emits and reads 4M little-endian words for eight rounds, then
checks unaligned patches. StringBufSnapshotBench takes 8192 immutable
snapshots of one unchanged 1 MiB buffer. It deliberately measures the
read-mostly case; mutation, widening and clear correctness are covered
by the StringBufSnapshot corpus case.
