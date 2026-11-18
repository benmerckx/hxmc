// A loop rotating variables (c = b; b = a) through an array it reads: LICM's
// guard moved the header's test to the latch with c's value from there b's
// first round, not its current one (Opt.licm; SHA-512's rounds)
class GuardRotation {
	static function main() {
		Sys.println(mix([for (i in 0...16) i * 7 + 1]));
	}

	static function mix(k:Array<Int>):String {
		var a = 1, b = 2, c = 3;
		for (t in 0...16) {
			var x = a + b * c + k[t];
			c = b;
			b = a;
			a = x & 0xffff;
		}
		return a + " " + b + " " + c;
	}
}
