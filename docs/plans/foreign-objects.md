# Plans: foreign objects

Reference-counted objects of other object systems held by Haxe objects:
Objective-C's (built: [interop.md](../interop.md#memory),
[objc.md](objc.md)), COM's (built: [interop.md](../interop.md#com),
[com.md](com.md)), JNI's and GObject's (next). What does not depend
on the system is the runtime's `hxmc.rt.Foreign`; a system is a **kind**, a
row of the kind table: its hooks (C functions) and its flags. The collector
names no kind: it calls `Foreign.scan` (roots) and `Foreign.sweep` (after a
collection), which read the table. Objective-C (`hxmc.rt.ObjCKind`) is the
first kind; `hxmc.foreign.ForeignKind` registers others from Haxe (a
runtime client, a test: `ForeignKinds`, three kinds over a small
reference-counted C object system).

## What the runtime does for every kind

- **Peers and toggle references.** A Haxe object paired with a foreign
  object (a Haxe class extending a foreign class) is an entry of the peers
  table: (object, reference, weak cell, kind, maker thread). The Haxe
  object's first slot holds the reference its pairing made. As Xamarin's
  toggle references, the entry is a GC root exactly while the foreign side
  retains the object beyond that reference (the kind's toggle, below), and
  weak otherwise: its Haxe object found dead, the reference is released and
  the entry freed. Entry 0 is never used: an index of 0 in the foreign
  object means the foreign side made it and its Haxe object is not made yet
  (Objective-C's initializers, `FnLower.objcAdopt`).
- **Detach.** The Haxe object gives up its reference at once; the entry
  stays a root while the foreign object lives (tracked by a weak cell of the
  kind's), and is freed with the Haxe object without a release. A box gives
  up its reference at once and becomes a tombstone, so the object boxed
  again gets a box of its own.
- **One box per object.** A foreign reference where a Haxe reference goes
  (`Dynamic`, an element, a type parameter) is its peer's Haxe object, else
  its one box: a native handle holding a reference, found by the kind's
  identity key (and `same` test), so `==` and maps see one object while it
  lives.
- **Owned, weak and unowned fields.** A field holding a reference (a
  class's, a closure's capture, a captured variable's box) is an entry
  (object, offset), released once its holder dies. A weak field holds a
  cell outside the heap (the kind's weak variable: a field moves with its
  object), destroyed with its holder. An unowned field holds the reference
  only, with no entry and no hook: nothing happens when its holder dies.
- **Finalisers.** `Gc.finalise`'s semantics: run once a major collection
  finds the value unreachable (from both sides, for a peer: a root's value
  is reachable), newest first among values found dead together, at the next
  allocation slow path or `NativeGc.runFinalisers` of whichever thread gets
  there. The value lives on for the call, so a peer's reference is released
  by the next collection that finds it dead (Objective-C's `dealloc`
  override runs this way, then Objective-C's own).
- **Releases put off.** Every release, weak cell destroyed and native
  destructor the collector causes happens with the world stopped only for a
  kind that says it may (`RELEASE_IN_STOP`, inside the kind's batch). Any
  other kind's is queued: (function, a, b, kind, thread), run in a safe
  region inside the kind's batch, newest first, by the thread the kind
  chooses, at its next allocation slow path, when `Gc.collect` returns, from
  `ForeignKind.runDeferred` (an event loop's), or as the thread ends. A
  native destructor that runs Haxe code puts itself off the same way
  (`Foreign.deferHere`: Objective-C mode classes' `dealloc`s).
- **Pressure.** A peer or a box promoted to the old space keeps its
  foreign object (memory the heap does not see) until a major collection;
  `RT_PEER_BUDGET` (1000; 0: off) of them since the last one start the next.

## The kind's hooks

A kind is a C struct of words (`Foreign.K_*`), copied when registered
(`Foreign.register(d)`, `ForeignKind.register(hooks)`; up to 63 kinds,
indices from 1). Null means none.

| Word | Signature | Called |
| --- | --- | --- |
| `name` (0) | `const char *` | reports |
| `flags` (8) | `int64_t` | the flags below |
| `threshold` (16) | `int64_t` | `TOGGLE_COUNT`, `TOGGLE_RELEASE`: a count above it keeps the Haxe object |
| `retain` (24) | `void *retain(void *ref)` | +1; returns the reference to store (`ref`, or a new handle: JNI's `NewGlobalRef`) |
| `release` (32) | `intptr_t release(void *ref)` | -1; returns the count left (read by `TOGGLE_RELEASE` only) |
| `count` (40) | `intptr_t count(void *ref)` | the count now (`TOGGLE_COUNT`) |
| `identity` (48) | `void *identity(void *ref)` | the key of the object's box (null: `ref`); borrowed |
| `same` (56) | `intptr_t same(void *a, void *b)` | whether two references with one key are one object (null: one key is one object) |
| `peer` (64) | `intptr_t peer(void *ref)` | the peers' entry the object names (-1: none, 0: not made yet) |
| `weak_init` (72) | `void weak_init(void **cell, void *ref)` | a weak cell made to refer to `ref` |
| `weak_load` (80) | `void *weak_load(void **cell)` | +1, or null once the object is gone |
| `weak_destroy` (88) | `void weak_destroy(void **cell)` | the cell given back |
| `batch_begin` (96) | `void *batch_begin(void)` | before a batch of releases (the sweeps', a put-off call's, detach's) |
| `batch_end` (104) | `void batch_end(void *token)` | after it |
| `wake` (112) | `void wake(intptr_t thread)` | a collection queued calls for that thread (a runtime thread id; 1 the main one) |

| Flag | |
| --- | --- |
| `TOGGLE_COUNT` (1) | the toggle: `count(ref) > threshold` |
| `TOGGLE_RELEASE` (2) | the toggle: `release(retain(ref)) > threshold`, for a system whose only counts are its release's results |
| `TOGGLE_NOTIFY` (4) | the toggle: what the system's notification last said (`Foreign.toggle(entry, strong)`, any thread, any state) |
| (none of the three) | never kept by the foreign side: a peer lives while Haxe references it |
| `RELEASE_IN_STOP` (8) | releases with the world stopped, by the collecting thread (else put off) |
| `RELEASE_ON_MAKER` (16) | put-off calls run on the thread that made the reference |
| `RELEASE_ON_MAIN` (32) | put-off calls run on the main thread (else: on any thread) |

The runtime's entry points (`hxmc.rt.Foreign`; `ForeignKind` wraps them):
`register(d):Int`, `pair(k, o, ref, typed):Int`, `peerGet(i)`,
`toggle(i, strong)`, `box(k, ref)`, `unbox(o)`, `refOf(k, v)`,
`own(k, o, offset)`, `ownWeak(k, o, offset)`, `weakCell()`, `detach(k, o)`,
`deferHere(k, f, a, b):Bool`, `runDeferred()`. Generated code reaches
Objective-C's through `rt_objc_*` exports (`ObjCKind`); a later kind's
lowering gets `rt_foreign_*` exports with its first caller (each in
`RuntimeSymbols`).

## Threading rules

- **With the world stopped** (the collecting thread, every other thread at
  a safepoint or in a safe region, the world lock held): the toggle's hooks
  (`count`; `retain` and `release` for `TOGGLE_RELEASE`), `weak_load` of
  detached peers (and the `release` of what it returned, put off unless
  `RELEASE_IN_STOP`), and for a `RELEASE_IN_STOP` kind `release`,
  `weak_destroy`, `batch_begin` and `batch_end`. These must not call Haxe
  code, allocate on the heap, start threads, or block on a lock a stopped
  thread may hold. A retain racing the scan on another thread (one in a
  safe region, inside the system) is seen at the next collection: a
  toggle's inherent race, Xamarin's too.
- **Out of the stop**: `identity`, `same` and `peer` (boxing, `refOf`,
  `detach`, from Haxe code on any runtime thread), `weak_init`, and every
  put-off call. `detach` releases on the calling thread unless the kind
  wants another one (then it is put off for it).
- **Put-off calls** run in a safe region, inside the kind's batch, so they
  may call into the system and back into Haxe (a callback leaves the
  region). A thread runs the calls for itself and for any thread; a thread
  that ends runs its own first, and what is queued for it later goes to any
  thread. A thread that blocks in an event loop and never allocates runs
  them only when told: the kind's `wake` (called by the collecting thread
  once the world resumed; it must not block or call Haxe) posts to that
  loop, which calls `ForeignKind.runDeferred`.
- **Native destructors** a release runs (with the world stopped, or in
  Haxe code outside a safe region: `detach`) that would run Haxe code call
  `deferHere`, which queues them for the calling thread (false when it may
  run now: in a safe region, or on a thread the runtime does not know).

## The systems

| | Objective-C (built) | COM (built) | GObject | JNI |
| --- | --- | --- | --- | --- |
| retain | `objc_retain` | `AddRef` (vtable slot 1) through a hook returning `ref` (`ComKind.retain`) | `g_object_ref` | `NewGlobalRef` (a new handle) |
| release | `objc_release` | `Release` (slot 2; returns the count): a foreign object's in a safe region | `g_object_unref`; a peer's: `g_object_remove_toggle_ref` | `DeleteGlobalRef` |
| toggle | `TOGGLE_COUNT`, `_objc_rootRetainCount > 1` | `TOGGLE_RELEASE` (IUnknown has no count query), threshold 1: a peer is a Haxe object implementing COM interfaces, whose COM object (the runtime's block) keeps its count in the runtime's memory, so the toggle's AddRef and Release are the runtime's own functions | `TOGGLE_NOTIFY`: `g_object_add_toggle_ref`'s notify calls `toggle(entry, !is_last_ref)` | none: the JVM has no counts (below) |
| identity | the id | `QueryInterface(IID_IUnknown)`, then `Release`: the canonical `IUnknown*`, stable while held | the pointer | `System.identityHashCode` as the key, `same`: `IsSameObject` |
| peer | the instance variable `hxmc_peer` | a word of the runtime's own COM object (its block: a vtable whose QueryInterface is the runtime's) | a `GQuark`'s qdata | a `long` field of the Java peer class (`GetLongField`) |
| weak | `objc_initWeak`, `objc_loadWeakRetained`, `objc_destroyWeak` | WinRT's `IWeakReferenceSource::GetWeakReference`, `IWeakReference::Resolve`, `Release`; classic COM: none (no detach of peers, no weak fields) | `g_weak_ref_init`, `g_weak_ref_get`, `g_weak_ref_clear` | `NewWeakGlobalRef`, `NewGlobalRef` of it (null once collected), `DeleteWeakGlobalRef` |
| batch | an autorelease pool | none | none | `GetEnv` or `AttachCurrentThread`, then `PushLocalFrame`/`PopLocalFrame` |
| releases | `RELEASE_IN_STOP` (libobjc's release runs no Haxe code; mode classes' deallocs put themselves off) | put off; `RELEASE_ON_MAKER` for apartment-threaded objects | put off; `RELEASE_ON_MAIN` for GTK's | put off, any thread |
| wake | none | `PostThreadMessage` to the apartment's thread, whose message loop calls `runDeferred` | `g_main_context_invoke` on the default context | none |

**Shared**: the tables, the toggle's three forms, detach, boxes by key,
owned and weak fields, the queue of put-off calls and its thread rules,
pressure, the sweeps' order (native handles newest first, then peers in
entry order, then owned fields in registration order).

**What each still needs**:

- **COM** (built: `hxmc.rt.ComKind`, [com.md](com.md)): boxes are per
  interface pointer (identity the canonical IUnknown, `same` the pointer);
  peers are Haxe objects implementing interfaces, paired at their first
  use as a pointer (`Foreign.pair`, untyped: the block is found from the
  object by its class's descriptor, not by its first slot). Threads:
  `CoInitializeEx` is the program's (`Com.init`, every thread making
  calls); an STA object's `Release` runs on its apartment's thread
  (`RELEASE_ON_MAKER`, woken by `PostThreadMessageW`); an ended
  apartment's queued calls run on any thread (its proxies were
  disconnected by `CoUninitialize`, their `Release` is local). Generated
  code reaches it through `rt_com_*` and `rt_foreign_attach`. No weak
  hooks: classic COM has no weak references (WinRT's: com.md).
- **GObject**: a peer's reference is a toggle reference, released with
  `g_object_remove_toggle_ref` (notify and data), not `g_object_unref`: a
  hook for a peer's release (`unpair`, null: `release`). Finalisers that
  touch GTK run in the main context (`RELEASE_ON_MAIN`, `wake`).
- **JNI** (PR 3): no counts, so no toggle. A peer is collected when Haxe
  drops it, which breaks a Java object that still calls into its Haxe peer;
  the fix is Xamarin.Android's bridge: before a collection, the peers
  unreachable from Haxe's roots get weak global references in place of their
  global ones, the JVM collects, and those still alive are made strong again
  and kept as roots. That is a phase before the stop, on a thread attached
  to the JVM (a `bridge` hook), not a hook in it. Local references are
  borrowed values valid in their frame: Haxe code on a thread the runtime
  started needs frames popped regularly (an autorelease pool's analogue
  around loops); calls Java makes get the JVM's frame. A `JNIEnv` per
  thread: every hook calls `GetEnv` (or attaches) first.

## Not on WebAssembly

The wasm32-wasi runtime (`wasm/Gc.hx`) has none of this: one thread, no
native handles' free functions, and no reference-counted objects: a host's
objects reach a module as handles whose lifetime is the host's collector
(JavaScript's `FinalizationRegistry` on its side). The kind table is the
native runtime's; `ForeignKinds` is excluded there.

## Open

- **Release on death by layout** (objc.md, open item 4): an entry per
  object rather than per field, for every kind.
- **The hooks for GObject's peers and JNI's bridge** above.
- **Kinds' statistics** (`RT_STATS`): pairs, boxes and put-off calls per
  kind.
