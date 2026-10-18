# Frontend bootstrap

`frontend.cjs.br` is `frontend/main.ml` linked with OCaml compiler-libs 4.14.1
and its standard-library CMI interfaces, compiled by js_of_ocaml 5.6.0 and
Brotli-compressed. It runs under node; no npm package or OCaml installation is
needed to generate the initial modules. Rebuild with `node tools/ml2hx/build.mjs`.
The JSON protocol is version 1. The readable source is always authoritative.

The linked OCaml compiler libraries are LGPL-2.1 with the OCaml linking
exception. The js_of_ocaml runtime is LGPL-2.1-or-later with its linking
exception. Their license notices are retained here; the generated JS also
retains its runtime license banner. The generator's own source is covered by
the repository's compiler license.

- OCaml 4.14.1: https://github.com/ocaml/ocaml/tree/4.14.1
- js_of_ocaml 5.6.0: https://github.com/ocsigen/js_of_ocaml/tree/5.6.0

`build.mjs wasi` builds the same ML source with wasm_of_ocaml >=6.4 using its
standalone WASI target. That output needs Wasm GC and exception handling.
This PR does not commit a WASI bootstrap or claim a WASI performance result.
