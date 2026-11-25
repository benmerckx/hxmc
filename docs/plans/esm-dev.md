# ESM dev loop — technical plan

How **`npx haxe --dev`** should serve **`-js -D esm`** hot reload alongside
the existing hxmc dev path, without merging ESM patches into the hxmc
snapshot protocol. Open product flags: [esm.md](esm.md). Built behavior
today: [esm.md](../esm.md), [dev.md](../dev.md).

## Goals

1. **One user entry:** `npx haxe --dev <build.hxml | args>` (same as hxmc).
2. **Branch on build shape**, not on a manual **`-D esm.hot`**:
   - **`-js`** + **`-D esm`** → ESM hot dev (`dev-esm.mjs`).
   - **`--custom-target hxmc=…`** → existing hxmc dev (`dev-hxmc.mjs`).
3. **Resident compilation server** for ESM (parity with hxmc dev latency).
4. **Run + patch in one session** (Node and browser).
5. **Long-term defines:** users pass **`-D esm`** only; **`--dev`** (driver
   and/or compiler) enables hot emit by setting **`esm.hot`** internally.
   Release builds: **`haxe -js … -D esm`** → prod idiomatic ESM — no
   **`-D esm.prod`**.

Non-goals:

- Unifying hxmc snapshot reload and ESM patch application in one runtime
  protocol.
- Requiring **`-D esm.hot`** or **`-D esm.prod`** in application hxml.
- **Changing the current hxmc dev loop** (`dev-hxmc.mjs` / today’s `dev.mjs`
  behavior). ESM work must not alter hxmc-specific reload semantics: native
  whole-program restart or **DevHost** shared-library swap on Linux/macOS/
  Windows; **WebAssembly** dev in the browser (single page, wasm swap,
  `hxmc.os` **browser.mjs**, GPU/canvas handoff); snapshot encoding via
  **`haxe.Serializer`** and the **`HXMC_DEV`** JSON-line protocol; **`-D
  hxmc.dev`** / **`-D hxmc.dev-host`** builds. Refactors may **extract** shared
  watch/server helpers into **`dev-shared.mjs`**, but **`dev-hxmc.mjs`** must
  remain behavior-identical unless a change is explicitly scoped to hxmc dev in
  [dev-loop.md](dev-loop.md).

## Define and backend matrix

| User invocation | Driver adds (per server build) | Compiler backend | Artifacts |
| --- | --- | --- | --- |
| `haxe --dev -js out/main.mjs -D esm …` | `-D esm.hot`, `-dce no` (if missing), `esm` classpath | `GenesmHot` | `__hx_hot_patch.mjs`, `__hx_esm_dev_client.mjs`, … |
| `haxe -js out/main.mjs -D esm …` | — | `GenesmProd` *(planned)* / today's `Genesm` until prod lands | static ESM graph |
| `haxe --dev --custom-target hxmc=out …` | `-D hxmc.dev`, … | hxmc `Main.generate` | executable / wasm / dylib |

**`esm.hot`** remains the **compiler switch** for hot metadata, `$h`, and patch
emit. Users stop typing it when **`dev-esm.mjs`** (and optionally
`HaxeMain` / `EsmInstall` for server builtins) inject it on each
**`--server-connect`** request. Tests and **`make esm`** may keep passing
**`-D esm.hot`** until harnesses are migrated.

Optional later: introduce **`-D esm.dev`** as a single internal define that
implies **`esm.hot`** + dev client emit, so logs and `#if` read clearly; not
required for v1.

## Entry points (unchanged shell)

| Layer | File | Role |
| --- | --- | --- |
| Compiler | `HaxeMain.dev()` | `node $HXMC_DEV_SCRIPT $compiler …` |
| Launcher | `launcher.mjs` `toolEnv` | `HXMC_DEV_SCRIPT` → `dev.mjs` |
| Router | **`dev.mjs`** | Parse shared flags, expand hxml, classify, delegate |
| hxmc backend | **`dev-hxmc.mjs`** | Current `dev.mjs` behavior (snapshot / wasm / DevHost) |
| ESM backend | **`dev-esm.mjs`** | Watch, resident server, run, WebSocket patch push |
| Shared | **`dev-shared.mjs`** | Server client, watch, debounce, build queue |
| WebSocket | **`ws.mjs`** | Promote `hxmc/test/esm/hot/ws-min.mjs` into `@hxmc/cli` |

Do **not** branch in `HaxeMain.hx` beyond **`--dev`** → `dev.mjs`. ESM routing
stays in Node ([esm.md](esm.md) boundary).

