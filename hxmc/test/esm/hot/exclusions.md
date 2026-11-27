# ESM hot exclusions (phase 2)

Machine-readable skips for **upstream `tests/unit` with `-D esm` and `-D esm.hot`**
when that suite is wired (not part of **`make esm`** lane `unit`, which stays **`-D esm` only**).

**`hxmc/test/esm/hot/exclusions.txt`** — same format as
[`hxmc/test/esm/exclusions.txt`](../exclusions.txt): one class or `class.method` per
line, optional reason after the first space. Comment lines start with `#`.

Phase 1 exclusions cover Genjs layout / single-file assumptions on plain `-D esm`.
Phase 2 deviations: [esm.md](../../../../docs/esm.md) (hot metadata, tiers); hard
limits in [plans/esm.md](../../../../docs/plans/esm.md#hard-limits-phase-2-hot):

| Bucket | Rationale |
| --- | --- |
| stack shape | Hot indirection and registry wrappers change names/depth vs stock `Genjs` |
| enum indices after patch | Hot enum tables can differ from a cold compile |
| stale closures | Capture-set changes force reload or reset; see [hard limits (phase 2 hot)](../../../../docs/plans/esm.md#hard-limits-phase-2-hot) |
| static init under patch | `@:esm.hot.*` policy (`keep` / `reset` / `migrate`) |

**Known (not in gate yet):** loading the full dev entry graph can hit hot-closure
emit bugs in upstream std (e.g. `Type#getEnumConstructs`); differential harnesses use
narrow node runners like the body-swap `run.mjs` until a hot unit lane exists.

**Current gate:** **`make esm`** (hot lanes in [testing.md](../../../../docs/testing.md#esm-tests)).
`EsmHotDualCheck` (lane `hot-dual`) is the dual-flavor compile smoke; the list here stays
empty until a hot upstream unit lane is added.