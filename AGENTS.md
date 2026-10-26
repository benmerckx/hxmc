# Agents

Read README.md first, then docs/development.md (layout, building),
docs/testing.md (tests) and docs/porting.md (rules for every change of
`haxe/src`). In short:

- `haxe/upstream` is the reference: never edit it or commit inside it.
- Port upstream modules directly, at the matching path, in upstream's order,
  with upstream's comments; other comments in `haxe/src` start with `// port:`.
- Reproduce OCaml semantics that reach the output; never stub with a silent
  success.
- The reference compiler is the nightly of the pinned commit (`make
  reference`). Before calling a change done, run the lanes it can affect
  (docs/testing.md; `make quick`/`check` for hxmc) and keep the fixpoint
  (`make fixpoint`) and crosshost (`make crosshost`) byte-identical.
- Tooling is Haxe run with our own compiler (`bin/hxmc/hxmc -cp ... --run`)
  and node; no Python. Never commit `bin/`.