## Router: classification

After **`words(args)`** (hxml expansion, same rules as today’s hxmc dev):

```text
hxmc     if --custom-target hxmc=<out>   (or -custom-target)
esm-hot  if (-js|--js) <entry> AND -D esm (value truthy; not "0")
error    if both hxmc output and esm-hot
error    if --dev with -js but no -D esm     → "use -D esm or plain haxe"
error    if -D esm.prod with --dev           → reject
unsupported (v1) if -js + esm without --dev   → plain compile; dev router not entered
```

Note: **`--dev`** is consumed in `HaxeMain` before the compilation server sees
it; only **`dev-esm.mjs`** appends **`-D esm.hot`** to server requests.

**Output paths**

- **`-js` entry** → `outDir = dirname(entry)`, entry path for `node` / browser.
- **Browser vs Node:** default Node; optional **`--dev-browser`** or
  heuristics (e.g. serve when entry is under a `www/` cp) — v1 can match hxmc
  (explicit flags only) and ship Node first.

## `dev-shared.mjs` — resident compilation server

Extract from current `packages/cli/hxmc/bootstrap/dev.mjs`:

1. Spawn **`compiler --server-connect 127.0.0.1:<port>`** with env:
   `HXMC_DEV_PROGRESS=1` (optional for ESM), nursery/old-space tuning as today.
2. Length-prefixed request queue (`--cwd`, build words one line each).
3. Parse answers: `\x01` output, `\x02` failure, else messages → `{ ok, messages }`.
4. **Watch:** union of resolved **`-cp`**, **`-lib`** package trees, **`.hxml`
   files** (not output paths; ignore editor temps).
5. On change: debounce (~10 ms); for each changed **`.hx`**, send
   **`server/invalidate`** JSON-RPC display request; then one build.
6. **HXB policy:** default **`-D disable-hxb-cache`** on server builds;
   `HXMC_DEV_HXB_CACHE=1` omits it (same as hxmc dev).
7. **Failure policy:** set `lastError`, notify clients, **do not** stop the
   last good program.

Callbacks for backends:

- `buildExtraArgs()` — hxmc: `-D hxmc.dev`, …; esm: `-D esm.hot`, `-dce no`, `-cp` esm std.
- `onBuildSuccess(result)` — hxmc: swap/reload; esm: push hot-patch if manifest changed.
- `onBuildFailure(messages)` — shared `error` WS / overlay.

## `dev-esm.mjs` — run loop

### Build requests

Every successful-path server request includes at least:

```text
...user args from hxml...
-D esm
-D esm.hot          # injected; user hxml must not need it
-dce no             # if not already set
-cp <esm-std>       # when HXMC_STD / package layout requires hxmc/std/esm
```

Ensure **`HAXE_STD_PATH`** / **`EsmInstall`** rules match a normal
**`-D esm`** compile from npm (`launcher.mjs`).

### Success detection

- Compiler exit / server answer OK.
- **`__hx_hot_patch.mjs`** exists under `outDir` and mtime/hash changed
  (or manifest diff via emit hashes on the server — already used in tests).

### Process model (Node)

1. First good build → **`spawn('node', [entry.mjs], { env: { HXMC_ESM_DEV: 'host:port', … } })`**.
2. **`__hx_esm_dev_client.mjs`** (emitted by `HotManifest.writeDevClient`):
   when **`HXMC_ESM_DEV`** is set, connect **`ws://host:port/__esm_hot/ws`**
   (path fixed for test + product parity).
3. On **`{ type: 'hot-patch', outDir, patchFile, patchMtime }`**: dynamic
   import patch with cache buster; **`applyHotPatchFromDev()`**; optional
   **`frame`** message for timing (`hxmc dev: swapped in …` analogue).

Extend **`writeDevClient`** and/or entry prelude so apps do not need a
separate **`run-ws-client.mjs`**.

### Browser

1. HTTP server on **`HXMC_DEV_PORT`** (default 4321, shared flag with hxmc dev).
2. Serve **`outDir`** with **`cache-control: no-store`** (entry, `hx/`,
   `__hx_*`).
3. Minimal shell: import entry + dev client; WebSocket **`/__esm_hot/ws`**.
4. **`error` / `ok` overlays** — reuse hxmc dev overlay styling/messaging pattern.
5. Patch in place; **`applyDevHotPatch`** already calls **`location.reload()`**
   when manifest requires full reload.

### WebSocket protocol (orchestration)

Shared with hxmc dev **semantics**, not hxmc **reload** payload:

