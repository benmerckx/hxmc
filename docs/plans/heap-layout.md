# Heap layout: one header per type

A proof of concept on the branch `array-over-nativearray` (linear memory:
native targets and wasm32; WasmGC has the engine's objects and is not
affected). The object header's meaning is decided by the type index, so that
variable-size objects carry their exact length in the header and fixed-size
ones a wider identity hash; it is what lets an Array's storage be a
NativeArray, and a Bytes a NativeArray of bytes, at no cost in memory
(benmerckx/hxmc#21, "Can/should NativeArray back Array?").

## From first principles

What the runtime needs to know about an object, and who asks:

- its **type**: type tests, inline caches, virtual dispatch, the enum tag,
  reflection; the collector, to scan it. Everyone, at a fixed place.
- its **size**: only the collector, when it copies an object or walks copies
  (both collectors copy: the nursery into the old space, the old space into a
  new region or new chunks; nothing is freed object by object). For a record
  the type fixes it; for an array it is its length times its element size.
- its **identity hash**, for objects used as ObjectMap keys: in the object,
  because a copying collector moves it.
- for an **array**, its exact length; for a **string**, also its content
  hash (StringMap, string switches, field ids), cached.

HashLink, the runtime made for Haxe (`hl.h`), answers differently because its
collector does not move objects: an object is its type's pointer (8 bytes)
and its fields; the allocator's pages know sizes and whether to scan; the
identity hash is the address. A NativeArray (`varray`) is `{type, element
type, size, pad}` before its elements (24 bytes); a String is a class
`{bytes, length}` over a second allocation, with no cached hash; Arrays are
Haxe classes over native storage (`ArrayObj {NativeArray<Dynamic>, length}`,
`ArrayBytes<T> {bytes, size, length}` per element type, `ArrayDyn` for
Dynamic views). Our copying collector needs size and hash in the object, so
the question is how to fit them.

The uniform header we had, from the first C runtime (`rt.h`), was
`[hash:16][type:16][kind:4][slots:28]`: the same fields for every object,
whatever it needs. A slot count is too coarse for a length (2 Ints, 8 Bools
per slot), so NativeArray, String and Bytes each carried a length word of
their own, and the GC kind restated what the type says. Arrays over
NativeArrays with that header (built first on this branch) pay the
NativeArray's word once more per storage: +1.9% bytes allocated in the
self-compile, +2.7% peak memory in the tool's build.

## The header

The 8 bytes before an object (`hxmc.rt.Types`): its type index first, which
decides what the other 48 bits are.

```
          p-8          p-6                      p-4
record:   [ type:16 ][ slots:16              ][ identity hash:32       ]
array:    [ type:16 ][ words:16 (0xFFFF: more) ][ length:32, in elements ]
string:   [ type:16 ][ words:16 (0xFFFF: more) ][ content hash:32         ]
          then its length (u32 at +0) and its UTF-16 units from +4
forwarded (while the collector copies): type 0xFFFF, the copy in slot 0
```

- The **size** is the 16 bits at −6 for every object, in 8-byte words, as
  the uniform header's slots were (the collector's `w0 >>> 16`). An array or
  string of 0xFFFF words (512 KB) or more says 0xFFFF; its size is then
  computed from its length and type (`Types.wordsAt`, `lenWords`: inline,
  as the collector's loops make no call). A record has at most 65534 slots
  (`Facts`).
- How the collector **scans** is the type's: a record (types below 16, and
  every generated type from 32) by its type's pointer map; an array of 16 to
  23 not at all, of 24 to 31 every slot (`Types.isRawArray`: `t & 0xFFF8 ==
  16`).
- A record's **identity hash** is set once, by a compare-and-swap
  (`Dyn.objHash`); arrays have none (below).
- Every heap object has at least one payload slot (the forwarding address
  goes there): an empty NativeArray is the static one of its kind, an empty
  string the static `""`.

## The runtime types

