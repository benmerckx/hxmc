package ml2hx.std;

import haxe.Int64 as I64;
import ml2hx.rt.*;

// integers' Signed.Long: a C long (64 bits on the hosts hxmc targets but
// Windows, where luv's longs come from 32-bit fields widened).
typedef SignedLongT = I64;

class Signed_Long {
	public static inline function toInt64(a:I64):I64 return a;
	public static inline function ofInt64(a:I64):I64 return a;
}
