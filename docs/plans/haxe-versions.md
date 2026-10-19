# Any Haxe version

Goal: hxmc builds with the compiler of any Haxe release, chosen per
project, 4.x (back to 4.0) included, and following a new upstream
release is a regeneration, not a port by hand.

Today the compiler is `haxe/src`: upstream's OCaml ported to Haxe by hand,
pinned to one commit of `haxe/upstream` (5.0.0-preview.1-573), with 1811
`port:` markers where it differs (hooks for hxmc, the module cache, the
server, performance). Following upstream means porting each commit; going
back to 4.x means porting another compiler. Neither scales to "any version".
So the compiler becomes generated, per version, from upstream's own
sources, and what is ours moves out of the compiler into layers that are
kept per version range, small and explicit.

## The layers

```
 upstream Haxe X.Y (OCaml, a pinned tag)
        │  dune build --> typed trees (.cmt)
        ▼
 ml2hx frontend (OCaml)  -->  JSON IR (versioned protocol)
        ▼
 ml2hx emitter  +  overlays/X.Y  -->  haxe/gen/X.Y  (Haxe, generated, not committed)
        ▼
 compiler API facade  (hxmc.api: typed AST, messages, module access)
        ▼
 hxmc back end, module cache, display, dev loop   (one implementation)
```

