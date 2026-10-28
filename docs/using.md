# Using hxmc

The user guide: which targets hxmc builds for, its options, what it
writes, how it finds libraries, how rebuilds stay fast, sockets, how to
debug a program, and what does not work yet. For a first build, see the
[README](../README.md).

## Targets

Pick one with `-D hxmc.target=<target>`. The default is the machine you
build on. Any host builds for any target.

| Target | Output |
| --- | --- |
| `linux-x86_64`, `linux-arm64` | static ELF executable (musl); with `-D hxmc.libc=glibc`, linked against the system's glibc 2.17+ |
| `macos-x86_64`, `macos-arm64` | Mach-O executable, ad hoc signed |
| `windows-x86_64`, `windows-arm64` | PE executable over the UCRT |
| `android-arm64`, `android-x86_64` | a shared library ([Android](#android)) |
| `ios-arm64`, `ios-sim-arm64` | Mach-O executable ([iOS](#ios)) |
| `wasm32-wasi` | WebAssembly module ([WebAssembly](#webassembly)) |

Code can test the target with `target.name == "hxmc"` (there is no `hxmc`
define) and with these flags:

| Flag | Where |
| --- | --- |
| `static`, `sys`, `utf16`, `target.unicode` | every target: static types (an `Int` is never null), the sys API, UTF-16 strings |
| `target.threaded` | the native targets: OS threads run in parallel |
| `target.atomics` | every target: `haxe.atomic` |

## Options

Defines go on the command line or in the hxml file. `haxe --help-defines`
lists the ones marked with *.

| Option | Effect |
| --- | --- |
| `-D hxmc.target=<target>` | the target (above) |
| `-D hxmc.libc=glibc` | Linux: link dynamically against glibc, so the program can import shared libraries (`@:hxmc.lib("libGL.so.1")`) and `dlopen` them |
| `-D hxmc.shared` | a shared library: Linux in the glibc mode, a dylib on macOS and iOS, a DLL on Windows; Android's output always is one |
| `-D hxmc.exports=<names>` | the `@:hxmc.export` functions a shared library exports |
| `-D hxmc.dll-base=<hex>` | Windows: a DLL's preferred base address |
| `-D hxmc.output=<path>` | the output path, instead of `--custom-target`'s |
| `-D hxmc.link=<paths>` | extra objects and archives to link (also `@:hxmc.link("path")` on a class) |
| `-D hxmc.jobs=<n>` | parallel module compilations (default: the number of cores; also `HXMC_JOBS`) |
| `-debug` | DWARF lines and a symbol table ([Debugging](#debugging)) |
| `-D hxmc.symbols` | a symbol table only (wasm: a name section) |
| `-D hxmc.lines` | DWARF lines only |
| `-D hxmc.no-stacks` | no call stacks: `haxe.CallStack` and exception stacks are empty |
| `-D hxmc.stacks` | call stacks in every program, so an uncaught exception prints its frames |
| `-D hxmc.no-frame-pointers` | x86-64: no frame pointers (arm64 always keeps them; also `HXMC_FRAME_POINTERS=0`) |
| `-D hxmc.null-checks=0\|1` * | test references against null before each access. Default: on for WebAssembly, off natively, where a fault handler throws instead ([Null access](#null-access)) |
| `-D hxmc.native-array-outofbounds=throws\|silent` * | `haxe.ds.Vector` and `hxmc.NativeArray` accesses out of bounds: `throws` an `ArgumentException`, or `silent` (reads give the default value, writes do nothing). Default: not tested, the result is unspecified |
| `-D hxmc.wasm-eh=legacy` | wasm: legacy exception handling (Chrome 95+, Firefox 100+, Safari 15.2+) instead of `exnref` (Chrome 137+, Firefox 131+, Safari 18.4+) |
| `-D hxmc.gc-prefault` * | Linux: a helper thread faults in the old space's pages ahead of the collector: less wall time, more CPU time |
| `-D hxmc.census` | a heap census at exit, by type (`RT_CENSUS=1` at run time) |
| `-D hxmc.no-module-cache` | no module cache for this build (also `HXMC_MODULE_CACHE=0`) |
| `-D hxmc.no-cache=<packages>` | type these packages, modules or library directories in every build ([Macros and the cache](#macros-and-the-module-cache)) |
| `-D hxmc.macros=mir` | experimental: run macros on hxmc's Mir interpreter instead of Eval ([Mir macros](#mir-macros)) |
| `-D hxmc.run=mir` | experimental: run `--interp`/`--run` on the Mir interpreter |
| `-D hxmc.pic` | a position-independent executable: refused, not written yet |

## Outputs

### Native executables

An executable links only what it uses. mbedtls (`sys.ssl`) and libuv
(`eval.luv`) are linked only into programs that use them. A hello world is
about 125 KB on linux-x86_64.

In the default static mode on Linux a program cannot import shared
libraries; such an import is a compile error that names
`-D hxmc.libc=glibc`.

### Shared libraries

`-D hxmc.shared` with `-D hxmc.exports=<names>` writes a library that
exports the named `@:hxmc.export` functions. Each library has its own
runtime and heap; `Gc.releaseHeap` gives the heap back when its main
returns, so a host can load, run and unload builds in turn (the
[dev loop](dev.md) does this).

### Android

`android-arm64` (phones) and `android-x86_64` (emulators), Android 10 (API
29) and later: a shared library against Bionic, which an APK's
`NativeActivity` loads. The program exports `ANativeActivity_onCreate` and
starts its own thread (see `hxmc/test/android/AndroidHello.hx`). A
packager writes the APK around it ([below](#native-output-for-a-packager)).

### iOS

`ios-arm64` (devices) and `ios-sim-arm64` (the simulator on Apple silicon),
iOS 15 and later: a Mach-O executable, or a dylib with `-D hxmc.shared`.
A UI library that defines `hxmc_ui_main` gets `UIApplicationMain` on the
main thread, and the program's body runs once the app has launched. A
packager writes the app bundle around it ([below](#native-output-for-a-packager)).

### Native output for a packager

hxmc writes no APKs or app bundles: a packager writes them around hxmc's
native output ([helder](https://github.com/benmerckx/helder) does). It
builds on two outputs, checked by `make native-check`:

- **Android**: the `.so`. Its `DT_SONAME` is always the output's file
  name, so name it `libmain.so` for `NativeActivity`.
  `ANativeActivity_onCreate` is exported when the program defines it.
- **iOS**: a plain Mach-O executable, or a dylib with `-D hxmc.shared`.
  `-D hxmc.ios-min-version=<major.minor>` sets its `LC_BUILD_VERSION`
  minimum (15.0, the floor). The linker signs it ad hoc, as
  linker-signed. With any of the defines below it is signed as `codesign
  -s -` signs a bundle's executable instead. The packager writes
  `Info.plist` and `CodeResources` first, then links, then puts the files
  together.

| Option | Signs |
| --- | --- |
| `-D hxmc.codesign-id=<identifier>` | the identifier (default: the output's name) |
| `-D hxmc.codesign-info-plist=<file>` | special slot 1, the bundle's `Info.plist` |
| `-D hxmc.codesign-resources=<file>` | special slot 3, `_CodeSignature/CodeResources` |
| `-D hxmc.codesign-entitlements=<file>` | special slot 5, the entitlements (an XML plist) |

They apply to Mach-O outputs only (macOS and iOS).

### WebAssembly

`wasm32-wasi` writes a linear-memory module with the whole runtime inside.
Run it with:

```sh
node hxmc/bootstrap/wasi.mjs app.wasm
wasmtime run -W exceptions=y --dir . app.wasm     # needs exnref: not with -D hxmc.wasm-eh=legacy
```

node 22 runs both exception encodings without flags.

In a browser, the page instantiates the module, provides its imports (WASI
preview 1 without a file system, and any `@:hxmc.lib("<module>")` externs)
and runs `_start`. The runtime stays alive after `_start` returns, so
JavaScript can call a `@:hxmc.callback` through the exported
`__indirect_function_table`, for example from `requestAnimationFrame`.
Calling C from wasm: [interop.md](interop.md#webassembly).

The module grows its memory only as it needs it. The shadow stack and the
frame stack are 4 MB each (`RT_STACK_MB`); an overflow exits with a
message. When memory cannot grow, the program prints "out of memory" and
exits.

## The npm packages

One install: `npm i -D @hxmc/cli` (node 22+). It brings `haxe` and `hxmc`
(the same command): every Haxe target (js, hl, jvm, `--interp`, ...) and
`--custom-target hxmc=<out>` for this machine. There are eight packages,
all published at one version:

| Package | Size (tarball, unpacked) | Contents |
| --- | --- | --- |
| `@hxmc/cli` | 1.3 MB, 7.7 MB | what you install: the launcher (`haxe`, `hxmc`), upstream's std, hxmc's std, `dist/` for lix; optional dependencies on the six platform packages |
| `@hxmc/linux-x64`, `@hxmc/linux-arm64` | about 10 MB, 34–38 MB each | the native compiler for that machine and its targets' runtime objects: `linux-<arch>/` (static, musl) and `linux-<arch>-glibc/` (`-D hxmc.libc=glibc`) |
| `@hxmc/darwin-x64`, `@hxmc/darwin-arm64` | about 8 MB, 26–28 MB each | the same for macOS: `macos-x86_64/`, `macos-arm64/` (also used for iOS) |
| `@hxmc/win32-x64`, `@hxmc/win32-arm64` | about 8 MB, 26–28 MB each | the same for Windows: `windows-x86_64/`, `windows-arm64/` |
| `@hxmc/source` | 2.4 MB, 9.1 MB | the compiler's sources, for building on it ([below](#building-on-the-compiler)); `hxmc-rebuild` |

Sizes are of 0.1.0 as packed (`@hxmc/source`'s of a later nightly); CI's job summary lists each build's.

npm installs the platform package that matches the machine, by its `os`
and `cpu` fields. A runtime-objects folder holds `rt.o`, `ssl.o` (mbedtls)
and `uv.o` (libuv). On a machine none of them fits, `haxe` prints one line
naming the machines it runs on and exits non-zero. An install without
optional dependencies does the same, naming the package to add.

### Cross builds

A target's runtime objects (`<dir>/<target>/rt.o`) come from the first of
these that has them:

1. the directories `HXMC_RT_DIR` lists (separated by the system's path
   separator). They add to the search; they do not replace it, so a cross
   build that names another machine's runtime objects keeps this machine's
   for macros and host tools. An empty `HXMC_RT_DIR` is the same as unset;
2. the compiler's own directory: the platform package it is in
   (`node_modules/@hxmc/linux-x64/linux-x86_64/rt.o`);
3. `rt/` beside the compiler: a checkout's `bin/hxmc/rt` (`make rt`);
4. the target's platform package beside the compiler's, of the same version
   (`node_modules/@hxmc/win32-x64/windows-x86_64/rt.o`).

The launcher (`node_modules/.bin/haxe`, also when the native compiler
stands in its place) also passes the installed platform packages of its
version in `HXMC_RT_DIR`, after yours. So the platform package's compiler, run
directly without the launcher, needs no `HXMC_RT_DIR`. When no directory
has them, the error lists every place searched. To build for another desktop machine, install its
platform package with `--force`; its `os` and `cpu` do not match, and its
compiler goes unused:

```sh
npm i -D @hxmc/cli
npm i -D --force @hxmc/win32-x64      # then: -D hxmc.target=windows-x86_64
```

A build for a target none of them has fails with one line naming the
package to install.

Android's runtime objects (`android-arm64`, `android-x86_64`) are in no npm
package. Take them from the runtime objects' GitHub release, or build them
from source (`make rt`, [development.md](development.md)). Then name the
directory in `HXMC_RT_DIR`. `@hxmc/cli`'s `package.json` names the
release its packages were built with, `"hxmc": {"rt": "rt-<hash>"}` (the
platform packages' runtime objects are that release's). Its assets are
`<target>-<file>.gz`:

```sh
tag=$(node -p "require('@hxmc/cli/package.json').hxmc.rt")
for f in rt.o ssl.o uv.o; do
  mkdir -p rt/android-arm64
  curl -fsSL "https://github.com/benmerckx/hxmc/releases/download/$tag/android-arm64-$f.gz" | gunzip > rt/android-arm64/$f
done
HXMC_RT_DIR=$PWD/rt npx haxe ... -D hxmc.target=android-arm64
```

In a checkout, `node hxmc/bootstrap/rt.mjs fetch <dir>` downloads the
release of its `hxmc/deps`.

### Without node

On Linux and macOS, `@hxmc/cli`'s postinstall script checks that the native
compiler runs and copies it over `hxmc/bootstrap/haxe` and `dist/haxe`. It
is best effort, offline, and writes only inside the package. Then
`node_modules/.bin/haxe` starts the compiler directly. With install scripts
disabled (`--ignore-scripts`, pnpm's default), the first call through node
does the same. `HXMC_INSTALL=0` keeps the launcher in place.

Builds for the hxmc target still go through node, which finds the runtime
objects (with `HXMC_RT_DIR` set too: it adds to them); other targets do not. A compilation server (`haxe --wait`) asks
node for their directories once, when it starts. On Windows, npm's `haxe.cmd` always starts
node (about 40-60 ms per call); point editors and lix at
`node_modules/@hxmc/cli/dist/haxe.exe` to bypass it.

The launcher writes nothing but the compiler's own output to stdout and
stderr, since editors parse them. A failure prints one line and exits
non-zero.

### Building on the compiler

`@hxmc/source` holds the sources of `@hxmc/cli`'s compiler: the port
(`haxe/src`), hxmc (`hxmc/src`) and hxmc's std (`hxmc/std`,
`hxmc/portable`). Install it at `@hxmc/cli`'s version; `@hxmc/cli`'s
`haxe` builds a compiler from it, natively, with a main of your own:

```sh
npm i -D @hxmc/cli@next @hxmc/source@next     # (one version: the nightlies' dist-tag)
npx haxe -cp node_modules/@hxmc/source/haxe/src -cp node_modules/@hxmc/source/hxmc/src \
  -cp src -main MyCompiler -D disable-parallelism --custom-target hxmc=bin/mycompiler
```

A frontend for another language adds its functions to the IR this way
([hxmc.md](hxmc.md#frontends)). Run the compiler it builds as the platform
package's is run directly: `HAXE_STD_PATH` set to
`node_modules/@hxmc/cli/haxe/upstream/std`, `HXMC_STD` to
`node_modules/@hxmc/cli/hxmc/bootstrap/hxmc-std`, and `HXMC_RT_DIR` to the
platform package (`node_modules/@hxmc/linux-x64`), whose runtime objects it
does not find beside itself.

`npx hxmc-rebuild` builds `@hxmc/cli`'s own compiler again from the
package's sources, edited or not, into the cache; `haxe` then runs that
one while `@hxmc/source` is installed, and `hxmc-rebuild --reset` returns to
the published one. To change the compiler for good, work in a checkout of
this repository ([development.md](development.md)).

## Editors and lix

- **vshaxe**: `"haxe.executable": "auto"` (the default) runs the workspace's
  `node_modules/.bin/haxe`. On Windows, set it to
  `node_modules/@hxmc/cli/dist/haxe.exe`.
- **lix**: `dist/` (`packages/cli/dist` in this repository) is an
  installation lix accepts as a path version: `lix use haxe
  ./node_modules/@hxmc/cli/dist`, or a `.haxerc` with
  `{"version": "./node_modules/@hxmc/cli/dist", "resolveLibs": "scoped"}`.
  lix's `haxe` shim then runs hxmc. CI checks this on Linux and macOS.
- **lix's npm package in the same project**: both packages declare a `haxe`
  bin, and npm links whichever comes last. Use lix's shim with the `dist/`
  version there.

## Libraries

The compiler resolves `-lib <name>` (also `-L`, `--library`, and in hxml
files) itself, with no haxelib or lix process. It looks in three places, in
this order: a lix scope, npm packages, haxelib repositories. This works
without node and without lix or haxelib installed.

**lix scopes.** The scope is the nearest `.haxerc` from the working
directory up (or the one `HAXESHIM_SCOPE` names), else lix's global
`$HAXESHIM_ROOT/.haxerc` (default `~/haxe`). Its `"resolveLibs"` decides:

| `resolveLibs` | Behaviour |
| --- | --- |
| `scoped` (default) | `haxe_libraries/<name>.hxml` beside the `.haxerc`; a library without one is an error unless `node_modules` has it |
| `mixed` (default for the global scope) | `haxe_libraries` first, then haxelib |
| `haxelib` | haxelib only |

The hxml files are read as lix reads them: one argument per line,
`${VAR}` from the environment, `HAXE_LIBCACHE`, `SCOPE_DIR`, `CWD`,
`__dirname`. Each library comes once per build, and a missing class path is
an error. The `.haxerc`'s `"version"` is ignored.

**npm packages.** A package is a library when its `package.json` has a
`"haxe"` field:

```json
"haxe": {"name": "mylib", "classPath": "src", "hxml": "extraParams.hxml"}
```

`-lib` takes that name or the package's (`-lib @scope/mylib`);
`-lib <name>:<version>` takes only that version. It expands as a haxelib
library does: the hxml's lines, the class path, `-D <name>=<version>`, then
its `dependencies` and `peerDependencies` that are libraries. The nearest
`node_modules` from the working directory up counts.

**haxelib.** As `haxelib path` (4.2.0) answers: a `.haxelib` repository in
the working directory or a parent, else the global one (`HAXELIB_PATH`,
`~/.haxelib`); dev paths and current versions; `haxelib.json`'s class path
and dependencies, `extraParams.hxml`, `ndll/`.

The cpp generator's `haxelib path hxcpp` is answered the same way. Running
a library (`haxelib run hxcpp`) still needs haxelib or lix.

## Fast rebuilds

**The module cache.** Every build keeps its typed modules and compiled
objects in the user's cache directory. The next build types and compiles
only what changed, and outputs share objects. It is on by default, for
every target.

| Variable | |
| --- | --- |
| `HXMC_CACHE=<dir>` | the cache directory. Default: `$XDG_CACHE_HOME/hxmc` or `~/.cache/hxmc`; macOS `~/Library/Caches/hxmc`; Windows `%LOCALAPPDATA%\hxmc\cache` |
| `HXMC_CACHE_SIZE=<n>[K\|M\|G]` | the cap (default `1G`); the least recently used entries go first |
| `HXMC_MODULE_CACHE=0` | off (or `-D hxmc.no-module-cache`) |
| `HXMC_MODULE_CACHE_LOG=1` | why each module was typed again |
| `HXMC_STATS=1` | what the build did and how long it took |

Entries unused for 14 days are removed.

**The compilation server** keeps typed modules, lowered bodies and compiled
objects in memory: `haxe --wait 6000`, then `haxe --connect 6000
build.hxml`.

**The dev loop.** `haxe --dev build.hxml` (`hxmc dev build.hxml` with the
repository's tool) builds the program, runs it, and on every save rebuilds
it and runs the new build. A build with errors leaves the last good build
running. Programs that want to keep their state across reloads speak a
small protocol: [dev.md](dev.md).

### Macros and the module cache

A module restored from the cache does not run its macros again, so the
cache watches what macros depend on:

- A macro that reads the time or a random number, or starts a process or
  uses the network (`Date.now`, `Sys.time`, `Math.random`, `Sys.command`,
  `sys.io.Process`, `sys.Http`, sockets, ...) makes its module typed again in
  every build. Modules that use it stay cached, unless the result was
  copied into them (an `inline` field, a field without a written type).
- A file a macro reads (`sys.io.File`, `FileSystem.exists`,
  `readDirectory`, `stat`) or an environment variable (`Sys.getEnv`) is
  recorded. The module is typed again when the content or value changes.
- Static variables of macro classes are tracked, so an `@:autoBuild`
  registry keeps working.

Where that is not enough (a macro writes a file, or keeps state elsewhere):

- `@:hxmc.noCache` on a class types its module in every build;
- `-D hxmc.no-cache=<package, module or library directory,...>` does so for
  those;
- `HXMC_MODULE_CACHE=0` turns the cache off.

`HXMC_MODULE_CACHE_LOG=1` prints the reason, for example
`Clock typed every build (macro called Date.now at src/Macros.hx:4)`.

The cache is not used for display requests, the compilation server, builds
with init macros (`--macro`), several compilations (`--next`), or HXB
libraries and output, or by the WebAssembly compiler. The compilation
server keeps upstream's behaviour.

### Mir macros

`-D hxmc.macros=mir` runs macros on hxmc's Mir interpreter inside the
native compiler, instead of Eval. It is experimental. Compute-bound macros
run several times faster; cold builds are slower. It is not in the
WebAssembly compiler. The differences from Eval are listed in
[hxmc.md](hxmc.md#macros-on-the-mir-interpreter).

## Sockets

`sys.net.Socket` keeps upstream's API, natively (WebAssembly has no
sockets). What upstream leaves open, hxmc does as follows, with additions in
`hxmc.net`:

- **A non-blocking connect** returns while the connection is in progress,
  as on HashLink, hxcpp and Neko. The socket turns writable when the
  connection completes or fails (on Windows a failure may show in
  `select`'s `others` instead). Then `SocketTools.connectError(s)` gives
  why it failed (SO_ERROR), or null; `finishConnect(s)` throws it as
  `Custom(message)`.

```haxe
using hxmc.net.SocketTools;

s.setBlocking(false);
s.connect(host, port);              // returns at once
Socket.select(null, [s], [s], 5.0);
s.finishConnect();                  // Custom("Connection refused")
```

- **`Socket.select`** is limited by FD_SETSIZE: descriptors below 1024 on
  Linux and macOS, 64 sockets a set on Windows. Beyond that it throws
  `Custom("Socket.select: beyond FD_SETSIZE ...")`.
- **`hxmc.net.Poll.poll(sockets, events, timeout)`** has no such limit
  (poll(2), WSAPoll). `events` are `Poll.IN`, `PRI`, `OUT` per socket; it
  returns each socket's ready events (0: none), `ERR`, `HUP` and `NVAL`
  included. The timeout is in seconds (0: no wait, negative: no limit).
  Other threads run while it waits. On wasm32-wasi it throws, as sockets do.

```haxe
var ready = Poll.poll(sockets, [for (_ in sockets) Poll.IN], 1.0);
```

- **`Poll.wait(fds, events, revents, count, timeout)`** allocates nothing:
  it waits for the first `count` entries of the caller's arrays and writes
  their ready events to `revents`, returning how many are ready. The
  system's structures live in a per-thread buffer that is kept.
- **Descriptors** come from `Poll.socketFd(s)`, or for file streams from
  `Poll.inputFd(i)` and `Poll.outputFd(o)` (a process's pipes,
  `Sys.stdin()`, files). Any other descriptor works too, such as a pidfd.
  On Windows, WSAPoll waits for sockets only: `inputFd`, `outputFd` and
  `wait` on anything else throw `Custom("... WSAPoll waits for sockets
  only ...")`. Pipes would need overlapped I/O, which hxmc does not offer
  yet.

```haxe
var fds = [Poll.socketFd(a), Poll.socketFd(b)], events = [Poll.IN, Poll.IN], revents = [0, 0];
while (Poll.wait(fds, events, revents, 2, -1) > 0) ...   // no allocation per call
```

## Debugging

- **Backtraces and breakpoints.** Build with `-debug` for DWARF lines and a
  symbol table. gdb and lldb then stop at Haxe lines and name Haxe functions
  (`pack.Class.field`) in backtraces. On Windows the DWARF is in the PE as
  MinGW writes it: gdb, lldb and llvm-symbolizer read it; Visual Studio and
  WinDbg do not (no PDB).
- **Profilers.** Every function keeps a frame pointer (x86-64 by default,
  arm64 always), so `perf record -g` works. Unwind tables are always
  written. `-D hxmc.symbols` alone gives profilers names.
- **Call stacks.** `haxe.CallStack` and exception stacks work natively. A
  program gets the table of functions and lines only if it reads stacks.
  With `-D hxmc.stacks` every program has it, and an uncaught exception
  prints its frames (`Called from Main.f (src/Main.hx line 3)`).
- **Runtime variables.** `RT_STATS=1` prints the collector's work,
  `RT_VERIFY=1` checks the heap, `RT_MINOR_KB=<n>` fixes the nursery size.
  More in [hxmc.md](hxmc.md#environment-variables).

### Measuring the collector

`hxmc.GcStats` reads the collector's counters, the same way natively and on
wasm32-wasi, without `@:access` into the runtime:

| Function | |
| --- | --- |
| `bytesAllocated():Float` | bytes allocated since the program started, by every thread, large objects included |
| `threadBytesAllocated():Float` | the same, by the calling thread |
| `collections():Int`, `minorCollections()`, `majorCollections()` | collections so far |
| `lastPause():Float`, `totalPause()`, `maxPause()` | pauses in seconds, from the collecting thread's request to resuming the program |
| `records(since = 0):Array<GcRecord>` | the last `GcStats.RECORDS` (64) collections, oldest first, from index `since` on |
| `now():Float` | the clock of the records (monotonic seconds) |

A `GcRecord` has the collection's `index` (from 0), `start` (the request),
`stopped` (every thread stopped; on wasm32 the same as `start`), `end` (the
program resumed) and `major`. A profiler keeps the last index it saw and
reads `records(last + 1)` once a frame.

```haxe
var b0 = hxmc.GcStats.bytesAllocated(), p0 = hxmc.GcStats.totalPause();
work();
trace('${hxmc.GcStats.bytesAllocated() - b0} bytes, ${hxmc.GcStats.totalPause() - p0} s paused');
```

Sizes are the collector's: an 8-byte header, then 8-byte slots (an
`Array<Float>` of capacity n holds n * 8 + 8 bytes of storage; a `Vector`
of 1000 Floats is 8008 bytes). The counters and the records are always
kept, whether read or not: a few additions, three clock reads and a
record's four stores in a ring of 64 per collection, and a few more
instructions when a thread takes a new allocation buffer. With several
threads, `bytesAllocated` counts other threads' current allocation
buffers whole until the next collection. `RT_STATS=1` prints the totals at exit
on both targets.

### Null access

Reading or writing through null throws the String `"Null Access"`, which
`catch` catches as any exception. Uncaught, the program prints `Uncaught
exception: Null Access` and exits with 1. A call of a null Dynamic throws
`Cannot call null`. `Reflect.field(null, "x")` stays null.

Natively this costs nothing until it happens: the access faults and a
fault handler turns the fault into a throw. A fault that is not a null
access still kills the process. On WebAssembly each access is tested
instead.

## Known limitations

- **WebAssembly**: no threads (creating one throws), sockets or processes;
  `haxe.CallStack` is empty.
- **Reflection** sees only what the program can reach: a class it never
  constructs or uses as a value is not found by `Type.resolveClass`, and
  methods nothing calls are not in `Type.getInstanceFields`
  ([hxmc.md](hxmc.md#reachability)).
- **`Reflect.deleteField`** removes only fields added at run time, not a
  structure's own fields (as on cpp).
- **A dynamic method set to null** is its own method again when read.
- **Call stacks** show an inlined function's frame as its caller's.
  `-D hxmc.no-frame-pointers` on x86-64 leaves stacks empty.
- **`Std.string` of a structure** prints `{ a : 1, b : 2 }`, fields by
  name, then fields added at run time.
- **Debugging**: no variables in the debugger yet, no PDB on Windows.
- **Android and iOS**: no release or device signing yet.
