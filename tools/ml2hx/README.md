# ml2hx: OCaml (typed trees) to Haxe

`ml2hx` turns the typed trees of an OCaml project (the pinned Haxe compiler in
`haxe/upstream`) into Haxe, together with every library module the project
reaches: OCaml's own standard library included. Spec:
`docs/plans/haxe-versions.md`.

```
 dune build @check (.cmt)          opam switch (.cmt of Stdlib, extlib, ...)
            \                        /
             frontend (OCaml, compiler-libs)  -->  JSON IR
                                                    |
                         emit.mjs + generate.mjs <--+
                                   |
       bin/ml2hx/generated: upstream.* (the compiler), ocaml.* (its libraries)
              calling ml2hx.rt (representations) and ml2hx.prim (primitives)
```

Unsupported constructs are errors, never `Dynamic` or stubs. A primitive the
runtime does not provide is reported (the module does not type), not
stubbed.

## Setup

The frontend is native OCaml built against compiler-libs of the opam switch
whose version the pinned compiler builds with (`OCAML_VERSION` in
`haxe/upstream/.github/workflows/main.yml`, 5.3.0):

```
opam switch create 5.3.0 && eval $(opam env --switch=5.3.0)
opam install ./haxe/upstream --deps-only     # the compiler's libraries (their .cmt are converted)
make ml2hx-frontend                          # bin/ml2hx/build/frontend.exe (checks the version)
make ml2hx-test                              # semantic tests: OCaml's output vs the generated Haxe's
make ml2hx-check                             # the progress count (below)
```

`ML2HX_ANY_OCAML=1` builds the frontend with another OCaml (typed trees are
version-specific: expect differences); `build-frontend.mjs --js` adds a
js_of_ocaml build. `ML2HX_HAXE=haxe` runs tests and checks with another Haxe
than hxmc's committed stage0 (faster).

## Progress

`make ml2hx-check` generates everything, type-checks it (removing modules
with errors until what remains types) and prints

- the compiler's modules that emit and type, of the 326 sources of the pin;
- the library units that do (OCaml's Stdlib and the other packages the
  compiler reaches, as many as it reaches: 113 at present);

with the first type error of each module in `bin/ml2hx/check.json`.

## State (parked, 2026-10-19)

Work on ml2hx is parked at this state (branch hv-emit):

- **Counts:** 324 of the pin's 326 compiler modules emit and type (the other
  two are upstream test files OCaml does not type either); 111 of 113
  library units (435 of 439 with the compiler's).
- **The generated compiler** (`make port-generated`, 56 s and 3.0 GB to
  build) runs. Its output for upstream's unit tests is identical to the
  port's, apart from the embedded build date, on js, lua, python, php, hl,
  hlc, neko, cppia and flash (SWF compared inflated).
- **haxe/test suites**, run with the port as the reference: Conformance has
  286 cases, 279 pass and 7 are expected failures (the reference fails them
  too). Interp (upstream's tests/misc/eval) has 352 cases: 276 pass, 76 are
  skipped, none fail.
- **Speed** (`make ml2hx-profile`, history in [PROFILE.md](PROFILE.md)):
  - Self-typing: 8.28 s, against the port's 4.45 s (1.86x) and upstream's
    own OCaml compiler at 5.19 s (1.60x).
  - Unit tests to JS: 6.56 s against 3.29 s for the port (1.99x) and 3.60 s
    for upstream (1.82x).
  - Allocation in self-typing: 6.6 GB against the port's 2.9 GB.
  - Peak RSS: 631 MB, against the port's 484 MB and upstream's 749 MB.
  - Stripped binary: 31.1 MB, against the port's 18.1 MB and upstream's
    29.9 MB.
- **Threads and domains** run as OCaml 5's systhreads (host threads under one
  master lock, ml2hx.rt.Gil), with no preemption of a thread that never
  blocks.
- **Not done:**
  - libuv: the luv bindings are stubs that raise Failure.
  - Overlays (plan step 4) are not started. The profile names the
    candidates: places where the port departs from upstream to save work,
    such as `map_expr` returning an unchanged node, where the generated
    compiler allocates twice the texpr nodes.
  - Speed: the remaining 1.9x is spread over converted code, allocation
    volume, polymorphic hashing of structured keys (generic Hashtbl, PMap,
    the matcher's tables) and closure adapters.
- **To resume:**
  1. Run `make ml2hx-check`, then `make ml2hx-profile` with
     `ML2HX_UTEST` set and `make reference` built.
  2. Run the haxe/test suites with `HAXE_REFERENCE` set to the port and
     `HAXE_IN_HAXE_PORT` set to the generated compiler.
  3. Next would come overlays ranked by profile impact, then luv over
     hxmc.NativeUv for the tests that need it.

## The generated compiler

`generate.mjs` also writes `Ml2hxCompiler`: every unit haxe.ml reaches,
initialised in link order (haxe.ml runs the compiler when initialised).
`make port-generated` builds it with hxmc into `bin/ml2hx/haxe` (`HXMC_SYMBOLS=1`
keeps symbols for gdb). It compiles hello world, and upstream's unit tests (tests/unit to JS),
byte-identically to the port.

`make ml2hx-profile` profiles it against the port, both built from the tree
with the same flags (and symbols), on self-typing (and upstream's unit tests
to JS with `ML2HX_UTEST=<utest checkout>`): `bin/ml2hx/profile/profile.md`
has phase times (`--times`), a differential perf profile by upstream
function, allocations by type from census builds (`-D hxmc.census`,
`RT_CENSUS=1`, which also counts every allocation) and perf counters; the
raw data stays beside it; upstream's own compiler (`make reference`) is timed as a third column when built. `make ml2hx-profile-report` reruns the
measurements on the binaries built (`tools/ml2hx/profile.mjs`).

## Replacements

`replacements/<package>/<unit>.ml`: library modules whose code depends on
OCaml's memory layout, rewritten without it and compiled against the
original interface (`-cmi-file`), so their typed trees stand for the
originals: extlib's ExtList, Enum.force and Std.input_list (lists built from
mutable records injected into 'a list), thread-local-storage (slots in a
field of Thread.t reached with Obj.magic), Stdlib's String (its per-character
decoders read the string instead of a Bytes copy of it). Each keeps the
order in which it calls its function arguments and returns equal values.
`replacements/haxe/<path>`: the same for the compiler's own sources, written
over the build checkout's copy (bin/ml2hx/checkouts, never the submodule):
Rbuffer.alloc (bytes written after Bytes.unsafe_to_string made the rope's
string of them).

