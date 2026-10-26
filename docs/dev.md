# The dev loop

How `haxe --dev` works and the protocol a program speaks to keep its state
across reloads. For library authors (a UI, a game loop) and for anyone
driving the loop from an editor. Usage is in
[using.md](using.md#fast-rebuilds); open work is in
[plans/dev-loop.md](plans/dev-loop.md).

```sh
npx haxe --dev build.hxml          # the npm package
bin/hxmc/hxmc dev build.hxml       # the repository's tool
```

The arguments are the build's. The output (`--custom-target hxmc=<out>`)
is the program the dev server runs.

## What happens

- **The compiler stays resident.** The dev server
  (`packages/cli/hxmc/bootstrap/dev.mjs`) starts it as a compilation
  server (`--server-connect`) and sends each build to it with `-D hxmc.dev`
  added. A build types again only the modules that changed and their
  dependents. Typed modules are kept in memory (`-D disable-hxb-cache`);
  `HXMC_DEV_HXB_CACHE=1` uses Haxe's HXB cache instead. Either way a build
  writes the same bytes as a fresh build.
- **The build's class paths, libraries and hxml files are watched.**
  Changes close together make one build.
- **A build that compiles replaces the running program.** A program that
  does not speak the protocol is stopped and the new build started. One
  that does is asked to snapshot first, and the new build starts from the
  snapshot.
- **A build with errors changes nothing.** The last good build keeps
  running; the errors show in the terminal.
- **A program that exits** starts again with the next build.

## What the target provides

| | |
| --- | --- |
| `-D hxmc.dev` | set on every build of the loop |
| `-D hxmc.dev-host` | set on a build that a swap host loads |
| Swap hosts | a build as a shared library (`-D hxmc.shared`, see [using.md](using.md#shared-libraries)) that a host process loads, runs and unloads. The process, and what it holds (windows, GPU contexts), survives each swap. Each build has its own runtime and heap |
| Snapshots | a string the old build writes before it hands over and the new build reads at its start |

The dev server builds the host itself when the build uses a library that
has one, and names each new build's library in the `reload` message.
universe's `@hxmc/os` implements the program's side for windowed programs
on Linux, macOS, Windows, Android, the iOS simulator and the browser.

## The protocol

JSON messages: one per line over TCP natively, WebSocket text messages in
the browser (the page's `/__hxmc/ws`).

| To the program | |
| --- | --- |
| `{"type":"reload"}` | a new build is ready: snapshot, dispose, hand over. Natively it carries `"snapshot": <file>`: write the snapshot there, answer `saved`, exit. With a swap host it also carries `"library": <file>`: hand the host's handles to that library and return from main |
| `{"type":"error","message":<text>}` | the build failed; keep running |
| `{"type":"ok"}` | the build compiles again |
| `{"type":"assets", ...}` | reserved: assets without a rebuild |

| From the program | |
| --- | --- |
| `{"type":"saved"}` | natively: the snapshot is written |
| `{"type":"frame"}` | the new build drew its first frame (for timing reloads) |
| `{"type":"log","text":<text>}` | browser: a line the module printed |

**Natively**, a program finds the dev server in `HXMC_DEV=<host>:<port>`
and its starting snapshot in the file `HXMC_DEV_SNAPSHOT`. With only the
latter set, it starts from a snapshot without a dev server (as the tests
do).

**In the browser**, the page fetches the new module
(`/__hxmc/app.wasm?swap`; 409 when the build failed), asks the running
module for its snapshot, disposes it and runs the new one in the same page.
The module imports `hxmc_dev`:

| Import | |
| --- | --- |
| `restore_length()`, `restore_take(p)` | the snapshot it was given (-1: none) |
| `register(f)` | the `@:hxmc.callback` the page calls for a reload |
| `send(p, n)` | hand over the snapshot |
| `frame()` | report the first frame |

The snapshot's content is the library's. `@hxmc/os` uses
`haxe.Serializer`'s encoding of an array of strings: key, type hash,
value, key, ...

## Tests

`make dev-check` (CI's `build` job) runs `hxmc dev` on a console program
(`hxmc/test/dev/dev-console.mjs`): the first build runs with `HXMC_DEV`
set, an edit replaces it, a compile error leaves it running, the fix runs.
`server-verify.mjs` checks that a compilation server's builds through edits
are byte-identical to fresh builds. The swaps with state are tested in
universe.