| t | type | layout |
| --- | --- | --- |
| 1 | ArrayIterator | record |
| 2, 3, 4, 6 | Int, Float, Bool, Int64 boxes | records |
| 5 | Array: length, kind; storage | record |
| 7, 8 | NativeArray of an erased type parameter, open and fixed: its storage; its length where a record has its hash | records |
| 9, 10 | BytesBuffer, StringBuf | records |
| 11, 12, 13 | captured variables | records |
| 14 | type object (static) | record |
| 16 | String | array (raw) |
| 17 | 8-byte slots: StringBuf's storage | array (raw) |
| 18 | 8-byte slots: Date, AtomicInt's cell, native handles | array (raw) |
| 19 to 24 | NativeArray storage by element kind, `naType(k) = 24 - k`: Byte 19 (a Bytes' data), Bool 20, Int64 21, Float 22, Int 23, references 24 | arrays |
| 25 | 8-byte slots of references: thread-local slots, AtomicObject's cell | array |
| 26 | a structure's added fields | array |
| 27 | a native handle with references (slot 0 its C pointer, outside the heap) | array |
| 28 to 31 | free | |

## Strings

A string is `[16][words][content hash]`, its length at +0 and its UTF-16
units from +4: 4 bytes more payload than its units, 8 bytes less than the
uniform header's (which had the length and hash in the payload). The hash is
FNV-1a over the units, all 32 bits (StringMap's index; 0 until computed, a
computed 0 stored as 1); `DataGen` writes the literals' at compile time
(`FnLower.strHash`, which string switches use too: the compiler's, not
the host runtime's, which may hash otherwise while bootstrapping). Literals
are static strings in `.rodata`, as the static empty NativeArrays: nothing
writes them (their hash is never 0), the collector leaves them alone.

On the way here strings had the length in the header and a 16-bit hash
(`[16][hash:16][length:32]`, units from +0): 4 bytes less on average, but a
StringMap past 65536 slots (about 49K keys) put every key in the first 65536
(50K keys: 390 ns per operation instead of 110; 200K keys: 177 µs), and the
collector computed a string's size from its length (a test on every copied
object). The 32-bit hash and the size in the header measured better on both
counts: 43M fewer instructions in the self-compile, the same bytes
allocated (the extra 4 bytes do not show), no cliff.

## Array over NativeArray

An Array is a record `[length | kind][storage]`; its storage a NativeArray of
its kind whose length is the capacity (rounded up to fill its last word:
`Boxes.roomFor`), the empty one of the kind while there is no room. Exactly
the bytes of the old data block, and NativeArray's code paths:
`NativeArray.fromArray`/`toArray` (so `Vector.fromArrayCopy`) are blit's
memmove from or into the storage. Bool elements take one byte. Push reads
the capacity from the storage's header (no null test: the empty storage has
none); a small array and its storage are one allocation (`hx_arr_new_n`).
The Array's kind duplicates its storage's type; it is read with the length
in one load on typed accesses, so it stays for now.

## Bytes over NativeArray<Byte>

`hxmc.Byte` (`abstract Byte(Int) from Int to Int`) is an unsigned byte as a
NativeArray's element: the kind `AK_BYTE` (5), one byte each, read as an Int
from 0 to 255, the low 8 bits written; anywhere else a Byte is an Int. The
IR knows it only there (`RNativeArr(TU8)`, `Lower.isByte`; its values are
TI32, `FnLower.elemValue`), so `Vector<Byte>` comes with it.
`haxe.io.BytesData` is `NativeArray<Byte>` (type 19).

A `haxe.io.Bytes` is a Haxe object holding its BytesData (`b`), as
upstream's class: the standard library's contract (an identity, so ObjectMap
keys; its class for `Type.getClass`, `getClassName` and the Serializer),
which an array cannot keep (arrays have no identity hash, below). `get` and
`set` are NativeArray accesses through `b`, the rest `hxmc.NativeBytes`
(the runtime's, over BytesData).

- Its `length` is `b's`: a property without storage, `@:hxmc.lengthOf("b")`,
  which gives the class's field table an entry of kind L (`Facts`,
  `DataGen`): Dynamic access and reflection read it as the field upstream
  declares (`Dyn.boxSlot`; on WasmGC `Meta.objGet`, `array.len`), and a
  write is refused (an exception). A Bytes is 16 bytes over its data.
- A small one (64 words of bytes at most) is allocated with its BytesData:
  one allocation, the storage's header written after the object's slot, `b`
  the next object (`Bytes.shared`, `Mem.typeIndexOf`; as `Boxes.arrNewN`
  for an Array); `alloc` is inline, `sub` copies with `memcpy` into the new
  one. The two are copied apart at the first collection.

