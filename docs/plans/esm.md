# ESM output and hot reload (hxmc)

Purpose: input for a full implementation plan. Covers goals, architecture,
runtime model, compatibility constraints, and open items to verify before the
plan is final.

This work lives in the **npm hxmc compiler**. It is **not** an upstream Haxe
feature. Stock `--js` (without `-D esm`) must stay **byte-identical** to the
reference port for fixpoint and `UpstreamTargets`.

## 0. Boundaries with hxmc

ESM is an **isolated scope**. We fit where existing hxmc pieces help; we do
**not** bend the hxmc target, the dev loop, or other plans to serve ESM.

| | |
| --- | --- |
| **Reuse when it fits** | Js platform (`-js` / `--js`), typer, filters, `#if js`, `js.*` externs, compilation server and module cache, optional reuse of watch / WebSocket / error-overlay patterns from `dev.mjs` in a later ESM dev tool |
| **Leave intact** | `Genjs` default path, `--custom-target hxmc`, `hxmc dev` (snapshot + fresh start: [dev.md](../dev.md), [dev-loop.md](dev-loop.md)), native/Wasm codegen, fixpoint and crosshost |
| **Branch out** | Generator and runtime under `hxmc/src` (e.g. `Genesm`), ESM std classpath when needed, ESM-specific dev server and patch protocol, closure-aware heap serializer (not `haxe.Serializer` / dev snapshot encoding) |
| **Port touch** | Minimal: e.g. `Platform.Js` dispatch in `Generate.hx` when `-D esm` is set; follow [porting.md](../porting.md) |

Merging ESM in-process hot reload with `hxmc dev` is **optional later**, only
after both workflows are understood.

**Decisions (fixed for this plan)**

| Topic | Choice |
| --- | --- |
| Integration | `--js <out>` with `-D esm`; `Platform.Js`, `-D js` stay defined |
| Distribution | hxmc npm compiler only |
| Phase 1 milestone | **Prod ESM** (idiomatic modules, tree-shakeable); hot reload deferred |
| Prod output shape | **Idiomatic ESM** (`import` / `export`, `import.meta`, multiple files, native closures) even if some classic-JS edge tests need exclusions early |
| Semantic target (prod) | Haxe semantics as exercised by the JS unit suite; **not** required to match `Genjs` output layout |
| Dev / hot reload | Separate path from `hxmc dev`; own serializer; may reuse compile server + transport ideas |
| Tier 3+ heap restore | ESM-owned serializer; not the dev-loop snapshot format |

## 1. Scope and assumptions

**Assumptions (change any of these and parts of the design change):**

- Compiler support: a dedicated ESM generator in hxmc, not a macro or genes-style
  library. Selected with **`--js`** (or `-js`) plus **`-D esm`** on the Js
  platform. Defines `esm` in addition to `js`.
- `#if js` code compiles. `js.*` externs are reused where they do not assume
  CommonJS or Genjs's single-file layout. ESM-only APIs go in **`esm.*`** (stdlib
  classpath when `-D esm`).
- **Phase 1** runtime is browser or bundler ESM (Node ESM is in scope for tests).
  **Phase 2** (dev) assumes single-threaded browser JS; patches at event-loop
  boundaries.
- **Phase 2 only:** "State" is everything reachable from Haxe-owned roots. DOM
  state and third-party JS library internals are out of scope.
- Sequencing: section 12.

**Goals**

**Phase 1 (now)**

1. Emit idiomatic, tree-shakeable ESM (per-module files, standard `import` /
   `export`, `import.meta` where needed).
