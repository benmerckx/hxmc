package ml2hx.rt;

using StringTools;

// One printf conversion with C's (and so OCaml's Printf's) semantics. The
// emitter compiles format strings to concatenations of these. spec is the
// conversion's text, e.g. "%-5d", "%.3f", "%08x", "%S".
class Format {
	static function parse(spec:String):{flags:String, width:Int, precision:Int, conv:String} {
		var i = 1, flags = "";
		while (i < spec.length && "-0+ #".indexOf(spec.charAt(i)) >= 0) flags += spec.charAt(i++);
		var w = 0, hasW = false;
		while (i < spec.length && spec.charCodeAt(i) >= 48 && spec.charCodeAt(i) <= 57) { w = w * 10 + spec.charCodeAt(i++) - 48; hasW = true; }
		var p = -1;
		if (i < spec.length && spec.charAt(i) == ".") {
			i++;
			p = 0;
			while (i < spec.length && spec.charCodeAt(i) >= 48 && spec.charCodeAt(i) <= 57) p = p * 10 + spec.charCodeAt(i++) - 48;
		}
		return {flags: flags, width: hasW ? w : 0, precision: p, conv: spec.substr(i)};
	}
	static function pad(s:String, flags:String, width:Int, zeroOk:Bool):String {
		if (s.length >= width) return s;
		if (flags.indexOf("-") >= 0) return s.rpad(" ", width);
		if (zeroOk && flags.indexOf("0") >= 0) {
			var sign = (s.startsWith("-") || s.startsWith("+") || s.startsWith(" ")) ? s.charAt(0) : "";
			var rest = s.substr(sign.length);
			var prefix = (rest.startsWith("0x") || rest.startsWith("0X")) ? rest.substr(0, 2) : "";
			rest = rest.substr(prefix.length);
			return sign + prefix + rest.lpad("0", width - sign.length - prefix.length);
		}
		return s.lpad(" ", width);
	}
	static function unsignedString(v:Int, base:Int, upper:Bool):String {
		// v as an unsigned 32-bit value.
		var digits = upper ? "0123456789ABCDEF" : "0123456789abcdef";
		if (v == 0) return "0";
		var hi = v >>> 16, lo = v & 0xFFFF;
		var n:Float = hi * 65536.0 + lo;
		var s = "";
		while (n > 0) {
			var d = Std.int(n % base);
			s = digits.charAt(d) + s;
			n = Math.ffloor(n / base);
		}
		return s;
	}
	public static function int(spec:String, v:Int):String {
		var f = parse(spec);
		var s = switch f.conv {
			case "d" | "i":
				var a = v < 0 ? Std.string(-(v : Float)) : Std.string(v);
				var digits = f.precision >= 0 ? a.lpad("0", f.precision) : a;
				(v < 0 ? "-" : f.flags.indexOf("+") >= 0 ? "+" : f.flags.indexOf(" ") >= 0 ? " " : "") + digits;
			case "u": unsignedString(v, 10, false);
			case "x": (f.flags.indexOf("#") >= 0 && v != 0 ? "0x" : "") + unsignedString(v, 16, false);
			case "X": (f.flags.indexOf("#") >= 0 && v != 0 ? "0X" : "") + unsignedString(v, 16, true);
			case "o": (f.flags.indexOf("#") >= 0 && v != 0 ? "0" : "") + unsignedString(v, 8, false);
			case c: throw new InvalidArgumentExn("format: %" + c);
		}
		return pad(s, f.flags, f.width, f.precision < 0);
	}
	public static function int32(spec:String, v:haxe.Int32):String return int(spec, v);
	public static function int64(spec:String, v:haxe.Int64):String {
		var f = parse(spec);
		if (f.conv == "d" || f.conv == "i") {
			var s = haxe.Int64.toStr(v);
			if (!s.startsWith("-") && f.flags.indexOf("+") >= 0) s = "+" + s;
			return pad(s, f.flags, f.width, true);
		}
		if (f.conv == "x" || f.conv == "X") {
			var s = (unsignedString(v.high, 16, f.conv == "X") + (v.high != 0 ? unsignedString(v.low, 16, f.conv == "X").lpad("0", 8) : "")).replace("", "");
			if (v.high == 0) s = unsignedString(v.low, 16, f.conv == "X");
			return pad(s, f.flags, f.width, true);
		}
		throw new InvalidArgumentExn("format: int64 %" + f.conv);
	}
	public static function string(spec:String, s:String):String {
		var f = parse(spec);
		if (f.precision >= 0) s = s.substr(0, f.precision);
		return pad(s, f.flags, f.width, false);
	}
	// %S: OCaml syntax for the string (String.escaped, in quotes).
	public static function camlString(spec:String, s:String):String {
		var f = parse(spec);
		return pad('"' + escaped(s) + '"', f.flags, f.width, false);
	}
	public static function camlChar(spec:String, c:Int):String {
		var f = parse(spec);
		var s = c == "'".code ? "\\'" : escaped(String.fromCharCode(c));
		return pad("'" + s + "'", f.flags, f.width, false);
	}
	public static function escaped(s:String):String {
		var b = new StringBuf();
		for (i in 0...s.length) {
			var c = s.fastCodeAt(i);
			switch c {
				case '"'.code: b.add('\\"');
				case '\\'.code: b.add("\\\\");
				case '\n'.code: b.add("\\n");
				case '\t'.code: b.add("\\t");
				case '\r'.code: b.add("\\r");
				case 8: b.add("\\b");
				case _ if (c >= 32 && c <= 126): b.addChar(c);
				case _: b.add("\\" + Std.string(c).lpad("0", 3));
			}
		}
		return b.toString();
	}

