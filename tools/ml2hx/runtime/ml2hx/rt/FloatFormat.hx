package ml2hx.rt;

// Float printing as OCaml's caml_format_float does it with glibc's printf
// (%f, %e, %E, %g, %G with the flags - + space # 0, a precision): the exact
// decimal value of the double, rounded to the requested digits to nearest,
// ties to even; "inf", "-inf", "nan", "-nan" (by the sign bit) for the
// specials. Padding is the caller's (Printf's fix_padding).
class FloatFormat {
	// ---- exact decimal digits of a positive finite double

	// big integers: little-endian limbs of base 10000
	static function bigOf(m:Float):Array<Int> {
		var r = [];
		while (m > 0) {
			var q = Math.ffloor(m / 10000);
			r.push(Std.int(m - q * 10000));
			m = q;
		}
		return r;
	}

	static function bigMul(b:Array<Int>, k:Int) {
		var carry = 0;
		for (i in 0...b.length) {
			var v = b[i] * k + carry;
			carry = Std.int(v / 10000);
			b[i] = v - carry * 10000;
		}
		while (carry > 0) {
			var q = Std.int(carry / 10000);
			b.push(carry - q * 10000);
			carry = q;
		}
	}

	static function bigDigits(b:Array<Int>):String {
		var buf = new StringBuf();
		var i = b.length - 1;
		buf.add(Std.string(b[i]));
		while (--i >= 0) {
			var v = b[i];
			if (v < 1000) buf.addChar(48);
			if (v < 100) buf.addChar(48);
			if (v < 10) buf.addChar(48);
			buf.add(Std.string(v));
		}
		return buf.toString();
	}

	// x = 0.D * 10^point where D (no leading or trailing zeros) is digits
	public static var digits:String = "";
	public static var point:Int = 0;

	public static function exact(x:Float) {
		var bits = Float64.bits(x);
		var hi = bits.high & 0x7FFFFFFF, lo = bits.low;
		var e = (hi >>> 20) & 0x7FF;
		var frac:Float = (hi & 0xFFFFF) * 4294967296.0 + (lo < 0 ? lo + 4294967296.0 : lo);
		var m:Float, e2:Int;
		if (e == 0) {
			m = frac;
			e2 = -1074;
		} else {
			m = frac + 4503599627370496.0; // 2^52
			e2 = e - 1075;
		}
		// drop trailing binary zeros: smaller numbers
		while (m > 0 && m % 2 == 0) {
			m /= 2;
			e2++;
		}
		var b = bigOf(m);
		var d:String;
		var p:Int;
		if (e2 >= 0) {
			var k = e2;
			while (k >= 13) {
				bigMul(b, 8192);
				k -= 13;
			}
			if (k > 0) bigMul(b, 1 << k);
			d = bigDigits(b);
			p = d.length;
		} else {
			var k = -e2;
			while (k >= 5) {
				bigMul(b, 3125);
				k -= 5;
			}
			var f = 1;
			for (_ in 0...k) f *= 5;
			if (f > 1) bigMul(b, f);
			d = bigDigits(b);
			p = d.length + e2;
		}
		var end = d.length;
		while (end > 1 && StringTools.fastCodeAt(d, end - 1) == 48) end--;
		digits = d.substr(0, end);
		point = p;
	}

	// keep the first `keep` digits of `digits`, rounded to nearest, ties to
	// even: sets digits (exactly `keep` of them, or keep + 1 on a carry
	// past the first) and point
	static function round(keep:Int) {
		var d = digits;
		if (keep < 0) {
			digits = "";
			point += -keep;
			// below half of the last kept unit
			return;
		}
		if (keep >= d.length) {
			digits = d + StringTools.lpad("", "0", keep - d.length);
			return;
		}
		var next = StringTools.fastCodeAt(d, keep) - 48;
		var up = next > 5 || (next == 5 && (keep + 1 < d.length || (keep > 0 && (StringTools.fastCodeAt(d, keep - 1) - 48) % 2 == 1)));
		var kept = d.substr(0, keep);
		if (!up) {
			digits = kept;
			return;
		}
		var a = [for (i in 0...keep) StringTools.fastCodeAt(kept, i) - 48];
		var i = keep - 1;
		while (i >= 0) {
			if (a[i] < 9) {
				a[i]++;
				break;
			}
			a[i] = 0;
			i--;
		}
		var buf = new StringBuf();
		if (i < 0) {
			buf.addChar(49);
			point++;
		}
		for (x in a) buf.addChar(48 + x);
		digits = buf.toString();
	}

