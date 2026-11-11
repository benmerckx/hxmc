import haxe.io.Bytes;
import hxmc.ReadOnlySpan;
import hxmc.unsafe.UInt8;

// Element checks of windows a loop proves (Opt.condProp's window; Str's
// search): d's m units compared at each i, c[i + k] with
// 0 <= i <= c.length - m, 0 <= k < m and m <= c.length tested; i counting
// up from a value tested >= 0 (while i < c.length - m + 1: i++ cannot
// wrap) or down from one tested <= c.length - m. And a bound tested
// against two lengths at once (`n > a.length || n > b.length`). The ones
// it must keep: m never tested against c's length (c[i + k]), a start
// never tested against c.length - m.
// span-checks: W.first=0 W.last=0 W.common=0 W.untested=1 W.unbounded=2
@:hxmc.kernel class W {
	public static function first(c:ReadOnlySpan<UInt8>, d:ReadOnlySpan<UInt8>, from:Int):Int {
		var m = d.length, i = from;
		if (m < 1 || m > c.length || i < 0) return -1;
		while (i < c.length - m + 1) {
			var k = 0;
			while (k < m && (c[i + k] : Int) == (d[k] : Int))
				k++;
			if (k == m) return i;
			i++;
		}
		return -1;
	}

	public static function last(c:ReadOnlySpan<UInt8>, d:ReadOnlySpan<UInt8>, from:Int):Int {
		var m = d.length, i = from;
		if (m < 1 || m > c.length || i > c.length - m) return -1;
		while (i >= 0) {
			if ((c[i] : Int) == (d[0] : Int)) {
				var k = 1;
				while (k < m && (c[i + k] : Int) == (d[k] : Int))
					k++;
				if (k == m) return i;
			}
			i--;
		}
		return -1;
	}

	// the length of a and b's common prefix
	public static function common(a:ReadOnlySpan<UInt8>, b:ReadOnlySpan<UInt8>):Int {
		var n = a.length < b.length ? a.length : b.length;
		if (n > a.length || n > b.length) return -1;
		for (i in 0...n)
			if ((a[i] : Int) != (b[i] : Int)) return i;
		return n;
	}

	public static function untested(c:ReadOnlySpan<UInt8>, d:ReadOnlySpan<UInt8>, from:Int):Int {
		var m = d.length, i = from;
		if (m < 1 || i < 0) return -1;
		while (i < c.length - m + 1) {
			var k = 0;
			while (k < m && (c[i + k] : Int) == (d[k] : Int))
				k++;
			if (k == m) return i;
			i++;
		}
		return -1;
	}

	public static function unbounded(c:ReadOnlySpan<UInt8>, d:ReadOnlySpan<UInt8>, from:Int):Int {
		var m = d.length, i = from;
		if (m < 1 || m > c.length) return -1;
		while (i >= 0) {
			if ((c[i] : Int) == (d[0] : Int)) {
				var k = 1;
				while (k < m && (c[i + k] : Int) == (d[k] : Int))
					k++;
				if (k == m) return i;
			}
			i--;
		}
		return -1;
	}
}

class SpanWindows {
	static function span(s:String):Bytes
		return Bytes.ofString(s);

	static function main() {
		var c = span("abracadabra"), d = span("abra"), e = span("cad"), z = span("");
		Sys.println([
			W.first(ReadOnlySpan.ofBytes(c), ReadOnlySpan.ofBytes(d), 0),
			W.first(ReadOnlySpan.ofBytes(c), ReadOnlySpan.ofBytes(d), 1),
			W.first(ReadOnlySpan.ofBytes(c), ReadOnlySpan.ofBytes(e), 0),
			W.first(ReadOnlySpan.ofBytes(c), ReadOnlySpan.ofBytes(e), 5),
			W.first(ReadOnlySpan.ofBytes(d), ReadOnlySpan.ofBytes(c), 0),
			W.first(ReadOnlySpan.ofBytes(c), ReadOnlySpan.ofBytes(z), 0)
		]);
		Sys.println([
			W.last(ReadOnlySpan.ofBytes(c), ReadOnlySpan.ofBytes(d), 7),
			W.last(ReadOnlySpan.ofBytes(c), ReadOnlySpan.ofBytes(d), 6),
			W.last(ReadOnlySpan.ofBytes(c), ReadOnlySpan.ofBytes(e), 3),
			W.last(ReadOnlySpan.ofBytes(c), ReadOnlySpan.ofBytes(d), 8)
		]);
		Sys.println([
			W.common(ReadOnlySpan.ofBytes(c), ReadOnlySpan.ofBytes(d)),
			W.common(ReadOnlySpan.ofBytes(d), ReadOnlySpan.ofBytes(c)),
			W.common(ReadOnlySpan.ofBytes(c), ReadOnlySpan.ofBytes(e))
		]);
		Sys.println([
			W.untested(ReadOnlySpan.ofBytes(c), ReadOnlySpan.ofBytes(e), 0),
			W.unbounded(ReadOnlySpan.ofBytes(c), ReadOnlySpan.ofBytes(d), 7)
		]);
	}
}
