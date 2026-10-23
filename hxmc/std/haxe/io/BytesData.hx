// hxmc: haxe/upstream/std/eval/_std/haxe/io/BytesData.hx: NativeArray storage
// of bytes, which a Bytes holds (hxmc.rt.Bytes); indexing reads and writes bytes,
// unchecked unless -D hxmc.native-array-outofbounds says otherwise

package haxe.io;

typedef BytesData = hxmc.NativeArray<hxmc.Byte>;
