# ESM output and hot reload on JavaScript

How the hxmc npm compiler emits multi-file ECMAScript modules from `--js`,
and how **`-D esm.hot`** patches live programs in Node. For library authors
targeting bundlers or Node, and for anyone building on the hot-reload
primitives. Open design and unimplemented work:
[plans/esm.md](plans/esm.md).

This is **not** upstream Haxe. Stock **`--js`** without **`-D esm`** uses the
usual single-bundle backend (**`Genjs`**) and must stay byte-identical to the
reference OCaml compiler on the **fixpoint** (hxmc rebuilds itself to match the
reference) and **`UpstreamTargets`** (multi-target parity suite in
[testing.md](testing.md)). **`-D esm`** switches to multi-file emit
(**`GenesmProd`** for release, **`GenesmHot`** with **`-D esm.hot`**) instead of
single-bundle **`Genjs`**.

ESM hot reload is a **separate dev workflow** from [hxmc dev](dev.md) (native /
Wasm snapshot reload over TCP or WebSocket).

## Quick start

**Release / bundler** (`-D esm`, no hot — static `import` / `export` between user modules):

```sh
bin/hxmc/hxmc -main Main -D esm -js out/main.mjs   # hxml or flags
node out/main.mjs
```

**Hot reload** (`-D esm` and **`-D esm.hot`**, or **`haxe --dev`** with **`-D esm`**):

```sh
bin/hxmc/hxmc -main Main -D esm -D esm.hot -dce no -js out/main.mjs
node out/main.mjs
```

Smoke sample: `hxmc/test/esm/hello.hxml` after `make hxmc`.

| Define | Generator | Linking | Hot reload |
| --- | --- | --- | --- |
| `-D esm` | `GenesmProd` | static `import` / `export` between user modules | no |
| `-D esm` + `-D esm.hot` | `GenesmHot` | `$h` registry (dev publish table) | yes (dev) |

