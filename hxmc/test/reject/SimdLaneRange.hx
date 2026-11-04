// A lane index past the vector's lanes is an error.
// expect: hxmc.simd: lane 4 of f32x4.extract_lane (4 lanes)
import hxmc.simd.F32x4;

class SimdLaneRange {
	static function main()
		trace(F32x4.splat(1.5).get(4));
}
