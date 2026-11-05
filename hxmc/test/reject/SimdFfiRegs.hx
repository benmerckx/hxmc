// A C function's vectors by value travel in vector registers only (System V,
// AAPCS64: docs/plans/simd.md, "ABIs"): a ninth is an error.
// target: linux-x86_64
// expect: a vector by value past the eight vector argument registers
import hxmc.simd.F32x4;

@:hxmc.c @:hxmc.fast extern class Nine {
	static function v_nine(a:F32x4, b:F32x4, c:F32x4, d:F32x4, e:F32x4, f:F32x4, g:F32x4, h:F32x4, i:F32x4):F32x4;
}

class SimdFfiRegs {
	static function main() {
		var v = F32x4.splat(1);
		trace(Nine.v_nine(v, v, v, v, v, v, v, v, v).get(0));
	}
}
