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
| **In scope (phase 2)** | **Generic layer** — **this repo only:** Haxe typer/filters **+ Genesm** under `-D esm.hot`; **`esm.hot`** runtime in classpath; no UI framework or JSX macros as repo work |
| **Out of scope (reference)** | **Framework layer** — external libs/macros (signals, templates, `component`/`computation` kind handlers). §4.2 and §13 record the full product model; **implementation is not scheduled in hxmc** |
| **Call-site injection (13.9)** | **Hybrid product model:** compiler implements **full A** (`@:esm.hot.keyed`, closure IDs, Genesm `__id`). Macro-supplied unit IDs — external; **ID rule:** keyed call uses compiler site ID; `esm.hot.cell("…", …)` uses explicit `id` |
| **Patch protocol (13.10)** | **Tiers 1–4 (severity) + kinds (dispatch).** This repo ships **builtin kinds** (`function`, `class`, `enum`) and a **pluggable kind registry** for external handlers; not UI kinds |
| **Port touch** | Minimal: e.g. `Platform.Js` dispatch in `Generate.hx` when `-D esm` is set; follow [porting.md](../porting.md) |

Merging ESM in-process hot reload with `hxmc dev` is **optional later**, only
after both workflows are understood.

**Decisions (fixed for this plan)**

| Topic | Choice |
| --- | --- |
| Integration | `--js <out>` with `-D esm`; `Platform.Js`, `-D js` stay defined |
| Distribution | hxmc npm compiler only |
| **Phase 1** | **Dev ESM baseline** — multi-file `.mjs`, **`$global` registry** (stepping stone); gates on JS unit suite today |
| **Phase 2** | **Dev + hot reload** — `-D esm.hot`: `$h` registry, cells, patches (sections 6–8) |
| **Hot metadata (phase 2)** | **Fixed prefix `@:esm.hot.*`** on types/fields/methods; runtime mirror in **`esm.hot.*`** |
| **Phase 3** | **Prod idiomatic ESM** — static `import`/`export` between Haxe user modules, bundler-visible graph, tree-shaking |
| Cross-module linking (phase 1) | **`$global` publish + entry topo side-effect loads** |
| Cross-module linking (phase 2) | **`$h` registry**; still no static imports between user types |
| Cross-module linking (phase 3) | **Static ESM imports** between user modules (genes-style); externs unchanged |
| Semantic target (phase 1 gate) | Haxe semantics as exercised by the JS unit suite; **not** required to match `Genjs` output layout |
| Dev / hot reload | Separate path from `hxmc dev`; own serializer; may reuse compile server + transport ideas |
| Tier 3+ heap restore | ESM-owned serializer; not the dev-loop snapshot format |
| **Compile flags** | **`-D esm`** phase 1 dev; **`-D esm.hot`** phase 2; **`-D esm.prod`** phase 3 static imports (§13.8) |
| **Reference port** | **Reject** `-D esm` / `-D esm.hot` on fixpoint reference build (§13.3) |
| **Hot-ID pipeline (phase 2)** | **Typed AST → hot-ID filter** (stable IDs, code/structure/layout hashes) before Genesm; per-type emit hashes in compile server (§13.4) |
| **`@:esm.hot.cell` lowering** | Compiler lowers metadata → `esm.hot.cell` / scope setup; Genesm emits `$new`/`$ctor` |
| **Policy default** | Unannotated initializer hash change → **reset** unless `@:esm.hot(keep)` (per kind) |
| **Genesm hot** | **Separate hot backend** when `-D esm.hot` (e.g. `GenesmHot`); phase 1 path unchanged |
| **Dev DCE** | **`-dce no`** (or dev equivalent) when **`-D esm.hot`** |
| **Patch delivery** | **WebSocket manifest + patch units** (target protocol) |
| **Closures (phase 2)** | **All** lambdas get IDs; full closure conversion (§6), not optional |
| **Call-site ID key (v1)** | **Structural ordinal** — `enclosingUnitId#n` (§13.11); line+remap **reference only** |
| **`@:esm.hot.keyed` ABI (v1)** | **Magic inject** at call sites when `-D esm.hot` (§13.12); monolithic hot compile assumed |

## 1. Scope and assumptions

**Assumptions (change any of these and parts of the design change):**

- Compiler support: a dedicated ESM generator in hxmc, not a macro or genes-style
  library. Selected with **`--js`** (or `-js`) plus **`-D esm`** on the Js
  platform. Defines `esm` in addition to `js`.
