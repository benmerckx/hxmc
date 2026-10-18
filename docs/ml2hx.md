# Generating the compiler from OCaml

This is an opt-in first migration slice. **Three upstream modules are generated;
the full compiler is not yet generated.** The normal build still uses the
handwritten port. The goal is to advance an upstream pin, regenerate, and review
only upstream changes and explicit host adaptations.

## Run it

A checkout with node and the upstream submodule is enough to generate:

```sh
make generate               # generated/compiler; never writes haxe/src or upstream
make generate-check         # regenerate in memory and reject committed drift
make port-generated         # bin/ml2hx/haxe; generated modules shadow haxe/src
make ml2hx-test              # behavioral tests on Eval and JS (with make port)
make ml2hx-history           # Haxe 4.0.5, 4.1.5, 4.2.5 and 4.3.7
make ml2hx-bench             # compare bin/port/haxe with bin/ml2hx/haxe; GNU time
```

After `make reference`, the existing harnesses can test the generated-module
binary against the pinned official nightly:

```sh
make test test-display test-server PORT_BIN=bin/ml2hx/haxe
make test PORT_BIN=bin/ml2hx/haxe CASES_FILE=haxe/test/conformance-macro-cases.txt
```

The generated shadow includes:

| OCaml source | Generated behavior | Handwritten adaptation |
| --- | --- | --- |
| `context/typerPass.ml` | enum, ordered pass list, length | persistent list to the existing array API |
| `compiler/server/serverConfig.ml` | reference cells, defaults, reset | property accessors expose the port's existing scalar fields |
| `core/ds/ring.ml` | record, create/push/iter/fold/find/reset | instance methods delegate to the generated curried functions |

Adapters live under `tools/ml2hx/adapters`. They contain ABI conversions rather
than copies of upstream algorithms. `modules.json` is the explicit initial
coverage list. Omitting the other compiler modules is not a claim that they
were translated: they continue to come from `haxe/src` in this experiment.

## Architecture

1. `frontend/main.ml` uses the real OCaml parser and compiler-libs typechecker.
   It exports resolved identifiers, inferred types, source locations and typed
   expressions as versioned JSON. No handwritten OCaml parser or inferred
   Haxe `Dynamic` substitute is involved.
2. The committed compressed js_of_ocaml bootstrap runs that frontend under
   node. The standard-library interfaces are embedded in its virtual filesystem.
   Normal generation downloads nothing and needs no OCaml toolchain.
3. `emit.mjs` lowers typed JSON into deterministic Haxe; `format.mjs` formats
   the emitter's output without interpreting strings or comments.
4. The manifest records the exact upstream commit, each input hash, each
   output hash and the exported OCaml values. The output contains no checkout
   absolute paths or timestamps. `generate-check` compares exact output bytes.
5. Haxe classpath precedence shadows the selected handwritten modules. The
   upstream checkout is never patched, and no existing compiler source changes
   are needed for this first slice.

The complete output is rendered before publication, so a translation error does
not partially publish a module set. An I/O failure while writing can still leave
incomplete output; regenerate to repair it. Unsupported types, expressions and
module constructs are errors. There are no silent success stubs or copied-port
fallbacks in the generator.

To inspect parser coverage independently of translation:

```sh
node tools/ml2hx/inventory.mjs > bin/ml2hx/inventory.json
```

The parser accepts all 297 implementation files at the current pin. This does
**not** mean the typechecker or emitter supports all those modules.

## Semantics already exercised

- Curried functions and partial application; self tail calls become loops with
  fresh per-invocation argument slots, including reuse of a partial application.
- OCaml operand evaluation order: application arguments right to left; `let
  ... and ...` right-hand sides and `for` bounds left to right; a record-update
  base is evaluated before its replacement fields.
- Immutable tuples and persistent lists; option constructors retain `Some`
  separately from `None`; mutable reference cells and shared record fields.
- Constructor patterns, guards, fallthrough and match failure.
- Native OCaml signed, wrapping 63-bit machine integers on every Haxe host,
  including JavaScript. Literal values come from source tokens before typing:
  js_of_ocaml's 32-bit `int` cannot truncate wide compiler constants.
- OCaml string literals are byte sequences, including NUL and invalid UTF-8.
  The current runtime represents each byte as one Haxe string character;
  future host string adapters must explicitly convert that representation.

