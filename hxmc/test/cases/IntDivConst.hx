// Division and remainder by constants (DivConst: a multiplication by the
// reciprocal, shifts and masks for powers of two): Int `%` and Std.int(a / b)
// of Ints (an integer division), haxe.Int64's `/` and `%`; positive and
// negative divisors, powers of two, MIN, dividends known not to be negative,
// a quotient and a remainder of the same dividend; each against the same
// operation by a divisor known only at run time, and its results summed (the
// same sums on every target). Std.int(a / b) by 0 and -1 (and MIN / -1), as
// the Float quotient converts, Int % 0 and % -1, and hxmc.unsafe.UInt64's
// unsigned `/` and `%` (by constants and by run-time divisors, against a long
// division) last.
import haxe.Int64;
import hxmc.unsafe.UInt64;

class IntDivConst {
	static var xs:Array<Int> = [
		0, 1, -1, 2, -2, 3, -3, 5, -5, 6, -6, 7, -7, 9, 10, -10, 11, -11, 13, 63, 64, 65, -63, -64, -65, 99, 100, 101, -99, -100, -101, 127, 128, -128, 255,
		256, 1000, -1000, 4095, 4096, -4097, 65535, 65536, 999999, 1000003, -1000003, 123456789, -123456789, 0x3FFFFFFF, 0x40000000, -0x40000000,
		0x7FFFFFFE, 0x7FFFFFFF, -0x7FFFFFFF, -0x7FFFFFFF - 1, 0x55555555, -0x55555555, 0x12345678, -0x12345678, 1431655765, 1431655766, 858993459,
		-858993460, 2147483600, -2147483600
	];
	static var ls:Array<Int64> = [];
	static var bad = 0;

	// v as the program sees it only when it runs
	static function opaque(v:Int):Int
		return Std.parseInt(Std.string(v));

	static function opaque64(v:Int64):Int64
		return Int64.parseString(Int64.toStr(v));

	static function check(what:String, x:Dynamic, d:Dynamic, got:Dynamic, want:Dynamic) {
		if (Std.string(got) != Std.string(want)) {
			if (bad++ < 20) Sys.println('MISMATCH $what $x by $d: $got, want $want');
		}
	}

	static inline function int(d:Int) {
		var dv = opaque(d);
		var sq = 0, sr = 0;
		for (x in xs) {
			var q = Std.int(x / d), r = x % d;
			check("/", x, d, q, Std.int(x / dv));
			check("%", x, d, r, x % dv);
			sq = (sq * 31 + q) | 0;
			sr = (sr * 31 + r) | 0;
			// known not to be negative
			var p = x & 0x7FFFFFFF, h = x >>> 1;
			check("/+", p, d, Std.int(p / d), Std.int(p / dv));
			check("%+", p, d, p % d, p % dv);
			check("/>>>", h, d, Std.int(h / d), Std.int(h / dv));
			check("%>>>", h, d, h % d, h % dv);
		}
		Sys.println('$d: ${Std.int(xs[22] / d)} ${xs[22] % d} ${Std.int(xs[52] / d)} ${xs[52] % d} $sq $sr');
	}

	static inline function long(d:Int64) {
		var dv = opaque64(d);
		var sq:Int64 = 0, sr:Int64 = 0;
		for (x in ls) {
			var q = x / d, r = x % d;
			check("L/", x, d, q, x / dv);
			check("L%", x, d, r, x % dv);
			sq = sq * 31 + q;
			sr = sr * 31 + r;
			var p = x & Int64.make(0x7FFFFFFF, 0xFFFFFFFF);
			check("L/+", p, d, p / d, p / dv);
			check("L%+", p, d, p % d, p % dv);
		}
		Sys.println('$d: ${ls[3] / d} ${ls[3] % d} $sq $sr');
	}

