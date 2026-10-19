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

### 2026-10-19, 1b890f5 + local changes: static small Int64 boxes; Poly caches by type index, int and string fast paths in compare and hash; List.mem/assoc/assoc_opt/mem_assoc by type; compare of re-exported types; Marshal string sharing; extc deflate

- self-typing (haxe/src, --interp --no-output): wall 3.86 s against 7.56 s (1.96x), user 3.54 s against 7.24 s, peak RSS 484 MB against 835 MB
  allocated: port 2946.8 MB (95779392 objects), generated 6808.8 MB (243283208 objects)

  | category | port (s) | generated (s) | Δ | ratio |
  | --- | ---: | ---: | ---: | ---: |
  | upstream code | 2.11 | 3.49 | +1.37 | 1.65x |
  | reflection and dynamic access (Dyn, Type, Std) | 0.07 | 0.81 | +0.74 | 10.84x |
  | allocation and collection (Gc, zeroing, page faults) | 0.77 | 1.45 | +0.68 | 1.89x |
  | polymorphic compare and hash (ml2hx.rt.Poly) | 0.00 | 0.48 | +0.48 | — |
  | ml2hx runtime and prims | 0.00 | 0.32 | +0.32 | — |
  | boxing | 0.02 | 0.27 | +0.25 | 14.62x |
  | libc and kernel | 0.34 | 0.53 | +0.20 | 1.59x |
  | Haxe code mapped to no upstream unit | 0.13 | 0.22 | +0.09 | 1.68x |
  | other hxmc runtime | 0.02 | 0.05 | +0.02 | 2.04x |
  | strings (runtime) | 0.10 | 0.02 | -0.08 | 0.21x |
  | arrays (runtime) | 0.17 | 0.07 | -0.09 | 0.44x |
  | Haxe maps (haxe.ds) | 0.16 | 0.00 | -0.16 | 0.01x |

- unit tests to JS (tests/unit, compile-js.hxml): wall 2.73 s against 5.75 s (2.11x), user 2.56 s against 5.43 s, peak RSS 431 MB against 424 MB
  allocated: port 2523.1 MB (79908889 objects), generated 5420.6 MB (184773989 objects)

  | category | port (s) | generated (s) | Δ | ratio |
  | --- | ---: | ---: | ---: | ---: |
  | upstream code | 1.40 | 2.66 | +1.26 | 1.90x |
  | reflection and dynamic access (Dyn, Type, Std) | 0.08 | 0.66 | +0.58 | 8.01x |
  | polymorphic compare and hash (ml2hx.rt.Poly) | 0.00 | 0.44 | +0.44 | — |
  | ml2hx runtime and prims | 0.00 | 0.39 | +0.39 | — |
  | allocation and collection (Gc, zeroing, page faults) | 0.46 | 0.71 | +0.25 | 1.56x |
  | boxing | 0.03 | 0.22 | +0.19 | 7.42x |
  | Haxe code mapped to no upstream unit | 0.04 | 0.14 | +0.11 | 3.92x |
  | libc and kernel | 0.34 | 0.37 | +0.02 | 1.07x |
  | other hxmc runtime | 0.04 | 0.06 | +0.02 | 1.50x |
  | arrays (runtime) | 0.11 | 0.08 | -0.04 | 0.69x |
  | strings (runtime) | 0.14 | 0.04 | -0.10 | 0.31x |
  | Haxe maps (haxe.ds) | 0.12 | 0.00 | -0.12 | 0.02x |

### 2026-10-19, 30b57b8 + local changes: record fields of GADT-cast values read through their class; let-bound partial applications of known functions applied in full call the function directly

- self-typing (haxe/src, --interp --no-output): wall 3.85 s against 7.88 s (2.05x), user 3.64 s against 7.36 s, peak RSS 484 MB against 629 MB
  allocated: port 2946.8 MB (95779392 objects), generated 6601.9 MB (233097545 objects)

  | category | port (s) | generated (s) | Δ | ratio |
  | --- | ---: | ---: | ---: | ---: |
  | upstream code | 2.20 | 3.81 | +1.61 | 1.73x |
  | reflection and dynamic access (Dyn, Type, Std) | 0.09 | 0.78 | +0.69 | 9.01x |
  | allocation and collection (Gc, zeroing, page faults) | 0.77 | 1.37 | +0.60 | 1.77x |
  | polymorphic compare and hash (ml2hx.rt.Poly) | 0.00 | 0.49 | +0.49 | — |
  | ml2hx runtime and prims | 0.00 | 0.34 | +0.34 | — |
  | boxing | 0.02 | 0.28 | +0.26 | 14.09x |
  | libc and kernel | 0.36 | 0.45 | +0.10 | 1.27x |
  | Haxe code mapped to no upstream unit | 0.12 | 0.17 | +0.05 | 1.43x |
  | other hxmc runtime | 0.03 | 0.07 | +0.04 | 2.69x |
  | strings (runtime) | 0.10 | 0.01 | -0.09 | 0.15x |
  | arrays (runtime) | 0.14 | 0.04 | -0.10 | 0.29x |
  | Haxe maps (haxe.ds) | 0.15 | 0.00 | -0.15 | 0.00x |

