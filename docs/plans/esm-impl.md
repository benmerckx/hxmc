# Implementation plan: ESM hot reload (hxmc)

**Design:** [esm.md](esm.md) (phases, §13.9–13.12, tiers, generic vs framework).

**Scope:** **compiler + `esm.hot` runtime + Genesm hot backend** in hxmc only. UI
frameworks / JSX macros are **not** repo work (§4.2).

**User choices (for this plan):**

- **M0:** in-process tier-1 proof; **M1:** add WebSocket patch manifest.
- **Phase 1 hygiene** (CI `esm-unit`, reference rejects `-D esm`) **in parallel**
  with early hot work.

---

## Principles

1. **`-D esm.hot` gates all hot behavior** — zero cost when absent (§1).
2. **Minimal `haxe/src` touch** — porting rules ([porting.md](../porting.md)); prefer
   `// port:` hooks and hxmc-owned modules (`hxmc/src`, `hxmc/std/esm`) where
   possible.
3. **Monolithic hot compile (v1)** — magic `@:esm.hot.keyed` inject (§13.12).
4. **Structural ordinal** call-site IDs (§13.11); line+remap reference only.
5. Each milestone has **tests** before the next milestone expands scope.

---

## Parallel track — phase 1 hygiene (non-blocking)

| Item | Deliverable | Verify |
| --- | --- | --- |
| CI | `make esm-unit` in a CI lane | Green on linux-x64 (or documented matrix) |
| Reference | Reject `-D esm` / `-D esm.hot` / `-D esm.prod` on reference port | `UpstreamTargets` / fixpoint unchanged |
| Docs | One paragraph consumption (`entry.mjs`, no lone `hx/*.mjs`) | Link from [esm.md](esm.md) §12 |

---

## Milestone map

```
M0  hot skeleton + tier-1 in-process
M1  WebSocket manifest + compile-server unit hashes
M2  closures + @:esm.hot.cell lowering + GenesmHot emit
M3  tier-2 class/enum kinds + layout migration (no serializer yet)
M4  tiers 3–4 serializer + transactional apply
M5  hot CI harness + dual-flavor gates
──  phase 3 prod (`-D esm.prod`) — separate plan chunk after M2+ stable
```

---

## M0 — Tier-1 hot skeleton (in-process)

**Goal:** One module, one function body change, **live swap** via **`function` kind**,
no dev server.

### M0.1 Defines and install

- Register **`esm.hot`** in `hxmc/Defines.hx` (already stubbed); document
  implies **`esm`**.
- `EsmInstall`: when `esm.hot`, append `hxmc/std/esm` and set **`GenesmHot.generate`**
  (or branch inside `Genesm` behind `// port:` if smaller).
- Reference port: error on `-D esm*` (hygiene track).

### M0.2 Hot metadata (parse + doc)

- Teach compiler **`@:esm.hot.*`** meta (prefix rules §4):
  - `keyed`, `cell`, `scope`, `was`, `keep` / `reset` / `migrate(...)`.
- **No lowering yet** except what M0.3–0.5 need.

### M0.3 Hot-ID filter (typed AST)

New module under **`hxmc/src`** (preferred) or minimal **`haxe/src/filters/`**
hook with `// port:`:

- Assign **unit IDs** (type, field, lambda) per §4.1.
- Assign **call-site IDs** `enclosingUnitId#ordinal` for calls to
  `@:esm.hot.keyed` callees (define ordinal walk: depth-first in function body,
  count per callee name or all keyed calls — **pick one in M0.3 and freeze in
  spec comment**).
- Emit **code hash** per swappable body; store on compile context for Genesm.

**Output:** in-memory map `unitId → { codeHash, kind, … }` consumed by Genesm.

### M0.4 `@:esm.hot.keyed` — typer + emit

- When **`-D esm.hot`:** calls to `@:esm.hot.keyed` functions get synthetic
  **`__hotId:String`** argument (magic inject §13.12).
- Callee signature in source unchanged; typed/API view may show extra arg only
  under hot.
- **GenesmHot** emits `__hotId` at call sites; callee reads it (first pipeline:
  optional last param in **emit** only).

### M0.5 `esm.hot` runtime (minimal)

Under **`hxmc/std/esm/hot/`** (classpath via `-D esm`):

- **`$h` registry** object (module `esm.hot.Registry` or similar).
- **`function` kind** handler: register impl by id; **swap** on patch.
- **Tier classifier (tier 1 only):** body hash change → tier 1 → swap.
- **`esm.hot.applyPatch(manifest)`** — in-process API for M0 test (no WebSocket).

### M0.6 GenesmHot v0

- Copy/adapt Genesm phase-1 layout: **`$h`** instead of `$global` for user types;
  still side-effect entry for dev.
- **Dev call indirection** for patched functions only (minimal): one hop through
  registry for tier-1 fields/methods marked swappable (start with **static function**
  bodies, then instance methods).
- **`-dce no`** when `esm.hot`.

### M0.7 Test harness

- **`hxmc/test/esm/hot/`** — tiny two-version fixture (body v1 → v2).
- **`EsmHotTier1Check.hx`** (or similar): compile v1, run, compile v2 to patch
  buffer, `esm.hot.applyPatch`, assert output changes without full reload.
