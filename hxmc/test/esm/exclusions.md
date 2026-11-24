# ESM JS unit suite exclusions (phase 1)

Gate: **`make esm-unit`** or:

```sh
bin/hxmc/hxmc -cp hxmc/test -cp haxe/test --run EsmGenesmCheck
bin/hxmc/hxmc -cp hxmc/test -cp haxe/test --run EsmSuites --haxe bin/haxe-js
```

`EsmGenesmCheck` covers Genesm-only layout (no `.mjs` for pure std externs,
shared `$hx_exports`); `EsmSuites` runs the upstream JS unit suite on `-D esm`.

Builds upstream `tests/unit` with `hxmc/test/upstream/unit-esm.hxml` (`-D esm`,
`--js bin/unit/main.mjs`), runs under node. Machine-readable exclusions:
**`hxmc/test/esm/exclusions.txt`** (one class or `class.method` per line).

Harness runs end-to-end; **1620 passed / 0 failed / 0 skipped** with an empty
exclusions list (was 1576 / 44 excluded, then 1619 / 1 skipped).

Cross-module types (e.g. `haxe.Exception` / `haxe.ValueException`) reference each
other via **`$global`** publish lines, not per-module ESM imports, so mutual
dependencies do not form import cycles.

| Bucket | Rationale |
| --- | --- |
| *(none)* | — |

Smoke:

```sh
bin/haxe-js hxmc/test/esm/hello.hxml
node hxmc/test/esm/out/main.mjs
```