package hxmc.rt;

import hxmc.scoped.Slice;
import hxmc.scoped.Str;

// Date's text, written once as scoped code over the scoped abstractions
// (docs/plans/lowlevel.md, "Two representations, one core"): the forms of
// HxOverrides.strDate read into fields, and "%04d-%02d-%02d %02d:%02d:%02d"
// written. The fields are six Ints: year, month (1 to 12), day, hours,
// minutes, seconds. The GC face is hxmc.rt.Date (fromString, toString), on
// every target; the calendar stays the C library's, or the host's on WasmGC.
@:hxmc.scoped
class DateText {
	// the fields c holds into f (checked: 6 of them): 1 a time of day
	// ("hh:mm:ss"), 2 a date ("YYYY-MM-DD"), 3 both ("YYYY-MM-DD hh:mm:ss");
	// 0 none of these
	public static inline function parse(c:Str, f:Slice<Int>):Int {
		if (f.length < 6) Abort.outOfRange();
		var n = c.length, r = 0;
		if (n == 8) {
			if (digits(c, 0, 2, f, 3) && c.unit(2) == ":".code && digits(c, 3, 2, f, 4) && c.unit(5) == ":".code && digits(c, 6, 2, f, 5)) r = 1;
		} else if ((n == 10 || n == 19) && digits(c, 0, 4, f, 0) && c.unit(4) == "-".code && digits(c, 5, 2, f, 1) && c.unit(7) == "-".code
			&& digits(c, 8, 2, f, 2)) {
			if (n == 10) r = 2 else if (c.unit(10) == " ".code && digits(c, 11, 2, f, 3) && c.unit(13) == ":".code && digits(c, 14, 2, f, 4)
				&& c.unit(16) == ":".code && digits(c, 17, 2, f, 5)) r = 3;
		}
		return r;
	}

	// the decimal digits at [pos, pos + count) of c into f[k]; false: a unit that is none
	static inline function digits(c:Str, pos:Int, count:Int, f:Slice<Int>, k:Int):Bool {
		var v = 0, ok = true;
		for (i in pos...pos + count) {
			var u = c.unit(i);
			if (u < "0".code || u > "9".code) ok = false else v = v * 10 + u - "0".code;
		}
		f.unsafeSet(k, v);
		return ok;
	}

	// the units of the fields f (checked: 6) as text
	public static inline function length(f:Slice<Int>):Int {
		if (f.length < 6) Abort.outOfRange();
		var n = 5; // the separators
		for (k in 0...6)
			n += padded(f.unsafeGet(k), k == 0 ? 4 : 2);
		return n;
	}

	// the fields f as text into d, which has length(f) units (checked as it fills)
	public static inline function write(f:Slice<Int>, d:Str) {
		if (f.length < 6) Abort.outOfRange();
		var j = 0;
		for (k in 0...6) {
			if (k > 0) {
				if (j >= d.length) Abort.outOfRange();
				d.setUnit(j++, k < 3 ? "-".code : k == 3 ? " ".code : ":".code);
			}
			j = pad(f.unsafeGet(k), k == 0 ? 4 : 2, d, j);
		}
	}

	// the units of v written at least w wide (a sign counts), zeros first
	static inline function padded(v:Int, w:Int):Int {
		var n = TextCore.intLength(v);
		return n > w ? n : w;
	}

	// v so written at j in d: where it ends
	static inline function pad(v:Int, w:Int, d:Str, j:Int):Int {
		var n = padded(v, w), digits = TextCore.intLength(v);
		if (j + n > d.length) Abort.outOfRange();
		var at = j;
		if (v < 0) d.setUnit(at++, "-".code);
		for (_ in digits...n)
			d.setUnit(at++, "0".code);
		// (the digits without their sign: intWrite of the magnitude after it)
		TextCore.intWrite(v < 0 ? -v : v, d.sub(at, j + n - at));
		return j + n;
	}
}
