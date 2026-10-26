// Int `%` and Std.int(a / b) by constants (DivConst: a multiplication by the
// reciprocal, or shifts): positive and negative divisors, powers of two, MIN,
// each against the same operation by a divisor known only at run time and
// Std.int against the Float quotient converted; then hxmc's own results by 0
// and -1 (and MIN / -1).
class IntDivConst {
	static var xs = [0, 1, -1, 7, -7, 10, -10, 63, 64, -64, -65, 1000003, -123456789, 0x40000000, 0x7FFFFFFF, -0x7FFFFFFF, -0x7FFFFFFF - 1];
	static var bad = 0;

	// v as the program sees it only when it runs
	static function opaque(v:Int):Int
		return Std.parseInt(Std.string(v));

	static inline function by(d:Int) {
		var dv = opaque(d), s = 0;
		for (x in xs) {
			var q = Std.int(x / d), r = x % d;
			if (q != Std.int(x / dv) || q != Std.int((x + 0.0) / dv) || r != x % dv) {
				bad++;
				Sys.println('MISMATCH $x by $d: $q $r');
			}
			s = (s * 31 + q * 7 + r) | 0;
		}
		Sys.println('$d: $s');
	}

	static function main() {
		by(1);
		by(2);
		by(3);
		by(7);
		by(10);
		by(64);
		by(641);
		by(1000003);
		by(0x40000000);
		by(0x7FFFFFFF);
		by(-3);
		by(-10);
		by(-64);
		by(-0x7FFFFFFF - 1);
		Sys.println(bad == 0 ? "same as by run-time divisors" : '$bad mismatches');
		var zero = opaque(0), m1 = opaque(-1), min = opaque(-0x7FFFFFFF - 1);
		Sys.println('Std.int: ${Std.int(min / -1)} ${Std.int(min / m1)} ${Std.int(7 / zero)} ${Std.int(-7 / zero)}');
		Sys.println('%: ${min % -1} ${min % m1} ${7 % 0} ${7 % zero}');
	}
}
