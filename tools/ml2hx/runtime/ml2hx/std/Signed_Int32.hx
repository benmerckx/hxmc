package ml2hx.std;

import Array;
import String;
import StdTypes;
import haxe.Int64 as I64;
import ml2hx.rt.*;

// integers' Signed.Int32.
typedef SignedInt32T = haxe.Int32;

class Signed_Int32 {
	public static inline function ofInt64(a:I64):haxe.Int32 return a.low;
	public static inline function toInt64(a:haxe.Int32):I64 return I64.ofInt(a);
	public static inline function ofInt(n:Int63):haxe.Int32 return n.toInt();
	public static inline function toInt(a:haxe.Int32):Int63 return Int63.ofInt(a);
}
