// Float counters as Ints (hxmc/src/hxmc/FloatCounters.hx): a Float that
// starts at an Int, goes up or down by one and is kept strictly below
// (above) an Int counts as an Int; what it computes is the Float's, up to
// the ends of the Int range. Counters of other shapes stay Floats: half
// steps, a bound that is not an Int, a test that lets them reach past the
// Int range, a start out of it. Each line prints what the loop computes.
class FloatCounters {
	static function sum(a:Array<Int>):Float {
		var s = 0.0;
		var i = 0.0;
		while (i < a.length) {
			s += a[Std.int(i)] * i;
			i += 1;
		}
		return s + i;
	}

	static function pairs(n:Int):Float {
		var t = 0.0;
		var i = 0.0;
		while (i < n) {
			var j = i + 1;
			while (j < n) {
				t += i * 10 + j;
				j += 1;
			}
			i += 1;
		}
		return t;
	}

	static function down(n:Int):String {
		var r = [];
		var k:Float = n;
		while (k > 0) {
			r.push(Std.string(k));
			k -= 1;
		}
		return r.join(",") + " " + k;
	}

	static function ends():String {
		var i = 2147483640.0;
		var c = 0;
		while (i < 2147483647) {
			c++;
			i += 1;
		}
		var j = -2147483640.0;
		while (j > -2147483648) {
			c++;
			j -= 1;
		}
		return '$c $i $j ${Std.int(i)} ${Std.int(j)}';
	}

	static function others():String {
		var a = 0.0, n = 0;
		while (a < 5) {
			a += 0.5;
			n++;
		}
		var b = 0.5;
		while (b < 3) {
			b += 1;
			n++;
		}
		var c = 0.0;
		while (c < 2.5) {
			c += 1;
			n++;
		}
		// (up to the Int maximum and one past it: a Float only)
		var d = 2147483645.0;
		while (d <= 2147483647) {
			d += 1;
			n++;
		}
		var e = 3e9;
		while (e < 3e9 + 3) {
			e += 1;
			n++;
		}
		return '$n $a $b $c $d $e';
	}

	static function integral(n:Int):Int {
		var hits = 0;
		var i = 0.0;
		while (i < n) {
			if (Std.int(i) == i) hits++;
			if (i == Std.int(i) + 0.5) hits += 100;
			i += 1;
		}
		return hits;
	}

	static function main() {
		Sys.println('sum: ${sum([3, 1, 4, 1, 5, 9, 2, 6])} ${sum([])}');
		Sys.println('pairs: ${pairs(5)} ${pairs(0)} ${pairs(1)}');
		Sys.println('down: ${down(4)} ${down(0)}');
		Sys.println('ends: ${ends()}');
		Sys.println('others: ${others()}');
		Sys.println('integral: ${integral(7)}');
	}
}
