# ESM JS unit suite exclusions (phase 1)

Gate: **`make esm-unit`** or:

```sh
bin/hxmc/hxmc -cp hxmc/test -cp haxe/test --run EsmSuites --haxe bin/haxe-js
```

Builds upstream `tests/unit` with `hxmc/test/upstream/unit-esm.hxml` (`-D esm`,
`--js bin/unit/main.mjs`), runs under node. Machine-readable exclusions:
**`hxmc/test/esm/exclusions.txt`** (one class or `class.method` per line).

Populated from **runtime** utest failures on Genesm (2026-11-24). Harness runs end-to-end;
**1587 passed / 33 failed / 0 skipped** with exclusions disabled (was 1576 / 44).

| Bucket | Rationale |
| --- | --- |
| `unit.issues.*` (18 tests) | Issue regression tests: macros, display, evaluator, layout |
| `unit.TestSerialize.*`, `unit.TestIO.*`, `unit.TestBasetypes.*` | Serialization, bytes, string/map identity vs Genjs |
| `unit.teststd.*` (6 tests) | Std parity (Array, Map, macro, runtime copy, IntMap, etc.) |
| `unit.TestMatch.testBasic`, `unit.TestExceptions.testValueException` | Enum / exception wiring |
| `unit.TestMatch.testBasic`, `unit.TestExceptions.testValueException` | Enum / exception wiring |

Smoke:

```sh
bin/haxe-js hxmc/test/esm/hello.hxml
node hxmc/test/esm/out/main.mjs
```