	static function main() {
		for (x in xs) {
			ls.push(x);
			ls.push(Int64.make(x, 0x9E3779B9) ^ Int64.make(0, x * 7));
			ls.push(Int64.make(x >> 3, x));
		}
		ls.push(Int64.make(0x7FFFFFFF, 0xFFFFFFFF));
		ls.push(Int64.make(0x80000000, 0));
		ls.push(Int64.make(0x80000000, 1));
		ls.push(Int64.make(0xFFFFFFFF, 0xFFFFFFFF));

		Sys.println("Int");
		int(1);
		int(2);
		int(3);
		int(5);
		int(6);
		int(7);
		int(9);
		int(10);
		int(11);
		int(12);
		int(13);
		int(25);
		int(60);
		int(64);
		int(97);
		int(100);
		int(125);
		int(641);
		int(1000);
		int(1000003);
		int(65536);
		int(0x40000000);
		int(0x7FFFFFFF);
		int(0x55555555);
		int(-2);
		int(-3);
		int(-7);
		int(-10);
		int(-64);
		int(-1000);
		int(-0x40000000);
		int(-0x7FFFFFFF);
		int(-0x7FFFFFFF - 1);

		// a quotient and a remainder of the same dividend (one multiplication)
		var digits = 0, n = 0;
		for (x in xs) {
			var v = x < 0 ? -x : x;
			do {
				digits = (digits * 3 + v % 10) | 0;
				v = Std.int(v / 10);
				n++;
			} while (v != 0);
		}
		Sys.println('digits $n $digits');

		// Std.int(a / b) of two Ints known only at run time (0, -1 and MIN
		// among them) as the Float quotient converted
		var pairs = 0;
		for (a in xs)
			for (b in xs) {
				var fa = a + 0.0;
				check("f/", a, b, Std.int(a / b), Std.int(fa / b));
				pairs++;
			}
		Sys.println('pairs $pairs');

		Sys.println("Int64");
		long(1);
		long(2);
		long(3);
		long(7);
		long(10);
		long(64);
		long(1000);
		long(1000003);
		long(1000000007);
		long(-3);
		long(-10);
		long(-1024);
		long(Int64.make(0, 0x80000000));
		long(Int64.make(1, 0));
		long(Int64.make(0x12345678, 0x9ABCDEF0));
		long(Int64.make(0x7FFFFFFF, 0xFFFFFFFF));
		long(Int64.make(0x40000000, 0));
		long(Int64.make(0xFFFFFFFF, 0x80000000));
		long(Int64.make(0x80000000, 0));
		long(Int64.make(0x80000000, 1));

		Sys.println(bad == 0 ? "same as by run-time divisors" : '$bad mismatches');
		hxmc();
	}

	// hxmc's own semantics: what the other targets differ in or have not
	static function hxmc() {
		var zero = opaque(0), m1 = opaque(-1), min = opaque(-0x7FFFFFFF - 1);
		Sys.println('Std.int(a / b): ${Std.int(7 / zero)} ${Std.int(-7 / zero)} ${Std.int(0 / zero)} ${Std.int(7 / m1)} ${Std.int(min / m1)} ${Std.int(min / -1)} ${Std.int(min / 1)}');
		var mn = min;
		Sys.println('Int %: ${7 % zero} ${7 % m1} ${mn % -1} ${mn % m1} ${mn % 0}');

		// unsigned
		var us:Array<UInt64> = [];
		for (x in ls)
			us.push((cast x : hxmc.I64));
		var ubad = 0, s:hxmc.I64 = 0;
		inline function u(d:UInt64) {
			var dv:UInt64 = (cast opaque64(cast d) : hxmc.I64);
			for (x in us) {
				var q = x / d, r = x % d;
				var lq = udiv(x, dv);
				var want = Int64.toStr(cast lq) + " " + Int64.toStr(cast ((x : hxmc.I64) - (lq : hxmc.I64) * (dv : hxmc.I64)));
				if (Int64.toStr(cast q) + " " + Int64.toStr(cast r) != want || Int64.toStr(cast (x / dv)) + " " + Int64.toStr(cast (x % dv)) != want) {
					if (ubad++ < 20) Sys.println('MISMATCH unsigned ${Int64.toStr(cast x)} by ${Int64.toStr(cast d)}: ${Int64.toStr(cast q)} ${Int64.toStr(cast r)}, want $want');
				}
				s = s * 31 + (q : hxmc.I64) + (r : hxmc.I64);
			}
			Sys.println('u ${Int64.toStr(cast d)}: ${Int64.toStr(cast (us[us.length - 1] / d))} ${Int64.toStr(cast (us[us.length - 1] % d))}');
		}
		u(1);
		u(2);
		u(3);
		u(7);
		u(10);
		u(64);
		u(1000);
		u(1000000007);
		u((cast Int64.make(0, 0x80000000) : hxmc.I64));
		u((cast Int64.make(0x12345678, 0x9ABCDEF0) : hxmc.I64));
		u((cast Int64.make(0x7FFFFFFF, 0xFFFFFFFF) : hxmc.I64));
		u((cast Int64.make(0x80000000, 0) : hxmc.I64));
		u((cast Int64.make(0x80000000, 1) : hxmc.I64));
		u((cast Int64.make(0xFFFFFFFF, 0xFFFFFFFF) : hxmc.I64));
		Sys.println('unsigned ${ubad == 0 ? "same as a long division" : ubad + " mismatches"} ${Int64.toStr(cast s)}');
	}

	// n / d unsigned, one bit at a time
	static function udiv(n:UInt64, d:UInt64):UInt64 {
		var q:hxmc.I64 = 0, r:UInt64 = 0;
		var i = 63;
		while (i >= 0) {
			var carry = (r : hxmc.I64) < 0;
			r = ((r : hxmc.I64) << 1) | (((n : hxmc.I64) >>> i) & 1);
			q = q << 1;
			if (carry || r >= d) {
				r = (r : hxmc.I64) - (d : hxmc.I64);
				q = q | 1;
			}
			i--;
		}
		return q;
	}
}
