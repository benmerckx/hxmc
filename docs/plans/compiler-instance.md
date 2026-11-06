# CompilerInstance

A typed API to the compiler, as the core, with the command line, the
JSON-RPC protocol (and later an LSP, an MCP, an editor in the same process)
as adapters above it. In place of PR #148's split.

## Starting point

From `main` again. Keep the part of #148 that moved out the hook
initialization and the argument parsing. Then build the pipeline *on the
side*: our own entry point, duplicating what it needs, so existing parts can
be ported over to it one by one. The existing entry points (`HaxeMain`,
`Main`, the server) keep working until the new one can replace them.

## How it works today

For reference; file and line numbers are of `haxe/src` as of `main`.

**A request.** `Server.runRequest` expands the arguments, makes a request
scope (with a JSON-RPC result handler when there is a `--display`), and
`process` runs `HighLevel.entry`, which makes a fresh `CommonContext` per
part (`Compiler.createContext` → `Common.create`). Nothing of a context
survives the request; only the cache (`sctx.cs`) and some statics do.

**Display mode** sets the display state (mode, position) and starts a normal
compilation. The typer, reaching the position, throws `DisplayException`
with the result, which is caught and turned into the response. The protocol
itself exists only as types in the std (`haxe/display/{Display,Server,
Protocol}.hx`); the compiler side (`DisplayJson.makeHandler`) is a table of
37 method names to handlers reading parameters ad hoc and building JSON by
hand.

**Init macros** run in every compilation (`Compiler.doType`): each
`--macro` of the arguments, before any type is loaded. They run in the macro
context, made at the first one by cloning the target context (defines
adapted for macros) with its signature locked at once, so their code comes
from the macro context's cache. What they change (defines, class paths,
global metadata, callbacks) goes into the target context, whose signature is
locked only after them (`lockSignature(com, "after_init_macros")`). APIs that
would load a target type throw before `CInitMacrosDone`, so nothing is read
from the target's cache while its signature can still change. Their cost
per request is running their code; the interpreter (`macroInterpCache`, one
per process) and the macro modules stay warm.

