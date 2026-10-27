package hxmc.rt;

// The representation the runtime's shared natives (Str, Arr, Bytes, Date)
// work on: strings and their units, arrays and their elements, bytes,
// StringBuf's and BytesBuffer's storage, dates: hxmc.rt.MemRepr over
// linear memory (Mem). All inline: what a native compiles to is its
// representation's own code.
typedef Repr = hxmc.rt.MemRepr;
typedef Chars = hxmc.rt.MemRepr.MemChars;
typedef Chars1 = hxmc.rt.MemRepr.MemChars1;
typedef Octets = hxmc.rt.MemRepr.MemOctets;