- Gate: `make esm-hot-m0` (new Makefile target) — **not** fixpoint.

**M0 exit criteria:** tier-1 body change swaps behavior in Node; `make esm-unit`
still green (no `-D esm.hot` in unit suite).

---

## M1 — Patch transport + incremental hashes

**Goal:** Same as M0 but patch arrives via **WebSocket manifest**; compile server
**per-type emit hashes** drive what to rebuild.

### M1.1 Compile-server integration

- Per **hot unit** emit hash on `GenesmHot` output (stable unit id).
- On rebuild, diff manifest: `{ changed: [unitId…], tiers: { unitId: 1|… } }`.

### M1.2 Dev transport

- Minimal **Node** script (under `packages/cli/hxmc/bootstrap/` or
  `hxmc/test/esm/hot/`): WebSocket push manifest + patch `.mjs` chunks.
- Reuse **watch** patterns from `dev.mjs` only as file watcher; **not** hxmc dev
  protocol.

### M1.3 Tests

- Harness: watch file change → second compile → WS client applies patch → assert.

**M1 exit criteria:** edit file on disk triggers patch apply without manual
`applyPatch` call.

---

## M2 — Cells, scopes, closures

**Goal:** Lang-level state and lambdas match §4–§6.

### M2.1 `@:esm.hot.cell` / `@:esm.hot.scope` lowering

- Compiler lowers to **`esm.hot.cell(id, init)`** / scope API.
- **Genesm** emits `$new`/`$ctor` under the hood.

### M2.2 Closure conversion

- All lambdas: stable **closure id** + lifted `impl` + registry wrappers (§6).
- Stale closure policy when capture set changes (§14).

### M2.3 `@:esm.hot.keyed` + cells integration test

- Keyed call + cell in same module; body patch + ordinal stability case (§13.11).

**M2 exit criteria:** closure survives tier-1 impl swap; cell keeps state on
body-only edit; ordinal insert test shows reset (documented expected behavior).

---

## M3 — Tier 2 + builtin `class` / `enum` kinds

**Goal:** §8 tier 2 path without serializer.

- Layout hash, `extends` change detection → tier **2**.
- **`class`** kind: re-parent / migration hooks (subset: field add optional first).
- **`enum`** kind: constructor table stability dev session (§4).
- **`@:esm.hot` policy** metadata honored per kind.

**Tests:** tier-2 scenarios with forced migration or full reload fallback where
not yet implemented.

---

## M4 — Tiers 3–4 heap

**Goal:** §8 serializer + transactional apply.

- ESM-specific serializer (closures `$id` + env, cycles, enums by name).
- Transaction apply + rollback (tier 4).
- `sessionStorage` optional full reload.

**Tests:** differential hot-patch + rollback harness (§12 workstream 10).

---

## M5 — CI and governance

- `make esm-hot-*` lanes in [testing.md](../testing.md).
- `-D esm` + `-D esm.hot` dual compile smoke.
- Exclusions file for hot-only deviations (stacks, etc.).

**M5 exit criteria:** `make esm-hot-m5` and `make esm-hot` green; [testing.md](../testing.md)
documents lanes; `hxmc/test/esm/hot/exclusions.txt` in place; phase 2 complete.

---

## Phase 3 prod (`-D esm.prod`) — after M2+ (outline)

Separate implementation chunk in Genesm (or `GenesmProd`):

- Static imports (`ensureImport` or new linker), cycle strategy (§12.11–12).
- **`esm-unit`** + bundler smoke; no hot overlap.

Track in [esm.md](esm.md) §12; detail when M2 exits.

---

## File / module sketch (hxmc)

| Area | Likely paths |
| --- | --- |
| Hot-ID filter | `hxmc/src/hxmc/esm/HotIds.hx` (or `filters/EsmHot*.hx` in `haxe/src`) |
| Genesm hot | `hxmc/src/hxmc/genesm/GenesmHot.hx` |
| Runtime | `hxmc/std/esm/hot/*.hx` |
| Install / defines | `hxmc/EsmInstall.hx`, `hxmc/Defines.hx` |
| Tests | `hxmc/test/esm/hot/`, `EsmHotTier1Check.hx` |
| Dev WS | `packages/cli/hxmc/bootstrap/esm-dev.mjs` (name TBC) |

---

## Open spec details (freeze in M0.3)

| Topic | Decide when implementing M0.3 |
| --- | --- |
| Ordinal walk | All `@:esm.hot.keyed` calls in unit vs per-callee-name counter |
| `__hotId` param name | `__hotId` vs `$__hotId` in emit |
| `enclosingUnitId` format | e.g. `pack.Type#field` for methods, `pack.Type#λn` for lambdas |

---

## Dependencies on [esm.md](esm.md) §13 still soft

- **§13.5** coroutines on Js — document before hot coroutine research.
- **§13.6** `@:coreApi` + ESM std shadows — when `esm.hot` touches std.
- **§13.7** ecosystem — phase 3 / optional.

---

## Not in this plan

- Framework `component` / `computation` kinds (registry **hook** only in M2+).
- Line+remap call-site IDs (reference).
- Visible `?__hotId` ABI for prebuilt libs (reference).
- Merging with **`hxmc dev`** snapshot protocol ([dev-loop.md](dev-loop.md)).