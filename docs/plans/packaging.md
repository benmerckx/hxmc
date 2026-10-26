# Packaging and npm

Built: the npm packages, `-lib` from node_modules, lix, release binaries for
the six desktop targets: [docs/using.md](../using.md) and
[docs/development.md](../development.md). npm first, haxelib later.

## The npm packages (from 0.1.0)

Seven packages, under the names the nightlies used:

- `@hxmc/cli`: the one install. The launcher (`haxe`, `hxmc`), upstream's
  std, hxmc's std, `dist/` for lix; optional dependencies on the six
  platform packages.
- `@hxmc/<os>-<cpu>` (linux-x64, linux-arm64, darwin-x64, darwin-arm64,
  win32-x64, win32-arm64): the native compiler of that machine and the
  runtime objects of its targets (Linux's with the glibc mode's), selected
  by npm through `os` and `cpu`.

The runtime objects of all targets were in `@hxmc/cli` before (most of the
package); now an install gets its machine's. A cross build installs the
other machine's platform package with `--force` (its compiler unused).
Android's runtime objects are in no package for now (the `rt-<hash>`
release, or a build from source, through `HXMC_RT_DIR`).

Not published from 0.1.0: `@hxmc/source` (the compiler's sources and
`hxmc-rebuild`, kept in `packages/source`: the hackable compiler comes
later), and `@hxmc/wasm` (the compiler as a WebAssembly module, the
fallback where no native compiler ran: gone with the launcher's path to
it); their npm pages can say so with `npm deprecate`.

## Open

- **Verifying the native build**: builds are deterministic (the port
  self-compiles to identical HXB, the tool rebuilds itself identically),
  so a compiler built on the user's machine (`hxmc-rebuild`) can be checked against a
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
