package ml2hx.rt;

import haxe.Int64;

// Conversions between floats and 64-bit integers, as OCaml's runtime does them
// with C casts (int64 to double rounds to nearest, double to int64 truncates).
class Float64 {
	static inline var TWO32 = 4294967296.0;

	// correctly rounded: high * 2^32 and the unsigned low word are exact doubles
	public static inline function ofInt64(v:Int64):Float {
		var lo:Float = v.low;
		if (lo < 0) lo += TWO32;
		return v.high * TWO32 + lo;
	}

	// truncation toward zero; nan and out of range give 0x8000000000000000 as x86's cvttsd2si
	public static function toInt64(f:Float):Int64 {
		if (!(f > -9223372036854775808.0 && f < 9223372036854775808.0)) return Int64.make(0x80000000, 0);
		var neg = f < 0;
		var t = neg ? -f : f;
		t = Math.ffloor(t);
		var hi = Math.ffloor(t / TWO32);
		var lo = t - hi * TWO32;
		var r = Int64.make(Std.int(hi > 2147483647.0 ? hi - TWO32 : hi), Std.int(lo > 2147483647.0 ? lo - TWO32 : lo));
		return neg ? -r : r;
	}

	public static inline function bits(f:Float):Int64
		return haxe.io.FPHelper.doubleToI64(f);

	public static inline function ofBits(v:Int64):Float
		return haxe.io.FPHelper.i64ToDouble(v.low, v.high);
}
