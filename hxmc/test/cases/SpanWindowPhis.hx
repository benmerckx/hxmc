import haxe.io.Bytes;
import hxmc.ReadOnlySpan;
import hxmc.unsafe.UInt8;

// A window's start carried by a loop's phi (Opt's window, SpanWindows): the
// phi holds the previous iteration's value, so a start is trusted only
// where its edge leaves tested against c.length - m, the same in every
// iteration. Kept: a width that changes (widths), a start never tested on
// one edge (skips), a span that shrinks (shrinks); dropped: a start tested
// on every edge against a fixed width (steps).
// span-checks: P.steps=0 P.widths=1 P.skips=1 P.shrinks=1
@:hxmc.kernel class P {
	public static function steps(c:ReadOnlySpan<UInt8>, m:Int, as:ReadOnlySpan<UInt8>):Int {
		var n = c.length, p = 0, sum = 0, j = 0;
		if (m < 1 || m > n) return -1;
		while (j < as.length) {
			var a:Int = as[j];
			j++;
			if (a < 0 || a > n - m) return -2;
			for (k in 0...m)
				sum += (c[p + k] : Int);
			p = a;
		}
		return sum;
	}

	public static function widths(c:ReadOnlySpan<UInt8>, ms:ReadOnlySpan<UInt8>, as:ReadOnlySpan<UInt8>):Int {
		var n = c.length, p = 0, sum = 0, j = 0;
		while (j < ms.length && j < as.length) {
			var m:Int = ms[j], a:Int = as[j];
			j++;
			if (m > n || m < 1) return -1;
			if (a < 0 || a > n - m) return -2;
			for (k in 0...m)
				sum += (c[p + k] : Int);
			p = a;
		}
		return sum;
	}

	public static function skips(c:ReadOnlySpan<UInt8>, m:Int, as:ReadOnlySpan<UInt8>):Int {
		var n = c.length, p = 0, sum = 0, j = 0;
		if (m < 1 || m > n) return -1;
		while (j < as.length) {
			var a:Int = as[j];
			j++;
			if (a > 200) {
				p = a;
				continue;
			}
			if (a < 0 || a > n - m) return -2;
			sum += (c[p] : Int);
			p = a;
		}
		return sum;
	}

	public static function shrinks(c:ReadOnlySpan<UInt8>, as:ReadOnlySpan<UInt8>):Int {
		var p = 0, sum = 0, j = 0;
		while (j < as.length && c.length > 1) {
			var n = c.length, a:Int = as[j];
			j++;
			if (a < 0 || a > n - 1) return -3;
			sum += (c[p] : Int);
			p = a;
			c = c.sub(0, n - 1);
		}
		return sum;
	}
}

class SpanWindowPhis {
	static function bytes(a:Array<Int>):Bytes {
		var b = Bytes.alloc(a.length);
		for (i in 0...a.length)
			b.set(i, a[i]);
		return b;
	}

	static function main() {
		var c = Bytes.alloc(16);
		for (i in 0...16)
			c.set(i, i + 1);
		trace(P.steps(ReadOnlySpan.ofBytes(c), 4, ReadOnlySpan.ofBytes(bytes([3, 12, 0]))), P.widths(ReadOnlySpan.ofBytes(c), ReadOnlySpan.ofBytes(bytes([4, 2, 1])), ReadOnlySpan.ofBytes(bytes([12, 14, 15]))));
		trace(P.skips(ReadOnlySpan.ofBytes(c), 1, ReadOnlySpan.ofBytes(bytes([5, 250]))), P.shrinks(ReadOnlySpan.ofBytes(c), ReadOnlySpan.ofBytes(bytes([10, 3, 2]))));
		// (the previous width's start, 15, for a width of 16: its check ends the program)
		trace(P.widths(ReadOnlySpan.ofBytes(c), ReadOnlySpan.ofBytes(bytes([1, 16])), ReadOnlySpan.ofBytes(bytes([15, 0]))));
	}
}
