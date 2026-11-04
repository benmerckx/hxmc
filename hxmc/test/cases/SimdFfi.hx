import hxmc.simd.*;
import hxmc.unsafe.*;

// hxmc.simd's vectors in C signatures (docs/plans/simd.md, "ABIs"): C's
// native 128-bit vectors by value, in vector registers on System V and
// AAPCS64 (the eight of them, then a scalar on the stack), by address on
// Win64 with the result in xmm0; and a callback C calls with vectors
// (SimdFfi.c, built by the corpus harness with zig; WebAssembly has no C
// objects, the interpreter no vector calls).
@:hxmc.c @:hxmc.fast extern class V {
	static function v_madd(a:F32x4, b:F32x4, c:F32x4):F32x4;
	static function v_mix(k:Int, a:I32x4, d:Float, b:I32x4):I32x4;
	static function v_sum(a:F32x4, b:F64x2):Float;
	static function v_make(x:Float32, y:Float32, z:Float32, w:Float32):F32x4;
	static function v_swap(a:F64x2):F64x2;
	static function v_eight(a:I32x4, b:I32x4, c:I32x4, d:I32x4, e:I32x4, f:I32x4, g:I32x4, h:I32x4):I32x4;
}

@:hxmc.c extern class VB {
	static function v_cb(f:Ptr):Float;
}

class SimdFfi {
	@:hxmc.callback static function back(a:F32x4, k:Int, b:F32x4):F32x4
		return a * F32x4.splat(k) + b;

	static function main() {
		var a = F32x4.make(1, 2, 3, 4), b = F32x4.make(0.5, -1, 2, 0.25), c = F32x4.splat(10);
		Sys.println("madd: " + V.v_madd(a, b, c).toString());
		Sys.println("mix: " + V.v_mix(3, I32x4.make(1, 2, 3, 4), 100.75, I32x4.make(-1, 0, 1, 2)).toString());
		Sys.println("sum: " + V.v_sum(a, F64x2.make(0.5, -2)));
		Sys.println("make: " + V.v_make(1.5, -2, 0.25, 8).toString());
		Sys.println("swap: " + V.v_swap(F64x2.make(1.25, -3)).toString());
		var vs = [for (k in 0...8) I32x4.make(k, k * 10, k * 100, -k)];
		Sys.println("eight: " + V.v_eight(vs[0], vs[1], vs[2], vs[3], vs[4], vs[5], vs[6], vs[7]).toString());
		// (a vector live across a C call: in a register the callee may clobber, or saved)
		var keep = I32x4.make(7, 8, 9, 10);
		var m = V.v_madd(a, a, a);
		Sys.println("kept: " + (keep + I32x4.splat(1)).toString() + " " + m.toString());
		Sys.println("callback: " + VB.v_cb(Callback.addr(back)));
	}
}