- `#if js` code compiles. `js.*` externs are reused where they do not assume
  CommonJS or Genjs's single-file layout. ESM-only APIs go in **`esm.*`** (stdlib
  classpath when `-D esm`).
- **Phase 1** runtime is browser or bundler ESM (Node ESM is in scope for tests).
  **Phases 1–2** assume dev-oriented emit (`$global` / registry). **Phase 3**
  targets production consumption with static imports.
- **Phase 2+:** "State" for hot reload is everything reachable from Haxe-owned
  roots. DOM state and third-party JS library internals are out of scope.
- **Phase 2 metaprogramming (external):** third-party macros may emit hot-reload
  **units** with explicit IDs; **not built in this repo**. Template/JSX compilation
  stays a **framework** concern. The compiler exposes primitives only (`@:esm.hot.*`,
  closure IDs, `esm.hot` registry hooks).
- **Design rule:** the compiler must not know what a "signal" or "component" is;
  missing framework concepts indicate a gap in the **generic** layer, not a reason
  to branch Genesm on framework types.
- **Hot dev compile (v1):** one **`-D esm.hot`** compilation of the **app closure**
  (main + typed deps in that build). Not a mix of prebuilt `.zip` libs compiled
  without hot and an app compiled with hot (§13.12).
- Sequencing: section 12.

**Goals**

**Phase 1 — dev ESM baseline (now)**

1. Emit **multi-file dev ESM**: per-module `.mjs` files, runtime and **extern**
   `import`/`export`, `import.meta` where needed; **DCE’d entry** side-effect-imports
   the main `modDeps` closure; Haxe types link through **`$global`** (not static
   peer imports).