2. Preserve Haxe **semantics** required by the JS unit suite (Ints, null, arrays,
   reflection behavior as tested—not Genjs's exact object graph).
3. Zero hot-reload overhead when `-D esm.hot` is absent.
4. No impact on stock `--js` or the hxmc target.

**Phase 2 (later — hot reload dev flavor, `-D esm.hot` or similar)**

5. Per-definition hot reload of bodies with live instances where the model allows.
6. Old closures run new code after a patch (callable wrappers, registry).
7. Layout / hierarchy / enum changes via migration, with full reload fallback.
8. Transactional patches with rollback.

**Non-goals**

- Changing `Genjs` output for non-ESM builds.
- Preserving in-flight native `Promise` or JS generator frames (phase 2).
- Preserving state inside third-party JS libraries (phase 2).
- Hot reload in prod.
- Upstreaming ESM to OCaml Haxe.

## 2. Why compiler-level support (versus macro-based generators)

A macro-based generator on stock JS gets body swaps with workarounds. Compiler
support in hxmc is justified for phase 2 and for prod semantics under idiomatic
ESM:

| Capability | Macro / genes-style | hxmc ESM generator |
| --- | --- | --- |
| Idiomatic multi-file ESM | Awkward | By design (phase 1) |
| Swap constructor bodies live | Workaround | By design (phase 2) |
| Change `extends` live | No (reload) | Yes (phase 2) |
| Old closures run new code | No | Yes (phase 2) |
| Heap snapshot incl. closures | No (`Serializer` throws) | Yes (phase 2, ESM serializer) |
| Transactional patch | Not feasible | Yes (phase 2) |
| Stock typer / filters for Js | Inherited | Inherited (`-D esm` only switches generator + classpath) |
| `Genjs` byte identity | N/A | Unchanged without `-D esm` |

**Flag shape (decided):** `--js out/main.js` (or an output directory convention
for multi-file emit) plus **`-D esm`**. Prod default. Phase 2 dev flavor:
**`-D esm.hot`** (name to confirm).

A standalone `--custom-target esm` is **out of scope**: it would fight Js platform
setup and haxelib compatibility without helping phase 1.

## 3. Pipeline

```
Js typer -> typed AST -> HIR (stable IDs, RTTI; layout hashes for phase 2)
                              |
         phase 2 only: closure conversion, enum tables,
                       coroutine lowering, layout hashing, field diffing
                              |
            +-----------------+------------------+
       Dev backend (phase 2)              Prod backend (phase 1)
       registry, patchable              idiomatic ESM, native closures,
                                        int enums, DCE, tree-shakeable
```

Generator lives in **hxmc** (`Genesm` or equivalent), invoked from the port's Js
branch when `-D esm` is set. Reuses typer, filters, DCE, and compilation-server
module cache; does not share the hxmc native IR pipeline unless that proves
convenient later.

**Phase 1 prod backend** does not require the dev cell object model (section 5).
It may use normal ES modules and constructors where idiomatic, reserving the
cell/`$ctor` model for phase 2.

## 4. Identity model (phase 2 — hot reload)

Every patchable entity has an ID that survives recompilation:

- **Type:** qualified Haxe path.
- **Field:** `type#name` plus a signature hash of its type.
- **Local function (lambda):** `enclosingFieldId/λ<structural-key>`, plus body
  hash for fuzzy re-match. `@:hot.was("oldName")` for explicit renames.
- **Layout hash:** ordered `(fieldName, typeHash)` for instance fields.
- **Enum table:** stable `constructorName -> index` for the dev session.

Not required for phase 1 beyond what reflection metadata needs.

## 5. Object model

### Phase 1 (prod, idiomatic ESM)

- Multi-module layout: one (or few) ESM files per Haxe module/type as the
  generator chooses; `import` / `export` between user types; externs as ordinary
  imports.
- Prefer **standard JS** construction (`class` / `function` + prototype) where
  it matches idiomatic ESM and semantics tests; avoid Genjs's single-bundle
  patterns when they fight tree-shaking.
- `Type` / `Reflect` / metadata: compatible enough for the JS unit suite;
  internal layout may differ from `Genjs` if tests allow.
- **Must match stock Haxe JS semantics** where tests assert: Int rules, null,
  array holes, string indexing, `@:native`, `@:expose`, coroutine lowering
  behavior (stage to confirm in hxmc's Js pipeline).

### Phase 2 (dev hot reload)

- **Persistent cells**, `$new` / `$ctor`, registry linking, re-parenting, and
  ctor-pinned types for native ES parents—as in the original technical design.
- Instances without hot-reload bookkeeping properties unless reflection tests
  require otherwise in dev mode.
- Sections 6–8 apply to phase 2 only.

## 6. Closure conversion (phase 2, dev flavor)

Each lambda is lifted to `impl(env, ...args)`; creation sites use callable
wrappers late-bound through a function registry (`$id`, `$env` as a named record,
boxes for mutated captures, `Reflect.compareMethods` parity, stale wrappers when
captures change).

## 7. Linking and patch delivery (phase 2)

- **Dev:** no ESM imports between user types; registry (`$h.Foo`) avoids cycles,
  TDZ, and import-map cache issues. Externs stay normal ESM imports.
- **Patch units**, atomic apply, compile-server per-type emit hashes, `-dce no`
  or `std` in dev.
- **ESM dev tool** (not `hxmc dev`): Node script or Vite plugin; manifest over
  WebSocket. May **reuse** file watching and error-overlay patterns from
  `packages/cli/hxmc/bootstrap/dev.mjs` but not the wasm/native reload protocol.
- **Static initialisers (dev):** init-if-absent; order matches Haxe.

## 8. Heap, migration, rollback (phase 2)

Patch tiers 1–4 as in the original design. **Serializer:** ESM-specific
(closures as `$id` + env, cycles, enums by name); optional `sessionStorage` on
full reload. **Do not** adopt `haxe.Serializer` dev snapshot encoding from
[dev.md](../dev.md).

## 9. Std lib and JS-compatibility surface

- **Reuse:** `js.*` externs that are platform-neutral; audit `@:jsRequire` /
  CommonJS-oriented externs for ESM consumers (document gaps).
- **Add `esm.*`:** `import`/`export` helpers, `import.meta`, dynamic `import`,
  top-level await; phase 2 hot-reload API (cells, registry, effects).
- **Classpath:** ESM overrides only when `-D esm` is set (same pattern as
  `bin/hxmc/std` for the native target—last `-cp` wins).
- **Phase 2:** hot-aware `Type` / `Reflect`; tracked-effect wrappers in `esm.*`.
- **Coroutines:** same lowering stage as Js in hxmc; phase 2 resumable frames
  only with `-D esm.hot`.

## 10. Semantic compatibility and testing

**Prod (`-D esm`, no hot):** semantic parity with **Haxe on JS** as defined by
the JS unit suite—not byte or structural parity with `Genjs`. Early exclusions
for tests that assert Genjs-specific layout, single-file names, or stack shape are
expected; keep a shrinking allow-list.

**Dev (`-D esm.hot`):** additional deviations (stacks, enum indices after patch,
stale closures, static init policy)—documented in section 11.

**Test strategy (hxmc)**

1. **Stock `--js`:** unchanged; `make test LANES=targets`, fixpoint.
2. **Prod ESM:** run JS unit suite (and targeted integration tests) with
   `-D esm`; track exclusions vs `Genjs`; add `hxmc/test` cases for multi-file
   emit and `import.meta`.
3. **Fuzzer:** eventual `diff:js-esm` lane; not compared to reference.
4. **Phase 2:** differential hot-patch tests, closure tests, server hash cache
   tests; not in phase 1 gate.

Flag matrix: derive from `haxe/test/Targets.hx` and CI js jobs (ES version,
`js-unflatten`, libraries).

## 11. Dev/prod divergence register

Track when phase 2 exists: closure identity, registry vs direct ESM imports,
enum representation after patch, DCE, static init, effect wrappers, stack traces.

Phase 1 only: document prod vs `Genjs` **observable** diffs (reflection fields,
module graph, `compareMethods` if any).

## 12. Workstreams

### Phase 1 — prod idiomatic ESM (now)

**Landed (2025-11):** `-D esm` with `--js <entry.mjs>` on the npm/`HaxeMain`
compiler: `generators.EsmHook` dispatch in `Generate.hx`, `hxmc.genesm.Genesm`
(multi-file under `<out>/hx/`, runtime `__hx_esm_runtime.mjs`, entry at
`--js`), `hxmc/EsmInstall`, optional `-cp hxmc/std/esm`, smoke test
`hxmc/test/esm/hello.hxml`. Genesm emits per-module `import`/`export` with a
`$global` bridge; cross-module refs add explicit imports; user modules and
nested std modules export top-level bindings. Entry side-effect-imports only the
**main module's `modDeps` closure** (DCE-kept graph), topo-sorted—not every
emitted file. Exclusions: `hxmc/test/esm/exclusions.txt` + `exclusions.md`.

**Harness:** `make esm-unit` (`EsmSuites.hx`) runs the upstream JS unit suite
with `-D esm`; baseline **1576 pass / 44 excluded** (`exclusions.txt`). On
Darwin, skip wasm/crosshost quick lanes when verifying locally.

**Open:** HIR layer, shrinking exclusions (runtime/metadata), `esm.*` std
shadows as tests require.

1. **Output mode and prod backend.** `-D esm`, minimal `Generate.hx` dispatch,
   `Genesm`, typed AST → HIR → ESM files, Int/null semantics, coroutines on Js
   path.
2. **Std and classpath.** Audit `js.*`; add `esm.*`; override std only as tests
   require. **Gate:** JS unit suite with documented exclusions.
3. **Tooling and docs.** hxml examples, npm/browser consumption, exclusion
   governance in CI.

### Phase 2 — hot reload (later)

4. Dev backend: cells, registry, `$new`/`$ctor`, patch units, ESM dev server.
5. Change detection and tier-1 patching (compile-server hash cache).
6. Closure conversion and semantic tests.
7. Heap tracking, migration, enum tables, re-parenting (tier 2).
8. ESM serializer, transactional apply (tiers 3–4).
9. Tracked-effect wrappers; coroutine resumable frames (research).
10. Dual-flavor CI and hot-patch harness.

## 13. Open items to verify

1. Exact JS test matrix in hxmc (`haxe/test/Targets.hx`, upstream-tests js job):
   which cases fail on idiomatic multi-file ESM first.
2. Output layout convention: directory per build vs single `--js` entry path as
   manifest.
3. Minimal port patch for generator dispatch; confirm reference `bin/port/haxe`
   ignores or rejects `-D esm` without affecting conformance.
4. Compile-server: per-type emit hashes for phase 2 (hxmc module cache already
   incremental for typing).
5. Coroutine lowering stage on Js in the current port.
6. `@:coreApi` and classpath override rules for ESM std shadows.
7. Ecosystem: `haxe-react`, tink, hxnodejs under `-D js` + `-D esm`; CommonJS
   extern audit.

## 14. Remaining hard limits (phase 2)

- DOM state outside Haxe's control.
- State inside foreign JS libraries.
- In-flight native `Promise` and generator frames.
- Closures whose captured-variable sets changed (stale until replaced).