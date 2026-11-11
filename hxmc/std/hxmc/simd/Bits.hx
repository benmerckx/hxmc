package hxmc.simd;

// The bits of float lanes for the scalar implementation (Ref): float32
// rounding (to nearest even), doubles' halves. On hxmc Mem's bit casts (the
// machine's own conversions), elsewhere through haxe.io.FPHelper.
#if (target.name == "hxmc")
@:hxmc.kernel
#end
@:noCompletion class Bits {
	// a Float rounded to float32: its bits
	public static function ofF32(x:Float):Int {
		#if (target.name == "hxmc")
		return hxmc.unsafe.Mem.f32Bits(x);
		#else
		return haxe.io.FPHelper.floatToI32(x);
		#end
	}

	// float32 bits as a Float (exactly)
	public static function f32(b:Int):Float {
		#if (target.name == "hxmc")
		return hxmc.unsafe.Mem.bitsF32(b);
		#else
		return haxe.io.FPHelper.i32ToFloat(b);
		#end
	}

	public static function f64(lo:Int, hi:Int):Float {
		#if (target.name == "hxmc")
		return hxmc.unsafe.Mem.bitsF64(((hi : hxmc.I64) << 32) | (((lo : hxmc.I64) << 32) >>> 32));
		#else
		return haxe.io.FPHelper.i64ToDouble(lo, hi);
		#end
	}

	public static function lo(x:Float):Int {
		#if (target.name == "hxmc")
		return hxmc.unsafe.Mem.f64Bits(x).toInt();
		#else
		return haxe.io.FPHelper.doubleToI64(x).low;
		#end
	}

	public static function hi(x:Float):Int {
		#if (target.name == "hxmc")
		return (hxmc.unsafe.Mem.f64Bits(x) >>> 32).toInt();
		#else
		return haxe.io.FPHelper.doubleToI64(x).high;
		#end
	}

	// whether x is -0 (or another negative number)
	public static function negZero(x:Float):Bool
		return hi(x) < 0;

	// 32-bit wrapping arithmetic where Int does not wrap by itself (JavaScript)
	public static inline function wrap(x:Int):Int {
		#if js
		return x | 0;
		#else
		return x;
		#end
	}

	public static inline function mul(a:Int, b:Int):Int {
		#if js
		return js.Syntax.code("Math.imul({0}, {1})", a, b);
		#else
		return a * b;
		#end
	}
}