	// ---------------------------------------------------------------- floats
	public static function float(spec:String, x:Float):String {
		var f = parse(spec);
		var conv = f.conv.charAt(f.conv.length - 1);
		var alt = f.flags.indexOf("#") >= 0 || f.conv.length > 1;
		var neg = x < 0 || (x == 0 && 1 / x < 0);
		var sign = neg ? "-" : f.flags.indexOf("+") >= 0 ? "+" : f.flags.indexOf(" ") >= 0 ? " " : "";
		var a = Math.abs(x);
		var body:String;
		if (Math.isNaN(x)) {
			body = conv == "F" ? "nan" : (conv == "E" || conv == "G") ? "NAN" : "nan";
			sign = conv == "F" ? "" : sign;
			if (conv == "F") return pad("nan", f.flags, f.width, false);
		} else if (!Math.isFinite(x)) {
			body = (conv == "E" || conv == "G") ? "INF" : conv == "F" ? "infinity" : "inf";
		} else {
			var p = f.precision < 0 ? 6 : f.precision;
			body = switch conv {
				case "f": fixed(a, p);
				case "e" | "E": var s = exponent(a, p); conv == "E" ? s.toUpperCase() : s;
				case "g" | "G": var s = general(a, f.precision < 0 ? 6 : (f.precision == 0 ? 1 : f.precision), alt); conv == "G" ? s.toUpperCase() : s;
				case "F": ocamlFloat(a);
				case "h" | "H": throw new InvalidArgumentExn("format: %h");
				case c: throw new InvalidArgumentExn("format: %" + c);
			}
		}
		return pad(sign + body, f.flags, f.width, Math.isFinite(x));
	}
	// OCaml's %F: like %.12g, with a trailing "." when it reads as an int.
	static function ocamlFloat(a:Float):String {
		var s = general(a, 12, false);
		for (i in 0...s.length) { var c = s.charAt(i); if (c == "." || c == "e" || c == "n" || c == "i") return s; }
		return s + ".";
	}
	// Exact decimal digits of a finite non-negative double: (digits, exponent)
	// with value = 0.digits * 10^exponent.
	static function exactDigits(a:Float):{digits:String, point:Int} {
		if (a == 0) return {digits: "0", point: 1};
		var bits = haxe.io.FPHelper.doubleToI64(a);
		var hi = bits.high, lo = bits.low;
		var e = (hi >>> 20) & 0x7FF;
		var mhi = hi & 0xFFFFF;
		if (e != 0) mhi |= 0x100000; else e = 1;
		e -= 1075;
		// mantissa as a big number in base 1e7 limbs (little endian)
		var m:Array<Int> = [];
		var lou:Float = lo < 0 ? lo + 4294967296.0 : lo;
		var mv:Float = mhi * 4294967296.0 + lou;
		while (mv > 0) { var r = mv % 10000000; m.push(Std.int(r)); mv = (mv - r) / 10000000; }
		var point:Int;
		if (e >= 0) {
			for (_ in 0...e) mulSmall(m, 2);
			point = 0;
		} else {
			for (_ in 0...(-e)) mulSmall(m, 5);
			point = e; // value = m * 10^e
		}
		var s = limbsToString(m);
		return {digits: s, point: s.length + point};
	}
	static function mulSmall(m:Array<Int>, k:Int) {
		var carry = 0;
		for (i in 0...m.length) {
			var v = m[i] * k + carry;
			m[i] = v % 10000000;
			carry = Std.int(v / 10000000);
		}
		while (carry > 0) { m.push(carry % 10000000); carry = Std.int(carry / 10000000); }
	}
	static function limbsToString(m:Array<Int>):String {
		var i = m.length - 1;
		while (i > 0 && m[i] == 0) i--;
		var s = Std.string(m[i]);
		while (--i >= 0) s += Std.string(m[i]).lpad("0", 7);
		return s;
	}
	// Round digits (value 0.d1d2... * 10^point) to n digits after the
	// decimal point, half to even on exact ties.
	static function roundAt(digits:String, point:Int, keep:Int):{digits:String, point:Int} {
		// keep = number of significant digits to keep (may be <= 0)
		if (keep >= digits.length) return {digits: digits, point: point};
		if (keep < 0) return {digits: "0", point: point};
		var head = digits.substr(0, keep);
		var next = digits.charCodeAt(keep) - 48;
		var rest = digits.substr(keep + 1);
		var up = next > 5 || (next == 5 && (~/[1-9]/.match(rest) || (keep > 0 && (head.charCodeAt(keep - 1) - 48) % 2 == 1)));
		if (!up) return {digits: head == "" ? "0" : head, point: point};
		var arr = [for (i in 0...head.length) head.charCodeAt(i) - 48];
		var i = arr.length - 1;
		while (i >= 0) { if (arr[i] < 9) { arr[i]++; break; } arr[i] = 0; i--; }
		var out = [for (d in arr) Std.string(d)].join("");
		if (i < 0) { out = "1" + out; point++; }
		return {digits: out, point: point};
	}
	static function fixed(a:Float, p:Int):String {
		var d = exactDigits(a);
		var r = roundAt(d.digits, d.point, d.point + p);
		var digits = r.digits, point = r.point;
		if (a != 0 && digits == "0") point = 1;
		if (a == 0) { digits = "0"; point = 1; }
		var intPart = point > 0 ? (digits.substr(0, point)).rpad("0", point) : "0";
		var frac = point >= 0 ? digits.substr(point) : "".lpad("0", -point) + digits;
		frac = frac.rpad("0", p).substr(0, p);
		intPart = intPart.length == 0 ? "0" : intPart;
		return p > 0 ? intPart + "." + frac : intPart;
	}
	static function exponent(a:Float, p:Int):String {
		var d = exactDigits(a);
		var r = a == 0 ? {digits: "0", point: 1} : roundAt(d.digits, d.point, p + 1);
		var digits = r.digits.rpad("0", p + 1);
		var exp = a == 0 ? 0 : r.point - 1;
		var mant = digits.charAt(0) + (p > 0 ? "." + digits.substr(1, p) : "");
		var es = Std.string(exp < 0 ? -exp : exp).lpad("0", 2);
		return mant + "e" + (exp < 0 ? "-" : "+") + es;
	}
	static function general(a:Float, p:Int, alt:Bool):String {
		var exp:Int;
		if (a == 0) exp = 0; else {
			var d = exactDigits(a);
			var r = roundAt(d.digits, d.point, p);
			exp = r.point - 1;
		}
		var s = (exp < -4 || exp >= p) ? exponent(a, p - 1) : fixed(a, p - 1 - exp);
		if (!alt) {
			var ePos = s.indexOf("e");
			var mant = ePos >= 0 ? s.substr(0, ePos) : s, tail = ePos >= 0 ? s.substr(ePos) : "";
			if (mant.indexOf(".") >= 0) {
				while (mant.endsWith("0")) mant = mant.substr(0, mant.length - 1);
				if (mant.endsWith(".")) mant = mant.substr(0, mant.length - 1);
			}
			s = mant + tail;
		}
		return s;
	}
}
