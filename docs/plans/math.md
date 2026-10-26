# Plans: math

Math is one implementation on every target: `hxmc/std/hxmc/rt/LibM.hx`,
musl's algorithms in Haxe, bit-identical to musl's C. Why printed floats
can differ from the reference's: [testing.md](../testing.md#two-exceptions-to-byte-identity).

## Correctly rounded math

The `libm` branch (98d9d82, 374bb61; parked) has exp, log and pow from
Arm's Optimized Routines (bit-identical to glibc), sin, cos, tan, asin,
acos, atan and atan2 from CORE-MATH (correctly rounded), and fma in
hardware where available. With it the port would differ from the reference
only where glibc is an ulp off, and the fuzzer's float tolerance could
shrink.

It replaces LibM's functions only where it is no slower at run time,
compile time and size:

- CORE-MATH's trig is slower than musl even in C (cos 17 ns, tan 24 ns
  against 6.5 and 10.5 on x86-64) and has about 166 KB of tables (as
  `Mem.words`: read-only data).
- One implementation only: where a CORE-MATH function costs too much, that
  function keeps musl's algorithm. No second variant behind a define.

The code generation math would like (jump tables, cmov, live-range
splitting) is in [codegen.md](codegen.md#smaller-items).
