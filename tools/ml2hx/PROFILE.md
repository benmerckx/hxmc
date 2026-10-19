# Profile history

One entry per `make ml2hx-profile` run worth keeping (ML2HX_PROFILE_NOTE set): self-typing and, when measured, unit tests to JS; the port built from the same tree with the same flags. Seconds by category are leaf samples (bin/ml2hx/profile/profile.md has the rest).

### 2026-10-19, 8ba04d5: first report (baseline)

- self-typing (haxe/src, --interp --no-output): wall 4.29 s against 10.29 s (2.40x), user 4.00 s against 9.91 s, peak RSS 484 MB against 747 MB
  allocated: port 2946.8 MB (95779393 objects), generated 9121.5 MB (375587277 objects)

  | category | port (s) | generated (s) | Δ | ratio |
  | --- | ---: | ---: | ---: | ---: |
  | upstream code | 2.38 | 3.90 | +1.51 | 1.63x |
  | reflection and dynamic access (Dyn, Type, Std) | 0.09 | 1.46 | +1.38 | 16.31x |
  | polymorphic compare and hash (ml2hx.rt.Poly) | 0.00 | 1.04 | +1.04 | — |
  | allocation and collection (Gc, zeroing, page faults) | 0.94 | 1.97 | +1.03 | 2.10x |
  | ml2hx runtime and prims | 0.00 | 0.37 | +0.37 | — |
  | boxing | 0.02 | 0.33 | +0.31 | 17.84x |
  | libc and kernel | 0.34 | 0.65 | +0.30 | 1.88x |
  | Haxe maps (haxe.ds) | 0.16 | 0.25 | +0.09 | 1.60x |
  | other hxmc runtime | 0.02 | 0.09 | +0.07 | 4.47x |
  | Haxe code mapped to no upstream unit | 0.13 | 0.18 | +0.05 | 1.43x |
  | arrays (runtime) | 0.17 | 0.17 | -0.00 | 0.99x |
  | strings (runtime) | 0.09 | 0.03 | -0.06 | 0.31x |

- unit tests to JS (tests/unit, compile-js.hxml): wall 2.95 s against 8.15 s (2.76x), user 2.73 s against 7.81 s, peak RSS 429 MB against 426 MB

  | category | port (s) | generated (s) | Δ | ratio |
  | --- | ---: | ---: | ---: | ---: |
  | upstream code | 1.53 | 3.06 | +1.53 | 2.00x |
  | reflection and dynamic access (Dyn, Type, Std) | 0.06 | 1.27 | +1.20 | 19.70x |
  | polymorphic compare and hash (ml2hx.rt.Poly) | 0.00 | 0.89 | +0.89 | — |
  | allocation and collection (Gc, zeroing, page faults) | 0.59 | 1.07 | +0.49 | 1.82x |
  | ml2hx runtime and prims | 0.00 | 0.45 | +0.45 | — |
  | boxing | 0.03 | 0.28 | +0.26 | 10.58x |
  | libc and kernel | 0.31 | 0.47 | +0.17 | 1.54x |
  | Haxe maps (haxe.ds) | 0.10 | 0.23 | +0.13 | 2.26x |
  | Haxe code mapped to no upstream unit | 0.06 | 0.15 | +0.09 | 2.62x |
  | other hxmc runtime | 0.04 | 0.09 | +0.05 | 2.29x |
  | arrays (runtime) | 0.15 | 0.16 | +0.01 | 1.06x |
  | strings (runtime) | 0.13 | 0.04 | -0.08 | 0.35x |

### 2026-10-19, 8ba04d5 + local changes: Poly without Type.typeof (hxmc.Native.typeKind), fields read in place, ranks by constructor type index; typed compare/equality per record, variant, tuple, list, option; min/max and Hashtbl.hash at known types

- self-typing (haxe/src, --interp --no-output): wall 4.06 s against 8.23 s (2.03x), user 3.74 s against 7.87 s, peak RSS 484 MB against 768 MB
  allocated: port 2946.8 MB (95779393 objects), generated 7579.9 MB (293829969 objects)

  | category | port (s) | generated (s) | Δ | ratio |
  | --- | ---: | ---: | ---: | ---: |
  | upstream code | 2.24 | 3.73 | +1.49 | 1.67x |
  | reflection and dynamic access (Dyn, Type, Std) | 0.08 | 1.09 | +1.01 | 14.45x |
  | allocation and collection (Gc, zeroing, page faults) | 0.79 | 1.49 | +0.70 | 1.89x |
  | polymorphic compare and hash (ml2hx.rt.Poly) | 0.00 | 0.61 | +0.61 | — |
  | ml2hx runtime and prims | 0.00 | 0.35 | +0.35 | — |
  | libc and kernel | 0.37 | 0.62 | +0.25 | 1.69x |
  | boxing | 0.03 | 0.26 | +0.23 | 8.59x |
  | other hxmc runtime | 0.03 | 0.08 | +0.05 | 2.39x |
  | Haxe code mapped to no upstream unit | 0.12 | 0.15 | +0.03 | 1.22x |
  | strings (runtime) | 0.09 | 0.02 | -0.08 | 0.18x |
  | arrays (runtime) | 0.18 | 0.08 | -0.10 | 0.42x |
  | Haxe maps (haxe.ds) | 0.16 | 0.00 | -0.16 | 0.00x |

- unit tests to JS (tests/unit, compile-js.hxml): wall 2.97 s against 6.09 s (2.05x), user 2.69 s against 5.81 s, peak RSS 431 MB against 427 MB
  allocated: port 2523.1 MB (79908890 objects), generated 5907.6 MB (216693533 objects)

  | category | port (s) | generated (s) | Δ | ratio |
  | --- | ---: | ---: | ---: | ---: |
  | upstream code | 1.50 | 2.72 | +1.22 | 1.81x |
  | reflection and dynamic access (Dyn, Type, Std) | 0.08 | 0.87 | +0.79 | 10.68x |
  | polymorphic compare and hash (ml2hx.rt.Poly) | 0.00 | 0.46 | +0.46 | — |
  | ml2hx runtime and prims | 0.00 | 0.42 | +0.42 | — |
  | allocation and collection (Gc, zeroing, page faults) | 0.48 | 0.78 | +0.30 | 1.63x |
  | boxing | 0.03 | 0.20 | +0.17 | 7.52x |
  | Haxe code mapped to no upstream unit | 0.06 | 0.15 | +0.09 | 2.67x |
  | other hxmc runtime | 0.04 | 0.06 | +0.03 | 1.75x |
  | libc and kernel | 0.36 | 0.39 | +0.03 | 1.07x |
  | arrays (runtime) | 0.13 | 0.08 | -0.05 | 0.60x |
  | strings (runtime) | 0.15 | 0.03 | -0.13 | 0.18x |
  | Haxe maps (haxe.ds) | 0.13 | 0.00 | -0.13 | 0.00x |
