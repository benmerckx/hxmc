// Math.random and Std.random (hxmc.rt.Random): Math.random in [0, 1) with
// 53 random bits, Std.random(n) in [0, n) reaching every value, 0 for
// n <= 1 (upstream's Std.hx), and both roughly uniform. The draws are
// seeded from the system's randomness, so nothing random is printed: only
// the checks (RandomSeed: other runs and threads draw other sequences).
class RandomRanges {
	static function main() {
		// Math.random: the range, the mean, and bits below 2^-32
		var n = 200000, inRange = true, sum = 0.0, fine = 0, odd = 0;
		var lo = 1.0, hi = 0.0;
		for (_ in 0...n) {
			var x = Math.random();
			if (!(x >= 0 && x < 1)) inRange = false;
			sum += x;
			if (x < lo) lo = x;
			if (x > hi) hi = x;
			var y = x * 4294967296.0;
			if (y != Math.ffloor(y)) fine++;
			// the 53rd bit: x * 2^53 is an integer, odd half the time
			var z = x * 9007199254740992.0;
			if (z == Math.ffloor(z) && Math.ffloor(z / 2) * 2 != z) odd++;
		}
		var mean = sum / n;
		Sys.println("Math.random in [0, 1): " + inRange);
		Sys.println("mean near 0.5: " + (Math.abs(mean - 0.5) < 0.005));
		Sys.println("spans the range: " + (lo < 0.001 && hi > 0.999));
		Sys.println("bits below 2^-32: " + (fine > n * 0.99));
		Sys.println("53rd bit set about half the time: " + (Math.abs(odd / n - 0.5) < 0.01));

		// Std.random(n): every value of [0, n), none outside, about n / draws each
		for (m in [2, 3, 7, 10, 100, 1000]) {
			var counts = [for (_ in 0...m) 0];
			var draws = m * 400, ok = true;
			for (_ in 0...draws) {
				var r = Std.random(m);
				if (r < 0 || r >= m) ok = false else counts[r]++;
			}
			var all = true, flat = true;
			for (c in counts) {
				if (c == 0) all = false;
				if (c < 250 || c > 550) flat = false;
			}
			Sys.println('Std.random($m): in range $ok, every value $all, flat $flat');
		}
		// large bounds: in range, and both halves reached
		var big = 0x7FFFFFFF, ok = true, low = 0, high = 0;
		for (_ in 0...10000) {
			var r = Std.random(big);
			if (r < 0 || r >= big) ok = false;
			if (r < 0x40000000) low++ else high++;
		}
		Sys.println("Std.random(0x7FFFFFFF): in range " + ok + ", both halves " + (low > 4000 && high > 4000));
		// upstream: "If x <= 1, the result is always 0"
		var zero = true;
		for (m in [1, 0, -1, -100, -0x7FFFFFFF - 1])
			for (_ in 0...100)
				if (Std.random(m) != 0) zero = false;
		Sys.println("Std.random(n <= 1) is 0: " + zero);
		// not one value over and over
		var first = Std.random(1000000), same = true;
		for (_ in 0...10)
			if (Std.random(1000000) != first) same = false;
		Sys.println("not constant: " + !same);
	}
}
