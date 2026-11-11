// Mem's functions of values alone in safe kernels (docs/interop.md,
// "Kernels"): unsigned comparisons and divisions, and the bit casts of
// doubles and floats, which are register moves (float32: rounded to
// nearest even).
import hxmc.I64;
import hxmc.unsafe.Mem;

class KernelBits {
	@:hxmc.kernel static function hi(x:Float):Int
		return (Mem.f64Bits(x) >>> 32).toInt();

	@:hxmc.kernel static function ofHalves(hi:Int, lo:Int):Float
		return Mem.bitsF64(((hi : I64) << 32) | ((lo : I64) & 0xFFFFFFFF));

	@:hxmc.kernel static function f32(x:Float):Int
		return Mem.f32Bits(x);

	@:hxmc.kernel static function ofF32(b:Int):Float
		return Mem.bitsF32(b);

	@:hxmc.kernel static function below(a:Int, b:Int):Bool
		return Mem.ult(a, b);

	@:hxmc.kernel static function halfOf(a:Int):Int
		return Mem.udiv(((a : I64) << 32) >>> 32, 2).toInt();

	static function main() {
		trace(StringTools.hex(hi(1.0)), StringTools.hex(hi(-2.0)), ofHalves(0x40090000, 0));
		trace(StringTools.hex(f32(1.5)), StringTools.hex(f32(0.1)), ofF32(0x3FC00000), ofF32(0xC0000000));
		trace(below(1, 2), below(-1, 2), below(2, -1), halfOf(-2));
	}
}