1. **The generated compiler (`haxe/gen/<version>`).** ml2hx (PR #5) turns
   a version's typed trees into Haxe: every module, the standard library
   calls it makes resolved to a Haxe runtime of the OCaml library
   (`ml2hx.rt`). Built in CI and cached by upstream SHA; never edited.
2. **Overlays (`haxe/overlay/<range>`).** What we change in the compiler
   becomes data the emitter applies, not edits: hooks (module cache's
   `missingFieldHook`, `buildClassHook`, `readerFindModuleHook`, the
   server's), replacements of hot functions by tuned Haxe (the speed work
   of PR #3: `x :: l` as pushes, `Meta.has`), and target-specific entry
   points. Each overlay names the upstream function it applies to and the
   version range it is valid for; the emitter fails when an overlay's
   target is gone or changed (its typed signature hashed), so drift is a
   build error, not a silent miss. The 1811 `port:` markers are the
   inventory to turn into overlays; most are expected to disappear as
   generated code (they exist because the port is by hand).
3. **The compiler API facade (`hxmc.api`).** hxmc's back end reads the
   typed AST (`core.TType`, `core.TFunctions`), `Ast` operators, messages,
   HXB and Eval values. Between 4.0 and 5.x these differ (fields, enum
   cases: e.g. 5.x's coroutines, `TIdent`, abstract handling, HXB only in
   5.x). hxmc gets one stable view: a facade generated from each version's
   types with hand-written adapters for the differences, so `hxmc/src`
   compiles once against `hxmc.api` and never names a version. What a
   version lacks is a capability flag (`api.hasHxb`), not an `#if`.
4. **Per-version features.** HXB, the persistent module cache and
   `hxmc dev`'s fast server path need 5.x's HXB; on 4.x the module cache
   falls back to the in-memory server cache (or off), and the dev loop
   uses the server without HXB. Native macros (Eval) are generated like
   the rest; their value encoding goes through the facade.

## Choosing a version

`-D haxe-version=4.3.6` (or `haxe.version` in package.json, or
`npx haxe --use 4.3.6`). The CLI fetches or builds that version's
generated compiler (prebuilt per release in the npm package's cache,
like the runtime objects; built locally from the pinned tag otherwise),
then compiles with it. One project, one version; switching is a cache
lookup.

Supported set: every 4.x release from 4.0.0, 5.x releases, and upstream's
development head (nightly). OCaml toolchains: each version builds with
the OCaml and opam libraries its own tag pins (an opam switch per version
range in CI); the frontend is compiled with that switch, so the typed
trees always match.

## Conformance, per version

A generated compiler is correct when it behaves as that version's OCaml
compiler: the same lanes as today, run per version against that version's
reference binary.

- Unit tests and misc tests of that version's `tests/`.
- Output identity: for each target the reference supports, the generated
  compiler's output equals the reference's (JS, HL, JVM bytes, ...), as
  the HXB conformance does for 5.x today.
- Display and server tests where the version has them.
- hxmc's own lanes (corpus, fixpoint, gfx/ui/3d programs) on the default
  version, and the corpus on every supported version.

CI: the default version on every push; all supported versions nightly and
on changes to ml2hx, overlays or the facade.

## Speed

The handwritten port is now faster than the OCaml compiler (PR #3). A
generated compiler must not lose that. Plan:

- Emit idiomatic Haxe, not an OCaml simulation: OCaml `int` as Haxe `Int`
  where a range analysis or the version's own invariants allow (63-bit
  semantics only where overflow is observable: the overlays mark those),
  records as classes, variants as enums, lists as an immutable list type
  with fast paths, tuples unboxed into multiple returns where they do not
  escape, functions without currying when fully applied.
- The runtime of the OCaml library is tuned once and shared by every
  version (Hashtbl, Buffer, Format, List, Map/Set functors), with OCaml's
  exact iteration orders where output depends on them.
- Hot functions that still lose get overlays (tuned Haxe), each with a
  benchmark proving it; the PR #3 set is the start.
- Gate: the self-build and `make measure` within 5% of the handwritten
  port before the switch.

## Steps

1. **ml2hx covers the language** (PR #5 grown): modules and functors,
   include, records, variants (incl. polymorphic and extensible, GADTs as
   needed), exceptions with payloads, labelled/optional arguments, objects
   (few, but the compiler has some), laziness, mutual recursion across
   modules; structural equality, compare and hash with OCaml semantics.
   Done when every module of the pinned 5.x tag emits and types. The
   frontend is built in CI, not committed as a bundle.
2. **The OCaml library runtime**: what the compiler uses of Stdlib, Str,
   Unix, Extlib, sedlex/ppx output, sha1, etc., with tests against OCaml.
3. **5.x generated compiler passes conformance**, without overlays except
   entry points. Compared with the handwritten port on the same tag.
4. **Overlays**: the hooks hxmc needs (module cache, server, LowerCache's,
   display) and the speed set; the emitter's checks for drift. Then the
   speed gate.
5. **The facade (`hxmc.api`)** for 5.x, and hxmc moved onto it. hxmc's
   corpus, fixpoint and every lane green on the generated 5.x compiler.
   **Switch**: the generated compiler replaces `haxe/src`; the handwritten
   port is retired (one implementation).
6. **4.3**: its toolchain switch, generation, its conformance, the facade's
   adapters (no HXB: the module cache's fallback). Then 4.2 down to 4.0,
   each a facade adapter and overlay range, expected small.
7. **Version selection in the CLI and npm package**: prebuilt compilers
   per release, `--use`, nightly head.

Each step lands green on its own; until step 5 the handwritten port stays
the default and the generated compiler is an extra CI lane.

## Risks

- **Speed** (above): the gate decides the switch; without it the
  handwritten port stays and generation becomes a porting assistant
  (drafts of upstream changes in the port's style) instead.
- **OCaml semantics in output**: Hashtbl and Format orders, float
  printing, string/bytes. Covered by output identity per version.
- **Old toolchains**: 4.0-4.2 need older OCaml and libraries; pinned opam
  switches in CI, cached.
- **hxmc's own compiler work** (LowerCache, Reach, server fixes) lives in
  hxmc and the overlays, so it carries across versions; anything that
  needs a typed-AST feature a version lacks becomes a capability flag.

## What exists

- PR #5 (draft): the frontend over every module of the pinned tag (324 of
  326 type), the emitter for a small subset (14 modules emit), a seed of
  the runtime and semantic tests. It commits a js_of_ocaml bundle of the
  frontend; step 1 replaces that with a CI build.
