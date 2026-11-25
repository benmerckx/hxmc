# ESM — open design

Future and unfinished ESM work. **Implemented** behavior (flags, layout,
linking, hot metadata, tests, dev workflow) is in [esm.md](../esm.md).

Stock `--js` without **`-D esm`** must stay byte-identical to the reference
port for fixpoint and `UpstreamTargets`. ESM lives in the **npm hxmc
compiler** only; do not bend the hxmc native target or [dev loop](dev-loop.md)
to serve ESM unless explicitly merging later.

## Boundaries (unchanged)

| | |
| --- | --- |
| **Reuse** | Js platform, typer, filters, `#if js`, compilation server |
| **Branch out** | `Genesm` / `GenesmHot`, `hxmc/std/esm`, ESM patch protocol, closure-aware heap serializer |
| **Framework layer (out of repo)** | signals, JSX, `component` / `computation` kind handlers built on generic primitives |

Generic rule: Genesm must not branch on framework types. External frameworks
register **pluggable kinds** on `esm.hot`; this repo ships **`function`**, **`class`**, **`enum`** only.

## Phase 3 — prod ESM (`-D esm.prod`)

**Define exists; emit is not implemented.** Planned backend (`GenesmProd` or prod mode):

| Topic | Decision |
| --- | --- |
| Flag | **`-D esm.prod`** with **`-D esm`**, never with **`-D esm.hot`** |
| Linking | Static `import` / `export` between Haxe user modules (genes-style); no `$global` / `$h` for ordinary cross-module types |
| Cycles | Deferred super/statics + explicit static imports (genes-style) |
| Consumption | Modules importable on their explicit graph; entry optional; bundler tree-shaking |
| Tests | Re-run `make esm` on prod emit + bundler smoke; separate exclusions from dev layout |

*Example:* a `lix`-published library built with **`-D esm.prod`** for npm
consumers; a local app keeps **`-D esm -D esm.hot`** for dev.

## Hygiene and CI (open)

| Item | Status |
| --- | --- |
| **`make esm` in CI** | Local gate exists; not yet a required CI job |
| **Fuzzer** | `diff:js-esm` lane — eventual, not compared to reference |
| **Hot upstream unit lane** | `hxmc/test/esm/hot/exclusions.txt` ready; suite not wired |
| **Consumption docs in CI matrix** | Covered by [esm.md](../esm.md) |
| **User-facing hot dev entry** | Test harness only; see [Dev loop gap (hot)](#dev-loop-gap-hot) |

Reference port: **reject** **`-D esm`**, **`-D esm.hot`**, **`-D esm.prod`** (implemented in `Generate.hx`).

## Dev loop gap (hot)

**`-D esm.hot`** emit, patch manifests, and in-process `applyHotPatch` are
implemented and gated in `make esm`. The **developer loop** around them is
not: there is no npm-facing equivalent of **`haxe --dev`** ([dev.md](../dev.md))
for Js ESM hot reload.

| | **`haxe --dev`** (`packages/cli/hxmc/bootstrap/dev.mjs`) | **ESM hot today** |
| --- | --- | --- |
| Entry | `npx haxe --dev build.hxml` | No supported entry; copy test scripts |
| Output | `--custom-target hxmc=<out>` | `-js <entry.mjs>` + **`-D esm.hot`** |
| Long-lived driver | `dev.mjs` (watch, compilation server, run/reload) | `hxmc/test/esm/hot/esm-dev.mjs` (test-only) |
| After a good build | Starts or reloads the program | **Does not** start Node or a browser |
| Patch delivery | Snapshot / swap (hxmc protocol) | WebSocket `hot-patch` to a **already running** client |
| Shipped in `@hxmc/cli` | yes (`dev.mjs`) | **no** (`esm-dev.mjs` lives under `hxmc/test/`) |

**`esm-dev.mjs` is test-oriented.** It watches `--watch` dirs, spawns a
**one-shot** compiler on each `.hx` change (no `--server-connect` yet),
then pushes `__hx_hot_patch.mjs` metadata on `/__esm_hot/ws`. The
`watch-patch` lane (`EsmHotWatchPatchCheck`) runs **`esm-dev.mjs` and a
separate `run-ws-client.mjs`** that loads the build and applies the patch —
two processes, not one user command.

**Gaps to close for a user-facing entry** (target: same ergonomics as
`haxe --dev`, discriminated by **`-js … -D esm.hot`** vs **`--custom-target
hxmc=…`**, not by folding patch reload into the hxmc snapshot protocol):

1. **Promote the driver** — ship a script beside `dev.mjs` (or branch inside
   it) from `@hxmc/cli`; document `npx haxe --dev` (or a dedicated flag) for
   ESM hot builds.
2. **Infer paths from the build** — `esm-dev.mjs` requires explicit `--out`
   even though Genesm writes next to the `-js` entry; derive output dir and
   watch roots from expanded hxml (`-js`, `-cp`, `-lib`), as `dev.mjs` does
   for `hxmc=` and class paths.
3. **Run + patch in one loop** — start `node <entry.mjs>` (or browser +
   dev client) once; on successful rebuild, push patch to the running app
   (wire `__hx_esm_dev_client.mjs` / env), not only broadcast with “no
   clients”.
4. **Reuse the compilation server** — watch → `server/invalidate` →
   incremental rebuild, matching hxmc dev latency instead of cold spawns.
5. **Package classpath** — ensure **`hxmc/std/esm`** (or `esm-std` next to
   `hxmc-std`) is on the npm install path when hot metadata needs std types.

Optional longer-term: **merge orchestration** with `dev.mjs` while keeping
**two reload backends** (snapshot vs patch); see [esm.md](../esm.md) versus
hxmc dev and [dev-loop.md](dev-loop.md) principles.

## Spec gaps to close

1. **Coroutines on Js** — confirm lowering stage in the port; under **`-D esm.hot`**
   target **resumable frames**; until then, in-flight generator/Promise frames are a **hard limit** (not silent partial support).
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
- Prebuilt libraries compiled **without** **`-D esm.hot`** used from a hot app.
- Ordinal insert/reorder in a unit: keyed state reset for affected sites.

## Optional later

- Unified **`haxe --dev`** orchestration (shared watch/server; separate reload
  paths) — after the [user-facing hot dev entry](#dev-loop-gap-hot) exists on
  its own.
- Upstreaming ESM to OCaml Haxe — **out of scope** for hxmc.