# Agents

Read README.md first, then docs/development.md (layout, building),
docs/testing.md (tests) and docs/porting.md (rules for every change of
`haxe/src`). In short:

- `haxe/upstream` is the reference: never edit it or commit inside it.
- Port upstream modules directly, at the matching path, in upstream's order,
  with upstream's comments; other comments in `haxe/src` start with `// port:`.
- Reproduce OCaml semantics that reach the output; never stub with a silent
  success.
- The reference compiler is the nightly of the pinned commit (`node make.mjs
  reference`). Before calling a change done, run the lanes it can affect
  (docs/testing.md; `node make.mjs quick`/`check` for hxmc) and keep the fixpoint
  (`node make.mjs fixpoint`) and crosshost (`node make.mjs crosshost`) byte-identical.
- The build is `node make.mjs <target>` (`tools/make/Make.hx`), on Linux,
  macOS and Windows with node and git alone. Tooling is Haxe run with our
  own compiler (`bin/hxmc/hxmc -cp ... --run`) and node; no Python, no make. Never commit `bin/`.