- unit tests to JS (tests/unit, compile-js.hxml): wall 3.38 s against 6.00 s (1.78x), user 3.10 s against 5.75 s, peak RSS 431 MB against 424 MB
  allocated: port 2523.1 MB (79908888 objects), generated 5314.0 MB (179647569 objects)

  | category | port (s) | generated (s) | Δ | ratio |
  | --- | ---: | ---: | ---: | ---: |
  | upstream code | 1.69 | 2.76 | +1.08 | 1.64x |
  | reflection and dynamic access (Dyn, Type, Std) | 0.08 | 0.72 | +0.63 | 8.65x |
  | ml2hx runtime and prims | 0.00 | 0.46 | +0.46 | — |
  | polymorphic compare and hash (ml2hx.rt.Poly) | 0.00 | 0.45 | +0.45 | — |
  | boxing | 0.02 | 0.23 | +0.21 | 9.70x |
  | allocation and collection (Gc, zeroing, page faults) | 0.64 | 0.74 | +0.09 | 1.15x |
  | Haxe code mapped to no upstream unit | 0.05 | 0.14 | +0.08 | 2.52x |
  | other hxmc runtime | 0.06 | 0.08 | +0.02 | 1.43x |
  | libc and kernel | 0.37 | 0.38 | +0.01 | 1.02x |
  | arrays (runtime) | 0.14 | 0.06 | -0.09 | 0.40x |
  | strings (runtime) | 0.15 | 0.04 | -0.11 | 0.28x |
  | Haxe maps (haxe.ds) | 0.14 | 0.00 | -0.14 | 0.02x |

### 2026-10-19, b5390a2 + local changes: Poly: ints compared before classifying, typeKind once per value in compare and hash

- self-typing (haxe/src, --interp --no-output): wall 3.94 s against 7.35 s (1.87x), user 3.57 s against 7.02 s, peak RSS 484 MB against 629 MB
  allocated: port 2946.8 MB (95779392 objects), generated 6601.9 MB (233097545 objects)

  | category | port (s) | generated (s) | Δ | ratio |
  | --- | ---: | ---: | ---: | ---: |
  | upstream code | 2.08 | 3.63 | +1.55 | 1.74x |
  | reflection and dynamic access (Dyn, Type, Std) | 0.09 | 0.80 | +0.72 | 9.41x |
  | polymorphic compare and hash (ml2hx.rt.Poly) | 0.00 | 0.50 | +0.50 | — |
  | allocation and collection (Gc, zeroing, page faults) | 0.72 | 1.20 | +0.47 | 1.66x |
  | ml2hx runtime and prims | 0.00 | 0.34 | +0.34 | — |
  | boxing | 0.02 | 0.24 | +0.21 | 9.62x |
  | Haxe code mapped to no upstream unit | 0.11 | 0.18 | +0.07 | 1.67x |
  | other hxmc runtime | 0.02 | 0.07 | +0.05 | 3.49x |
  | libc and kernel | 0.40 | 0.41 | +0.01 | 1.03x |
  | strings (runtime) | 0.10 | 0.02 | -0.08 | 0.24x |
  | arrays (runtime) | 0.19 | 0.05 | -0.14 | 0.27x |
  | Haxe maps (haxe.ds) | 0.17 | 0.00 | -0.17 | 0.00x |

### 2026-10-19, 08ccf47 + local changes: threads (master lock), host pipes and processes; upstream's own compiler timed as a third column