**`GenesmProd`** / **`GenesmHot`** are the multi-file JavaScript backends for
**`-D esm`** (release vs hot dev). They replace single-bundle **`Genjs`**. Hot
dev registry **`$h`** is defined under [Linking](#linking).

**`-D esm`** sets **`js`** as well. Use the usual Js platform (`-js` /
`--js <entry.mjs>`). **`esm.hot`** implies **`esm`**. Do **not** pass
**`-D esm.prod`** in application hxml — production output is **`-D esm`** alone
(the compiler may still recognize `esm.prod` only for internal transition). The
reference compiler **rejects** all **`esm*`** defines.

## Output layout

`--js` names the **entry** `.mjs`. Genesm writes sibling artifacts next to it:

| Path | Role |
| --- | --- |
| `<entry>.mjs` | Modules kept after dead-code elimination (DCE), imported for side effects in dependency order |
| `hx/<module path>.mjs` | One emitted file per Haxe module (small modules may be merged into one file) |
| `__hx_esm_runtime.mjs` | shared runtime (prod: minimal init; hot: `$h` and patch helpers) |
| `__hx_includes.mjs` | only when the build lists `--include` files |
| `__hx_hot_patch.mjs` | hot only: patch units + manifest hook |
| `__hx_esm_dev_client.mjs` | hot only: applies patches from the dev transport |

Pure std extern modules may emit **no** `.mjs` under `hx/` (types link via the
runtime). **Release** **`-D esm`** (`GenesmProd`) uses normal ESM
`import` / `export` between user modules. **Hot** **`-D esm.hot`** keeps the
**`$h`** publish table instead of sibling `import` for user types (see linking).

**Consumption rule:** run or bundle from the **entry** `.mjs` (or a dev server
that preserves the same load order). Importing a lone `hx/*.mjs` without the
entry graph is unsupported.

## Linking

**Externs** (`@:jsRequire`, npm packages): normal ESM `import` / `export`.

**User Haxe types** in **release** builds link with static ESM imports:

- **`-D esm`** (no hot): **`GenesmProd`** emits `import { MyType } from "./…"` /
  `export { … }` between sibling `hx/*.mjs` files and named imports on the
  entry `.mjs` — a bundler-visible graph with no `$global` publish table for
  ordinary cross-module types.

**Hot dev** **`GenesmHot`** uses the **publish table** instead of sibling
`import` for swappable user types:

- **`-D esm.hot`:** types and swappable bodies live on **`$h`**
  (`Genesm.reg()`).

Further prod design notes: [plans/esm.md](plans/esm.md).

### Publish table (hot dev linking)

| Symbol | Meaning |
| --- | --- |
| **`$h`** | Hot-reload registry where **`GenesmHot`** publishes class constructors, enum tables, swappable bodies, and patch helpers |
| **Publish table** | Hot-only pattern: modules write user types onto `$h` instead of `import { MyType }` from sibling files |
| **`modDeps`** | Transitive Haxe **module** dependencies of the compilation's main module — the entry `.mjs` side-effect-imports this closure |

Runtime helpers (exceptions, reflection, hot runtime) live in
**`__hx_esm_runtime.mjs`** (hot mode still bridges std through **`$h`** where
needed).

## Hot reload under `-D esm.hot` (default dev behavior)

With **`-D esm.hot`** (injected by **`haxe --dev`** on ESM Js builds — see
[dev.md](dev.md)), ordinary application code needs **no** hot metadata for
**body replacement**. Users write normal methods; the compiler registers hot
units and emits the `$h` registry ([`GenesmHot`](hxmc/src/hxmc/genesm/GenesmHot.hx)).

### Patch tiers and hot units

A **hot unit** is the smallest piece the compiler can swap on its own. Each
unit has a **kind** — `function`, `class`, or `enum` — that selects the swap
handler. When a unit changes, the manifest records a **patch tier**: how
invasive that change is for live objects.

| Tier | Also called | Typical trigger | What the runtime does |
| --- | --- | --- | --- |
| **1** | Body swap | Method, constructor, or `static function` body edits only | Replace the function in `$h`; instances and locals stay unless you use **cells** (named `$h` slots that survive body swaps) |
| **2** | Append-only layout | Class fields or enum constructors change but class layout only **grows** at the end | Migrate instances / enum tables; static `var` bodies may refresh |
| **3** | Breaking layout | Class fields removed, reordered, or otherwise not append-only | Snapshot heap, run layout migration, or request **full reload** if unsafe |
| **4** | Rolled back | Patch application failed while a snapshot was active | Restore pre-patch heap; user keeps running the old code |

For one type **T**, tier **2+** on **T** wins over tier-**1** body swaps on **T**
in the same manifest. Frameworks may register extra **kinds** on `esm.hot`; this
repo ships **`function`**, **`class`**, and **`enum`** only ([plans/esm.md](plans/esm.md)).

### What the compiler does automatically

| Mechanism | Rule |
| --- | --- |
| **Swappable methods** | Every method, `static function`, and constructor with a body becomes a **`function`** hot unit (tier **1**, id `pack.Type#fieldName`), unless opted out. Static `var` / property initializers are not swappable units. |
| **Class / enum units** | Non-extern types get **`class`** / **`enum`** hot units (tier **2** or **3** when layout changes) from layout metadata (field names + coarse types, enum constructors). |
| **Keyed callees** | A **keyed** callee is a method that holds **`@:esm.hot.cell`** state **and** is called from another method on the **same type**. Callers pass a synthetic **`__hotId`** (compiler-only, not in your source) so each call site keeps distinct cell storage. |
| **Call-site ids** | `enclosingUnitId#ordinal` — depth-first ordinal of keyed calls inside the **caller** unit (all keyed calls share one counter per caller). |
| **Body change detection** | `codeHash` / `emitHash` from structural hashes of the lowered body (not a user-visible type signature key). |
| **Closure units** | Lexical id `unit/λN` is the patch/manifest key. Each `registerClosure` at runtime also allocates a unique instance id (`lexId#<seq>`); `makeClosure` uses that instance id so repeated invocations of the same hot function do not overwrite live closures. |

**Opt out:** `@:esm.hot(false)` on a type or field (for drivers, stable
entrypoints, or code that must not go through `$h.invoke`).

**Typical app:** edit any method body → tier-**1** patch swaps that **`function`**
unit. **Locals** inside a method are **not** preserved across a body swap unless
you use **cells** (below). **Instance and static fields** use tier-**2** / **3**
class migration when layout metadata changes.

### When users add metadata (power user / state)

| Metadata | Role |
| --- | --- |
| `@:esm.hot(false)` | Opt out of implicit swappable-body hot units on the annotated type or field |
| `@:esm.hot.cell` | Preserve a local or field across patches (`$h.cell`); id `unit#cell.name`, or `(hotId ?? unit)#cell.name` when the callee is keyed (`hotId` is the synthetic call-site id, not stored alone) |
| `@:esm.hot.cell("fixedId")` | Same as above but the string id is **canonical** (wins over call-site ids; safe when keyed call ordinals shift) |
| `@:esm.hot.scope` | Scope boundary for nested keyed state |
| `@:esm.hot(keep)` / `reset` / `migrate("…")` | Policy when structure hashes change |
| `@:esm.hot.was("OldName")` | Rename mapping across patches |

Use **`@:esm.hot.cell("fixedId")`** (compiler metadata) or **`esm.hot.cell("fixedId", …)`** (stdlib macro when present) when call ordinals would be fragile.

**Keyed-call caveat:** inserting or reordering keyed calls in a caller shifts
ordinals and **resets** affected cells unless a **fixed string id** is used.

**Monolithic hot compile:** the app and its Haxe user types should be built
with **`-D esm.hot`** together (no prebuilt non-hot lib called from a hot app).

**Dev API** (`esm.hot.Hot` on `hxmc/std/esm`): `applyPatch`, `esmSerialize` /
`esmUnserialize`, `trackInstance`. Manifest entries carry the **patch tier** and
**kind** described above; framework-specific kinds stay out of tree — see
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

**`-D esm`** switches `Generate.hx` to `EsmInstall` / **`GenesmProd`** or
**`GenesmHot`** (minimal `// port:` hook in `haxe/src`). **`hxmc/std/esm`** is
appended when present
(same last-`-cp`-wins pattern as `hxmc/std` on the native target).

Add **`esm.*`** std shadows only when tests or hot behavior require them; most
`js.*` externs work unchanged if they do not assume **`Genjs`**'s single-file
bundle layout.

## Tests

| Make target | What |
| --- | --- |
| `esm` | `Esm.hx`: Genesm layout (lane `genesm`: prod static imports + **esbuild** bundler smoke), upstream unit (**`-D esm`**), hot-reload harnesses; `ESM_ARGS` narrows lanes |

Details: [testing.md](testing.md#esm-tests). Hot harnesses are **outside** the
**fixpoint** gate and the reference **`LANES=targets`** job. A future **upstream
unit** lane with **`-D esm.hot`** would use `hxmc/test/esm/hot/exclusions.txt`.

**Upstream unit (`make esm`, lane `unit`):** runs upstream Haxe's `tests/unit`
suite through **`-D esm`**; **1620** tests pass with an empty exclusion list
today (same semantics as Haxe-on-JS, different file layout than **`Genjs`**).

## Versus hxmc dev

| | ESM hot (`-D esm.hot`) | hxmc dev (`hxmc dev`) |
| --- | --- | --- |
| Target | Js / Node (npm compiler) | hxmc native, Wasm, shared libs |
| Reload unit | Patch manifest + `.mjs` chunks | Full program or swap library |
| State | ESM heap serializer + cells | `haxe.Serializer` snapshot / protocol in [dev.md](dev.md) |
| Transport | WebSocket patch (test dev script) | TCP / WebSocket `reload` messages |
| Merge | optional later | independent today |