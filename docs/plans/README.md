# Plans

Open designs and decisions, by area. Each file lists open items only:
what, why, and the approach decided. What comes next and in which order:
[ROADMAP.md](../../ROADMAP.md). What is built: [docs/](../hxmc.md).

| | |
| --- | --- |
| [compiler.md](compiler.md) | the module cache, faster rebuilds, macro-heavy builds, Mir macros, code generation at run time |
| [runtime.md](runtime.md) | the collector, pauses, background work, system calls, TLS and the event loop |
| [io.md](io.md) | completion-based I/O (io_uring, IOCP): off-heap buffers, system calls, blocking calls |
| [heap-layout.md](heap-layout.md) | the object header, Bytes, strings and arrays |
| [codegen.md](codegen.md) | escape analysis, allocation folding, debugging information |
| [targets.md](targets.md) | WebAssembly, Android, iOS, Windows, Linux, macOS |
| [dev-loop.md](dev-loop.md) | the dev loop: faster reloads, snapshot hooks, Windows, iOS devices |
| [lowlevel.md](lowlevel.md) | C interop and low-level Haxe: native memory, manual memory, value enums |
| [packaging.md](packaging.md) | npm, haxelib, verified native builds |
| [math.md](math.md) | correctly rounded math |
| [haxe-versions.md](haxe-versions.md) | parked: any Haxe version per project |
