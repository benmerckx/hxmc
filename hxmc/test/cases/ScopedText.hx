import hxmc.scoped.*;

// The text cores on both faces (docs/plans/lowlevel.md, "One core, two
// faces"): numbers to text and back (hxmc.rt.FloatText: Std.string and
// Std.parseFloat on the GC face, Str.ofFloat and toFloat on the scoped one)
// and case mapping beyond ASCII (hxmc.rt.CaseMap: String's toUpperCase and
// toLowerCase, Str.toCase). The two faces must agree on every value.
@:hxmc.scoped class Code {
	public static function ofFloat(v:Float, out:Grow<Int>) {
		var s = Str.ofFloat(v);
		for (i in 0...s.length)
			out.push(s[i]);
	}

	public static function toFloat(text:Str):Float
		return text.toFloat();

	public static function toCase(text:Str, toUpper:Bool, out:Grow<Int>) {
		var s = text.toCase(toUpper);
		for (i in 0...s.length)
			out.push(s[i]);
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
		trace(bad == 0 ? "the faces agree" : '$bad differ');
		trace([for (v in values) Std.string(v)].join(" "));
		trace([for (t in texts) Std.string(Std.parseFloat(t))].join(" "));
		trace([for (w in words) w.toUpperCase() + "/" + w.toLowerCase()].join(" "));
	}
}
