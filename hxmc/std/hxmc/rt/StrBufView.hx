package hxmc.rt;

import hxmc.rt.Repr;

// A StringBuf's layout (hxmc.rt.Str, T_STRINGBUF: slot 0 its length) read
// for kernels, as StrView reads a string's. Only its length: its units are
// written by code that allocates (growing, widening).
@:keep @:hxmc.kernel @:hxmc.unsafe
class StrBufView {
	public static function length(b:StringBuf):Int
		return Repr.sbLen(b);

	// (no unit is freed nor read: a length of 0 is always within them)
	public static function clear(b:StringBuf)
		Repr.sbSetLen(b, 0);
}
