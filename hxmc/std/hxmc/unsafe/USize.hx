package hxmc.unsafe;

import hxmc.I64;

// C's size_t in a declaration (docs/interop.md, "Typed bindings"): an I64
// here, passed as the target's size_t (64 bits natively, 32 on wasm32,
// where C reads its low half), as a span's length is.
abstract USize(I64) from I64 to I64 {
	public inline function toInt():Int
		return (this : I64).toInt();

	@:from static inline function ofInt(v:Int):USize
		return (v : I64);
}