## Layout

| Path | What |
| --- | --- |
| `frontend/main.ml` | typed trees (.cmt) to JSON: structure, types (hash-consed per unit), declarations |
| `emit.mjs` | the emitter: one Haxe module per OCaml unit |
| `generate.mjs` | the pin's units, the library units they reach (transitively), output |
| `naming.mjs` | the naming contract below |
| `runtime/ml2hx/rt/` | representations: Int63, MlList, MlOption, Ref, TupleN, Lazy, Unit, PolyVariant, MlException and the predefined exceptions, Poly (OCaml's compare/equal/hash), FloatFormat (printf and strtod of doubles) |
| `runtime/ml2hx/prim/` | primitives: the C functions OCaml's runtime implements, and the compiler's own (`%` primitives) beyond an expression |
| `runtime/ml2hx/std/` | stand-ins for libraries that are C bindings (Unix, Str, luv's types, Pcre2, Domainslib, Dynlink, Effect, ...) |
| `overlay/ml2hx/std/` | the former hand-written Stdlib (List, Hashtbl, Map, Printf, ...): out of the build; one comes back only as a speed overlay a benchmark justifies |
| `test/` | semantic tests (`cases/*.ml`, compiled by OCaml and by ml2hx, outputs compared) |

## The naming contract

### Units

| OCaml | Haxe |
| --- | --- |
| `src/dir/foo.ml` of the pin | class `upstream.dir.FooModule` |
| library unit `Stdlib__List`, `IO` of extlib | class `ocaml.stdlib.ListModule`, `ocaml.extlib.IOModule` (package `ocaml.<opam package>`) |
| submodule `Foo.Bar` | class `FooModule_Bar` beside it (a functor instance: one class per application; an included instance `..._Include`, an anonymous argument `..._Arg`) |
| type `t` of `Foo` (or of `Foo.Bar`) | `FooT` (`FooBarT`): module-prefixed, unique per package |
| exception `E` of `Foo` | class `FooEExn extends ml2hx.rt.MlException` (`exnName` is `"Foo.E"`) |
| value `foo_bar` | static `fooBar`; a Haxe keyword gets the suffix `Value`; operators: `opAdd`, `opConcat`, ... and otherwise `op` + character names (`( @@> )` -> `opAtAtGt`) |

Values: a function of syntactic arity n is a static function with n
parameters, called uncurried when applied to n arguments; function values
are curried closures (`(A) -> ((B) -> C)`). Labelled and optional
parameters are positional (optional ones as `MlOption`).

### Representations

| OCaml | Haxe |
| --- | --- |
| `int` | `ml2hx.rt.Int63` (63-bit, wrapping, Int64-backed) |
| `char` | `Int` (0..255) |
| `string` | `String` whose code units are bytes 0..255 (file names converted at the boundary) |
| `bytes` | `haxe.io.Bytes` |
| `float`, `bool` | `Float`, `Bool` |
| `unit` | `ml2hx.rt.Unit` |
| `'a list`, `'a option` | `ml2hx.rt.MlList<A>`, `ml2hx.rt.MlOption<A>` |
| `'a ref` (and `Atomic.t`) | `ml2hx.rt.Ref<A>` (`value`) |
| `'a array`, `floatarray` | `Array<A>`, `Array<Float>` |
| tuples | `ml2hx.rt.TupleN` (`v0`, `v1`, ...), N = 2..12 |
| `int32`, `int64`, `nativeint` | `haxe.Int32`, `haxe.Int64`, `haxe.Int64` |
| `exn` | `ml2hx.rt.MlException`; an OCaml value laid out as OCaml lays it out (constant: its extension constructor, tag 248; else tag 0, constructor then arguments) |
| `'a Lazy.t` | `ml2hx.rt.Lazy<A>` |
| records | classes implementing `ml2hx.rt.Block`, fields camelCased |
| variants (GADTs too) | enums with the OCaml constructor names; GADT constructors give their result type |
| polymorphic variants | `ml2hx.rt.PolyVariant` (tag: OCaml's `hash_variant`) |
| extensible variants | a base class per type (its parameters phantom), a class per constructor |
| objects, classes | classes (virtual methods abstract); immediate objects and object types are structures; an open object type is a type parameter constrained by its methods |
| first-class modules | a structure of the signature's values (curried) |
| `Obj.t`, `in_channel`, `Mutex.t`, ... | the runtime's (`builtinTypes` in emit.mjs): `Any`, `ml2hx.prim.Io.InChannel`, `ml2hx.prim.Sync.Mutex`, ... |

Structural operations are `ml2hx.rt.Poly`: compare.c and hash.c ported over
these representations.

### Primitives

An `external f : ... = "caml_name"` of a converted unit is a static calling
`ml2hx.prim.<Group>.camlName` (the C name camelCased). OCaml's runtime
primitives are grouped as its C files group them (`primGroup` in
naming.mjs): `Io` (io.c: channels on descriptors), `Sys`, `Strings`, `Ints`
(formats, parsing), `Floats` (printf and strtod of doubles, libm), `Arrays`,
`Hash`, `Obj`, `Sync` (mutexes, conditions, atomics), `Domain`, `Gc`,
`Backtrace`, `Weak` (ephemerons), `Bigarray`, `Digest` (MD5, BLAKE2b),
`Lexing`, `Parsing` (the ocamlyacc automaton), `Random` (LXM), `Runtime`.
Primitives of other C libraries belong to their unit (`ml2hx.prim.Extc`,
`ml2hx.prim.Mbedtls`). A primitive OCaml declares with `char` and with `int`
alike (`caml_ml_output_char`) takes ints.

The compiler's own primitives (`%addint`, `%int32_add`, `%caml_bytes_get32`,
`%atomic_load`, `%dls_get`, `%caml_ba_ref_1`, ...) are emitted inline or call
`ml2hx.prim.Builtin`.

C libraries are bound to hxmc's own implementations (the ones today's port
uses): `Pcre2` runs on `hxmc.Regex`, `ml2hx.prim.Mbedtls` on
`hxmc.NativeSsl` (built by another Haxe it raises `Failure`). The check and
the tests put hxmc's `hxmc` package alone on the class path
(`bin/ml2hx/natives`).

## Constructs

Converted: modules, submodules, functors (instantiated statically per
application, across units, curried bodies that apply other functors),
`include` (of structures, applications, unpacked modules), first-class
modules, records (inline ones too), variants, GADTs (values of refined types
are cast where used in GADT branches), polymorphic variants, extensible
variants and exceptions (local ones too), objects and classes (inheritance,
virtual methods, open object types), laziness, recursion (mutual, recursive
values of records, lazies and functions made by applications), pattern
matching (or-patterns, guards, exceptions, aliases, integer and float and
boxed integer constants), structural equality/compare/hash, strings, bytes,
chars, formats (as CamlinternalFormat values), effects (deep handlers that
resume their continuation last: see below), labelled and optional arguments,
locally abstract types, polymorphic recursion.

## Remaining gaps

- Haxe has no GADT equations, no polymorphism of non-generalised type
  variables and no structural subtyping of classes: GADT branches cast,
  unbound type variables are `Any` (some uses then do not type: "Any should
  be T"), and object coercions to unrelated class types are unchecked casts
  (right on dynamic targets only). Most of the compiler modules that do not
  type stop here.
- Not converted: recursive modules (unused by the compiler and its
  libraries), let rec values that use the group's variables other than as
  record fields (nested records included), lazies or closures.
- Effects: a handler that does work after `continue` does it before the
  computation resumes.
- Primitives not available: reading marshalled data (`input_value`,
  `Marshal.from_*`: the runtime lacks the static types to rebuild values;
  writing is OCaml's format, sharing included), `Obj.add_offset`,
  libuv (luv: typed for eval.luv, its functions raise Failure "luv: ... is
  not available in the generated compiler" until bound over hxmc.NativeUv), BIO callbacks of mbedtls on Haxe streams; GC
  statistics count nothing and finalisers never run. Threads and domains
  run one at a time under a master lock; one that never blocks is never
  preempted (OCaml's tick thread has no counterpart). Event has send,
  receive, always, sync and poll (no choose, wrap or guard).
- The C-library stand-ins: Unix's sockets are hxmc's NativeNet (errno-exact
  Unix_error on Linux and macOS). Its pipes and create_process use host
  descriptors on POSIX hosts, other platforms fall back to Haxe's sys API.
  Its files, Str and Domainslib are written over Haxe's sys API; kill sends
  SIGKILL whatever the signal.
