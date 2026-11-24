# ESM JS unit suite exclusions (phase 1)

Gate: **`make esm-unit`** or:

```sh
bin/hxmc/hxmc -cp hxmc/test -cp haxe/test --run EsmSuites --haxe bin/haxe-js
```

Builds upstream `tests/unit` with `hxmc/test/upstream/unit-esm.hxml` (`-D esm`,
`--js bin/unit/main.mjs`), runs under node. Machine-readable exclusions:
**`hxmc/test/esm/exclusions.txt`** (one class or `class.method` per line).

Populated from **runtime** utest failures on Genesm (2026-11-24). Harness runs end-to-end;
**1619 passed / 1 failed / 0 skipped** with exclusions disabled (was 1587 / 33, 1576 / 44).

| Bucket | Rationale |
| --- | --- |
| `unit.TestExceptions.testValueException` | Exception/ValueException circular ESM import |

Smoke:

```sh
bin/haxe-js hxmc/test/esm/hello.hxml
node hxmc/test/esm/out/main.mjs
```