// A vector's lane index is a constant (hxmc.simd, docs/plans/simd.md): a
// lane read at a run-time index is an error.
// expect: hxmc.simd: a lane index must be a constant
import hxmc.simd.I32x4;

class SimdLane {
	static function lane(v:I32x4, i:Int):Int
		return v.get(i);

	static function main()
		trace(lane(I32x4.splat(3), Std.random(4)));
}
