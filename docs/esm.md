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

## Hot reload under `-D esm.hot` (default dev behavior)

With **`-D esm.hot`** (injected by **`haxe --dev`** on ESM Js builds — see
[dev.md](dev.md)), ordinary application code needs **no** hot metadata for
**body replacement**. Users write normal methods; the compiler registers hot
units and emits the `$h` registry ([`GenesmHot`](hxmc/src/hxmc/genesm/GenesmHot.hx)).

### What the compiler does automatically

| Mechanism | Rule |
| --- | --- |
| **Swappable methods** | Every method, `static function`, and constructor with a body becomes a tier-1 **`function`** unit (`pack.Type#fieldName`), unless opted out. Static `var` / property initializers are not swappable units. |
| **Class / enum units** | Non-extern types get tier-2 **`class`** / **`enum`** units from layout (field names + coarse types, enum constructors). |
| **Keyed callees** | When a method contains **`@:esm.hot.cell`** (or lowered cell markers) **and** another method on the **same type** calls it, the compiler treats it as **keyed**: call sites receive a synthetic id; emit adds a compiler-only `__hotId` parameter (never shown in user source). |
| **Call-site ids** | `enclosingUnitId#ordinal` — depth-first ordinal of keyed calls inside the **caller** unit (all keyed calls share one counter per caller). |
| **Body change detection** | `codeHash` / `emitHash` from structural hashes of the lowered body (not a user-visible type signature key). |

**Opt out:** `@:esm.hot(false)` on a type or field (for drivers, stable
entrypoints, or code that must not go through `$h.invoke`).

**Typical app:** edit any method body → patch swaps that **`function`** unit.
**Locals** inside a method are **not** preserved across body swap unless you use
**cells** (below). **Instance and static fields** follow tier-2 class policy when
layout changes.

### When users add metadata (power user / state)

| Metadata | Role |
| --- | --- |
| `@:esm.hot(false)` | Opt out of implicit swappable-body hot units on the annotated type or field |
| `@:esm.hot.cell` | Preserve a local or field across patches (`$h.cell`); id `unit#cell.name` or call-site–scoped when the callee is keyed |
| `@:esm.hot.scope` | Scope boundary for nested keyed state |
| `@:esm.hot(keep)` / `reset` / `migrate("…")` | Policy when structure hashes change |
| `@:esm.hot.was("OldName")` | Rename mapping across patches |

Explicit **`esm.hot.cell("fixedId", …)`** (when implemented in stdlib macros)
pins a cell id when call ordinals would be fragile.

**Keyed-call caveat:** inserting or reordering keyed calls in a caller shifts
ordinals and **resets** affected cells unless a **fixed string id** is used.

**Monolithic hot compile:** the app and its Haxe user types should be built
with **`-D esm.hot`** together (no prebuilt non-hot lib called from a hot app).

**Dev API** (`esm.hot.Hot` on `hxmc/std/esm`): `applyPatch`, `esmSerialize` /
`esmUnserialize`, `trackInstance`. Patches use tiers **1–4** and builtin kinds
**`function`**, **`class`**, **`enum`**. Framework kinds stay external — see
[plans/esm.md](plans/esm.md).

## Patches and dev workflow

With **`-D esm.hot`**, Genesm emits **`__hx_hot_patch.mjs`** holding changed
units and metadata. Apply in-process:

```js
import { applyHotPatch } from "./__hx_esm_runtime.mjs";
import * as patch from "./__hx_hot_patch.mjs";
applyHotPatch(patch.manifest);  // or patchModule.applyHotPatchFromDev()
```

For the supported dev loop, use **`npx haxe --dev … -js <entry.mjs> -D esm`**
(same **`--dev`** entry as hxmc native targets). `dev.mjs` routes to
**`dev-esm.mjs`**: resident compilation server, watch, injects **`-D esm.hot`**
and **`-dce no`**, runs the entry under Node (or **`--dev-browser`** for a
static page), and pushes `__hx_hot_patch.mjs` over WebSocket `/__esm_hot/ws`.
The emitted `__hx_esm_dev_client.mjs` connects when
**`HXMC_ESM_DEV`** is set (Node) or from the browser shell. The **`watch-patch`**
lane in **`make esm`** exercises the packaged **`dev.mjs`** router (driver
injects **`-D esm.hot`**).

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