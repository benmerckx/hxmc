# The dev loop: `hxmc dev`

Save a file, see the change. `hxmc dev` builds the program, runs it, and on
every save builds it again and runs the new build. The design and what
comes next: [plans/dev-loop.md](plans/dev-loop.md).

```sh
npx haxe --dev build.hxml          # the npm package
bin/hxmc/hxmc dev build.hxml       # the repository's tool
```

The arguments are the build's, as for `haxe` (an hxml file, or options);
the output, `--custom-target hxmc=<out>`, is the program the dev server
runs (its output in the terminal).

What happens:

- The compiler stays resident: the dev server
  (`packages/cli/hxmc/bootstrap/dev.mjs`) starts it as a compilation server
  (`--server-connect`: it connects to the dev server and takes each build on
  that one connection) and each build is a request to it, with `-D hxmc.dev`
  added. Typed modules, lowered bodies and compiled objects stay in memory;
  a build types again only the modules that changed and those that depend
  on them. The typed modules are kept as they are (`-D disable-hxb-cache`,
  Haxe's in-memory server cache), not written as HXB after each build and
  read back in the next (`HXMC_DEV_HXB_CACHE=1`: the HXB cache, Haxe's
  default); either way a build makes the bytes a fresh build makes (`make
  dev-check`).
- The class paths and libraries the build names (and its hxml files) are
  watched; a change builds again (several changes close together: one
  build).
- A build that compiles replaces the running program. A program that does
  not speak the protocol below is stopped and the new build started (a cold
  start); one that does is asked to snapshot and hand over first, and the
  new build starts from its snapshot.
- A build with errors changes nothing: the last good build keeps running,
  the errors show in the terminal.
- A program that ends by itself starts again with the next build.

The target's side of it, which libraries build on:

- `-D hxmc.dev`: set on every build of the loop, for code that behaves
  differently there.
- Swap hosts: a build can be a shared library (`-D hxmc.shared`, with
  `-D hxmc.exports=<names>`; Linux in the glibc mode, macOS and iOS dylibs,
  Windows DLLs, `-D hxmc.dll-base=<hex>`, Android's library) that a host
  process loads, runs and closes again, each build with its own runtime and
  heap (`Gc.releaseHeap` gives a shared library's heap back when its main
  returns), so that the process, and whatever the host keeps for it
  (windows, GPU contexts), survives a swap. `-D hxmc.dev-host` is the
  define such a build carries; the dev server builds the host itself when
  the build uses a library that has one, and names each new build's library
  in the `reload` message.
- Snapshots: the protocol's `HXMC_DEV_SNAPSHOT` file, a string a build
  writes before it hands over and the next one reads at its start.

universe's `@hxmc/os` (<https://github.com/benmerckx/universe>) implements
the program's side for windowed programs: the dev host
(`hxmc.dev.DevHost`, `hxmc.dev.Hosted`), fast refresh's state carried by
key (`hxmc.dev.Hot`), the browser page for `.wasm` outputs, and the swaps on
Linux, macOS, Windows, Android and the iOS simulator; its docs/dev.md
describes them.

## The protocol

The dev server and the program talk in JSON messages: JSON lines over a
TCP connection natively, WebSocket text messages in the browser (the
page's `/__hxmc/ws`), so editors and other tools can drive the loop:

| To the program | |
| --- | --- |
| `{"type":"reload"}` | a new build is ready: snapshot, dispose, hand over. Natively it carries `"snapshot": <file>`: write the snapshot there, answer `saved`, exit (with the dev host, `"library": <file>` too: hand the host's handles over to that library and return from main). In the browser the page fetches the new module (`/__hxmc/app.wasm?swap`: 409 when the build failed, the running one stays), asks the running module for its snapshot, disposes it and runs the new one in the same page |
| `{"type":"error","message":<text>}` | the build failed (the overlay); the program keeps running |
| `{"type":"ok"}` | the build compiles again (the overlay goes) |
| `{"type":"assets", ...}` | reserved: styles and images without a rebuild (step 4) |

| From the program | |
| --- | --- |
| `{"type":"saved"}` | natively: the snapshot is written |
| `{"type":"frame"}` | the first frame of a build is drawn (the reload's time) |
| `{"type":"log","text":<text>}` | the page: a line the module printed |

The snapshot is a string, `haxe.Serializer`'s encoding of an array of
strings: key, type hash, value (`hxmc.dev.Hot.save`'s encoding, universe's), key, ... A native
program finds the dev server in `HXMC_DEV=<host>:<port>` and starts from
the snapshot file in `HXMC_DEV_SNAPSHOT`; with only the latter, a program
starts from a snapshot without any dev server (as the tests do). In the
browser the page gives the module the imports of `hxmc_dev`:
`restore_length()` and `restore_take(p)` (the snapshot it was given, -1:
none), `register(f)` (the `@:hxmc.callback` the page calls for a reload),
`send(p, n)` (the snapshot) and `frame()`. universe's `@hxmc/os` app loop reads the
dev server's messages at each turn (an idle loop wakes every 10 ms in a dev
build) and reports the first frame.

## Tests

`make dev-check` (CI: the `build` job): `hxmc dev` on a console program
(`hxmc/test/dev/dev-console.mjs`: the first build runs with `HXMC_DEV`
set, an edit runs the new build in place of the old one, a compile error
leaves the old one running, the fix runs), and a compilation server's
builds of small programs through edits against fresh builds of the same
sources, byte for byte (`server-verify.mjs`). The swaps with state, in the
browser and natively, are tested in universe.

## Not yet

- The program's side of the protocol (the dev host, the snapshot's
  primitives) lives in a library; hxmc's std could carry the host and the
  primitives so that any program hands over its state.
- An iOS device cannot load a new build's code (plans/dev-loop.md).
- Styles and assets without a rebuild (step 4).
