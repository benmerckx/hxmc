// A shuffle's lanes are constants below 32 (16 of each vector's bytes).
// expect: hxmc.simd: shuffle lane 32 (0 to 31: the first vector's, then the second's)
import hxmc.simd.I32x4;

class SimdShuffle {
	static function main()
		trace(I32x4.splat(1).shuffle(I32x4.splat(2), 0, 1, 2, 8).get(0));
}