Measured on the way (instructions): Bytes as the storage itself (no object)
was the fastest, but Map<Bytes, X> degenerated (below); the object with a
stored length (upstream's `length(default, null)`) cost 8 bytes per Bytes
and +18.6% on many small Bytes; the shared allocation, `alloc` inline and
`sub's` `memcpy` (it first copied through blit's memmove: +11%) brought
that to +12%.

## Measured

Xeon E-2356G, 6 cores / 12 threads, 62 GB, Linux 6.1, node 24. The port's
self-compile to HXB (7 interleaved runs, medians) against the branch
`vectors` (the cycles under load from other work on the machine):

| | self-compile |
| --- | --- |
| instructions | +1.5% (32.20G to 32.69G) |
| cycles | +0.4% |
| CPU time | +0.3% |
| peak memory | −4 to −5% (639 to 608–615 MB; it moves by ±10 MB with the nursery's size: when the minor collections fall) |
| bytes allocated | −1.2% (5129 to 5065 MB) |
| bytes promoted | −4% (624 to 597 MB) |

The tool is 1.7% smaller (17.39 to 17.10 MB). The HXB is the same (the
time stamps aside); the tool rebuilds itself byte-identically.

What the instructions are: about +220M in the collector (a copied object's
forwarding test, size and scan by the type, where the uniform header gave
them by a shift and a mask), about +90M in the runtime's array paths, about
+80M Bytes as objects, the compiled code's ±0. The way there, each
measured: the uniform header with the NativeArray's own word (+0.2%
instructions, +1.9% bytes allocated); a header decided by the type with
descriptors (+2.0%); width bits for arrays (+2.0%: the collector decoded
every array's size from its length, +449M); the size in the 16 bits (+1.4%;
a call left in the collector's copy loop first cost +231M in spilled
registers); the strings above (+1.3%); Bytes as objects (+1.5%).

A Bytes benchmark against the uniform header's Bytes (instructions,
cycles; 7 interleaved runs):

| | Bytes the array | Bytes objects (final) |
| --- | --- | --- |
| many small Bytes (alloc, blit, sub, compare, ofString) | −1.8%, −4.8% | +10.2%, +10.8% |
| get and set loops | ±0, ±0 | +4.1%, −5.1% |
| getInt32, getUInt16, getDouble | ±0, ±0 | +5.7%, +13% |
| BytesBuffer | −1.6%, −2.2% | −1.6%, −1.3% |
| Sha256, Md5, Crc32 over 4 MB | −0.1%, −0.5% | +0.5%, −0.3% |
| BytesInput, BytesOutput | −0.9%, ±0 | −0.9%, ±0 |

The objects' cost: a second object (header) per Bytes, and `b` loaded in
each iteration of a loop with calls (`Opt.licm` moves it out of the others
since the object is not null: get and set loops ±0 then; docs/plans/codegen.md).
Allocation folding takes the self-compile to +0.9% instructions, −0.3% cycles
(the same machine, loaded by other work).
Map<Bytes, Int> (16-byte keys): 18, 20, 24 ns per operation for 1000, 10000,
40000 keys (the uniform header's: 20, 20, 29).

## Identity hashes of arrays

Arrays have none, by decision (NativeArray is not an object; Bytes, which
must be, wraps one): `Dyn.objHash` gives an array `(length * 31 + type) *
golden`, so an ObjectMap whose keys are NativeArrays or Vectors of one length
puts them all in one cluster. It stays correct (the keys are compared by
identity) but each operation walks the cluster (Bytes as arrays, 16-byte
keys: 1000 keys 1.1 µs per operation, 10000 keys 8.1 µs, 40000 keys 32.5
µs). Should arrays need one: a weak table of the arrays hashed, which the
collector updates for the arrays it moves; or address-based hashing, the
hash appended when the collector moves a hashed array (the size is in the
header, not the length, so a copy may carry a word after its elements).

## Not built yet

- **Bytes' shared allocation by the compiler**: allocation folding
  (docs/plans/codegen.md) after the length test's branches, so that
  `new Bytes(new BytesData(n))` folds and `Bytes.shared` goes.
- **Bytes' multi-byte accessors inline** (`getInt32`, `getDouble`: loads of
  the storage, not runtime calls): their loops then lose `b`'s reload too
  (`Opt.licm` leaves a loop with calls).
- **StringBuf's storage** as a NativeArray of units (it keeps its capacity in
  slots of type 17); `toString` could hand out its storage as the string (a
  string's size is its header's, not its length's) and copy only when the
  buffer is added to again, at the cost of the spare capacity the string
  keeps.
- **Header-only objects**: short strings, Int boxes, empty arrays in 8 bytes.
  They need the forwarding address in the header (48 bits fit any user-space
  address; built and measured once here: 278M more instructions in the
  self-compile than forwarding through slot 0, so back to slot 0 for now).
- **Array as a Haxe class** over NativeArray (HashLink's way), its methods in
  the std instead of `Arr`/`Boxes` and MirBuild's special lowering.
- **The Array's kind** dropped, read from its storage's type.
- Compact strings: a second string type (Latin-1, one byte per unit), not a
  flag.
- A new stage0 (`make stage0`): the committed one cannot build these sources
  (a layout change: the previous tool builds the new compiler against the
  previous std, which then builds itself).

Fixed on the way: `rt/wasm/Gc.hx`'s `drain` scanned a reference
NativeArray's length/kind word as a reference; `macro/Loader.isBundleObject`
read the type index at −4; `Type.getClass(bytes) == haxe.io.Bytes` was
false (so `haxe.Serializer` could not serialize Bytes) and
`Type.getClassName(Type.getClass(bytes))` crashed (the uniform header's tool
too: Bytes are objects now).