The semantic fixture is checked against output produced by native OCaml, Eval
and JS. Set `ML2HX_OCAMLC` and, if needed, `ML2HX_OCAMLRUN` when running the node
tests to refresh that native comparison. The checked-in expected output remains
available when OCaml is not installed.

There is deliberately no generic structural equality/comparison fallback.
Function physical equality is also rejected: generic function factories create
fresh closures, so claiming OCaml identity would be wrong. Local polymorphism,
labelled/optional arguments, most exceptions, lazy values, objects, functors,
includes and many library operations still need lowering/runtime support.

## Frontend builds and WASI

The initial frontend ABI is compiler-libs **4.14.1**. Rebuild the JS bootstrap
with OCaml 4.14.1 and js_of_ocaml 5.6.0:

```sh
node tools/ml2hx/build.mjs
```

`OCAMLC` and `JS_OF_OCAML` can select executables. Build products stay in `bin/`.
The bootstrap's source and dependency notices are in
`tools/ml2hx/bootstrap/README.md`. This is a bootstrap artifact, like stage0;
CI verifies generated-source drift using it.

The same ML source has a WASI build recipe:

```sh
WASM_OF_OCAML=wasm_of_ocaml node tools/ml2hx/build.mjs wasi
```

It requires wasm_of_ocaml >=6.4, Binaryen, Wasm GC and exception handling.
The resulting node launcher is `bin/ml2hx/build/frontend-wasi.js`; its Wasm
assets can also run in compatible standalone engines. This recipe is not yet
validated in this PR's environment, and there is no JS-versus-WASI benchmark.
No JavaScript bindings are used by the ML frontend itself.

`ML2HX_FRONTEND` can name an executable wrapper implementing the JSON protocol
for native OCaml, a WASI launcher, or another compiler-libs version. It receives
the same file arguments as the bootstrap. A native bytecode frontend is built
by `build.mjs native`; a wrapper can run it through `ocamlrun` with the correct
`--stdlib` and `-I` paths. The provided executable wrapper is
`tools/ml2hx/frontend-native.mjs`; select it with `ML2HX_FRONTEND`.

`--cmt` requires the native 64-bit frontend: JS cannot faithfully unmarshal
native machine integers. It reads compiler-produced implementation typedtrees
and requires their source files to preserve machine-integer literals. CMT/CMI formats are version
specific: files built by OCaml 5 cannot be read by the 4.14 frontend. This is a
future integration path, not an implemented whole-upstream build driver.

## Historical pins

```sh
node tools/ml2hx/generate.mjs --profile history \
  --upstream /path/to/clean/haxe-checkout --out bin/ml2hx/historical
node tools/ml2hx/matrix.mjs 4.0.5 4.1.5 4.2.5 4.3.7
```

The matrix uses isolated checkouts and outputs. It parses every implementation
file, then generates and executes the server configuration and ring modules on
Eval and JS. The historical profile accepts the server-config path relocation;
the ring is absent in 4.0.5, and `find` is absent in the tested 4.x rings. These
are recorded/handled explicitly using the generated export manifest. No old
upstream checkout is modified. Full old compilers are **not** rebuilt by this
matrix.

## Sources, releases and next migration steps

Keep generated sources on the normal development branch, beside one pinned
upstream revision. A pin-update PR contains the upstream submodule change,
regenerated output and any adaptation changes. CI must reject generation drift.
Tag releases; use maintenance branches only for versions maintained separately.
Historical test outputs belong in `bin/`, not permanent release branches.

The remaining work before arbitrary-pin whole-compiler generation is substantial:

1. Establish the shared `Globals`/AST/type ABI and compatibility runtime, while
   preserving the representations consumed by the handwritten hxmc backend.
2. Add dependency-aware typing or consume typedtrees from a matching upstream
   build, with an OCaml 5 frontend as needed. Avoid recreating OCaml inference.
3. Lower module includes/functors, local polymorphism, exceptions, lazy values,
   recursive groups and OCaml library primitives with differential tests.
4. Move Eval's host objects, OS/regex/TLS bindings and hxmc's generation/cache
   hooks behind explicit runtime substitutions or checked injection points.
5. Expand the coverage manifest a dependency slice at a time. Keep the existing
   official-nightly conformance, server, display, self-hosting, fixpoint and
   crosshost checks; profile closure allocation and integer representation as
   compiler-hot modules move over.

A new pin may need new translator features or adapters. It must fail visibly
until those are implemented; “any commit” is the goal, not a current guarantee.

Initial test and performance results: [ml2hx-results.md](ml2hx-results.md).
