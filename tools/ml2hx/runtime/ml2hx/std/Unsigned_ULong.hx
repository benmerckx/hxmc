package ml2hx.std;

import haxe.Int64 as I64;
import ml2hx.rt.*;

// integers' Unsigned.ULong: a C unsigned long, its bits in an Int64.
typedef UnsignedULongT = I64;

class Unsigned_ULong {
	// (to_int: the low 63 bits, as OCaml's Int of the value)
	public static inline function toInt(a:I64):Int63 return Int63.ofInt64(a);
}
