# ESM output and hot reload on JavaScript

How the hxmc npm compiler emits multi-file ECMAScript modules from `--js`,
and how **`-D esm.hot`** patches live programs in Node. For library authors
targeting bundlers or Node, and for anyone building on the hot-reload
primitives. Open design and unimplemented work:
[plans/esm.md](plans/esm.md).

This is **not** upstream Haxe. Stock `--js` without **`-D esm`** stays
byte-identical to the reference port for fixpoint and `UpstreamTargets`. ESM
is a **separate dev workflow** from [hxmc dev](dev.md) (native/Wasm snapshot
reload).

## Quick start

**Dev modules** (`-D esm`, multi-file layout, no hot):

```sh
bin/hxmc/hxmc -main Main -D esm -js out/main.mjs   # hxml or flags
node out/main.mjs
```

**Hot reload** (`-D esm` and `-D esm.hot`):

```sh
bin/hxmc/hxmc -main Main -D esm -D esm.hot -dce no -js out/main.mjs
node out/main.mjs
```

Smoke sample: `hxmc/test/esm/hello.hxml` after `make hxmc`.

| Define | Generator | Linking | Hot reload |
| --- | --- | --- | --- |
| `-D esm` | `Genesm` | `$global` on `globalThis` | no |
| `-D esm` + `-D esm.hot` | `GenesmHot` | `$h` registry | yes (dev) |
| `-D esm.prod` | *(not implemented)* | static `import` between user modules | no |

**`-D esm`** sets **`js`** as well. Use the usual Js platform (`-js` /
`--js <entry.mjs>`). **`esm.hot`** implies **`esm`**; **`esm.prod`** must not
be combined with **`esm.hot`**. The reference compiler **rejects** all
**`esm*`** defines.

## Output layout

`--js` names the **entry** `.mjs`. Genesm writes sibling artifacts next to it:

| Path | Role |
| --- | --- |
| `<entry>.mjs` | DCE-kept module graph loaded by side-effect `import`s (topo-sorted) |
| `hx/<module path>.mjs` | one file per Haxe module (packed groups) |
| `__hx_esm_runtime.mjs` | shared runtime (`$global` / `$h`, hot helpers when enabled) |
| `__hx_includes.mjs` | only when the build lists `--include` files |
| `__hx_hot_patch.mjs` | hot only: patch units + manifest hook |
| `__hx_esm_dev_client.mjs` | hot only: applies patches from the dev transport |

Pure std extern modules may emit **no** `.mjs` under `hx/` (types link via the
runtime). In **`-D esm`** and **`-D esm.hot`** dev layouts, cross-module Haxe
types do **not** use `import { Type }` between user modules (see linking below).

**Consumption rule:** run or bundle from the **entry** `.mjs` (or a dev server
that preserves the same load order). Importing a lone `hx/*.mjs` without the
entry graph is unsupported.

## Linking

**Externs** (`@:jsRequire`, npm packages): normal ESM `import` / `export`.

**User Haxe types** in dev link through a publish table, not peer imports:

- **`-D esm`:** after each definition, emit publishes onto **`$global`**
  (`globalThis`). The entry side-effect-imports every module in the main
  module's `modDeps` closure.
- **`-D esm.hot`:** user types publish on **`$h`** instead (`Genesm.reg()`).
  Runtime helpers on `$global` stay on the runtime module even in hot mode.

**`-D esm.prod`** (not implemented): static `import`/`export` between Haxe user
modules for bundler-visible graphs — see [plans/esm.md](plans/esm.md).

## Hot metadata and runtime

Compiler surface uses the **`@:esm.hot.*`** prefix only. Haxe types in
`hxmc/std/esm` mirror the runtime (`esm.hot.*`).

