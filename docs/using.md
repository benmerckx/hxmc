# Using hxmc in depth

The short version is in the [README](../README.md). This covers the npm packages (which to install, how `haxe` picks a compiler and finds the runtime objects), editors and lix, libraries from npm, and fast rebuilds.

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

Which package to install:

| You want | Install | You get |
| --- | --- | --- |
| Haxe with hxmc: native executables | `npm i -D @hxmc/cli` | `haxe` and `hxmc` (the same command): every Haxe target, and `--custom-target hxmc=<out>` for this machine; the runtime objects of a target are downloaded on the first build for it |
| The same, offline or in CI, or cross builds without a download | `npm i -D @hxmc/cli @hxmc/rt-<target> ...` | the runtime objects of those targets installed with it (for example `@hxmc/rt-windows-x86_64` on a Linux machine) |
| The Haxe compiler alone (js, hl, jvm, `--interp`, ...) | `npm i -D @hxmc/haxe` | `haxe`; a build for the hxmc target says to install `@hxmc/cli` (or `@hxmc/target` beside it) |

The packages, all published at one version:

| Package | Size (tarball, unpacked) | |
| --- | --- | --- |
| `@hxmc/cli` | 11 KB, 29 KB | the main install: the commands `haxe` and `hxmc`, which run `@hxmc/haxe`'s launcher; depends on `@hxmc/haxe` and `@hxmc/target` |
| `@hxmc/haxe` | 1.0 MB, 6.3 MB | the port alone: the `haxe` launcher, upstream's std, `dist/` for lix; optional dependencies on the six platform packages |
| `@hxmc/haxe-linux-x64`, `@hxmc/haxe-linux-arm64`, `@hxmc/haxe-darwin-x64`, `@hxmc/haxe-darwin-arm64`, `@hxmc/haxe-win32-x64`, `@hxmc/haxe-win32-arm64` | 7.3-7.9 MB, 24-28 MB each | the native compiler built by CI for one platform (npm installs the one that matches, by their `os` and `cpu` fields) |
| `@hxmc/haxe-wasm` | 4.0 MB, 20 MB | the compiler as a wasm32-wasi module, with its WASI runner for node: the fallback where no native compiler runs |
| `@hxmc/target` | 0.3 MB, 1.4 MB | hxmc's std (the target's runtime and std, in Haxe), and the integrity hashes of the runtime objects' tarballs |
| `@hxmc/rt-<target>`: `linux-x86_64`, `linux-x86_64-glibc`, `linux-arm64`, `linux-arm64-glibc`, `macos-x86_64`, `macos-arm64`, `windows-x86_64`, `windows-arm64`, `android-arm64`, `android-x86_64` | 0.3-1.5 MB, 1.0-6.3 MB each | the runtime objects of one target (`<target>/rt.o`, `ssl.o` with mbedtls, `uv.o` with libuv), named as `-D hxmc.target` names it (`-glibc`: `-D hxmc.libc=glibc`; the iOS targets use `macos-arm64`'s); no `os` or `cpu` field, so any of them installs on any machine |

(Sizes of 0.1.0 as packed; CI's job summary lists each build's.)

`haxe` runs the platform package's native compiler; else, when there is none
or it cannot start here (an unsupported machine, an install without optional
dependencies, a noexec file system, StackBlitz's WebContainers;
`HXMC_PLATFORM_PACKAGE=0` and `HXMC_NATIVE=0` force this path), the compiler
as a WebAssembly module under node: `@hxmc/haxe-wasm` when it is installed
(`npm i -D @hxmc/cli @hxmc/haxe-wasm` where no native compiler can run), else
downloaded on first use.

hxmc's std comes from `@hxmc/target`, found beside `@hxmc/haxe` (or in the
project's `node_modules`) at the same version. The runtime objects of a
target come, in this order, from an installed `@hxmc/rt-<target>` of the same
version, from the cache (`hxmc/npm/<version>/rt-<target>/`), else from a
download on the first build that needs them: never at install, so CI and
offline machines can install the runtime-object packages they need instead.
`haxe` finds the targets a build needs from its arguments and the hxml files
they name (`--custom-target hxmc`, `-D hxmc.target=`, `-D hxmc.libc=glibc`);
a target set elsewhere (a library's `extraParams.hxml`) is not downloaded,
and the build says which package to install.

Both downloads are the package's tarball of the same version from the npm
registry (`npm_config_registry`, which npm and npx set, else the `registry` of
an `.npmrc`, else registry.npmjs.org), checked against the integrity hash
pinned when the packages were packed (`@hxmc/haxe-wasm`'s in `@hxmc/haxe`'s
`package.json`, the runtime objects' in `@hxmc/target`'s), and unpacked into
the cache (`hxmc/npm/<version>/`); offline, `haxe` prints one line saying so
and exits non-zero. The cache is the user's (`HXMC_CACHE` above; "hxmc").
`HXMC_WASM_TARBALL` (a path or URL) and `HXMC_RT_TARBALLS` (a directory or URL
holding `npm pack`'s files, `hxmc-rt-<target>-<version>.tgz`) replace the
registry (CI's tests).

For offline or cross builds, install the runtime objects with the project:

```sh
npm i -D @hxmc/cli @hxmc/rt-linux-x86_64 @hxmc/rt-windows-x86_64 @hxmc/rt-android-arm64
```

## Without node

Without node: on Linux and macOS a postinstall script of `@hxmc/haxe` (best
effort, offline, it only writes inside the package) checks that the native
compiler runs and copies it over `hxmc/bootstrap/haxe` and `dist/haxe`, so
`node_modules/@hxmc/haxe/hxmc/bootstrap/haxe` (and `node_modules/.bin/haxe`
when it links that one: an install of `@hxmc/haxe` itself) starts the compiler
directly; with install scripts disabled (`--ignore-scripts`, pnpm's default)
the first call through node does the same. `@hxmc/cli`'s `haxe` and `hxmc`
start node, which runs the native compiler, as npm's `haxe.cmd` does on
Windows (about 40-60 ms per call); point editors and lix at
`node_modules/@hxmc/haxe/dist/haxe` (Windows: `dist/haxe.exe`) to bypass it.
Run that way, a build for the hxmc target goes through node all the same
(the launcher finds hxmc's std and the runtime objects); the other targets do
not. Nothing but the compiler's own output goes to stdout or stderr (editors
run `haxe --wait stdio`, whose answers are on stderr, and parse `haxe
--version`); notices (the WebAssembly fallback, a download) go to an
interactive terminal only, and a failure prints one line and exits non-zero.
`HXMC_INSTALL=0` keeps the launcher in place.

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
an editor here); on Windows set it to `node_modules/@hxmc/haxe/dist/haxe.exe`.
`dist/` (`packages/haxe/dist` in this repository) is an installation lix
accepts as a path version (`dist/haxe`, `dist/std`, `dist/platform.txt`,
written on install or first use): `lix use haxe ./node_modules/@hxmc/haxe/dist`, or `.haxerc` with
`{"version": "./node_modules/@hxmc/haxe/dist", "resolveLibs": "scoped"}`; lix's
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
