# ESM — open design

Future and unfinished ESM work. **Implemented** behavior (flags, layout,
linking, hot metadata, tests, dev workflow) is in [esm.md](../esm.md).

Stock `--js` without **`-D esm`** must stay byte-identical to the reference
port for fixpoint and `UpstreamTargets`. ESM lives in the **npm hxmc
compiler** only; do not bend the hxmc native target or [dev loop](dev-loop.md)
to serve ESM unless explicitly merging later.

## User-facing modes (target)

Long-term, users choose **dev vs release** from the command line, not from
extra define names:

| Command | Emit | Hot reload |
| --- | --- | --- |
| **`haxe --dev`** … **`-js`** … **`-D esm`** | dev layout (`GenesmHot`, `$h`, patch artifacts) | yes — `dev.mjs` runs the app and pushes patches |
| **`haxe`** … **`-js`** … **`-D esm`** | production idiomatic ESM (static `import` / `export` between user modules) | no |

**`--dev`** on an ESM Js build turns hot reload on. The **dev driver**
(`dev-esm.mjs`) and, if useful, the **compiler** inject **`esm.hot`** (and
**`-dce no`** where the hot backend requires it) — users do not pass
**`-D esm.hot`** in hxml for normal work.

**`-D esm.hot`** on the command line remains a **dev artifact for now**
(`make esm`, harnesses, migration). It stays the internal switch for
`GenesmHot` until the dev loop and prod emit split is finished; then
document it as advanced/testing-only and prefer **`haxe --dev`** +
**`-D esm`**.

**`-D esm.prod`** is **not** part of the long-term UX. Production output is
**`-D esm`** alone. The define may linger in the compiler during transition
(GenesmProd backend); it must **not** be required for npm or bundler
consumption.

Technical plan for the unified **`haxe --dev`** entry and resident server:
[esm-dev.md](esm-dev.md).

## Boundaries (unchanged)

| | |
| --- | --- |
| **Reuse** | Js platform, typer, filters, `#if js`, compilation server |
| **Branch out** | `Genesm` / `GenesmHot` / prod Genesm, `hxmc/std/esm`, ESM patch protocol, closure-aware heap serializer |
| **Framework layer (out of repo)** | signals, JSX, `component` / `computation` kind handlers built on generic primitives |

Generic rule: Genesm must not branch on framework types. External frameworks
register **pluggable kinds** on `esm.hot`; this repo ships **`function`**,
**`class`**, **`enum`** only.

## Production ESM (`-D esm`, release builds)

**Not implemented as the default backend yet.** Today **`-D esm`** without
**`-D esm.hot`** still uses the dev **`Genesm`** layout (`$global` publish
table). The planned **release** backend (formerly sketched as **`esm.prod`** /
`GenesmProd`):

| Topic | Decision |
| --- | --- |
| User flag | **`-D esm`** only (with `--js`); no **`-D esm.prod`** |
| Linking | Static `import` / `export` between Haxe user modules (genes-style); no `$global` / `$h` for ordinary cross-module types |
| Cycles | Deferred super/statics + explicit static imports (genes-style) |
| Consumption | Modules importable on their explicit graph; entry optional; bundler tree-shaking |
| Tests | Re-run `make esm` on prod emit + bundler smoke; separate exclusions from dev/hot layout |

*Example:* a library published to npm is built with **`haxe -D esm -js …`**;
the same project uses **`haxe --dev -D esm -js …`** locally for hot reload.

## Hygiene and CI (open)

| Item | Status |
| --- | --- |
| **`make esm` in CI** | Local gate exists; not yet a required CI job |
| **Fuzzer** | `diff:js-esm` lane — eventual, not compared to reference |
| **Hot upstream unit lane** | `hxmc/test/esm/hot/exclusions.txt` ready; suite not wired |
| **Consumption docs in CI matrix** | Covered by [esm.md](../esm.md) |
| **User-facing hot dev entry** | Test harness + manual **`-D esm.hot`**; target: **`haxe --dev -D esm`** — [esm-dev.md](esm-dev.md) |