| `type` | Direction | Meaning |
| --- | --- | --- |
| `error` | server → client | Build failed; running app unchanged |
| `ok` | server → client | Build OK after prior error |
| `log` | client → server | Optional forward to terminal |
| `frame` | client → server | Patch applied / first frame (timing) |
| `hot-patch` | server → client | ESM reload payload |
| `hello` | client → server | Optional; tests use today |

Do **not** send hxmc **`reload`** / snapshot fields on the ESM path.

## `dev-hxmc.mjs`

Move the body of today’s **`dev.mjs`** unchanged except imports from
**`dev-shared.mjs`**. Export:

```js
export async function runDevHxmc(compiler, { port, host, quiet, cwd, args })
```

## Compiler touch (optional, phased)

| Change | When | Why |
| --- | --- | --- |
| Driver-only **`-D esm.hot`** injection | v1 | No compiler rebuild for npm users |
| **`GenesmHot` when `define esm.hot` OR internal esm.dev** | v1/v2 | Single `#if` gate |
| Entry auto-import dev client when **`HXMC_ESM_DEV`** | v1 | One-process UX |
| **`HaxeMain` / server** add hot define if env **`HXMC_DEV_ESM=1`** | optional | Defense in depth for `--display` builds |
| Default **`Genesm`** → prod emit for **`-D esm`** without hot | phase prod | Drop user **`-D esm.prod`** |

No change to **`Generate.hx`** reference rejection of **`esm*`** defines.

## npm package layout

Add to **`package.json` `files`**:

- `dev-shared.mjs`, `dev-hxmc.mjs`, `dev-esm.mjs`, `ws.mjs`

Keep **`HXMC_DEV_SCRIPT=…/dev.mjs`**. Optionally ship **`hxmc/std/esm`** or
document **`HXMC_STD`** sibling for ESM patches (gap in current install).

## Migration

| From | To |
| --- | --- |
| `hxmc/test/esm/hot/esm-dev.mjs` | Import shared server helpers from `@hxmc/cli` or duplicate minimally in tests until packaged |
| Manual **`-D esm.hot`** in hxml | **`haxe --dev -D esm`**; keep **`-D esm.hot`** in `make esm` until lanes updated |
| **`esm-dev.mjs --out --watch`** | Router infers from **`-js`** and **`-cp`** |
| Two-process **`run-ws-client.mjs`** | **`HXMC_ESM_DEV`** + emitted client |

## Testing

1. **Unit:** existing `make esm` hot lanes; add lane that runs **`packages/cli/.../dev.mjs`** against a small hxml (**`-js -D esm`**, driver injects hot).
2. **Resident server:** extend **`hxmc/test/dev/server-verify.mjs`** pattern for Js target + patch manifest stability (or ESM-specific verify).
3. **watch-patch:** replace ad hoc **`esm-dev.mjs`** spawn with router path when promoted.
4. **Regression:** stock **`--js`** without **`-D esm`** unchanged on reference fixpoint.

## Implementation order

1. **`dev-hxmc.mjs`** + **`dev-shared.mjs`** — refactor only; **`dev.mjs`** router stub that always delegates to hxmc (behavior identical).
2. Router classification + **`dev-esm.mjs`** v1: shared server, inject **`-D esm.hot`**, watch, **`hot-patch`** broadcast (Node client still manual → quick win: **`run-ws-client`** optional).
3. **`ws.mjs`** in package; **`HXMC_ESM_DEV`** + **`writeDevClient`** connect logic.
4. Node single-process; browser static server + overlay.
5. Docs: [dev.md](../dev.md), [esm.md](../esm.md) quick start; trim user-facing **`-D esm.hot`**.
6. Prod **`Genesm`** default under **`-D esm`** (separate from dev loop).

## Principles (from [dev-loop.md](dev-loop.md))

- Last good build keeps running on compile errors.
- Zero hot cost in release (**no `esm.hot`** in prod emit).
- Measure edit-to-patch latency like hxmc dev.
- Hooks, not framework lock-in: **`esm.hot.*`** metadata and patch kinds stay generic.

## Decisions (recorded)

| Topic | Choice |
| --- | --- |
| WebSocket path | **`/__esm_hot/ws`** (match tests) |
| Node bootstrap | **`HXMC_ESM_DEV`** + emitted **`__hx_esm_dev_client.mjs`** |
| Branch location | **`dev.mjs`** in `@hxmc/cli`, not `HaxeMain` |
| Reload backends | hxmc snapshot vs ESM patch — **two backends**, one orchestration layer |