| Metadata | Typical site | Role |
| --- | --- | --- |
| `@:esm.hot.keyed` | Function / method | Compiler injects caller call-site id at each call (magic `__hotId`) |
| `@:esm.hot.cell` | Field, local | Keyed cell; lowered to `esm.hot.Cell` / `$new` / `$ctor` in emit |
| `@:esm.hot.scope` | Block | Scope boundary for nested keyed state |
| `@:esm.hot.function` | Method | Swappable body via the function kind |
| `@:esm.hot(keep)` / `reset` / `migrate("…")` | Field, type, unit | Policy when hashes change |
| `@:esm.hot.was("OldName")` | Field, type | Rename mapping across patches |

**Call-site ids (v1):** `enclosingUnitId#ordinal` — the *n*-th call to a
`@:esm.hot.keyed` callee inside that unit (structural ordinal). Inserting or
reordering keyed calls shifts ordinals and **resets** those cells unless an
explicit string id was used (e.g. macro `esm.hot.cell("fixed", …)`).

**Keyed callees:** source signature unchanged; under **`-D esm.hot`** the
typer adds an extra argument at call sites only. **v1** expects one
**`-D esm.hot`** compile of the whole app graph (not a hot app calling a
prebuilt lib compiled without hot).

**Dev API** (`esm.hot.Hot` in the std classpath): `applyPatch`,
`esmSerialize` / `esmUnserialize`, `trackInstance` (runtime heap snapshot API,
not `haxe.Serializer` / `haxe.Unserializer`). Patches classify by **severity
(tiers 1–4)** and dispatch through builtin **kinds** (`function`, `class`,
`enum`). See [plans/esm.md](plans/esm.md) for framework kinds and heap migration
rules still being hardened.

## Patches and dev workflow

With **`-D esm.hot`**, Genesm emits **`__hx_hot_patch.mjs`** holding changed
units and metadata. Apply in-process:

```js
import { applyHotPatch } from "./__hx_esm_runtime.mjs";
import * as patch from "./__hx_hot_patch.mjs";
applyHotPatch(patch.manifest);  // or patchModule.applyHotPatchFromDev()
```

For watch → rebuild → push, use **`hxmc/test/esm/hot/esm-dev.mjs`**: file
watcher, recompile, WebSocket manifest + patch path (same transport ideas as
`hxmc dev`, **not** its snapshot protocol).

Hot builds use **`-dce no`**. The compilation server can attach **per-unit
emit hashes** to drive incremental patch manifests (harnessed in
`make esm ESM_ARGS=watch-patch` or the full `make esm` gate).

## Classpath and port touch

**`-D esm`** switches `Generate.hx` to `EsmInstall` / `Genesm` (minimal
`// port:` hook in `haxe/src`). **`hxmc/std/esm`** is appended when present
(same last-`-cp`-wins pattern as `hxmc/std` on the native target).

Add **`esm.*`** std shadows only when tests or hot behavior require them; most
`js.*` externs work unchanged if they do not assume Genjs's single-file layout.

## Tests

| Make target | What |
| --- | --- |
| `esm` | `Esm.hx`: Genesm layout, upstream unit (**`-D esm`**), hot-reload harnesses; `ESM_ARGS` narrows lanes |

Details: [testing.md](testing.md#esm-tests). Hot harnesses are **outside**
fixpoint and reference `LANES=targets`. A future upstream unit lane with
**`-D esm.hot`** would use `hxmc/test/esm/hot/exclusions.txt`.

**Upstream unit (`make esm`, lane `unit`):** **1620** tests pass with an empty
exclusion list today (semantic parity with Haxe-on-JS, not Genjs layout).

## Versus hxmc dev

| | ESM hot (`-D esm.hot`) | hxmc dev (`hxmc dev`) |
| --- | --- | --- |
| Target | Js / Node (npm compiler) | hxmc native, Wasm, shared libs |
| Reload unit | Patch manifest + `.mjs` chunks | Full program or swap library |
| State | ESM heap serializer + cells | `haxe.Serializer` snapshot / protocol in [dev.md](dev.md) |
| Transport | WebSocket patch (test dev script) | TCP / WebSocket `reload` messages |
| Merge | optional later | independent today |