- self-typing (haxe/src, --interp --no-output): wall 4.45 s against 8.28 s (1.86x), user 4.16 s against 7.84 s, peak RSS 484 MB against 631 MB; upstream's own compiler 5.19 s, 749 MB (generated 1.60x)
  allocated: port 2946.8 MB (95779392 objects), generated 6601.0 MB (233080524 objects)

  | category | port (s) | generated (s) | Δ | ratio |
  | --- | ---: | ---: | ---: | ---: |
  | upstream code | 2.49 | 3.80 | +1.31 | 1.52x |
  | reflection and dynamic access (Dyn, Type, Std) | 0.10 | 0.82 | +0.72 | 8.26x |
  | allocation and collection (Gc, zeroing, page faults) | 0.87 | 1.57 | +0.71 | 1.82x |
  | polymorphic compare and hash (ml2hx.rt.Poly) | 0.00 | 0.53 | +0.53 | — |
  | ml2hx runtime and prims | 0.00 | 0.36 | +0.36 | — |
  | boxing | 0.03 | 0.30 | +0.27 | 10.67x |
  | libc and kernel | 0.42 | 0.59 | +0.16 | 1.39x |
  | Haxe code mapped to no upstream unit | 0.12 | 0.20 | +0.08 | 1.64x |
  | other hxmc runtime | 0.03 | 0.08 | +0.05 | 2.93x |
  | strings (runtime) | 0.14 | 0.02 | -0.12 | 0.13x |
  | arrays (runtime) | 0.19 | 0.05 | -0.15 | 0.24x |
  | Haxe maps (haxe.ds) | 0.18 | 0.00 | -0.18 | 0.00x |

- unit tests to JS (tests/unit, compile-js.hxml): wall 3.29 s against 6.56 s (1.99x), user 3.02 s against 6.20 s, peak RSS 431 MB against 424 MB; upstream's own compiler 3.60 s, 369 MB (generated 1.82x)
  allocated: port 2523.1 MB (79908890 objects), generated 5304.6 MB (179540308 objects)

  | category | port (s) | generated (s) | Δ | ratio |
  | --- | ---: | ---: | ---: | ---: |
  | upstream code | 1.61 | 2.96 | +1.35 | 1.84x |
  | reflection and dynamic access (Dyn, Type, Std) | 0.08 | 0.74 | +0.66 | 9.01x |
  | polymorphic compare and hash (ml2hx.rt.Poly) | 0.00 | 0.50 | +0.50 | — |
  | ml2hx runtime and prims | 0.00 | 0.47 | +0.47 | — |
  | allocation and collection (Gc, zeroing, page faults) | 0.61 | 0.95 | +0.34 | 1.56x |
  | boxing | 0.03 | 0.23 | +0.20 | 7.98x |
  | Haxe code mapped to no upstream unit | 0.06 | 0.15 | +0.09 | 2.42x |
  | libc and kernel | 0.38 | 0.42 | +0.04 | 1.09x |
  | other hxmc runtime | 0.05 | 0.07 | +0.02 | 1.46x |
  | arrays (runtime) | 0.16 | 0.04 | -0.11 | 0.28x |
  | Haxe maps (haxe.ds) | 0.14 | 0.00 | -0.14 | 0.01x |
  | strings (runtime) | 0.20 | 0.03 | -0.16 | 0.18x |

### Final state when parked (2026-10-19, d020de5)

The numbers are from the run above, 08ccf47 plus the reference column.

**Speed and allocation history** (self-typing, generated compiler; the port took 3.9 to 4.5 s in each run):

| Step | Generated | Against the port | Allocated |
| --- | ---: | ---: | ---: |
| Before profiling | 26.5 s | | |
| Poly kind and ranks cache | 22.4 s | | |
| Lambda lifting | 12.9 s | | |
| First profile report | 10.29 s | 2.40x | 9.1 GB |
| Typed compare, Poly without Type.typeof | 8.23 s | 2.03x | 7.6 GB |
| Static small Int64 boxes, List.mem/assoc by type | 7.56 s | 1.96x | 6.8 GB |
| Partial applications, Poly int paths | 7.35 s | 1.87x | 6.6 GB |
| Final | 8.28 s | 1.86x | 6.6 GB |

In the final run, upstream's own OCaml compiler took 5.19 s, so the generated compiler is 1.60x upstream.

**Suites** (generated compiler; the port as the reference):
- haxe/test Conformance: 286 cases, 279 pass, 7 expected failures.
- Interp: 352 cases, 276 pass, 76 skipped, 0 fail.
- Unit-test output: identical apart from the build date on js, lua, python, php, hl, hlc, neko, cppia and flash.

**Build:** 56 s and 3.0 GB. Stripped binary: 31.1 MB, against the port's 18.1 MB and upstream's 29.9 MB.