	static function zeros(n:Int):String
		return n <= 0 ? "" : StringTools.lpad("", "0", n);

	// the digits of %e (precision p), no sign; exp written
	static function fmtE(x:Float, p:Int, alt:Bool, upper:Bool):String {
		var exp:Int;
		var ds:String;
		if (x == 0) {
			ds = zeros(p + 1);
			exp = 0;
		} else {
			exact(x);
			round(p + 1);
			ds = digits;
			if (ds.length > p + 1) ds = ds.substr(0, p + 1);
			exp = point - 1;
		}
		var buf = new StringBuf();
		buf.addChar(StringTools.fastCodeAt(ds, 0));
		if (p > 0 || alt) buf.addChar(46);
		buf.addSub(ds, 1);
		buf.addChar(upper ? 69 : 101);
		buf.addChar(exp < 0 ? 45 : 43);
		var a = exp < 0 ? -exp : exp;
		if (a < 10) buf.addChar(48);
		buf.add(Std.string(a));
		return buf.toString();
	}

	static function fmtF(x:Float, p:Int, alt:Bool):String {
		var ip:String, fp:String;
		if (x == 0) {
			ip = "0";
			fp = zeros(p);
		} else {
			exact(x);
			round(point + p);
			var ds = digits, pt = point;
			if (ds.length == 0) {
				ip = "0";
				fp = zeros(p);
			} else if (pt <= 0) {
				ip = "0";
				fp = (zeros(-pt) + ds + zeros(p)).substr(0, p);
			} else {
				var all = ds + zeros(pt + p - ds.length);
				ip = all.substr(0, pt);
				fp = all.substr(pt, p);
			}
		}
		return p > 0 || alt ? ip + "." + fp : ip;
	}

	static function stripZeros(s:String):String {
		var dot = s.indexOf(".");
		if (dot < 0) return s;
		var e = s.indexOf("e");
		if (e < 0) e = s.indexOf("E");
		var mant = e < 0 ? s : s.substr(0, e);
		var rest = e < 0 ? "" : s.substr(e);
		var end = mant.length;
		while (end > dot + 1 && StringTools.fastCodeAt(mant, end - 1) == 48) end--;
		if (end == dot + 1) end = dot;
		return mant.substr(0, end) + rest;
	}

	static function fmtG(x:Float, p:Int, alt:Bool, upper:Bool):String {
		if (p == 0) p = 1;
		var exp:Int;
		if (x == 0) exp = 0 else {
			exact(x);
			round(p);
			exp = point - 1;
		}
		var s = if (p > exp && exp >= -4) fmtF(x, p - 1 - exp, alt) else fmtE(x, p - 1, alt, upper);
		return alt ? s : stripZeros(s);
	}

	// printf's %<flags>.<prec><conv> of x without padding; conv one of f F e E g G
	public static function format(conv:Int, prec:Int, plus:Bool, space:Bool, alt:Bool, x:Float):String {
		var bits = Float64.bits(x);
		var neg = bits.high < 0;
		var sign = neg ? "-" : (plus ? "+" : (space ? " " : ""));
		var upper = conv == "E".code || conv == "G".code || conv == "F".code;
		if (x != x) return sign + (upper ? "NAN" : "nan");
		if (x == Math.POSITIVE_INFINITY || x == Math.NEGATIVE_INFINITY) return sign + (upper ? "INF" : "inf");
		var a = neg ? -x : x;
		var body = switch conv {
			case "f".code | "F".code: fmtF(a, prec, alt);
			case "e".code | "E".code: fmtE(a, prec, alt, upper);
			case _: fmtG(a, prec, alt, upper);
		}
		return sign + body;
	}

	// Stdlib.string_of_float: "%.12g", then a "." when only digits and '-'
	public static function stringOfFloat(x:Float):String {
		var s = format("g".code, 12, false, false, false, x);
		for (i in 0...s.length) {
			var c = StringTools.fastCodeAt(s, i);
			if (!((c >= 48 && c <= 57) || c == 45)) return s;
		}
		return s + ".";
	}

	// ---- float_of_string (caml_float_of_string: '_' ignored, strtod's syntax
	// including leading blanks, hexadecimal, inf, infinity, nan; nothing after)