Reference port: **reject** **`-D esm`**, **`esm.hot`**, **`esm.prod`** (implemented in `Generate.hx`). Internal hot metadata and `@:esm.hot.*` remain hxmc-only.

## Dev loop gap (hot)

Hot emit, patch manifests, and in-process `applyHotPatch` are implemented and
gated in `make esm` (via **`-D esm.hot`** today). The **npm dev loop** is not.

| | **`haxe --dev`** (target) | **ESM hot today** |
| --- | --- | --- |
| Entry | `npx haxe --dev build.hxml` | No supported entry; copy test scripts |
| Discriminator | **`-js`** + **`-D esm`** (driver injects hot) | **`-js`** + manual **`-D esm.hot`** |
| vs hxmc | **`--custom-target hxmc=<out>`** → `dev-hxmc.mjs` | (same **`--dev`**, different branch) |
| Long-lived driver | `dev.mjs` router → `dev-esm.mjs` | `hxmc/test/esm/hot/esm-dev.mjs` (test-only) |
| After a good build | Start Node or browser; patch in process | Often **no** runner; two-process harness |
| Patch delivery | WebSocket **`/__esm_hot/ws`** | Same (tests); not hxmc snapshot protocol |
| Compilation server | resident **`--server-connect`** (planned) | one-shot spawns |

See [esm-dev.md](esm-dev.md) for the branch in `dev.mjs`, shared
orchestration, and reload backends (patch vs hxmc snapshot).

## Spec gaps to close

1. **Coroutines on Js** — confirm lowering stage in the port; under hot dev
   target **resumable frames**; until then, in-flight generator/Promise
   frames are a **hard limit** (not silent partial support).
2. **`@:coreApi` and ESM std shadows** — override rules when `esm.hot` touches std.
3. **Ecosystem** — `haxe-react`, tink, hxnodejs under **`-D js` + `-D esm`**; audit CommonJS-oriented `@:jsRequire` externs.
4. **Policy `migrate("…")`** — tier-2 class/enum handlers: full migration vs full-reload fallback still evolving in harnesses.
5. **Call-site ordinal walk** — freeze the exact pre-order in a spec comment (all keyed calls in unit vs per-callee counter); diagnostics use `pos`, not primary key.
6. **Visible `?__hotId` ABI** — reference only for prebuilt keyed libs compiled without hot (v1: monolithic hot compile).
7. **Line / position + session remap** for call-site ids — reference only, not v1.

### Decisions (stable for future work)

**Tiers vs kinds:** tiers 1–4 = patch **severity**; **kinds** = **dispatch** when the tier allows unit-level swap. Tier ≥ 2 on type **T** dominates tier-1 swaps on **T**. Tier ≥ 3 may bypass fine-grained kinds for affected heap.

**ID collision:** keyed call → compiler call-site id wins; explicit `esm.hot.cell("…", …)` string id is canonical.

**Dev serializer:** ESM-owned (closures as `$id` + env); **not** `haxe.Serializer` / [dev.md](../dev.md) snapshot encoding.

## Framework layer (reference only)

| Concern | Where |
| --- | --- |
| Signals, memos, `onCleanup` | External lib on `esm.hot.cell` / `scope` |
| Template / JSX → hot units | External macro + pluggable kind registry |
| Structure hash → subtree rebuild | Framework `component` kind |
| Disposal order on swap | Framework kind handlers |

## Hard limits (phase 2 hot)

- DOM and foreign JS library state outside Haxe roots.
- In-flight native `Promise` / generator frames until resumable coroutine work lands.
- Closures whose capture sets changed (stale wrappers until replaced).
- Prebuilt libraries compiled **without** hot metadata used from a hot app.
- Ordinal insert/reorder in a unit: keyed state reset for affected sites.

## Optional later

- **`docs/esm.md` quick start** — rewrite examples around **`haxe --dev`** and
  **`-D esm`**; drop user-facing **`-D esm.hot`** / **`-D esm.prod`**.
- Upstreaming ESM to OCaml Haxe — **out of scope** for hxmc.