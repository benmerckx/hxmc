# SIMD: portable 128-bit vectors (`hxmc.simd`)

The design record of hxmc's vector types: what other languages do, what
hxmc does and why, and what is left. The API, its semantics and the code
generation described here are built (`hxmc/std/hxmc/simd`,
`hxmc/src/hxmc/SimdOps.hx`); [Later](#later) lists what is open.

In short: nine value types of 128 bits (`F32x4`, `F64x2`, `I8x16`,
`U8x16`, `I16x8`, `U16x8`, `I32x4`, `U32x4`, `I64x2`), one register each,
with WebAssembly simd128's operations and its exact results on every
target: SSE4.1 on x86-64, NEON on arm64, simd128 on wasm32, and a scalar
implementation with the same results everywhere else (the Mir interpreter,
Eval, JavaScript, any other Haxe target).

## Prior art

| | Width | Portable layer | Per-machine layer | Results across machines | Shuffles | FMA |
| --- | --- | --- | --- | --- | --- | --- |
| WebAssembly simd128 | 128 | the only layer | none | identical, but NaN bits | 16 constant byte lanes of two vectors; `swizzle` at run time (index >= 16: 0) | none |
| wasm relaxed-simd | 128 | on top of simd128 | none | may differ (each op lists its allowed results) | `relaxed_swizzle` (out of range: either rule) | `relaxed_madd`: fused or not |
| .NET `Vector128<T>` | 128 (also 64, 256, 512, `Vector<T>`) | `Vector128.Add`, operators, `Shuffle` | `Sse41.*`, `AdvSimd.*`, `IsSupported` folded by the JIT | the portable ops: identical; `*Native`/`*Estimate`: may differ | constant or run time (out of range: 0) | `FusedMultiplyAdd` fused (software if no FMA), `MultiplyAddEstimate` either |
| Rust `std::simd` | any `N` up to 64 | `Simd<T, N>`, operators, `simd_swizzle!` (nightly) | `core::arch` (stable, `unsafe`, `#[target_feature]`, run-time detection) | identical (LLVM's semantics) | constant indices | `mul_add` fused (slow without FMA) |
| Zig `@Vector` | any `N` | builtin operators, `@shuffle`, `@select`, `@reduce` | inline assembly, LLVM intrinsics | identical (LLVM) | `@shuffle` with a comptime mask (negative: the second vector) | `@mulAdd` fused |
| Swift `SIMD4<Float>` ... | 2 to 64 lanes | protocol `SIMD`, `.<` masks, `replacing(with:where:)` | `simd` module, LLVM | identical (LLVM) | subscripting by an index vector | `addingProduct` fused |
| Java Vector API | species (64 to 512, preferred) | `FloatVector`, `lanewise(ADD)`, `VectorMask`, `VectorShuffle` | none (C2 intrinsics) | identical; the fallback is plain Java (allocating, slow) | run time `VectorShuffle` (checked) | `FMA` lanewise, fused |
| Highway (C++) | 128 to scalable (SVE, RVV) | `Add(d, a, b)` on tags (`Full128<T>`, `ScalableTag<T>`) | per-target code through `foreach_target.h`, static and dynamic dispatch | documented as target-dependent for some ops (NaN in `Min`, estimates) | `TableLookupBytes`, `Shuffle2301` ... | `MulAdd`: fused or not, by target |
| GLSL/HLSL | `vec2` to `vec4` | builtin types, `.xyzw`/`.rgba` swizzles, `mix`, `clamp` | none | implementation-defined (precision qualifiers, NaN in `min`/`max` undefined) | swizzles only (constant) | `fma` (fused only when `precise`) |

What each teaches:

- **wasm simd128** is the intersection that x86-64's SSE4.1 and arm64's
  NEON both do well, with every result specified (but a NaN's sign and
  payload). It is the one design that is deterministic and fast on all
  three of hxmc's machine kinds, and one of them runs it as it is.
- **relaxed-simd** shows the price of the last few percent: results that
  differ by machine (`relaxed_madd`, `relaxed_min`, `relaxed_trunc`).
  hxmc's corpus compares outputs bit for bit across seven targets; an
  opt-in relaxed layer can come later ([Later](#later)).
- **.NET** has both layers, the portable one first. The per-machine one
  (`Sse41.Shuffle`, `IsSupported`) is where code stops being portable;
  .NET 9 moved its portable `Min`/`Max` to IEEE 754-2019's NaN-propagating
  rule and added `MinNative`/`MaxNative` for the machine's own: the same
  split as wasm's `min` and `pmin`.
- **Rust** shows the split of `std::simd` (portable, still unstable after
  years, generic over `N`) and `core::arch` (stable, `unsafe`, per
  machine). The generic `N` is what keeps the portable layer unstable:
  each `N` and element type needs legalizing on each machine.
- **Zig** and **Swift** have builtin vector types of any length, lowered by
  LLVM: convenient, and they inherit LLVM's choices (fused `@mulAdd`, NaN
  rules of `minnum`).
- **Java's Vector API** keeps the shape abstract (`SPECIES_PREFERRED`),
  and its fallback, when C2 does not intrinsify, allocates: a lesson for
  the scalar side, which must stay unboxed and fast enough to run tests.
- **Highway** is the most complete portable library (scalable vectors,
  dynamic dispatch) and documents where results differ by target; it is
  also the most to learn.
- **GLSL/HLSL** have the ergonomics games want (`v.xyzw`, `v.zyx`
  swizzles, `clamp`, `mix`) without fixing results: GPUs differ.

## The API, and why

```haxe
import hxmc.simd.*;

var a = F32x4.make(1, 2, 3, 4), b = F32x4.splat(0.5);
var c = (a * b + F32x4.splat(1)).clamp(F32x4.zero(), F32x4.splat(2));
var m = a.gt(b);                         // an I32x4 mask: all ones where true
var d = F32x4.select(m, a, b);           // a where m, else b
var s = a.swizzle(3, 2, 1, 0).sum();     // constant lanes; a Float
var px = U8x16.load(bytes, 16);          // 16 bytes, unaligned, checked
var w = U16x8.extendLow(px);             // widened
U8x16.narrow(w.asI16x8(), w.asI16x8()).store(bytes, 32);   // saturated
```

- **Nine types, one width.** `F32x4`, `F64x2`, `I8x16`, `U8x16`, `I16x8`,
  `U16x8`, `I32x4`, `U32x4`, `I64x2`: abstracts over one 16-byte
  `@:hxmc.struct` (`V128`, four little-endian 32-bit words). Signedness is
  in the type, as wasm's `_s`/`_u` instructions are: `I8x16.min` and
  `U8x16.min`, `>>` arithmetic on signed lanes and logical on unsigned ones,
  `narrow` signed or unsigned by its result's type. `asU8x16()`,
  `asF32x4()`, ... reinterpret the same bits (no instruction).
  Fixed width rather than generic `N` (Rust, Zig): 128 bits is what every
  target has, one register; 256 bits is a later tier with run-time dispatch.
- **Operators** where Haxe has them: `+ - *` (and `/` for floats), unary
  `-`, `& | ^ ~` and shifts on integer lanes. Named methods otherwise, in
  Haxe's style: `addSat`, `subSat`, `avg`, `mulQ15`, `dot`, `min`, `max`,
  `pmin`, `pmax`, `abs`, `sqrt`, `floor`, `ceil`, `trunc`, `round`,
  `clamp`, `mulAdd`, `andNot`, `sum`.
- **Comparisons give masks**, not Bools: `eq ne lt le gt ge` return the
  integer type of the same lanes (all ones or zero), for `select` (bitwise:
  `mask ? a : b` per bit) and `any`, `all`, `bitmask`. `==` on vectors is
  the struct's field comparison, as for any struct: a Bool.
- **Lanes and shuffles are constants.** `get(i)`, `with(i, x)` and every
  shuffle index must be known at compile time (a literal, or arithmetic on
  an inline function's literal arguments): they are immediates on every
  machine. `swizzle` of `U8x16` by another `U8x16` is the one run-time
  permutation (wasm's `i8x16.swizzle`, SSSE3's `pshufb`, NEON's `tbl`).
- **Memory**: `load`/`store` on `Bytes` (checked: `OutsideBounds`),
  `loadSpan`/`storeSpan` on spans (checked as spans are, in kernels:
  [interop.md](../interop.md#spans)), `loadPtr`/`storePtr` on a `Ptr`
  (`@:hxmc.unsafe`, unchecked); 16 bytes, or the low 8 or 4
  (`load64`, `load32`: the rest zero; `store64`, `store32`). Unaligned, so
  there is no aligned variant to misuse: on SSE4.1, NEON and wasm an
  unaligned 16-byte access is one instruction at the speed of an aligned one
  when it does not cross a cache line.
- **Widen and narrow**: `extendLow`/`extendHigh` (signed by type),
  `narrow` (saturating), `F64x2.promoteLow`, `F32x4.demote`, conversions
  `toI32x4`, `fromI32x4`, `fromU32x4`, `F64x2.fromI32x4Low`.
- **Reductions**: `sum` (in a fixed pairwise order), `any`, `all`,
  `bitmask`; min/max reductions are a `swizzle` and a `min` away.

The names of the underlying operations are wasm's (`f32x4.add`,
`i8x16.narrow_i16x8_u`): `SimdOps.LIST` maps each to its opcode, the one
number Mir, every instruction selection and the scalar implementation key
on.

Not in this layer, on purpose: `i64x2` ordering, `i64x2.mul` and
`abs` (SSE4.1 has no `pcmpgtq`, which is SSE4.2, nor a 64-bit multiply,
which is AVX-512), `i8x16.popcnt`, the extended multiplies and pairwise adds,
unsigned float conversions of `f64x2`. Each is a sequence on some target;
they come when a kernel needs them.

## Semantics

Every operation has wasm simd128's result, bit for bit, on every target
(the corpus checks it: [Tests](#tests)). The decisions that are not
obvious:

- **Integer arithmetic wraps** (`+ - *`, shifts by the count modulo the
  lane's width, `neg`, `abs` of the minimum is the minimum). Saturation is
  explicit: `addSat`/`subSat` on 8- and 16-bit lanes, `narrow`, `mulQ15`
  (`(a * b + 0x4000) >> 15`, saturated: -1.0 times -1.0 is 32767), float to
  integer conversions.
- **Float lanes are IEEE binary32/binary64**, each result rounded to
  nearest even; a lane read (`get`) is exact; `splat` and `with` round a
  Float to float32. No flush to zero: subnormals are kept (SSE and NEON
  default to that; hxmc never sets FTZ/DAZ).
- **NaN in `min`/`max`**: a NaN in either lane gives NaN, and -0 is below
  +0 (IEEE 754-2019 `minimum`/`maximum`, wasm's `min`/`max`). `pmin`/`pmax`
  are the other rule, `b < a ? b : a`, one instruction on every target
  (`minps` with its operands as SSE orders them), for clamps where NaN does
  not matter; `clamp(lo, hi)` is `pmax` then `pmin` (a NaN lane gives
  `lo`). On arm64 `fmin`/`fmax` are wasm's rule; on x86-64 `min`/`max` are
  seven instructions (`minps` in both operand orders, an `or` that keeps
  -0 and NaN, an unordered compare and a mask for the NaN lanes).
- **A NaN's sign and payload are not specified** (as in wasm): targets
  differ in which NaN propagates. Code that prints or hashes the bits of a
  NaN result canonicalizes it first (the corpus's `showF`).
- **FMA is not fused.** `mulAdd(b, c)` is `this * b + c` with two
  roundings, the same everywhere. A fused multiply-add is in neither wasm
  simd128 (only relaxed-simd's `relaxed_madd`, fused or not by machine) nor
  SSE4.1 (FMA3 comes with AVX2-era machines); emulating it exactly where
  the hardware lacks it costs ten times the operation. A fused `fma`
  belongs to the 256-bit tier, which can assume FMA3 ([Later](#later)).
- **Float to integer conversions truncate and saturate; NaN gives 0**
  (`trunc_sat`): `F32x4.toI32x4`, `F64x2.toI32x4` (the two results in lanes
  0 and 1, the others 0). x86-64's `cvttps2dq` gives `0x80000000` for NaN
  and every out-of-range value, so NaN lanes are masked to zero first and
  positive overflow fixed up after (six instructions); NEON's `fcvtzs`
  and wasm's are the rule itself. `U32x4.toF32x4` rounds to nearest even
  (x86-64 has no unsigned conversion: two halves).
- **`round` is to nearest, a half to even** (`roundps` mode 0, `frintn`,
  wasm's `nearest`), not Haxe's `Math.round` (a half up).
- **Shuffles**: lane indices of two vectors, `0` to `2n - 1` (the first's,
  then the second's), constants; a byte shuffle with an index of 32 or
  more is a compile error (`reject/SimdShuffle`), as is a lane out of range
  (`reject/SimdLaneRange`) or not constant (`reject/SimdLane`). `swizzle`
  by a vector at run time gives 0 for an index of 16 or more (wasm's rule;
  `pshufb` needs the index's top bit set for that, so the index is
  saturated first).
- **Bit casts are free and total**: every type reinterprets the same 128
  bits (`asI32x4()`), little-endian on every target.

## The scalar implementation

`hxmc.simd.Ops` is a macro over each operation. On hxmc's native and
WebAssembly targets it expands to the compiler's intrinsic
(`hxmc.simd.Simd`, an extern class: `FnLower.simdCall`, `MirBuild`'s Mir
`VOp`). Everywhere else it expands to `hxmc.simd.Ref`, the same operation
lane by lane on the four 32-bit words, by opcode: the Mir interpreter
(`-D hxmc.interp`, and Mir macros), Eval, JavaScript, and any Haxe target
the types are copied to (`hxmc-portable`, `MkStd.PORTABLE`). Float32
rounding goes through memory on hxmc's interpreter and through
`haxe.io.FPHelper` elsewhere; 32-bit multiplies through `Math.imul` on
JavaScript (`Bits`).

`Ref` is the specification in code: written from wasm's semantics, not
from any machine's output, and the corpus's golden files must match it on
Eval and JavaScript (`make portable-check`) as they match the native
targets. It is a `@:hxmc.kernel` class of small inline functions, so a
build for the interpreter runs it without allocating. It is slow (tens of
instructions an operation) and meant for tests, tooling and the targets
without vectors, not for speed.

## Vectors as values

A vector is a struct value of 16 bytes, so it follows the struct rules
([interop.md](../interop.md#struct-values),
[hxmc.md](../hxmc.md#where-struct-values-are-boxed)): it is never null,
assignment copies, and it lives in locals, parameters, results, fields of
classes and structs, statics, and native memory. What is special is only
where it is in a function:

- **In registers.** `FnLower` gives each intrinsic the addresses of its
  operands and of a fresh slot for its result; `MirBuild.simd` expands it
  into 16-byte loads (`MTy.V128`), the operation and a store; `Sroa`
  promotes every slot that is only loaded and stored whole to a Mir value,
  so a kernel's vectors are SSA values in vector registers, phis across
  loops, and spilled to 16-byte frame slots when there are more than the
  registers (`Lir.isVec`, `Regalloc`'s vector class). A struct of vectors
  (`Mat4`, the IDCT's `Eight`) is scalar-replaced the same way.
- **Boxed where a reference is needed**, as any struct: an `Array<F32x4>`
  element, a `Map` value, a `Null<F32x4>`, `Dynamic`, `Std.string`, and a
  type parameter's slot. The box is 24 bytes (an 8-byte header, the 16
  bytes) and immutable.
- **Type parameters (issue #127).** A value of a type parameter is a tagged
  64-bit word ([hxmc.md](../hxmc.md#values-of-type-parameters)): an Int or
  a Float in the word itself, anything else a reference. A vector does not
  fit in a word, so in a `T` slot it is a reference to its box, as every
  struct is: `id(v)` of a generic `id<T>` boxes `v` and copies it back out.
  `@:generic` or `inline` generic code keeps it unboxed. The corpus builds
  the vector cases with `-D hxmc.verify-tags` too (no box is read as a
  scalar word, no word as a reference).
- **Dynamic.** `var d:Dynamic = v` boxes; `var w:F32x4 = d` copies it back
  out. The box is a `V128`'s: the lane types are compile-time views of it.
- **Closures** take and return vectors (copies, through memory as struct
  values do); a closure cannot capture a vector local (the struct rule).
- **Kernels.** Vector operations are values, so a `@:hxmc.kernel` may use
  them; `loadSpan`/`storeSpan` are spans' accesses and checked as theirs
  are; `loadPtr`/`storePtr` are raw memory and need `@:hxmc.unsafe`
  (`reject/SimdPtrKernel`).

## Code generation

| | x86-64 | arm64 | wasm32 |
| --- | --- | --- | --- |
| registers | xmm0-15 (`movups` moves and spills) | v0-v7, v16-v31 (not v8-v15: AAPCS64 keeps only their low 64 bits across calls) | `v128` locals |
| instruction set | SSE2, SSSE3, SSE4.1 (x86-64-v2) | NEON (every arm64) | simd128 |
| typical expansion | one instruction; a few where SSE differs (float `min`/`max`, conversions out of range, unsigned compares, byte shifts, 64-bit shifts right) | one instruction; a few for `bitmask` and `all_true` | one instruction |
| constants | a 16-byte literal in `.rodata`, `pxor`/`pcmpeqd` for zeros and ones | `movi` for zeros and ones, else two moves through x16 | `v128.const` |

Each instruction selection implements every opcode of `SimdOps.LIST`
(`x64/Isel.hx`, `a64/Isel.hx`, `wasm/WasmGen.hx`); the encoders gained the
SSE `0x0f38`/`0x0f3a` maps with their prefixes (`x64/Asm.hx`: `vx`),
NEON's instructions as their encoding and three registers (`a64/Asm.hx`:
`neon`, `movV`), and wasm's `0xfd` prefix (`wasm/Enc.hx`). Opt treats `VOp` and `VConst` as pure (value
numbering, dead code), never speculates them nor joins them in
if-conversion; `Sroa` promotes `V128` slots.

**x86-64's level: SSE4.1 is required, not detected.** A program that uses
`hxmc.simd` needs an x86-64-v2 machine (SSE4.1, which every x86-64 CPU
since 2008 for Intel and 2011 for AMD has; Windows 11 24H2 and RHEL 9 require
x86-64-v2 themselves). A program that does not use the vector types keeps
hxmc's SSE2 baseline: no other code uses SSE4.1. Emulating SSE4.1 on SSE2
(`pmulld`, `pminsd`, `pmovsx`, `roundps`, `ptest`, `pinsrb`, `pextrb`,
`pblendw`, SSSE3's `pshufb`) would double the code of half the operations
for machines that no longer run current systems; a start-up check that
fails clearly instead of with an illegal instruction is in [Later](#later).

**WebAssembly needs simd128** in the engine: node 16.4 and later, Chrome
91 and Firefox 89 (2021), Safari 16.4 (2023), wasmtime. Only a module whose program
keeps a vector operation contains `v128` (a module with it does not
validate on an engine without it, even if the code never runs).

## ABIs

- **Between Haxe functions** a vector passes as every struct value does,
  on every target: the caller copies it into its frame and passes the
  address; a result is written to an address the caller passes. Inside a
  function, and across inlined calls (`inline` methods, the inliner's
  small functions), it stays in a register. The address costs a store and
  a load per non-inlined call: hot vector code is written with inline
  functions, as `SimdBench`'s kernels are.
- **C functions** take and return a vector as C's native 128-bit vector
  type (`__m128`, `__m128i`, `float32x4_t`, a `vector_size(16)` type),
  by each ABI's rule for it (`CAbi.isVector`):

  | | argument | result |
  | --- | --- | --- |
  | System V x86-64 | the next of xmm0-7 | xmm0 |
  | Win64 | the address of a 16-byte aligned copy (as MSVC passes `__m128`) | xmm0 |
  | AAPCS64 (Linux, Apple, Windows) | the next of q0-q7 | q0 |
  | wasm32 | the address of a copy (the struct rule) | stored at an address passed first |

  On System V and AAPCS64 a vector past the eighth float or vector argument
  register (where C puts it in a 16-byte stack slot) and a vector in a
  variadic call are compile errors (`reject/SimdFfiRegs`): pass a `Ptr`
  there. WebAssembly keeps the struct rule because a C function there is an
  import its JavaScript host implements, and JavaScript takes no `v128`.
  `@:hxmc.callback` functions receive and return vectors by the same rules
  (`SimdFfi`: C calling back into Haxe with vectors). The interpreter's
  calls of C pass no vector registers: a build with `-D hxmc.interp` or
  Mir macros rejects such a call.
- **Registers across calls.** On x86-64 every xmm register is
  caller-saved in hxmc's code; a function entered from C on Win64 saves
  xmm6-15 whole (all 128 bits) when it uses them. On arm64 vectors never
  take v8-v15, whose upper halves a callee need not keep. Spill slots of
  vectors and of float registers in a function with vectors are 16 bytes.

## Tests

| Case | What |
| --- | --- |
| `SimdOps` | every operation on edge values (NaN, -0, infinities, saturation bounds, out-of-range conversions, shifts past the width, every shuffle form), as words |
| `SimdValues` | vectors in fields of structs and classes, statics, call arguments and results, boxed (Array, type parameter, Dynamic, Null), closures, twenty live at once (spills), live across calls, kernels over spans with every access width |
| `SimdExamples` | this page's worked examples against their scalar versions |
| `SimdFfi` | C functions (`SimdFfi.c`, `vector_size(16)` types) taking and returning vectors, eight vector arguments, a vector live across a C call, a callback C calls with vectors (x86-64 Linux and Windows, arm64; not wasm: no C objects) |
| `reject/SimdLane`, `SimdLaneRange`, `SimdShuffle`, `SimdPtrKernel`, `SimdFfiRegs` | a lane at run time, a lane out of range, a shuffle index of 32, raw memory in a safe kernel, a ninth vector argument of a C function |

`SimdOps`, `SimdValues` and `SimdExamples` run bit-exact on x86-64 Linux,
arm64 Linux (qemu), x86-64 Windows (wine), wasm32-wasi (node), the
interpreter build (`--interp`), and, by `make portable-check`, on Eval and
JavaScript against the same golden files; also with `-D hxmc.verify-tags`
and `RT_VERIFY=1`. `SimdFfi` runs where there are C objects (x86-64 Linux
and Windows, arm64). CI runs the corpus on each of the six targets' own
machines too (Linux, Windows and macOS on x86-64 and arm64).

## Benchmarks

`make bench-simd` (`hxmc/test/bench/simd`): three image kernels, each as
plain Haxe over `Bytes` and `Vector` (`bytes`), as a kernel over spans
(`span`), with `hxmc.simd` (`simd`), and in C (`simd_bench.c`: scalar, and
with SSE4.1 intrinsics, the same data and checksums). Nanoseconds per unit
(an 8x8 block, an output pixel): each run the median of 7, the table the
best of 5 runs of the whole benchmark, on a shared virtual Intel Xeon at
2.1 GHz (x86-64 Linux, which varies by up to 40% between runs); gcc 13.3
(its -O3 vectorizes with SSE2); node 22 for wasm32.

| Kernel | hxmc bytes | hxmc span | **hxmc simd** | wasm bytes | wasm span | **wasm simd** | C -O2 | C -O3, no vectorizer | C -O3 | **C SSE4.1 intrinsics, -O2** |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 8x8 IDCT (ns a block) | 192.6 | 197.0 | **86.4** | 192.6 | 200.0 | **74.0** | 168.6 | 131.1 | 172.3 | **52.7** |
| YCbCr to RGBA (ns a pixel) | 3.71 | 3.55 | **1.28** | 4.64 | 3.98 | **1.21** | 2.38 | 2.48 | 2.46 | **0.91** |
| bilinear resize (ns a pixel) | 10.2 | 11.4 | **3.73** | 14.9 | 11.8 | **4.45** | 7.69 | 7.63 | 7.63 | **2.10** |

Against hxmc's best scalar version the vector kernels are 2.2x (IDCT),
2.8x (colour) and 2.7x (resize) faster natively, and 2.6x, 3.3x and 2.7x
on wasm; against gcc's -O3 2.0x, 1.9x and 2.0x (gcc vectorizes none of the
three profitably: its -O3 IDCT is slower than without the vectorizer). On
wasm the IDCT is faster than natively: V8 emits AVX's three-operand forms,
where hxmc's SSE code copies registers before each destructive operation.

The intrinsics column is `SimdKernels` translated one to one into
`<smmintrin.h>` (the same lanes and fixed-point math, each `shuffle` as the
unpack it is), so it compares code generation alone: gcc is 1.6x (IDCT),
1.4x (colour) and 1.8x (resize) faster than hxmc's native code. The
instructions doing the work are the same (64 `pmulld` in both IDCTs, the
same `pshufb`/`pmovzxbw`/`pmaddwd` chain in the resize); hxmc loses on what
surrounds them. In the IDCT (about 1,600 instructions with its check failures, against gcc's 530;
240 vector moves to or from the stack against 54) every vector temporary
goes through memory by address: each `I32x4.splat` is `movd`, a store, a
load, `pshufd`, a store and a load, inside the loop where gcc loads a
constant from `.rodata` once or folds it into `pmulld`'s operand, and the
`Eight` structs are zeroed and written to the frame instead of staying in
registers. In all three, every span access is bounds-checked again (two
compares a load, although `idct`'s callers checked the block), a span's
base address is reloaded from the frame, and an address is `imul $0x1`,
`add` and a load rather than one `(base,index)` operand; a byte `shuffle`
of two vectors that is an unpack (the colour conversion's interleave) is
two `pshufb` and a `por`, a `shuffle` with `U8x16.zero()` (the resize's
`pairs`) the same, where one `punpcklbw`, or one `pshufb` with zeroing
indices, does it. Follow-ups, none done here: splats of constants as
constant-pool loads hoisted out of loops; vector temporaries and returned
structs of vectors kept in registers (no address-taken copies); span checks
of one access range hoisted or merged with an earlier check; addressing
modes folded into loads and stores; unpack patterns recognized in
`shuffle`, and a shuffle with a zero vector as one `pshufb`. libjpeg-turbo's
own SIMD IDCT is not in the table: only TurboJPEG's whole-image API is
installed here, which does not expose the IDCT alone.

The vector kernels compute exactly what the scalar ones do (the same
checksums): the IDCT as libjpeg's `jpeg_idct_islow` four columns a vector
with a transpose between the passes, the colour conversion sixteen pixels
a step with saturating narrows as the clamp, the resize one output pixel a
step with `I16x8.dot` doing both horizontal taps of two channels at once.

## Worked examples

### 8x8 inverse DCT

`SimdBench.SimdKernels.idct`: the coefficients' rows widened to 32-bit
lanes and dequantized, libjpeg's butterfly on eight vectors (four columns
at once, the left and right halves of the block), a 4x4 transpose of
32-bit lanes (two rounds of `shuffle`), the butterfly again on the rows,
then the output narrowed twice (saturating: the clamp to 0-255) and
transposed as 16-bit lanes:

```haxe
static inline function butterfly(i0:I32x4, ..., i7:I32x4, shift:Int, round:Int):Eight {
	var z1 = (i2 + i6) * c(4433);
	var tmp2 = z1 + i6 * c(-15137), tmp3 = z1 + i2 * c(6270);
	var tmp0 = (i0 + i4) << 13, tmp1 = (i0 - i4) << 13;
	...
	e.v0 = (tmp10 + tmp3 + k) >> shift;
	...
}
// a 4x4 transpose: rows a, b, c, d to columns
var t0 = a.shuffle(b, 0, 4, 1, 5), t1 = c.shuffle(d, 0, 4, 1, 5);
var col0 = t0.shuffle(t1, 0, 1, 4, 5), col1 = t0.shuffle(t1, 2, 3, 6, 7);
// eight 32-bit lanes to bytes, clamped
U8x16.narrow(I16x8.narrow(lo0, hi0), I16x8.narrow(lo1, hi1)).storeSpan(out, o);
```

`Eight` is a struct of eight `I32x4`, returned by an inline function: it
is scalar-replaced, its fields registers.

### YCbCr to RGBA

`SimdKernels.yccRgba`: sixteen pixels a step, each channel widened to four
`I32x4`, the fixed-point products of JFIF's conversion, then narrowed with
saturation and interleaved by byte and 16-bit shuffles:

```haxe
var yv = U8x16.loadSpan(y, i), bv = U8x16.loadSpan(cb, i), rv = U8x16.loadSpan(cr, i);
var y0 = y32(yv, 0), b0 = y32(bv, 0) - k128, r0 = y32(rv, 0) - k128; // ... groups 1-3
var R = bytes(y0 + ((c(91881) * r0 + c(32768)) >> 16), ...);           // saturated to 0-255
var rg0 = R.shuffle(G, 0, 16, 1, 17, 2, 18, 3, 19, 4, 20, 5, 21, 6, 22, 7, 23);
var ba0 = B.shuffle(alpha, 0, 16, 1, 17, 2, 18, 3, 19, 4, 20, 5, 21, 6, 22, 7, 23);
rg0.asU16x8().shuffle(ba0.asU16x8(), 0, 8, 1, 9, 2, 10, 3, 11).storeSpan(out, 4 * i);
```

### Bilinear and Lanczos row resampling

Bilinear (`SimdKernels.resizeRow`): an output pixel's two source pixels'
channels paired as 16-bit lanes, both horizontal weights in each pair, so
that one `dot` per row does the horizontal pass of all four channels:

```haxe
var wx = c((fx << 16) | (256 - fx)).asI16x8();
var r = (pairs(t, o).dot(wx) * wy0 + pairs(b, o).dot(wx) * wy1 + half) >> 16;
var p = I16x8.narrow(r, r);
U8x16.narrow(p, p).storeSpan32(dst, 4 * x);
```

Lanczos-3 (`SimdExamples.resampleRow`): six taps of float32 weights, a
pixel's RGBA as one `F32x4`, rounded and saturated back to bytes:

```haxe
var acc = F32x4.zero();
for (k in 0...6) {
	var p = U32x4.extendLow(U16x8.extendLow(U8x16.loadSpan32(src, o + 4 * k))).toF32x4();
	acc = p.mulAdd(F32x4.splat(weight(x, k)), acc);
}
var q = acc.round().toI32x4();
U8x16.narrow(I16x8.narrow(q, q), I16x8.narrow(q, q)).storeSpan32(dst, 4 * x);
```

### Audio mix with gain and clamp

`SimdExamples.mix`: two streams of 16-bit samples, each with a Q15 gain,
summed with saturation, eight samples a step, the tail scalar:

```haxe
var va = I16x8.splat(ga), vb = I16x8.splat(gb);
while (i + 8 <= n) {
	I16x8.loadSpan(a, 2 * i).mulQ15(va).addSat(I16x8.loadSpan(b, 2 * i).mulQ15(vb)).storeSpan(out, 2 * i);
	i += 8;
}
```

With float samples (`SimdValues.mix`): `x.mulAdd(gain, y).clamp(lo, hi)`,
and `loadSpan32`/`storeSpan32` for the last one to three samples.

### 4x4 matrix product

`SimdExamples.Mat4`: four `F32x4` columns, a struct; a matrix times a
vector is the columns weighted by the vector's lanes, splat by `swizzle`:

```haxe
static inline function apply(a:Mat4, v:F32x4):F32x4
	return a.c0 * v.swizzle(0, 0, 0, 0) + a.c1 * v.swizzle(1, 1, 1, 1)
		+ a.c2 * v.swizzle(2, 2, 2, 2) + a.c3 * v.swizzle(3, 3, 3, 3);

static inline function mul(a:Mat4, b:Mat4):Mat4
	return new Mat4(apply(a, b.c0), apply(a, b.c1), apply(a, b.c2), apply(a, b.c3));
```

Sixteen multiplies and twelve adds, all in registers; the result is the
scalar product's, sum for sum (unfused, in the same order).

## Two scalar findings (a sprite fill on wasm)

A report from a WebAssembly sprite renderer: four consecutive stores
`b.setFloat(o, ...)`, `setFloat(o + 4, ...)`, `setFloat(o + 8, ...)`,
`setInt32(o + 12, ...)` into a local `Bytes`.

- **Repeated null and range checks.** The storage and its length were
  loaded again, and null-tested on wasm, before each store: the raw
  accesses of `hxmc.rt.Bytes`' accessors were of memory class `MOther`, so
  each store killed every field load. They are `MElem` now (the array's
  bytes, which no field or header shares), and the storage is loaded and
  tested once (1bfbc4e). The range test of each store was two compares
  (`pos >= 0 && pos <= length - n`); it is now one unsigned compare
  against `length - (n - 1)` after a `length >= n` test that is the same
  for every store of that size, which `Opt.condProp` makes once (equal
  constants as one operand: `Opt.sameVal`). Four stores: eight compares
  before, four and one now. Merging the four into one test of `o` and
  `o + 12` would change what a failing store leaves behind (the stores
  before it happen first), so that needs a loop or block versioned with a
  fast path, in [Later](#later).
- **`setFloat` not inlined in large functions while `setInt32` was.** The
  float32 conversion (`hxmc$f64_to_f32`) counted as a call in the inlining
  size and as a call that writes memory; it counts as nothing now and
  writes nothing (1bfbc4e). A function of 64 stores (32 `setFloat`, 32
  `setInt32`) inlines all of them, natively and on wasm.

## Later

- **256-bit vectors with run-time dispatch**: `F32x8` and friends on AVX2
  (and FMA3: a fused `fma`), two 128-bit halves on NEON and wasm; a
  function compiled for both levels and chosen once at start-up by
  `cpuid` (`@:hxmc.simd.dispatch`), as Highway's dynamic dispatch. The
  start-up check of SSE4.1 belongs with it.
- **Relaxed operations, opted into**: wasm relaxed-simd's `relaxed_madd`,
  `relaxed_min`, ... and their native counterparts (`minps`, `fmla`), with
  results that may differ by target, under their own names.
- **Vectors in registers across Haxe calls** (a vector argument in xmm or
  v registers rather than by address); C vectors past the argument
  registers (16-byte stack slots) and in variadic calls.
- **Auto-vectorization**: superword packing of struct arithmetic (four
  `Float32` fields of a struct, `acc = acc + d * k`), then loops over spans
  whose checks a loop proves (`SpanLoops`): the scalar kernels of the
  benchmark are the targets.
- **The rest of wasm's operations** (`i64x2` ordering and multiply,
  `popcnt`, extended multiplies, pairwise adds, unsigned `f64x2`
  conversions), half floats, SVE and RISC-V's vector extension.
- **Unboxed `Array<F32x4>`** comes with unboxed struct arrays
  ([lowlevel.md](lowlevel.md#struct-values-in-generic-storage)).
- **Range checks of constant offsets from one base** (the sprite fill):
  one test of the whole range guarding a copy of the block without checks,
  the checked block as the fallback.
