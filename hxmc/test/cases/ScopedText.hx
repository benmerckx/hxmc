import hxmc.scoped.*;
import hxmc.unsafe.UInt8;

// The text cores on both faces (docs/plans/lowlevel.md, "One core, two
// faces"): numbers to text and back (hxmc.rt.FloatText: Std.string and
// Std.parseFloat on the GC face, Str.ofFloat and toFloat on the scoped one)
// case mapping beyond ASCII (hxmc.rt.CaseMap: String's toUpperCase and
// toLowerCase, Str.toCase) and String's search, order, hash and UTF-8
// and integers (hxmc.rt.TextCore: Str's find, findLast, compare, hash,
// utf8, ofUtf8, ofInt, toInt).
// The two faces must agree on every value.
@:hxmc.scoped class Code {
	public static function ofFloat(v:Float, out:Grow<Int>) {
		var s = Str.ofFloat(v);
		for (i in 0...s.length)
			out.push(s[i]);
	}

	public static function toFloat(text:Str):Float
		return text.toFloat();

	public static function ofInt(v:Int, out:Grow<Int>) {
		var s = Str.ofInt(v);
		for (i in 0...s.length)
			out.push(s[i]);
	}

	public static function toInt(text:Str):Int
		return text.toInt(-12345);

	public static function toCase(text:Str, toUpper:Bool, out:Grow<Int>) {
		var s = text.toCase(toUpper);
		for (i in 0...s.length)
			out.push(s[i]);
	}

	public static function search(a:Str, b:Str, out:Grow<Int>) {
		out.push(a.find(b));
		out.push(a.find(b, 2));
		out.push(a.findLast(b, a.length));
		out.push(a.findLast(b, 1));
		out.push(a.compare(b));
		out.push(a.hash());
	}

	// the UTF-8 round trip: the units again, and the byte count
	public static function utf8(text:Str, out:Grow<Int>):Int {
		var buf:Slice<UInt8> = Scope.slice(3 * text.length + 1);
		var n = text.utf8(buf);
		var s = Str.ofUtf8(buf, n);
		for (i in 0...s.length)
			out.push(s[i]);
		return n;
	}
}

class ScopedText {
	static function units(g:Grow<Int>):String {
		var b = new StringBuf();
		for (u in g)
			b.addChar(u);
		return b.toString();
	}

	static function main() {
		var values = [0.0, -0.0, 1.0, -1.5, 0.1, 1 / 3, 1e21, 1e-7, 123456789.125, 5e-324, 1.7976931348623157e308, Math.POSITIVE_INFINITY,
			Math.NEGATIVE_INFINITY, Math.NaN, 2.5e-310, 9007199254740993.0, 0.30000000000000004];
		var bad = 0;
		for (v in values) {
			var g = new Grow<Int>();
			Code.ofFloat(v, g);
			var s = units(g);
			if (s != Std.string(v)) {
				trace('ofFloat($v): $s');
				bad++;
			}
		}
		var texts = ["0", "  42", "-1.5e3", "0x1p3", "1e400", "-1e-400", "inf", "-Infinity", "nan", "3.14abc", "abc", "", ".5", "5.", "1e",
			"0.1000000000000000055511151231257827", "2.2250738585072011e-308", "\t7"];
		for (t in texts) {
			var a = Code.toFloat(Str.copyOf(t)), b = Std.parseFloat(t);
			if (!(a == b || (Math.isNaN(a) && Math.isNaN(b))) || (a == 0 && 1 / a != 1 / b)) {
				trace('toFloat("$t"): $a, Std.parseFloat: $b');
				bad++;
			}
		}
		for (v in [0, 7, -7, 10, 2147483647, -2147483648, 1000000000]) {
			var g = new Grow<Int>();
			Code.ofInt(v, g);
			if (units(g) != Std.string(v)) {
				trace('ofInt($v): ' + units(g));
				bad++;
			}
		}
		for (t in ["12", " -3", "0x1f", "x", "", "99999999999", "+0"]) {
			var a = Code.toInt(Str.copyOf(t)), b = Std.parseInt(t);
			if (a != (b == null ? -12345 : b)) {
				trace('toInt("$t"): $a, Std.parseInt: $b');
				bad++;
			}
		}
		var words = ["hello", "ÉTÉ", "straße", "ǅungla", "Ωμέγα", "АБВгд", "ǈ", "ﬃ", "mixed Case 123"];
		for (w in words)
			for (up in [true, false]) {
				var g = new Grow<Int>();
				Code.toCase(Str.copyOf(w), up, g);
				var s = units(g);
				if (s != (up ? w.toUpperCase() : w.toLowerCase())) {
					trace('toCase("$w", $up): $s');
					bad++;
				}
			}
		var hashes = [];
		var pairs = [["hello", "l"], ["hello", "lo"], ["abcabc", "bc"], ["", ""], ["x", ""], ["abc", "abd"], ["ab", "abc"], ["Ωμέγα", "έ"], ["a😀b", "😀"]];
		for (p in pairs) {
			var a = p[0], b = p[1];
			var g = new Grow<Int>();
			Code.search(Str.copyOf(a), Str.copyOf(b), g);
			hashes.push(g[5]);
			var expect = [a.indexOf(b), a.indexOf(b, 2), a.lastIndexOf(b, a.length), a.lastIndexOf(b, 1), Reflect.compare(a, b)];
			for (i in 0...expect.length)
				if (g[i] != expect[i]) {
					trace('search("$a", "$b") #$i: ${g[i]}, String: ${expect[i]}');
					bad++;
				}
		}
		for (w in words.concat(["a😀b", "\u{10FFFF}x"])) {
			var g = new Grow<Int>();
			var n = Code.utf8(Str.copyOf(w), g);
			if (units(g) != w || n != haxe.io.Bytes.ofString(w).length) {
				trace('utf8("$w"): $n');
				bad++;
			}
		}
		trace(bad == 0 ? "the faces agree" : '$bad differ');
		trace(hashes.join(" "));
		trace([for (v in values) Std.string(v)].join(" "));
		trace([for (t in texts) Std.string(Std.parseFloat(t))].join(" "));
		trace([for (w in words) w.toUpperCase() + "/" + w.toLowerCase()].join(" "));
	}
}