2. Preserve Haxe **semantics** required by the JS unit suite (Ints, null, arrays,
   reflection behavior as tested—not Genjs's exact object graph).
3. Zero hot-reload overhead when `-D esm.hot` is absent.
4. No impact on stock `--js` or the hxmc target.

**Phase 2 — dev with hot reload (`-D esm.hot` or similar)**

5. Per-definition hot reload of bodies with live instances where the model allows.
6. Old closures run new code after a patch (callable wrappers, registry).
7. Layout / hierarchy / enum changes via migration, with full reload fallback.
8. Transactional patches with rollback.

**Phase 3 — prod idiomatic ESM (later)**

9. Static **`import`/`export` between Haxe user modules** (genes-style linking).
10. Bundler-visible dependency graph and **tree-shaking** without relying on
    `$global` for cross-module types.
11. Prod-suitable module layout (per-module files, optional native `class` emit where
    it helps semantics and tooling).

**Non-goals**

- Changing `Genjs` output for non-ESM builds.
- Preserving in-flight native `Promise` or JS generator frames (phase 2).
- Preserving state inside third-party JS libraries (phase 2).
- Hot reload in prod (phases 2–3 split: hot stays dev-only).
- Upstreaming ESM to OCaml Haxe.

## 2. Why compiler-level support (versus macro-based generators)

A macro-based generator on stock JS gets body swaps with workarounds. Compiler
support in hxmc is justified for **phase 2 hot reload**, **phase 3 prod emit**, and
for running the unit suite on **`$global` dev emit** in phase 1:

| Capability | Macro / genes-style | hxmc ESM generator |
| --- | --- | --- |
| Multi-file ESM (`.mjs`, extern imports) | Awkward | Phase 1 (dev `$global`) |
| Static imports between Haxe user modules | Natural | **Phase 3** (prod) |
| Swap constructor bodies live | Workaround | Phase 2 |
| Change `extends` live | No (reload) | Phase 2 |
| Old closures run new code | No | Phase 2 |
| Heap snapshot incl. closures | No (`Serializer` throws) | Phase 2 (ESM serializer) |
| Transactional patch | Not feasible | Phase 2 |
| Stock typer / filters for Js | Inherited | Inherited (`-D esm` switches generator + classpath) |
| `Genjs` byte identity | N/A | Unchanged without `-D esm` |

**Flag shape (decided):** `--js out/main.mjs` plus **`-D esm`** (phase 1 dev
baseline). **`-D esm.hot`** enables phase 2 (requires `-D esm`). **`-D esm.prod`**
selects phase 3 static-import emit (no hot reload); does not replace `-D esm` on
the dev/hot path (§13.8).

A standalone `--custom-target esm` is **out of scope**: it would fight Js platform
setup and haxelib compatibility without helping phase 1.

## 3. Pipeline

```
Js typer -> typed AST -> hot-ID filter (stable IDs, code/structure/layout hashes)
                              |
         phase 2 only: closure conversion, enum tables,
                       coroutine lowering, layout hashing, field diffing
                              |
     +----------------+----------------+----------------+
     | Phase 1 dev    | Phase 2 dev    | Phase 3 prod   |
     | $global,       | $h registry,   | static imports |
     | multi-file     | cells, patches | tree-shakeable |
     +----------------+----------------+----------------+
```

Generator lives in **hxmc** (`Genesm` or equivalent), invoked from the port's Js
branch when `-D esm` is set. Reuses typer, filters, DCE, and compilation-server
module cache; does not share the hxmc native IR pipeline unless that proves
convenient later.

**Phase 1** does not require cells or `$ctor`. **`$global` linking** is shared
infrastructure toward phase 2’s **`$h` registry** (user types under `-D esm.hot` only).
**Phase 3** is **`Genesm` prod mode** under **`-D esm.prod`**, not a small delta on
hot reload. **`-D esm.hot`** uses a **separate Genesm hot backend** from phase 1 emit.

## 4. Hot reload — generic layer vs framework (phase 2)

**Generic layer (in scope):** hxmc compiler + Genesm under `-D esm.hot`.

**Framework layer (out of scope, reference):** userland libs + macros (e.g.
Solid-like signals, React-like hooks, Elm-like loops) built on generic primitives.

A generic mechanism is enough and is the intended design. The test: a **second**
framework could ship on the same compiler primitives without Genesm gaining
`if (isComponent)` branches.

### 4.1 What the generic layer must provide

1. **Stable identity for every declaration and expression unit.** IDs derive from
   lexical path plus hashes split into **code** vs **structure** so consumers can
   decide which edits matter. Compiler baseline IDs (phase 2):
   - **Type:** qualified Haxe path.
   - **Field:** `type#name` plus a signature hash of its type.
   - **Local function (lambda):** `enclosingFieldId/λ<structural-key>`, plus body
     hash for fuzzy re-match. **`@:esm.hot.was("oldName")`** for explicit renames.
   - **Layout hash:** ordered `(fieldName, typeHash)` for instance fields.
   - **Enum table:** stable `constructorName -> index` for the dev session.
   - **Every closure expression** gets an ID generically (not only named decls).

2. **Implicit call-site identity (key feature).** Library helpers such as
   `createSignal()` must be keyed by the **user's call site**, not a line inside
   the library. Opt-in **`@:esm.hot.keyed`** on the callee injects the caller's
   call-site ID (e.g. implicit `__id`
   argument). Without it, frameworks fall back to call-order keying (hooks-style),
   which breaks when calls are added or reordered. **Decided:** typer + Genesm
   when `-D esm.hot` (§13.9); macro-emitted IDs are external to this repo.

3. **Keyed state cells and scopes (language surface).** User-facing
   **`@:esm.hot.cell`**, **`@:esm.hot.scope`** (and related **`@:esm.hot.*`**)
   metadata is the lang-level API for keyed dev state. Runtime
   counterparts live in **`esm.*`** (e.g. `esm.hot.cell(id, init)`,
   `esm.hot.scope(id, ?key)`). Optional runtime `key` covers dynamic cases (e.g.
   list items in `<For>`) where the static ID alone is not unique. **Genesm emit**
   implements these with **`$new` / `$ctor`** (and related layout) as
   **implementation details**, not the API app authors use.

4. **Swap protocol with extensible kinds.** Each unit registers under a **kind**.
   On edit, runtime dispatches to that kind's handler. **This repo** implements
   builtin kinds **`function`**, **`class`**, **`enum`** and a **pluggable registry**
   for external kinds (e.g. `component` — reference only, §4.2). **Patch tiers 1–4**
   (section 8) classify **severity**; kinds classify **how to apply** when tier
   allows fine-grained swap (§13.10).

5. **Policy syntax.** Annotations such as **`@:esm.hot(keep)`**, **`@:esm.hot(reset)`**,
   **`@:esm.hot(migrate("…"))`** consulted when classifying an edit (per **kind**,
   not hardcoded in Genesm). **Default:** initializer hash change without
   `@:esm.hot(keep)` → **reset** via kind handler.

6. **Dev-only indirection** for function and method calls, with **safe-point**
   swapping (ties to closure conversion, section 6).

**Cost:** call-site ID injection stays **opt-in** (`@:esm.hot.keyed` only); making
every call keyed bloats dev builds.

**Hot metadata catalog (decided):** use only the **`@:esm.hot`** prefix (not
`@:hot`, `@:keyed`). Prefer dotted tails where Haxe allows meta on the symbol:

| Metadata | Typical site | Role |
| --- | --- | --- |
| `@:esm.hot.keyed` | Function/method | Callee opts in; compiler injects caller call-site ID |
| `@:esm.hot.cell` | Field, local binding | Keyed cell; Genesm emits `$new`/`$ctor` underneath |
| `@:esm.hot.scope` | Block / macro-owned region | Scope boundary; optional runtime `key` for lists |
| `@:esm.hot(keep)` etc. | Field, type, unit | Swap policy on hash change |
| `@:esm.hot.was("OldName")` | Field, type | Rename mapping across patches |

Runtime API in **`esm.hot.*`** mirrors names (`esm.hot.cell`, `esm.hot.scope`, …).

### 4.2 What stays in the framework layer (reference only — not hxmc work)

No framework library, JSX macro, or UI kind handler is in scope for this
repository. The rows below describe the **intended full stack** for external
consumers of `esm.hot`.

| Concern | Where it lives |
| --- | --- |
| Signals, memos, owners, `onCleanup` | Framework library, on `esm.hot.cell` / `esm.hot.scope` |
| Template / JSX → binding code | Framework macro, emitting units with IDs via generic ID API |
| "Static structure changed → rebuild subtree" | Framework macro: structure in structure hash; registers a `component` kind handler |
| "Dependency set changed" warnings | Optional framework analysis pass (macro-level) |
| Disposal order, re-tracking on swap | Framework kind handlers |

### 4.3 Where purely generic breaks down

- **Without compile-time metaprogramming**, frameworks cannot emit per-binding
  units; the compiler would need framework special cases. Requirement: macro or
  plugin API to emit hot-reload units, not framework awareness in Genesm.
- **Closure identity:** anonymous `() => …` in templates needs compiler-assigned IDs.
- **Edit classification is policy-dependent:** generic layer reports hash deltas;
  keep vs reinit is framework/kind policy via pluggable classifiers.
- **Compiler smell:** if Genesm needs "this is a component", add a generic primitive.

### 4.4 Recommendation (fixed for this plan)

Ship **generic** IDs, **`@:esm.hot.keyed`**, cells/scopes, **tiers + builtin
kinds**, and policy metadata as **compiler + `esm.*` runtime in hxmc**. External
frameworks (§4.2) are **not** repo work. Do not embed signal/component semantics
in Genesm.

Not required for phase 1 beyond what reflection metadata needs.

## 5. Object model

### Phase 1 — dev ESM baseline

- Multi-module layout: one `.mjs` per Haxe module under `<out>/hx/`, plus
  `__hx_esm_runtime.mjs` and `--js` entry.
- **Linking:** cross-module Haxe types use **`$global.Type`** after publish lines;
  the entry **side-effect-imports** the DCE-kept module closure (topo-sorted).
  Peer Haxe modules do **not** `import` each other. **Externs** use normal ESM
  `import`/`export` (`@:jsRequire`, etc.).
- **Construction:** Genjs-style `function` + prototype (Genesm reuses Genjs).
- Consumption: run the **entry** (or a dev server that preserves load order);
  importing a lone `hx/*.mjs` without the graph is unsupported.
- `Type` / `Reflect` / metadata: compatible enough for the JS unit suite;
  internal layout may differ from `Genjs` if tests allow.
- **Must match stock Haxe JS semantics** where tests assert: Int rules, null,
  array holes, string indexing, `@:native`, `@:expose`, coroutine lowering
  behavior (stage to confirm in hxmc's Js pipeline).

### Phase 2 — dev with hot reload

- Lang-level keyed state: **`@:esm.hot.cell`**, scopes, **`@:esm.hot(...)` policy**
  (section 4). **Genesm** emits **`$new` / `$ctor`** (and friends) as implementation
  of those cells/ctors.
- **`$h` registry** linking, re-parenting, ctor-pinned types for native ES parents.
- Instances without hot-reload bookkeeping properties unless reflection tests
  require otherwise in dev mode.
- Sections 6–8 apply to phase 2 only.

### Phase 3 — prod idiomatic ESM

- **Linking:** **`import { Type } from './relative.mjs'`** (or namespace imports)
  between Haxe modules; **`$global` not used** for ordinary cross-module type
  refs (reflection/runtime hooks may still use a shared runtime module).
- **Construction:** prefer idiomatic emit (`class` or `function` + prototype) where
  it satisfies the unit suite and bundler tooling.
- **Consumption:** modules are **importable independently** subject to their
  explicit dependency graph; entry is optional for apps.
- Tree-shaking and static analysis follow the **ESM import graph**, not a global
  publish table.

## 6. Closure conversion and dev call indirection (phase 2)

Each lambda is lifted to `impl(env, ...args)` with a **stable closure ID** (section
4.1). Creation sites use callable wrappers late-bound through a function registry
(`$id`, `$env` as a named record, boxes for mutated captures,
`Reflect.compareMethods` parity, stale wrappers when captures change).

**Dev-only indirection (section 4.1.6):** function and method calls go through
dispatch points where the runtime can swap implementations at **safe points**
(event-loop boundaries; aligns with phase 2 assumptions in section 1).

## 7. Linking and patch delivery

**Phase 1 (dev baseline):** **no static imports between user types**; **`$global`**
on `globalThis` as the type registry and publish lines after each definition.

**Phase 2 (dev hot):** no ESM imports between user types; **`$h` / registry**
(`$h.Foo`) supersedes `$global` for patchable user types—avoids cycles, TDZ, and
import-map cache issues. Externs stay normal ESM imports.

- **Patch units**, **transactional apply + rollback**; compile-server **per-type
  emit hashes**; **`-dce no`** when `-D esm.hot`.
- **ESM dev tool** (not `hxmc dev`): Node script or Vite plugin; **WebSocket
  manifest + patch units** (target protocol). May **reuse** file watching and error-overlay patterns from
  `packages/cli/hxmc/bootstrap/dev.mjs` but not the wasm/native reload protocol.
- **Static initialisers (dev):** init-if-absent; order matches Haxe.

**Phase 3 (prod):** static ESM imports between user modules; patch/hot reload
**not** supported (full reload only).

## 8. Heap, migration, rollback (phase 2)

**Patch tiers 1–4** set **severity**; **kind** handlers run when the tier permits
(§13.10). **Precedence (decided):**

| Tier | Trigger (summary) | Kind / path |
| --- | --- | --- |
| **1** | Body / code hash only | **`function`** (and other unit kinds) swap impl; instances kept |
| **2** | Layout, `extends`, enum table, hierarchy on a type | **`class`**, **`enum`** builtin migration for **that type**; tier-1 swaps on **unaffected** units |
| **3** | Heap-wide or serializer-required change | **ESM serializer** path; fine-grained kinds **bypassed** for affected heap |
| **4** | Transaction failure | **Rollback** to pre-patch snapshot; then tier-3 restore rules |

- **Tier ≥ 2 for type T:** tier path for **T** dominates; do not apply tier-1
  `function` swap to **T** as a substitute for layout/hierarchy fixes.
- **Tier ≥ 3:** session may supersede all fine-grained kinds for affected objects.

**Serializer (required in design):** ESM-specific (closures as `$id` + env, cycles,
enums by name); optional `sessionStorage` on full reload. Implementation may trail
tier-1 milestone; **not** optional in the target design. **Do not** adopt
`haxe.Serializer` dev snapshot encoding from [dev.md](../dev.md).

## 9. Std lib and JS-compatibility surface

- **Reuse:** `js.*` externs that are platform-neutral; audit `@:jsRequire` /
  CommonJS-oriented externs for ESM consumers (document gaps).
- **Add `esm.*`:** `import`/`export` helpers, `import.meta`, dynamic `import`,
  top-level await; phase 2 **`esm.hot`** runtime (cells, scopes, kind registry,
  policy hooks). Language metadata **`@:esm.hot.*`** is the author surface; Genesm
  emit (`$new`, `$ctor`, indirection thunks) is internal.
- **Classpath:** ESM overrides only when `-D esm` is set (same pattern as
  `bin/hxmc/std` for the native target—last `-cp` wins).
- **Phase 2:** hot-aware `Type` / `Reflect`; tracked-effect wrappers in `esm.*`.
- **Phase 3:** std shadows only if prod static-import layout needs them.
- **Coroutines:** same lowering stage as Js in hxmc; **target** under `-D esm.hot`
  is **resumable frames**; until implemented, treat in-flight frames as **hard
  limit** (§14), not silent partial support.

## 10. Semantic compatibility and testing

**Phase 1 (`-D esm`, no hot):** semantic parity with **Haxe on JS** as defined by
the JS unit suite—not byte or structural parity with `Genjs`. Early exclusions
for tests that assert Genjs-specific layout, single-file names, or stack shape are
expected; keep a shrinking allow-list.

**Phase 2 (`-D esm.hot`):** additional deviations (stacks, enum indices after patch,
stale closures, static init policy)—documented in section 11.

**Phase 3 (prod):** re-run the JS unit suite (and bundler integration tests) on
static-import emit; define exclusions vs phase 1 dev layout where observables differ.

**Test strategy (hxmc)**

1. **Stock `--js`:** unchanged; `make test LANES=targets`, fixpoint.
2. **Phase 1 dev ESM:** run JS unit suite with `-D esm`; track exclusions;
   `make esm-unit` / `hxmc/test/esm/exclusions.txt`.
3. **Fuzzer:** eventual `diff:js-esm` lane; not compared to reference.
4. **Phase 2:** differential hot-patch tests, closure tests, server hash cache
   tests; not in phase 1 gate.
5. **Phase 3:** unit suite + bundler smoke on static-import prod backend.

Flag matrix: derive from `haxe/test/Targets.hx` and CI js jobs (ES version,
`js-unflatten`, libraries).

## 11. Dev/prod divergence register

| Topic | Phase 1 dev | Phase 2 dev hot | Phase 3 prod |
| --- | --- | --- | --- |
| Cross-module types | `$global` | `$h` registry | static `import` |
| Hot reload | no | yes | no |
| Closure identity | native | registry wrappers | native |
| DCE | normal | relaxed in dev | normal |

Document observable diffs vs `Genjs` for each phase that ships (reflection fields,
module graph, `compareMethods` if any).

## 12. Workstreams

### Phase 1 — dev ESM baseline (now)

**Landed (2025-11):** `-D esm` with `--js <entry.mjs>` on the npm/`HaxeMain`
compiler: `generators.EsmHook` dispatch in `Generate.hx`, `hxmc.genesm.Genesm`
(multi-file under `<out>/hx/`, runtime `__hx_esm_runtime.mjs`, entry at
`--js`), `hxmc/EsmInstall`, optional `-cp hxmc/std/esm`, smoke test
`hxmc/test/esm/hello.hxml`. Genesm emits per-module ESM (runtime import,
`export { … }`, **`$global` publish** for types); cross-module refs use
**`$global`**, not peer `import { Type }`. Entry side-effect-imports only the
**main module's `modDeps` closure** (DCE-kept graph), topo-sorted. Exclusions:
`hxmc/test/esm/exclusions.txt` + `exclusions.md`.

**Harness:** `make esm-unit` (`EsmSuites.hx`); baseline **1620 pass / 0 excluded**.
On Darwin, skip wasm/crosshost quick lanes when verifying locally.

**Open (hygiene):** CI gate for `make esm-unit`, consumption docs for dev entry
graph, `esm.*` std shadows as tests require.

1. **Dev backend (`$global`).** **Done** for phase 1 milestone: `Genesm`, unit
   suite gate. Remaining: coroutines-on-Js verification (section 13).
2. **Std and classpath.** Audit `js.*`; add `esm.*`; override std only as tests
   require.
3. **Tooling and docs.** hxml examples, dev server prerequisites, exclusion
   governance in CI.

**Phase 2 design gate:** §13.11–§13.12 **decided**; implement per [esm-impl.md](esm-impl.md).

### Phase 2 — dev with hot reload (later)

4. Generic hot core (compiler only): hot-ID filter, `@:esm.hot.cell` lowering,
   `@:esm.hot.*` / **`@:esm.hot.keyed`** (§13.11–12), **`GenesmHot`**, builtin kinds
   + tier table (§8), `esm.hot` runtime, **`$h` registry`, WebSocket patch units,
   dev server.
5. Change detection and tier-1 patching (compile-server hash cache).
6. Closure conversion and semantic tests.
7. Heap tracking, migration, enum tables, re-parenting (tier 2).
8. ESM serializer, transactional apply (tiers 3–4).
9. Tracked-effect wrappers; coroutine resumable frames (research).
10. Dual-flavor CI and hot-patch harness.

### Phase 3 — prod idiomatic ESM (later)

11. Prod backend: static imports between user modules (`ensureImport` or new linker).
12. Cycle strategy (**decided**): genes-style deferred super/statics + explicit
    static imports (§13.8).
13. Bundler/tree-shake integration tests; npm consumption docs.
14. **Decided:** **`-D esm.prod`** for phase 3; **`-D esm` + `-D esm.hot`** unchanged
    for dev/hot (§13.8).

## 13. Open items to verify

1. Exact JS test matrix in hxmc (`haxe/test/Targets.hx`, upstream-tests js job):
   ongoing monitoring via `esm-unit` / exclusions (currently 1620 / 0).
2. Output layout convention (phase 1): **`--js` = entry `.mjs`**, `hx/<module>.mjs`
   tree, `__hx_esm_runtime.mjs` beside entry (**decided** for dev baseline).
3. Reference port: **reject** `-D esm` / `-D esm.hot` — **decided** (§13.3).
4. Compile-server **per-type emit hashes** in dev — **decided**; wire to patch
   manifest (§0).
5. Coroutine lowering stage on Js in the current port.
6. `@:coreApi` and classpath override rules for ESM std shadows.
7. Ecosystem: `haxe-react`, tink, hxnodejs under `-D js` + `-D esm`; CommonJS
   extern audit.
8. **Phase 3 flag** — **decided:** **`-D esm.prod`** (§13.8).
9. **Call-site injection** — **decided** (§13.9); ID key **decided** (§13.11).
10. **Kinds vs patch tiers** — **decided** (§13.10); tier table (§8).
11. **Keyed callee ABI** — **decided** (§13.12).

### 13.9 Call-site injection — **decided** (hxmc: compiler half only)

**Product model (full stack):** hybrid **C** — compiler **A** + external macros for
template units and structure hashes (§4.2, not this repo).

**Implemented in hxmc:**

- Typer/filter when **`-D esm.hot`:** callee marked **`@:esm.hot.keyed`** → inject
  caller **call-site ID** (e.g. implicit `__id`) at every call site.
- Genesm emits the extra argument; gated off prod / non-hot builds.
- **Closure expression IDs** for all lambdas (not only named decls).

**External (reference):** macros call `esm.hot.cell(id, …)` with a chosen `id`;
register framework kinds. Not scheduled in hxmc.

**ID collision rule (decided):** for a keyed call, **compiler call-site ID wins**.
For `esm.hot.cell(id, init)` with an explicit string `id`, **that string is
canonical** (typical macro expansion path).

*Example (in-repo):* `mylib.Signal.create(0)` in `App.setup` with callee
`@:esm.hot.keyed` → `create(0, __hotId)` with `__hotId = "Main.setup#2"` (§13.11).

*Example (external):* JSX macro expands to `esm.hot.cell("App.hx:12:btn", …)`;
no compiler `__id` on that path unless the expansion also calls a `@:esm.hot.keyed`
function.

**Rejected for hxmc-only scope:** **B** (macro-only injection) — insufficient
lang-level support.

### 13.10 Kinds vs patch tiers — **decided** (hxmc: tiers + builtin kinds)

**Protocol (decided):** **A** — **tiers 1–4** = patch **severity**; **kinds** =
**dispatch** when the tier allows unit-level swap.

**Precedence (decided):** see tier table (§8). Tier **1** → kinds; tier **≥ 2** on
type **T** → migration/serializer rules for **T**; tier **≥ 3** may supersede
session-wide fine-grained kinds.

**Kinds shipped in hxmc (builtin):** at minimum **`function`**, **`class`**, **`enum`**
— handlers owned by **`esm.hot`** / Genesm coordination, not framework types.

**Kinds external (reference):** e.g. **`component`**, **`computation`** — register
via pluggable API on `esm.hot`; no Genesm branches on framework types.

*Example:* Tier **1**, `Foo.bar` body hash changed → **`function`** kind swaps
implementation.

*Example:* Tier **3**, `Foo` instance layout changed → tier path runs; **`function`**
kind does not pretend to fix layout.

*Example (external):* framework registers **`component`**; hxmc does not implement
that handler — only the registry hook.

**Rejected:** **B** (kinds-only) — loses shared severity ladder for §8.

### 13.3 Reference port and `-D esm` — **decided**

Fixpoint / `UpstreamTargets` use the **reference** compiler. **Reject** (error, not
ignore) **`-D esm`**, **`-D esm.hot`**, and **`-D esm.prod`** there so ESM semantics
stay hxmc-only and conformance stays unambiguous.

*Example:* CI `make fixpoint` with stock port must not accept `-D esm` on the same
hxml as reference `--js` tests.

### 13.8 Phase 3 compile flag — **decided**

| Flag | Emit |
| --- | --- |
| `-D esm` | Phase 1 dev (`$global`, multi-file) |
| `-D esm` + `-D esm.hot` | Phase 2 hot (`$h`, `GenesmHot`, cells) |
| `-D esm` + `-D esm.prod` | Phase 3 prod static imports (no hot) |

Do **not** switch phase 1/2 linking when `-D esm.prod` is absent. Hot reload never
uses prod static-import graph.

*Example:* `lix`-published game lib built with `-D esm.prod` for npm consumers;
local app uses `-D esm -D esm.hot` with `$h` and patch server.

### 13.11 Call-site ID primary key — **decided (v1): structural ordinal**

**Primary key:** `enclosingUnitId + "#" + ordinal`, where **ordinal** is the
**n-th** call to a **`@:esm.hot.keyed`** callee within that enclosing callable unit
(pre-order in the unit body; exact walk **TBC in spec**, but stable across compiles
with the same structure).

**Diagnostics:** record `pos` (file/line/col) in the hot-ID manifest and patch
payload; **not** part of the primary key.

**Ordinal shift (insert/reorder keyed calls in the same unit):** IDs change; **old
cells orphan and are disposed**; **new ordinals init from scratch** (default
**reset**). Same discipline as hook order — no attaching old `#1` state to a
different call that became `#1`. **`@:esm.hot(keep)`** applies when the **same id
string** survives a patch (body edit), not when ordinals shift. Explicit
`esm.hot.cell("fixed", …)` ids (external macros) do not shift with ordinals.

*Example:* `Main.setup` has two `create(0)` calls → `Main.setup#1`, `Main.setup#2`.
Insert a third `create` at the top → new `…#1` is **fresh init**; old `…#1`/`…#2`
cells **disposed** unless a future manifest **remap** pairs sites (v1: **no**
ordinal remap).

*Example:* Insert comments only above calls; ordinals unchanged → same ids, body
hash patch can swap impl with **keep** where policy allows.

#### Reference only: line / position + remap

Not v1. Would use `module:line:col` as key plus **session manifest** pairing sites
across compiles (structural matcher often required anyway). Compiler always knows
**new** `pos`; **old→new** mapping is dev-server + matcher work, not a single
compile. See prior discussion in plan history; revisit if tooling demands line-native
IDs.

### 13.12 `@:esm.hot.keyed` callee ABI — **decided (v1): magic inject**

When **`-D esm.hot`**: callee has **`@:esm.hot.keyed`** and **unchanged** source
signature; typer/gen injects **`__hotId`** (name TBC) at **call sites only**. Callee
JS emit accepts the extra argument in the hot backend only.

**Assumption (v1):** **one hot compilation** of the program under test — app,
`haxe_libraries` / classpath sources, and keyed callees are **typed and emitted in
the same** `-D esm.hot` build (typical Haxe app: single `-main`, one compile graph).
Haxe already types the whole reachable program together; magic inject fits that.

**Not supported in v1:** app compiled with **`-D esm.hot`** calling **`@:esm.hot.keyed`**
APIs from a dependency **precompiled without hot** (different arity/emit). Revisit
**visible optional `?__hotId`** (reference below) for distributable keyed libs.

*Example (v1):* `MyApp.hxml` has `-D esm -D esm.hot`; `import my.ui.Signal` from
source on `-cp` → `create(0)` → `create(0, "Main.setup#1")` at emit time.

*Example (out of scope v1):* `mylib` built to `.zip` without `esm.hot`; app adds
`-D esm.hot` only → **unsupported**.

#### Reference only: visible optional param

`create(v:Int, ?__hotId:String)` on keyed APIs for **separate** lib vs app compile
graphs. Not v1.

## 14. Remaining hard limits (phase 2)

- DOM state outside Haxe's control.
- State inside foreign JS libraries.
- In-flight native `Promise` and generator frames (until resumable coroutine work lands).
- Closures whose captured-variable sets changed (stale until replaced).
- **Keyed lib ABI:** prebuilt libraries compiled without `-D esm.hot` used from a
  hot app (until visible-param or dual-build ABI lands).
- **Ordinal insert/reorder** in a hot unit: keyed state reset for affected sites
  (§13.11).