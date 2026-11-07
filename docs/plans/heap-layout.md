# Plans: object layout

Open work on the object header and the layout of arrays, strings and
Bytes. The current layout: [hxmc.md](../hxmc.md#object-layout).

Built: `StringBuf.toString()` shares its backing storage, and the next
write copies it. Snapshots with excessive spare capacity are copied to
avoid retaining large buffers after `clear` ([details](../hxmc.md#strings-and-dates)).

- **Bytes' shared allocation by the compiler.** `Bytes.shared` allocates a
  small Bytes with its data by hand. Allocation folding after the length
  test's branches would make `new Bytes(new BytesData(n))` fold, and
  `Bytes.shared` could go.
- **Bytes' multi-byte accessors inline** (`getInt32`, `getDouble`): loads
  of the storage instead of runtime calls. Their loops would then also lose
  `b`'s reload.
- **Header-only objects**: short strings, Int boxes and empty arrays in 8
  bytes. They need the forwarding address in the header; measured once at
  278M more instructions in the self-compile than forwarding through slot
  0.
- **Array as a Haxe class** over NativeArray (HashLink's way), its methods
  in the std instead of `Arr`, `Boxes` and MirBuild's special lowering.
- **The Array's kind** dropped, read from its storage's type.
- **Identity hashes for arrays.** Arrays have none: an ObjectMap keyed by
  NativeArrays of one length puts them in one cluster (correct, but each
  operation walks it). If needed: a weak table of hashed arrays the
  collector updates, or a hash appended when the collector moves a hashed
  array.