	public static function parse(s:String):Null<Float> {
		var b = new StringBuf();
		for (i in 0...s.length) {
			var c = StringTools.fastCodeAt(s, i);
			if (c != "_".code) b.addChar(c);
		}
		var t = b.toString();
		var i = 0, n = t.length;
		while (i < n && isSpace(StringTools.fastCodeAt(t, i))) i++;
		var start = i;
		var neg = false;
		if (i < n && (StringTools.fastCodeAt(t, i) == "+".code || StringTools.fastCodeAt(t, i) == "-".code)) {
			neg = StringTools.fastCodeAt(t, i) == "-".code;
			i++;
		}
		var rest = t.substr(i).toLowerCase();
		if (rest == "inf" || rest == "infinity") return neg ? Math.NEGATIVE_INFINITY : Math.POSITIVE_INFINITY;
		if (rest == "nan" || (StringTools.startsWith(rest, "nan(") && StringTools.endsWith(rest, ")") && validNanChars(rest)))
			return neg ? -Math.NaN : Math.NaN;
		if (StringTools.startsWith(rest, "0x")) {
			var v = parseHex(rest.substr(2));
			if (v == null) return null;
			return neg ? -v : v;
		}
		// decimal: digits [. digits] [e [sign] digits], at least one digit in the mantissa
		var j = i, digits = 0;
		while (j < n && isDigit(StringTools.fastCodeAt(t, j))) {
			j++;
			digits++;
		}
		if (j < n && StringTools.fastCodeAt(t, j) == ".".code) {
			j++;
			while (j < n && isDigit(StringTools.fastCodeAt(t, j))) {
				j++;
				digits++;
			}
		}
		if (digits == 0) return null;
		if (j < n && (StringTools.fastCodeAt(t, j) == "e".code || StringTools.fastCodeAt(t, j) == "E".code)) {
			var k = j + 1;
			if (k < n && (StringTools.fastCodeAt(t, k) == "+".code || StringTools.fastCodeAt(t, k) == "-".code)) k++;
			var ed = 0;
			while (k < n && isDigit(StringTools.fastCodeAt(t, k))) {
				k++;
				ed++;
			}
			if (ed > 0) j = k; // strtod stops before a bare 'e'
		}
		if (j != n) return null;
		return Std.parseFloat(t.substr(start));
	}

	static function validNanChars(s:String):Bool {
		for (i in 4...s.length - 1) {
			var c = StringTools.fastCodeAt(s, i);
			if (!(isDigit(c) || (c >= "a".code && c <= "z".code) || c == "_".code)) return false;
		}
		return true;
	}

	static inline function isSpace(c:Int):Bool
		return c == 32 || (c >= 9 && c <= 13);

	static inline function isDigit(c:Int):Bool
		return c >= 48 && c <= 57;

	static function hexDigit(c:Int):Int {
		if (c >= 48 && c <= 57) return c - 48;
		if (c >= 97 && c <= 102) return c - 87;
		return -1;
	}

	// after "0x" (lower-cased): hex digits [. hex digits] [p [sign] decimal digits]
	static function parseHex(s:String):Null<Float> {
		var i = 0, n = s.length;
		var m = 0.0, e = 0, digits = 0;
		var significant = 0;
		while (i < n && hexDigit(StringTools.fastCodeAt(s, i)) >= 0) {
			if (significant < 15) {
				m = m * 16 + hexDigit(StringTools.fastCodeAt(s, i));
				if (m > 0) significant++;
			} else
				e += 4;
			i++;
			digits++;
		}
		if (i < n && StringTools.fastCodeAt(s, i) == ".".code) {
			i++;
			while (i < n && hexDigit(StringTools.fastCodeAt(s, i)) >= 0) {
				if (significant < 15) {
					m = m * 16 + hexDigit(StringTools.fastCodeAt(s, i));
					if (m > 0) significant++;
					e -= 4;
				}
				i++;
				digits++;
			}
		}
		if (digits == 0) return null;
		if (i < n && StringTools.fastCodeAt(s, i) == "p".code) {
			i++;
			var neg = false;
			if (i < n && (StringTools.fastCodeAt(s, i) == "+".code || StringTools.fastCodeAt(s, i) == "-".code)) {
				neg = StringTools.fastCodeAt(s, i) == "-".code;
				i++;
			}
			var x = 0, ed = 0;
			while (i < n && isDigit(StringTools.fastCodeAt(s, i))) {
				if (x < 100000) x = x * 10 + StringTools.fastCodeAt(s, i) - 48;
				i++;
				ed++;
			}
			if (ed == 0) return null;
			e += neg ? -x : x;
		}
		if (i != n) return null;
		// scale in steps that stay exact
		while (e > 0) {
			var k = e > 60 ? 60 : e;
			m *= Math.pow(2, k);
			e -= k;
		}
		while (e < 0) {
			var k = e < -60 ? 60 : -e;
			m /= Math.pow(2, k);
			e += k;
		}
		return m;
	}
}
