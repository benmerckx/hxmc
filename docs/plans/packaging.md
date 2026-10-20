# Packaging and npm

Built: the npm packages (`@hxmc/cli`, the six platform packages,
`@hxmc/wasm`, `@hxmc/source`), `-lib` from node_modules, lix, release binaries for the six
desktop targets: [docs/using.md](../using.md) and
[docs/development.md](../development.md). npm first, haxelib later.

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
  nine packages only.
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
