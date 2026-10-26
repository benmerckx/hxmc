# Using hxmc in depth

The short version is in the [README](../README.md). This covers the npm packages (what they hold, cross builds, how `haxe` finds the runtime objects), editors and lix, libraries from npm, and fast rebuilds.

## All options

| Option | |
| --- | --- |
| `-D hxmc.target=<target>` | `linux-x86_64`, `linux-arm64`, `windows-x86_64`, `windows-arm64`, `macos-x86_64`, `macos-arm64`, `android-arm64`, `android-x86_64` (an output ending in `.apk`: an APK, [hxmc.md](hxmc.md#android)), `ios-arm64`, `ios-sim-arm64` (an output ending in `.app` or `.ipa`: an app bundle, [hxmc.md](hxmc.md#ios)), `wasm32-wasi` (default: this machine) |
| `-D hxmc.libc=glibc` | Linux: an executable linked dynamically against the system's glibc (2.17 or later; the default is static with musl), which can import C functions of shared libraries (`@:hxmc.lib("libGL.so.1")`) and load them at run time (`hxmc.unsafe.Posix.dlopen`) |
| `-debug`, `-D hxmc.symbols` | a symbol table (profilers), wasm: a name section |
| `-D hxmc.shared`, `-D hxmc.exports=<names>` | a shared library exporting the named `@:hxmc.export` functions (Linux in the glibc mode; a Mach-O dylib on macOS and iOS; a DLL on Windows, `-D hxmc.dll-base=<hex>` its preferred base; Android's output always is one) |
| `-D hxmc.output=<path>` | the output, instead of `--custom-target`'s (`hxmc dev`: the iOS simulator's builds as dylibs) |
| `-D hxmc.pic` | a position-independent executable (refused: not written yet) |
| `-D hxmc.jobs=<n>` | parallel module compilations (default: the cores) |
| `-D hxmc.native-array-outofbounds=throws\|silent` | what a Vector (or `hxmc.NativeArray`) access out of bounds does: `throws` `haxe.exceptions.ArgumentException`, `silent` reads the default value (0, false, null) and writes nothing; not defined: not tested (the fastest; the result is unspecified, as Haxe leaves it). Also listed by `haxe --help-defines`. |
| `-D hxmc.wasm-eh=legacy` | wasm: the legacy exception-handling instructions (`try`/`catch_all`/`rethrow`: Chrome 95+, Firefox 100+, Safari 15.2+) instead of `exnref` (Chrome 137+, Firefox 131+, Safari 18.4+) |
| `HXMC_STATS=1` | what the build did and how long it took |
| `HXMC_CACHE=<dir>` | the cache directory (default `~/.cache/hxmc`, macOS `~/Library/Caches/hxmc`, Windows `%LOCALAPPDATA%\hxmc\cache`; "hxmc" below) |
| `HXMC_CACHE_SIZE=<bytes>[K\|M\|G]` | the most the module cache's store keeps (default `1G`; beyond it the least recently used goes, older builds of the tool first) |
| `HXMC_MODULE_CACHE=0`, `-D hxmc.no-module-cache` | no module cache: every build types its modules from source (the cache keeps typed modules between builds; see "Macros and the module cache") |

## The npm packages

One install: `npm i -D @hxmc/cli` (node 22+). It brings `haxe` and `hxmc`
(the same command): every Haxe target (js, hl, jvm, `--interp`, ...) and
`--custom-target hxmc=<out>` for this machine. Seven packages, all published
at one version:

| Package | Size (tarball, unpacked) | |
| --- | --- | --- |
| `@hxmc/cli` | 1.3 MB, 7.7 MB | what you install: the launcher (`haxe`, `hxmc`), upstream's std, hxmc's std, `dist/` for lix; optional dependencies on the six platform packages |
| `@hxmc/linux-x64`, `@hxmc/linux-arm64` | about 10 MB, 34–38 MB each | the native compiler for that machine and the runtime objects of its targets: `linux-<arch>/` (static, musl) and `linux-<arch>-glibc/` (`-D hxmc.libc=glibc`) |
| `@hxmc/darwin-x64`, `@hxmc/darwin-arm64` | about 8 MB, 26–28 MB each | the same for macOS: `macos-x86_64/`, `macos-arm64/` (also the iOS targets') |
| `@hxmc/win32-x64`, `@hxmc/win32-arm64` | about 8 MB, 26–28 MB each | the same for Windows: `windows-x86_64/`, `windows-arm64/` |

(Sizes of 0.1.0 as packed; CI's job summary lists each build's.) npm installs
the platform package that matches the machine (by their `os` and `cpu`
fields); a runtime-objects folder holds `rt.o`, `ssl.o` (mbedtls) and `uv.o`
(libuv). On a machine none of them fits, `haxe` prints one line naming the
machines it runs on and exits non-zero; so does an install without optional
dependencies, naming the package to add.

**Cross builds.** The runtime objects of a target come, in this order, from
this machine's platform package, from any other platform package of the same
version installed in the project, and from the directories `HXMC_RT_DIR`
lists. To build for another desktop machine, install its platform package
with `--force` (its `os` and `cpu` are not this machine's; its compiler goes
unused):

```sh
npm i -D @hxmc/cli
npm i -D --force @hxmc/win32-x64      # then: -D hxmc.target=windows-x86_64
```

A build for a target none of them has fails with one line naming the package
to install. Android's runtime objects (`android-arm64`, `android-x86_64`) are
in no npm package: take them from the runtime objects' release
(`rt-<hash>`, which `hxmc/bootstrap/rt.mjs fetch <dir>` downloads) or build
them from source (`make rt`, [development.md](development.md)), and name the
directory with `HXMC_RT_DIR` (a list, by the system's path separator).

## Without node

Without node: on Linux and macOS a postinstall script (best effort, offline,
it only writes inside the package) checks that the native compiler runs and
copies it over `hxmc/bootstrap/haxe` and `dist/haxe`, so
`node_modules/.bin/haxe` (a link to it) starts the compiler directly; with
install scripts disabled (`--ignore-scripts`, pnpm's default) the first call
through node does the same. A build for the hxmc target goes through node
all the same (the launcher finds the runtime objects); the other targets do
not. On Windows npm's `haxe.cmd` always starts node (about 40-60 ms per
call), which runs the native compiler; point editors and lix at
`node_modules/@hxmc/cli/dist/haxe.exe` to bypass it. Nothing but the
compiler's own output goes to stdout or stderr (editors run `haxe --wait
stdio`, whose answers are on stderr, and parse `haxe --version`), and a
failure prints one line and exits non-zero. `HXMC_INSTALL=0` keeps the
launcher in place.

## Changing the compiler

The compiler's sources and `hxmc-rebuild` (`packages/source`, `@hxmc/source`)
are not published for now: change the compiler in a checkout of this
repository ([development.md](development.md)).

## Libraries

Libraries: the compiler resolves `-lib <name>` (also `-L`, `--library`, and
in hxml files) itself, without a `haxelib` or lix process
(`hxmc/src/hxmc/libs`), from three places, as below: lix's scopes, npm
packages and haxelib's repositories. Within a lix scope it resolves as lix's
`haxe` shim would before calling the compiler; elsewhere as the compiler
does through `haxelib path`, node_modules first.

**lix's scopes.** The scope is the nearest `.haxerc` from the working
directory up (or the one `HAXESHIM_SCOPE` names), else lix's global one,
`$HAXESHIM_ROOT/.haxerc` (default `~/haxe`), when it exists; with neither,
there is none. Its `"resolveLibs"` (`scoped` by default, `mixed` for the
global scope) decides:

- `scoped`, `mixed`: `haxe_libraries/<name>.hxml` beside the `.haxerc`,
  read as lix reads it (one argument per line, a flag and its value split at
  the first space, `${VAR}` from the environment, `HAXE_LIBCACHE`,
  `SCOPE_DIR`, `CWD`, `__dirname`), with its `-lib` and hxml files
  resolved in turn, in the place of the `-lib`;
- `mixed`, `haxelib`: the others through haxelib (lix's root's
  `haxelib` repository), after the build's arguments;
- `scoped`: a library without its hxml is an error, unless node_modules has
  it.

Each library comes once per build (`--next` part), and a missing class path
of a library is an error, as with lix. The `"version"` is not looked at (the
compiler is the one running).

**npm packages.** A package is a library when its package.json has a
`"haxe"` field, `{"name": "mylib", "classPath": "src", "hxml":
"extraParams.hxml"}` (`hxml` optional); `-lib` takes that name or the
package's own (`-lib @scope/mylib`), and `-lib <name>:<version>` only that
version. It expands as haxelib's libraries do: the hxml's lines, the class
path, `-D <name>=<version>`, then its dependencies (the packages of its
`dependencies` and `peerDependencies` that have a `"haxe"` field), each
library once. The nearest `node_modules` holding it counts (from the working
directory up, as node looks): after a lix scope's hxml, before haxelib.

**haxelib.** What `haxelib path` answers (haxelib 4.2.0, the version upstream
ships): a `.haxelib` repository in the working directory or a parent, else
the global one (`HAXELIB_PATH`, `~/.haxelib`, ...); `name:version`, the
dev path or the current version; haxelib.json's class path and
dependencies, `extraParams.hxml`, `ndll/`; haxelib's messages.

The cpp generator's `haxelib path hxcpp` (`hxcpp=` in `Options.txt`) is
answered the same way: within a lix scope as lix's `haxelib` shim answers it
(from `haxe_libraries/hxcpp.hxml`), elsewhere as haxelib does. Running a
library (`haxelib run hxcpp`, `haxelib run hashlink`, the native builds)
still needs haxelib or lix.

All of it works without node (`node_modules/.bin/haxe` as the native
compiler) and without lix or haxelib installed. Run through lix's own `haxe`
shim (the `dist/` version below), the shim resolves the libraries before the
compiler sees them, the same way.

## Editors and lix

Editors and lix: vshaxe with `"haxe.executable": "auto"` (the default) runs
the workspace's `node_modules/.bin/haxe` when there is one (as for the lix
npm package; expected from vshaxe's documentation of `auto`, not verified in
an editor here); on Windows set it to `node_modules/@hxmc/cli/dist/haxe.exe`.
`dist/` (`packages/cli/dist` in this repository) is an installation lix
accepts as a path version (`dist/haxe`, `dist/std`, `dist/platform.txt`,
written on install or first use): `lix use haxe ./node_modules/@hxmc/cli/dist`, or `.haxerc` with
`{"version": "./node_modules/@hxmc/cli/dist", "resolveLibs": "scoped"}`; lix's
`haxe` shim then runs hxmc (checked with this repository's lix on Linux and
macOS in CI). With the lix npm package in the same project both packages
declare a `haxe` bin: npm reports nothing and `node_modules/.bin/haxe` is
whichever it linked last (both orders occur), so use lix's shim with the
`dist/` version there.

## Fast rebuilds

Fast rebuilds: the typed modules and the compiled objects of every build are
kept in the user cache directory (`HXMC_CACHE` overrides; only what changed
is typed and compiled again, and outputs share objects), and the compilation server keeps
typed modules, lowered bodies and compiled objects in memory:
`haxe --wait 6000`, then `haxe --connect 6000 build.hxml` (a no-change rebuild
of a small program in about 0.4 s). `haxe --dev build.hxml` does that for you,
watching the sources and running the new build on each save: [dev.md](dev.md).

### Macros and the module cache

A module restored from the cache does not run its macros again, so the
cache watches what they look at. A macro that reads the time or a random
number, starts a process or uses the network (`Date.now`, `Sys.time`,
`Math.random`, `Sys.command`, `sys.io.Process`, `sys.Http`, sockets) makes
the module it ran for typed again in every build; the modules that use it
stay cached unless it copied the result into them (an `inline` field, a
field without a written type). A file a macro reads (`sys.io.File`,
`FileSystem.exists`, `readDirectory`, `stat`) or an environment variable
(`Sys.getEnv`) is checked instead: the module is typed again when the
file's content or the variable's value changes. Where that is not enough
(a macro using state the cache cannot see, a file it writes),
`@:hxmc.noCache` on a class types its module every build,
`-D hxmc.no-cache=<package or library>` does so for a package or a library,
and `HXMC_MODULE_CACHE=0` turns the cache off. `HXMC_MODULE_CACHE_LOG=1`
prints why each module was typed again, for example
`Clock typed every build (macro called Date.now at src/Macros.hx:4)`. The
compilation server (`--wait`) keeps upstream's behaviour: its macros'
results last until their module changes.
