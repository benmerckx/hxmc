# ESM hot exclusions (phase 2)

Machine-readable skips for **upstream `tests/unit` with `-D esm` and `-D esm.hot`**
when that suite is wired (not part of `make esm-unit`, which stays **`-D esm` only**).

**`hxmc/test/esm/hot/exclusions.txt`** — same format as
[`hxmc/test/esm/exclusions.txt`](../exclusions.txt): one class or `class.method` per
line, optional reason after the first space. Comment lines start with `#`.

Phase 1 exclusions cover Genjs layout / single-file assumptions on plain `-D esm`.
Phase 2 adds deviations documented in [plans/esm.md](../../../docs/plans/esm.md) §10–11:

| Bucket | Rationale |
| --- | --- |
| stack shape | Hot indirection and registry wrappers change names/depth vs stock `Genjs` |
| enum indices after patch | Hot enum tables can differ from a cold compile |
| stale closures | Capture-set changes force reload or reset (§14) |
| static init under patch | `@:esm.hot.*` policy (`keep` / `reset` / `migrate`) |

**Known (not in gate yet):** loading the full dev entry graph can hit hot-closure
emit bugs in upstream std (e.g. `Type#getEnumConstructs`); differential harnesses use
narrow node runners like tier-1's `run.mjs` until a hot unit lane exists.

**Current gate:** differential harnesses `make esm-hot-m0` … `make esm-hot-m5` and
aggregate `make esm-hot` ([testing.md](../../../docs/testing.md#esm-phase-2-hot-reload)).
`EsmHotDualCheck` (`esm-hot-m5`) is the dual-flavor compile smoke; the list here stays
empty until a hot upstream unit lane is added.