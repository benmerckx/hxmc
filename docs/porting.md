# Porting rules

The rules for every change to the port (`haxe/src`), for contributors.
The port must behave exactly like the reference compiler of the pinned
upstream commit.

## The reference

- `haxe/upstream` is the canonical reference. Never edit its files or
  commit inside it; the harnesses leave it clean.
- Moving the pinned revision is a deliberate change. It ports every
  upstream commit in between, lands on a commit with a nightly build on
  build.haxe.org (the reference), and updates the revision in
  `haxe/src/compiler/server/ServerCompilationContext.hx`.
- Before calling a change done, run the lanes it can affect
  ([testing.md](testing.md#which-tests-to-run)). Never commit `bin/`.

## Translating

- Read the upstream OCaml module before changing its Haxe counterpart, at
  the matching path: `typing/typer.ml` is `haxe/src/typing/Typer.hx`;
  `macro/eval/evalFoo.ml` is `haxe/src/macros/eval/EvalFoo.hx` (`macro` is
  a keyword).
- Names go from `snake_case` to `camelCase`; records become classes; a
  name that is a Haxe keyword gets a suffix (`throw` becomes `throwValue`).
- Keep function order, branch order, data layout, error messages and
  exception behaviour. Prefer a direct translation over a redesign.
- Never stub behaviour with a silent success. What the port cannot support
  fails explicitly, with a `// port:` note.
- `haxe/upstream/libs` holds OCaml dependencies. Reproduce what the compiler
  reaches (`haxe/src/libs`: the Neko compiler, swflib, zlib's deflate,
  extlib IO, ziplib) rather than porting them.

## Comments

- Upstream's comments stay at the matching place, in upstream's wording
  (`(** *)` becomes `/** */`).
- A ported file starts with its upstream module's license header.
- Every other comment in `haxe/src` starts with `// port:` (continuation
  lines `// ...`) and stays true.

## OCaml semantics that reach the output

- `Hashtbl` iteration order: `core.ds.OcamlHashtbl`.
- `PMap` order: sorted keys; extlib's `PMap.map` and `mapi` visit the tree
  in post-order.
- Right-to-left evaluation of arguments with side effects.
- Float printing: `core.Numeric`, `core.ds.OcamlPrintf`.
- 31/63-bit integers.
- Never derive output order from Haxe `Map` iteration.

## Strings are bytes

OCaml strings are bytes. On a UTF-16 host (`core.StringHelper.codePointHost`
false), bytes that are not UTF-8 become lone U+DC80 to U+DCFF, which hxmc's
runtime writes back as those bytes
([hxmc.md](hxmc.md#strings-and-dates)). So:

- where upstream works on bytes, work on `Bytes.ofString`'s (extlib's UTF8
  functions, lengths in bytes);
- compare strings with `core.ds.Key.compareStrings` (OCaml's order is code
  point order, which UTF-16 units are not).

## Lists

- **Fixed-size lists are `haxe.ds.Vector`s**: upstream's arrays, and lists
  the port never extends once stored, such as the AST's expression lists
  (`EBlock`, `ECall`, `TCall`, `TBlock`, switch cases, catches), metadata
  arguments, type parameters and function arguments. A Vector is one
  allocation; on hxmc the empty one is shared.
- `core.ds.VectorTools` has `vector(a, b)` (a literal; `vector()` is empty)
  and the list functions on Vectors. `core.ds.List` and `core.ds.ArrayTools`
  take Arrays and Vectors alike. Array patterns (`case [a, b]:`) match
  Vectors too, so upstream's list patterns stay as they are.
- A list built by pushing stays an Array until stored, then becomes a
  Vector once (or is allocated at its final length when known). A
  recursion over a list's tail walks the Vector by index instead of
  slicing.
- Other lists are Arrays, except where a hot path relies on O(1)
  `x :: l` and shared tails: there use `core.ds.MlList` (`Nil`/`Cons`).
  The matcher's rows use it. Convert another site only when it measures.

## The one exception to byte identity

hl/c's digest names of types whose description holds a closure depend on
the reference binary's own machine code. The port writes a documented
placeholder instead, and the harnesses normalize only those names
([testing.md](testing.md#two-exceptions-to-byte-identity),
`haxe/test/HlcNames.hx`). A new case of this kind extends both, never a
general tolerance.
