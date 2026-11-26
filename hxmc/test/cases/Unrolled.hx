// Full unrolling (hxmc/src/hxmc/Unroll.hx): loops of a few constant rounds
// (counting up or down, by steps on the way back, tested either way round)
// run as copies of their body; values made in the loop are read after it,
// and a loop with a break leaves at the round it breaks in.
class Unrolled {
	static var table = [for (i in 0...18) i * 7 + 1];

	static function rounds(x:Int):Int {
		var i = 0;
		while (i <= 14) {
			i += 1;
			x ^= table[i] << (i & 7);
			i += 1;
			x = (x + table[i]) | 0;
		}
		return x + i;
	}

	static function down():Int {
		var s = 0, last = -1;
		var k = 6;
		while (k > 0) {
			s = s * 3 + k;
			last = k;
			k -= 2;
		}
		return s * 100 + last;
	}

	static function early(stop:Int):Int {
		var n = 0;
		for (i in 0...8) {
			if (i == stop) break;
			n += i;
		}
		return n;
	}

	static function floats():Float {
		var a = [1.5, 2.5, 3.5, 4.5];
		var t = 0.0;
		for (i in 0...4)
			t = t * 0.5 + a[i];
		return t;
	}

	static function main() {
		Sys.println('rounds: ${rounds(12345)} ${rounds(-1)}');
		Sys.println('down: ${down()}');
		Sys.println('early: ${early(3)} ${early(9)}');
		Sys.println('floats: ${floats()}');
	}
}
