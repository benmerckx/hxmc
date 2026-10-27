# Plans: low-level Haxe and C interop

Open work on C interop, native memory and an opt-in manual-memory dialect.
What is built (externs on every ABI, structs by value, `Arena`, struct
values, `@:hxmc.unsafe`): [interop.md](../interop.md). These APIs are
hxmc-only by design.

The design has three layers:

1. **C interop**: declared signatures called directly (built).
2. **Native memory with lifetimes**, after Java's FFM API: arenas,
   bounds-checked segments, pinning and handles for the moving collector.
3. **Manual memory**, after Zig: an `Allocator` interface, containers over
   it, and `@:hxmc.unsafe` as a checked boundary.

## Declarations from C

Externs are written by hand today. Next:

- **A C declaration parser** in Haxe, used from a macro: pasted
  declarations (`int SDL_Init(Uint32 flags);`, structs, enums, typedefs,
  function pointers) become externs, LuaJIT-style. No preprocessor, no
  libclang.
- **A header generator** run at development time over preprocessed headers
  (`zig cc -E`), its output checked in.
- **Optional embedded tcc** at build time, for `static inline` functions,
  function-like macros and small C glue. Inline C and C++ stay out of
  scope.
- **User C libraries** ship as per-target prebuilt objects linked by hxmc,
  as mbedtls and libuv do.

## Native memory

The collector moves objects, so C must never keep a pointer into the GC
heap without the runtime knowing.

```haxe
// Arena.scoped(a -> ...)  built: freed when the function returns or throws
// Arena.auto()            freed by the GC once unreachable (a finalizer)
// Arena.global            never freed
// Segment<T>              a bounds-checked view of arena memory, tied to its arena

pixels.pin(p -> SDL.updateTexture(tex, null, p, w * 4));   // in place for one call
var h = Handle.of(app);                                    // a stable token C keeps
SDL.addEventWatch(onEvent, h.ptr());
h.release();
```

- **`pin`** keeps a GC object in place for a scoped call. A copying
  collector needs a non-moving space for it. `@:hxmc.fast` calls cover the
  short cases meanwhile; I/O that outlives a call uses off-heap buffers
  (`IoBuffer`), and pinning is rejected for it ([io.md](io.md)).
- **`Handle`** gives C a stable token; `Handle.get` looks the object up.
- **Segments** check that their arena is open (an epoch compare) and their
  bounds; release builds may drop the checks.
- **Thread attach**: a public entry point for threads C creates.

## Manual memory

An opt-in dialect: no GC allocation, explicit allocators, values and
pointers only. Arenas are one kind of allocator, so C interop and
low-level Haxe share one memory model.

```haxe
interface Allocator {
  function alloc(bytes:Int, align:Int):Ptr<UInt8>;
  function resize(p:Ptr<UInt8>, old:Int, bytes:Int):Bool;
  function free(p:Ptr<UInt8>, bytes:Int):Void;
}
// Arena, FixedBuffer, Pool<T>, Malloc, Debug (finds leaks, double frees, use after free)

@:hxmc.unsafe function step(alloc:Allocator, ps:Slice<Particle>, dt:Float32):Slice<Particle> {
  var alive = new ArrayList<Particle>(alloc);
  for (p in ps) { p.x += p.vx * dt; if (p.y < 1000) alive.push(p); }
  return alive.toOwnedSlice();
}
```

- Allocators are passed explicitly, as in Zig, with `Malloc.instance` as an
  optional default.
- GC code calls manual code freely; manual code reaches GC objects only
  through `Handle.get` and `pin`.
- No borrow checker: use after free and leaks are possible. The `Debug`
  allocator, segment checks and bounds checks mitigate it. Go's stalled
  arena experiment is why these are part of the design.

What it needs from the compiler:

- **Instance methods on structs** (an abstract over the struct carries
  them today).
- **Generics specialized for structs** (`ArrayList<Particle>` storing
  values), starting from `@:generic`. Today a struct in a generic container
  is boxed: an allocation per element.
- **`@:hxmc.unsafe` as a documented, complete public rule** (it is
  checked for the runtime already).
- **GC references inside structs**, and struct locals captured by
  closures.

## Struct values in generic storage

A struct value stored where the type is not the struct is boxed: 32 B
for three Floats on every store ([hxmc.md](../hxmc.md#where-struct-values-are-boxed)).
Two cases are common enough in numeric code to remove.

**`Array<S>` storing values.** Structs hold no GC references, so their
elements can live in storage without references: a new element kind,
`AK_STRUCT`, whose storage is a byte NativeArray of `n * size` bytes, the
struct's type index kept in the array's kind word (beside the kind) for
the runtime.

- The lowering of an `Array<S>` (S known): `a[i]` is the address
  `data + i * size` (a read copies out, as a struct field's does; `a[i].x
  = 1` can then write in place), `a[i] = v` and `push` copy in, growth as
  for the other kinds (`hx_arr_grow` with the element size).
- The runtime's natives over any kind (`Arr`, `MemRepr`: copy, concat,
  slice, splice, reverse, `arrRotate` for sort, insert, resize) already go
  through `elemSize`; it learns the struct's size. `indexOf` and `==`
  compare field by field; `Std.string` and `join` box each element to
  print it.
- Seen as `Array<Dynamic>` or through a type parameter: a read boxes a copy
  (the type index gives the box's type); a store of a value that is not an
  `S` converts the storage to references (boxes), as an Int array takes a
  Float today.
- `[for ...]` literals and `NativeArray.literal` make the kind directly;
  `Array<Null<S>>` stays boxed. WasmGC keeps boxes (a struct value is an
  object there).
- Cost: a kind in every generic array path of the runtime, the lowering of
  element access, the corpus' kind conversions; the port is unaffected
  (it has no struct values).

**`Null<S>` as a nullable address.** A struct value is already the address
of its memory; `Null<S>` can be that address or 0, so an optional
argument `?s:S` and a `Null<S>` result need no box:

- An argument: the caller passes the address of its copy, or 0 for `null`
  or a missing argument (the defaults' entry, `__dflt`, likewise). The
  callee copies it into its frame when it writes it.
- A result: the caller passes the sret memory as for `S`; the callee
  returns that address, or 0. A `Null<S>` local is a frame slot and an
  address (0 or the slot).
- Boxing moves to where a reference is really needed: `Null<S>` to
  `Dynamic` boxes a non-zero address; `Dynamic` to `Null<S>` copies the
  box's struct into a frame slot (a box can move: its address is never
  kept).
- To change: `Lower.ty` of `Null<S>`, call and return lowering, the closure
  adapters and dynamic calls between `Null<S>` and `Dynamic` signatures,
  interface and override signatures that mix them, and the Mir
  interpreter's calls. One representation covers both arguments and
  results; a presence flag beside a copied value would cost a second
  argument and a second result register for the same.

## Value enums

Haxe enum values are immutable, so an enum can opt into a value
representation, as Zig's tagged unions:

```haxe
@:hxmc.value enum Shape { Circle(r:Float32); Rect(w:Float32, h:Float32); }
```

Stored as a tag plus room for the largest payload: inline in structs and
slices, never allocated. `switch` and exhaustiveness work unchanged.
Restrictions: no identity comparison, never `null`, no direct
self-recursion, payloads of value types only; conversion to `Dynamic`
boxes.

## Smaller items

- `defer` as a macro (`@:defer expr`: cleanup on every exit).
- Distinct pointer abstracts: `ConstPtr<T>`.
- `@:hxmc.union` structs with overlapping fields, for C unions.
- SIMD intrinsics.
