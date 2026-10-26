# Packaging and npm

Built: the npm packages, `-lib` from node_modules, lix, release binaries for
the six desktop targets: [docs/using.md](../using.md) and
[docs/development.md](../development.md). npm first, haxelib later.

## The npm packages (from 0.1.0)

- `@hxmc/cli`: the main install. `haxe` and `hxmc`, both `@hxmc/haxe`'s
  launcher; depends on `@hxmc/haxe` and `@hxmc/target` at its version.
- `@hxmc/haxe`: the port alone, usable without the hxmc target (js, hl,
  jvm, ...): the launcher, upstream's std, `dist/` for lix; optional
  dependencies on `@hxmc/haxe-<os>-<cpu>` (the six native compilers), and
  `@hxmc/haxe-wasm` downloaded on demand where none runs (its integrity
  pinned in `@hxmc/haxe`'s `package.json`).
- `@hxmc/target`: hxmc's std, and the integrity of each runtime-object
  tarball.
- `@hxmc/rt-<target>` (the ten directories of `bin/hxmc/rt`): the runtime
  objects of one target, without `os` or `cpu` fields, so any installs
  anywhere (cross builds). The launcher takes an installed one, else the
  cache's, else downloads it on the first build that needs it (never at
  install: CI and offline machines install the ones they need).

The runtime objects were in `@hxmc/cli` before (33 MB unpacked of all
targets, most of the package); now a project gets only its targets'. Not
published from 0.1.0: `@hxmc/source` (the compiler's sources and
`hxmc-rebuild`, kept in `packages/source`: the hackable compiler comes
later), and the nightlies' names `@hxmc/<os>-<cpu>` and `@hxmc/wasm`
(now `@hxmc/haxe-<os>-<cpu>` and `@hxmc/haxe-wasm`); their npm pages can
say so with `npm deprecate`.

## Open

- **Verifying the native build**: builds are deterministic (the port
  self-compiles to identical HXB, the tool rebuilds itself identically),
  so a compiler built on the user's machine (`hxmc-rebuild`, or the
  WebAssembly fallback building a native one) can be checked against a
  hash published with the package: stronger than trusting a downloaded
  binary.
- **First run**: the std's modules from the module cache, warmed at
  install ([compiler.md](compiler.md), "Cached modules").
- **The `hxmc` haxelib** (`-lib hxmc`, `--custom-target hxmc=out`,
  `-D hxmc.target=<os>-<arch>`), as hxc had one.
- **The source-only libraries** (`@hxmc/os`, `@hxmc/gfx`, `@hxmc/ui`, ...)
  left with universe (<https://github.com/benmerckx/universe>), which
  publishes them if it does; `publish-npm` here publishes the compiler's
  packages above only.
- **`@hxmc/esx` is superseded by `@hxmc/view`**: esx 0.1.0 was published
  with the UI toolkit; its markup and `hxmc.ui.reactive`'s signals are
  `@hxmc/view` now, and `@hxmc/ui` from 0.2.0 depends on that. The
  package is no longer in the repository and gets no new versions; its
  npm page can say so with `npm deprecate` when someone with the rights
  does it.
- **Using hxmc's built-in compiler**: HXB ties the user's Haxe version to
  hxmc's. hxmc contains the whole compiler port, so it (or the haxelib)
  can compile the user's sources itself; the "HXB from your own Haxe"
  path stays for display/IDE use.
- **User C libraries** would ship as per-target prebuilt objects linked by
  hxmc, as mbedtls and libuv do ([lowlevel.md](lowlevel.md), "Calls and
  linking").
