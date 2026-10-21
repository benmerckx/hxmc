// Ordering a nullable number (upstream's unit test TestOps.testNadakoOps): hxmc
// read null as 0 (0 >= null was true); null is not ordered with a number and
// two nulls are equal, as on Eval and the static targets.
class NullCompare {
	@:analyzer(ignore)
	static function main() {
		var n:Null<Int> = null, z:Null<Int> = 0, o:Null<Int> = 1;
		var r = [];
		for (x in [0, 1, -1])
			r.push([x > n, x >= n, x < n, x <= n, n > x, n >= x, n < x, n <= x]);
		r.push([z > n, z >= n, z < n, z <= n, n > z, n >= z, n < z, n <= z]);
		r.push([o > z, o >= z, o < z, o <= z]);
		r.push([null > n, null >= n, null < n, null <= n, n >= null, n <= null]);
		var nf:Null<Float> = null, zf:Null<Float> = 0.5;
		r.push([0.5 > nf, 0.5 >= nf, nf < 0.5, nf <= zf, zf >= nf, zf > 0.25, 1 < zf]);
		for (a in r)
			Sys.println(a);
	}
}
