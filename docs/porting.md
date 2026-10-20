# Porting rules

These apply to every change of `haxe/src`.

- `haxe/upstream` is the canonical reference: never edit its files or commit
  inside it (the harnesses leave it clean). Moving the pinned revision is a
  deliberate change: it ports every upstream commit in between, must land on
  a commit with a nightly build on build.haxe.org (the reference), and updates
  the revision in `Version.version_extra`'s counterpart
  (`haxe/src/compiler/server/ServerCompilationContext.hx`).
- Read the upstream OCaml module before adding or changing its Haxe
  counterpart, at the matching path (`typing/typer.ml` becomes
  `haxe/src/typing/Typer.hx`; `macro/eval/evalFoo.ml` becomes
  `haxe/src/macros/eval/EvalFoo.hx`, `macro` being a keyword). Names go
  `snake_case` to `camelCase`, records become classes, a name that is a Haxe
  keyword gets a suffix (`throw` becomes `throwValue`).
- Preserve function order, branch order, data layout, error messages and
  exception behavior. Prefer a direct translation over a redesign.
- Reproduce OCaml semantics that reach the output: `Hashtbl` iteration order
  (`core.ds.OcamlHashtbl`), `PMap` order (sorted keys; extlib's `PMap.map`
  and `mapi` visit the tree in post-order), right-to-left evaluation of
  arguments with side effects, float printing (`core.Numeric`,
  `core.ds.OcamlPrintf`), 31/63-bit integers. Never derive output order from
  Haxe `Map` iteration.
- Upstream's lists are Arrays, except where a hot path relies on O(1)
  `x :: l` and shared tails: there `core.ds.MlList` (`Nil`/`Cons`, the shape
  of ml2hx's runtime list), so far the matcher's rows (2% fewer instructions
  in the self-compile). Convert another site only when it measures: the
  resolution list and the analyzer's CFG edges saved 0.2-0.5% of the
  instructions and no wall time beyond noise, so they stayed Arrays.
  `core.TType`'s fields stay Arrays (hxmc's back end and HXB read them).
- Output that depends on the reference binary itself is the one exception
  to byte identity: hl/c's digest names of the types whose description
  holds a closure (Marshal writes code pointers and the digest of the
  reference's machine code). The port writes a documented placeholder
  instead of constants of one reference build, and the harnesses normalize
  only those names (the digest names found on one side only: docs/testing.md,
  "hl/c digest names"; `haxe/test/HlcNames.hx`); a new case of the kind extends
  both, never a general tolerance.
- Never stub out behavior with a silent success: what the port cannot
  support fails explicitly with a `// port:` note.
- Comments from upstream stay at the matching place with upstream's wording
  (`(** *)` becomes `/** */`); a ported file starts with its upstream
  module's license header; every other comment in `haxe/src` starts with
  `// port:` (continuation lines `// ...`) and stays true.
- `haxe/upstream/libs` holds OCaml dependencies: reproduce what the compiler
  reaches (`haxe/src/libs`: the Neko compiler, swflib, zlib's deflate,
  extlib IO, ziplib) rather than porting them.
- Before calling a change done, run the lanes it can affect: HXB conformance
  and macro cases for typing or filters, the fuzzer's `diff:<target>` lanes
  and `UpstreamTargets` for generators, display and server for those
  services, `quick`/`check` for hxmc, everything for broad changes. Never
  commit `bin/`.