**The server's cache** (`compiler/CompilationCache.hx`, `compiler/server/
ServerCache.hx`):

- One `Cache` per process, partitioned by signature (an MD5 of the defines,
  minus the signature-neutral ones: `display`, `display_stdin`, the
  timers, ...; `Define.hx:169`). A build and a display request with the same
  defines share a partition; the macro context has its own.
- Per partition (`ContextCache`): modules as HXB chunks with their
  `ModuleDefExtra` (or as `ModuleDef`s with `-D disable-hxb-cache`), parsed
  files (declarations and mtime), the class paths' directories and their
  mtimes.
- **Lazy.** A context starts empty. `TypeloadModule.loadModulePrime` asks
  the context, then the cache (`typeModuleHook` → `ServerCache.typeModule`),
  then types from source. A hit is checked, decoded (expressions only under
  full typing; in display mode later, at `PConnectField`), and pulls its
  dependencies (in display mode the display dependencies) into the context
  with it.
- **Written at the end** of a successful compilation (`afterSave` →
  `cacheContext`): every module of the context, encoded again, in parallel.
- **Invalidation is checked when a module is loaded** (`checkModule`), once
  per request: the file's mtime (with `CheckFileContentModification`, a
  structural comparison of the declarations), shadowing by a newer file in a
  changed directory (directories found by mtime, once per request), the
  library of an extern, then the dependencies, recursively. Tainted ahead of
  that by `server/invalidate`, the macro API's invalidation, and
  `defineType`/`defineModule`. Changed class paths reset the partition's
  directories; partitions unused for `staleContextMaxAgeSeconds` are
  dropped. A dirty module is not removed: it is typed again and overwritten.

**Ben's on-disk cache** (`hxmc/src/hxmc/ModuleCache.hx` and friends, see
`docs/plans/compiler.md` for the table): typed modules on disk with a
stricter check (content hashes, the defines and files and environment a
module's typing read, its dependencies' interface hashes, macro classes'
static state, modules macros define kept with their definer), module objects
and Mir macro functions on disk, lowered bodies in memory (server only). The
IR is not stored: the objects' key is a hash of it, so a warm build lowers
again to find them. It is wired by `ModuleCache.install()` (about 20 static
hooks) and opened per compilation from `Compiler.beforeTypingHook`
(`Compiler.hx:132`, before the init macros), and turns itself off for
several compilations in a process, the server, display requests and init
macros (`unusable`, `ModuleCache.hx:702`): its key (cwd, std, class paths)
does not see what init macros do, and its reads are credited to the module
being typed, which init macros are not.

## The pipeline

A function of the arguments and the cache:

1. The arguments are parsed and normalized (hxml flattened, `-lib`
   resolved) and initialize a context.
2. The init macros run.
3. The final state locks the signatures: the target's after the init
   macros, the macro context's at the first init macro. These select the
   cache's partitions.
4. The compilation loads types as it finds them, from the cache (checked)
   or from the class paths.
5. At the end of a successful compilation, the partitions are updated.

## CompilerInstance

```haxe
class CompilerInstance {
	function new(args:RequestArgs, cache:CompilerCache); // later: a CompilerConfig
	function build(io:CompilerIoData):BuildResult; // {code, messages}; later: ?options:{clean:Bool}
	final display:DisplayServices; // implements DisplayApi: completion, hover, definition, ...
	final server:ServerServices; // implements ServerApi: server/*, typer/compiledTypes
	function request<T>(start:CommonContext->RequestStep<T>, ?env:RequestEnv):RequestOutcome<T>; // what the methods run
}
```

- `CompilerConfig` is the normalized arguments (minus `--display`), with
  what else they depend on: the cwd, `HAXE_STD_PATH`, what each `-lib`
  resolved to. Equal configs are the same instance, so a server can keep
  instances by config (a cache of args → instance), like `ts.Program`.
- **Init macros run per call** (`build` or a display method), as today:
  they write into the context, and a context is made per compilation.
  Running them once and cloning the context after `CInitMacrosDone` is a
  later optimization, the same deep cloning as
  HaxeFoundation/haxe#11519.
- **The protocol's methods, typed** (`compiler.DisplayApi`/`DisplayServices`
  for `display/*`, `compiler.ServerApi`/`ServerServices` for `server/*`
  and `typer/compiledTypes`): one method per method of the protocol. The
  parameters are the std's (`haxe.display`), plus `fileContents`, which
  the compiler reads for every request naming a file. The results are the
  compiler's own values (`FieldsResult`, `HoverResult`, positions,
  `DiagnosticsContext`, metadata, cached files, ...), of which the
  protocol's results are the JSON; null where the protocol answers null.
  `server/module` is a `Genjson.ModuleSummary`: the module with what its
  JSON reads of the cache (its dependencies' signatures, its dependents),
  looked up in the request; `server/type` and `typer/compiledTypes` are
  `ModuleType`s; the memory methods are reports (`DisplayMemory
  .CacheMemory`, ...), measured in the request. Positions are the compiler's: a relative file is
  relative to the request's directory (its `--cwd`, `server/setCwd`'s),
  which the adapter keeps current until the response is written
  (`RequestEnv.keepCwd`), as upstream encodes inside the request. Each
  call runs one compilation, as a `--display`
  request does (the arguments, then the method): a failed one throws a
  `CompilationError` with its messages, a method's own error (an invalid
  directory, an unknown module) a `ServiceError`. How the pieces fit:
  - `CompilerInstance.request` runs a request: once the arguments are
    processed, the method says how it is answered (`RequestStep`): now,
    from the context (`server/*`); by typing, whose display result the
    request's result handler gets; or at a stage of the compilation (after
    the init macros: `display/metadata`, `display/defines`,
    `server/readClassPaths`; after the filters: `typer/compiledTypes`).
  - Upstream encodes each result where it is found and sends it
    (`send_result_raise`), so a request's answer is bytes on the output
    before the compilation unwinds (`JsonCompleted`, caught by the driver).
    Here the result handler gets the value (`ResultHandler
    .sendDisplayResultRaise`, `context.display.DisplayResult`). Encoding
    needs no context: what diagnostics' encoding read from it (the
    reported files, the deprecation warnings) is in the result.
  - Each display method's setup of the context is a function of its typed
    parameters (`context.display.DisplayRequests`).
  - The JSON-RPC adapter is a dispatcher (`DisplayJson.handler`,
    `DisplayJson.dispatch`): each method decodes the request into the
    std's types, with upstream's getters in upstream's order, calls the
    typed method and encodes its value. Upstream reads the parameters once
    the arguments are processed, so a bad request's error is the
    compilation's: the dispatcher replays a decoding failure inside a
    request, after what upstream did with what it read before the failure
    (`server/configure` applies its print settings as it reads them). The
    response's timestamp and `--times`' timers are taken when the request is
    answered, inside the compilation (`RequestEnv.onAnswer`), where upstream
    writes its response. The server's requests and `haxe --display` both run through
    it, on an instance over the server's cache or none.
  - Protocol state stays the protocol's: `initialize`'s settings,
    `completionItem/resolve` and the completion it details
    (`lastCompletionResult`, recorded and filtered to `maxCompletionItems`
    as the completion is encoded). A typed completion call gets every
    item, and neither records nor filters them.
- **Unsaved edits**: only the file of the display request comes from the
  request (as stdin does today); every other file is read from disk. Edits
  in other buffers are deliberately not seen.
- **Errors**: `build` returns its diagnostics (the messages, and whether it
  failed) rather than throwing or taking a callback; the adapters print or
  encode them.

## Caches

Three providers, behind one interface the pipeline uses at two points:

```haxe
interface CompilerCache {
	function begin():ServerCompilationContext; // the server context of a build: its `cs`, the hooks pointed at it
	function end(sctx:ServerCompilationContext):Void; // after the build
}
```

Upstream already has the distinction: a plain `haxe` makes a server
context too, with `isServer = false`, so nothing is written to its cache
(`afterSave`); the server keeps one with `isServer = true`, and its
requests go through `Server.process` (reset, the persistent cwd, the
delays, the timers in the result handler).

- **`SkipCache`**: a new server context per build, `isServer = false`,
  disposed at the end. A plain build.
- **`InMemoryCache`**: one server context kept across builds; `begin`
  points the hooks at it again (another cache may have moved them). The
  server. Several instances can share one (upstream's server shares one
  between all argument sets), as long as one compilation runs at a time.
  Cleanup and exploration between requests stay the host's (after the
  client has its answer).
- **`OnDiskCache`**: an `InMemoryCache` with a store behind it: a partition
  missing a module asks the store, and `commit` writes the modules that
  changed. So an editor's instance with it starts warm from disk and stays
  warm in memory, and the three keep distinct names while the layering
  falls out of the third.

`clean`: do not read what is cached, but write the result.

Everything below the interface stays upstream's machinery
(`ServerCache.typeModule`, `checkModule`, `cacheContext`), which already
works against `com.cs`; the providers only decide which server context
(and so which `Cache`) that is and what happens at the end.

### OnDiskCache, step by step

1. **HXB on disk.** Per partition, the modules' chunks and their
   `ModuleDefExtra` (Ben's `ModuleStore.writeExtra`/`readExtra` encode it),
   loaded lazily: a hook where `ContextCache.getHxbModule` and
   `findModuleExtra` miss. Checked by upstream's rules (mtime, shadowing,
   dependencies). Two things to get right:
   - The directories: a partition new to the process skips the shadowing
     check (`getChangedDirectoriesImpl` returns `[]`, "it's a new context").
     With modules from disk it is not new: store the directories with their
     mtimes.
   - Known unsound across processes, where the server is sound in memory:
     macro classes' static state (in the server the interpreter keeps it;
     a new process starts with it empty) and modules macros define. The
     same gaps Ben's tracking closes; until then, opt-in.
2. **Ben's check**: content hashes instead of mtimes, the reads (defines,
   files, environment), interface hashes with early cutoff, macro state,
   definers. Through `ServerCache.checkModuleHook` as now, but opened by the
   provider with our key instead of `beforeTypingHook` (whose
   `unusable` refuses several compilations, the server and display
   requests).
3. **Ben's other layers**: module objects, Mir macro functions, lowered
   bodies. Per field target code in general (IR, objects, a target's
   source) belongs to the same store: `docs/plans/compiler.md`, "One cache".

### The key and init macros

- In memory, per instance: the config never changes, so neither do the
  init macros; upstream's trust in the arguments is sound there. What is
  left is init macros reading files or the environment.
- On disk: the key gets a hash of the normalized arguments and of the init
  macros' modules' content; the files and environment variables they read
  are credited to a pseudo-module (`<init>`) with Ben's read tracking.
- One knob: how much of the init macros goes into the key. "Nothing"
  (upstream's server), "the config" (the default), "the config and their
  reads", and "bypass" (Ben's current behaviour).

## Process-wide state

The entry point sets up the statics (hooks, `ServerConfig`, the cache's
wiring) as it sees fit, and instantiates Ben's structures as needed. This
assumes **one compilation at a time per process**: shared are the macro
interpreter (`MacroContext.macroInterpCache`), `DisplayPosition
.displayPosition`, `TypeloadCacheHook.typeModuleHook` and the other hooks,
`ModuleCache.state`, `ServerConfig.*`, `DisplayJson.supportsResolve`,
`DisplayToplevel.exclude`, `DisplayException.lastCompletionResult`, the
parser's state. Moving them into the instance (for several at once, or one
on another thread) comes later, one at a time.

## Order of work

1. From `main`: argument parsing and hook initialization out of the entry
   points (from #148). Done: `compiler.Init.initHooks`,
   `Server.parseMessage`.
2. `CompilerInstance` with `SkipCache`; `build` matches a plain compile
   (fixpoint, crosshost byte-identical). Done: `haxe`'s builds (not its
   display requests) run on an instance.
3. `InMemoryCache`; the server as instances over one shared cache; the
   server tests pass. Done for builds: the server's build requests run on
   an instance per request over its cache. Keeping instances by config
   pays once an instance holds state of its own (step 4, init macros run
   once).
4. The display methods typed; the JSON-RPC adapter over them. Done: the
   results as values (`DisplayResult`), each method's setup as a function
   of the std's parameters (`DisplayRequests`), every method typed
   (`CompilerInstance.display`, `.server`; `haxe/test/unit
   /CompilerInstanceTest.hx`), and the JSON-RPC requests (the server's,
   `haxe --display`'s) dispatched onto them.
5. `OnDiskCache` as HXB on disk, then Ben's check, then his other layers.

## Open

- Which `server/*` methods stay protocol-only (`configure`'s settings are
  statics today).
- Whether `build` and display share one instance's partitions freely (they
  do today: `display` is signature-neutral) or display wants its own
  freshness rules.
- Running init macros once per instance (clone after `CInitMacrosDone`).
