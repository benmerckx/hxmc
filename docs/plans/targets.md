# Plans: targets

Open work per target. What is built: [using.md](../using.md#targets) and
[hxmc.md](../hxmc.md#targets).

## WebAssembly

- **Threads**: shared memory, atomics and `memory.atomic.wait`, under
  wasi-threads or a browser's workers; the native stop-the-world handshake
  (`Threads.hx`) would come back. Until then creating a thread throws.
- **Sockets and processes** need WASI preview 2 or JavaScript imports.
- **Size and startup**: a small canvas app is about 1.8 MB of wasm. First
  link-time DCE ([compiler.md](compiler.md#faster-rebuilds)), then code
  splitting into lazily loaded modules; measure time to first frame on a
  mid-range phone.
- **Speed**: no tail calls yet. About 485k `i32.wrap_i64` remain in the
  playground's module, of i64 values also used in full; an i32 local for
  those, or an i32 pointer type in Mir, would remove most.
- **Firefox's throws** walk the whole stack (0.17 µs per frame): lighter use
  of exceptions in the port's hot paths, or setjmp-free try blocks.

### WasmGC

Built behind `-D hxmc.wasm-gc`, generated from the same object-level Mir as
native code. **The call: not yet the browser default.** Linear memory
stays for WASI, the compiler modules, threads, and engines without WasmGC.

Current numbers (HaxeBenchmarks under node 22, seconds, medians of 5):

| | WasmGC | linear |
| --- | --- | --- |
| alloc | 2.78 | 1.82 |
| formatter_noio | 11.13 | 8.42 |
| json | 0.94 | 0.91 |
| mandelbrot_anon | 0.72 | 1.48 |
| the port's module, gzip -9 | 3.19 MB | |

WasmGC wins on module size and scalar-heavy code and loses where much is
allocated (the engine's collector, casts of untyped values). A large
compiler (tsc-haxe) is 15-22% slower and uses 18-25% more memory.
Before revisiting:

1. Startup of large modules: string literals made lazily, Meta's tables
   only when reflection is used, the dispatch table overlaid; then measure
   the first frame again (the UI examples' was up to 72% later in
   Chromium).
2. WebKit: profile frames (60% slower in the gallery) and reproduce an
   unexplained trap.
3. Smaller gzipped modules: fewer casts, the strings' encoding.
4. The allocation-heavy benchmarks: the casts untyped locals cost.

Switch browser builds when the first frame and WebKit hold, keeping linear
memory as the fallback.

## Android

Built: NativeActivity apps and Java glue. Left:

- several ABIs in one APK;
- release signing with the developer's keystore (PKCS#12, v3 for key
  rotation);
- icons and a `resources.arsc`;
- `.aab` bundles for Google Play (protobuf manifest and resources);
- `DT_RELR` or packed relocations to shrink the RELATIVE table; RELRO for
  data that holds addresses.

## iOS

Built: simulator and device bundles, ad hoc signed. Left:

- **Device signing**: a CMS signature by the developer's certificate (RSA
  or P-256; `P256.hx` has the curve), the provisioning profile as
  `embedded.mobileprovision`, its entitlements (also as DER), the
  designated requirement, the team id. `CodeSign.Identity` is the API,
  filled from a PKCS#12 export and a downloaded profile. Install with
  libimobiledevice or `xcrun devicectl`.
- **Icons**: an asset catalog (`Assets.car`, undocumented); plain PNGs in
  `CFBundleIcons` meanwhile. `PkgInfo`, a binary `Info.plist`.
- **UIScene** (required after iOS 26) and `os_log` for output on a device.
- **App Store checks**: the declared SDK and Xcode (`DT*` keys),
  `LC_ENCRYPTION_INFO_64`, and the main stack's 1 GB reservation (iOS
  limits address space).
- `ios-sim-x86_64` is left out: it needs `objc_msgSend_stret`.

## Windows

- **A GUI subsystem**: `-D hxmc.subsystem=windows` writes subsystem 2 in the
  PE header, so a GUI app opens no console; launched from a terminal, the
  program attaches to the parent console so `trace` still prints.
- **The dev loop's first edit is a cold build**:
  [dev-loop.md](dev-loop.md#windows-first-edit).

## Linux

- A dynamic musl mode (`/lib/ld-musl-<arch>.so.1`) beside the glibc mode.
- Choosing the glibc mode automatically when a program imports a shared
  library (today a compile error names the mode).
- Lazy binding (PLT) if startup with many imports needs it.
- Direct system calls: [runtime.md](runtime.md#direct-system-calls-on-linux).

## macOS

- Split the runtime's Mach-O objects per function so unused runtime code is
  dropped, as on ELF; today they are linked whole (`ssl.o` is 0.8-0.9 MB).
- x86-64 Objective-C calls returning structs over 16 bytes
  (`objc_msgSend_stret`), which a Metal back end needs.
