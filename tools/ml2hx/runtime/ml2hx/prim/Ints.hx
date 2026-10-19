package ml2hx.prim;

import haxe.Int64;
import ml2hx.rt.*;

// A C printf specification, as OCaml's runtime receives it from
// CamlinternalFormat: %[flags][width][.precision][l|L|n]conv.
class CSpec {
	public var minus = false;
	public var zero = false;
	public var plus = false;
	public var space = false;
	public var hash = false;
	public var width = 0;
	public var prec = -1;
	public var conv = 0;

	public function new(fmt:String) {
		var i = 0, n = fmt.length;
		inline function c() return StringTools.fastCodeAt(fmt, i);
		if (i < n && c() == "%".code) i++;
		while (i < n) {
			switch c() {
				case "-".code: minus = true;
				case "0".code: zero = true;
				case "+".code: plus = true;
				case " ".code: space = true;
				case "#".code: hash = true;
				case _: break;
			}
			i++;
		}
		while (i < n && c() >= 48 && c() <= 57) {
			width = width * 10 + c() - 48;
			i++;
		}
		if (i < n && c() == ".".code) {
			i++;
			prec = 0;
			while (i < n && c() >= 48 && c() <= 57) {
				prec = prec * 10 + c() - 48;
				i++;
			}
		}
		while (i < n && (c() == "l".code || c() == "L".code || c() == "n".code || c() == "h".code)) i++;
		if (i < n) conv = c();
	}

	// the field: `body` (without its sign) padded to the width
	public function pad(sign:String, prefix:String, body:String, zeroOk:Bool):String {
		var len = sign.length + prefix.length + body.length;
		if (width <= len) return sign + prefix + body;
		var fill = width - len;
		if (minus) return sign + prefix + body + StringTools.lpad("", " ", fill);
		if (zero && zeroOk) return sign + prefix + StringTools.lpad("", "0", fill) + body;
		return StringTools.lpad("", " ", fill) + sign + prefix + body;
	}
}

// OCaml's ints.c: formatting and parsing of int, int32, int64, nativeint
// (nativeint is 64-bit, as int64).
class Ints {
	// an unsigned 64-bit value in base 8, 10 or 16
	public static function unsigned(v:Int64, base:Int, upper:Bool):String {
		if (v == 0) return "0";
		var digits = upper ? "0123456789ABCDEF" : "0123456789abcdef";
		var buf = [];
		var b = Int64.ofInt(base);
		while (v != 0) {
			var q = Int64.divMod(v >>> 1, Int64.ofInt(base >> 1)).quotient;
			if (base & 1 == 1) q = Int64.divMod(v >>> 1, b).quotient << 1;
			var r = v - q * b;
			while (Int64.ucompare(r, b) >= 0) {
				q = q + 1;
				r = r - b;
			}
			buf.push(digits.charAt(r.low));
			v = q;
		}
		buf.reverse();
		return buf.join("");
	}

	// C's printf of an integer of `bits` bits (sign-extended in v)
	public static function format(fmt:String, v:Int64, bits:Int):String {
		var s = new CSpec(fmt);
		var sign = "", prefix = "", body;
		switch s.conv {
			case "d".code | "i".code:
				var neg = v < 0;
				body = neg ? (v == Int64.make(0x80000000, 0) ? "9223372036854775808" : Int64.toStr(-v)) : Int64.toStr(v);
				sign = neg ? "-" : (s.plus ? "+" : (s.space ? " " : ""));
			case c:
				var u = bits == 32 ? Int64.make(0, v.low) : v;
				body = switch c {
					case "x".code: unsigned(u, 16, false);
					case "X".code: unsigned(u, 16, true);
					case "o".code: unsigned(u, 8, false);
					case "u".code: unsigned(u, 10, false);
					case _: throw new InvalidArgument("format_int: bad conversion");
				}
				if (s.hash && u != 0) switch c {
					case "x".code: prefix = "0x";
					case "X".code: prefix = "0X";
					case "o".code: body = "0" + body;
					case _:
				}
		}
		if (s.prec >= 0) {
			if (s.prec == 0 && v == 0) body = "";
			if (body.length < s.prec) body = StringTools.lpad(body, "0", s.prec);
		}
		return s.pad(sign, prefix, body, s.prec < 0);
	}

	public static function camlFormatInt(fmt:String, n:Int63):String return format(fmt, n.toInt64(), 64);
	public static function camlInt32Format(fmt:String, n:haxe.Int32):String return format(fmt, Int64.ofInt(n), 32);
	public static function camlInt64Format(fmt:String, n:Int64):String return format(fmt, n, 64);
	public static function camlNativeintFormat(fmt:String, n:Int64):String return format(fmt, n, 64);

	// parse_intnat: sign, 0x 0o 0b 0u prefixes, '_' after the first digit
	public static function parse(s:String, nbits:Int, err:String):Int64 {
		var p = 0, n = s.length;
		var sign = 1;
		if (p < n && StringTools.fastCodeAt(s, p) == "-".code) {
			sign = -1;
			p++;
		} else if (p < n && StringTools.fastCodeAt(s, p) == "+".code)
			p++;
		var base = 10, signed = true;
		if (p + 1 < n && StringTools.fastCodeAt(s, p) == "0".code) {
			switch StringTools.fastCodeAt(s, p + 1) {
				case "x".code | "X".code:
					base = 16;
					signed = false;
					p += 2;
				case "o".code | "O".code:
					base = 8;
					signed = false;
					p += 2;
				case "b".code | "B".code:
					base = 2;
					signed = false;
					p += 2;
				case "u".code | "U".code:
					signed = false;
					p += 2;
				case _:
			}
		}
		var b64 = Int64.ofInt(base);
		var threshold = udiv(Int64.make(0xFFFFFFFF, 0xFFFFFFFF), base);
		var d = p < n ? digit(StringTools.fastCodeAt(s, p)) : -1;
		if (d < 0 || d >= base) throw new Failure(err);
		var res = Int64.ofInt(d);
		p++;
		while (p < n) {
			var c = StringTools.fastCodeAt(s, p);
			if (c == "_".code) {
				p++;
				continue;
			}
			d = digit(c);
			if (d < 0 || d >= base) break;
			if (Int64.ucompare(res, threshold) > 0) throw new Failure(err);
			res = res * b64 + d;
			if (Int64.ucompare(res, Int64.ofInt(d)) < 0) throw new Failure(err);
			p++;
		}
		if (p != n) throw new Failure(err);
		if (signed) {
			var lim = Int64.make(nbits == 64 ? 0x80000000 : (nbits == 63 ? 0x40000000 : 0), nbits == 32 ? 0x80000000 : 0);
			if (sign >= 0) {
				if (Int64.ucompare(res, lim) >= 0) throw new Failure(err);
			} else {
				if (Int64.ucompare(res, lim) > 0) throw new Failure(err);
			}
		} else if (nbits < 64) {
			var lim = Int64.make(nbits == 63 ? 0x80000000 : 1, 0);
			if (Int64.ucompare(res, lim) >= 0) throw new Failure(err);
		}
		var r = sign < 0 ? -res : res;
		// an unsigned literal beyond the signed range wraps (0xFFFFFFFF : int32 = -1)
		if (nbits == 32) r = Int64.ofInt(r.low);
		return r;
	}

	static function udiv(v:Int64, base:Int):Int64 {
		var b = Int64.ofInt(base);
		var q = Int64.div(v >>> 1, Int64.ofInt(base >> 1));
		if (base & 1 == 1) q = Int64.div(v >>> 1, b) << 1;
		var r = v - q * b;
		while (Int64.ucompare(r, b) >= 0) {
			q = q + 1;
			r = r - b;
		}
		return q;
	}

	static function digit(c:Int):Int {
		if (c >= "0".code && c <= "9".code) return c - "0".code;
		if (c >= "A".code && c <= "F".code) return c - "A".code + 10;
		if (c >= "a".code && c <= "f".code) return c - "a".code + 10;
		return -1;
	}

	public static function camlIntOfString(s:String):Int63 return Int63.ofInt64(parse(s, 63, "int_of_string"));
	public static function camlInt32OfString(s:String):haxe.Int32 return parse(s, 32, "Int32.of_string").low;
	public static function camlInt64OfString(s:String):Int64 return parse(s, 64, "Int64.of_string");
	public static function camlNativeintOfString(s:String):Int64 return parse(s, 64, "Nativeint.of_string");

	public static function camlInt32OfFloat(f:Float):haxe.Int32 return Float64.toInt64(f).low;
	public static function camlInt32ToFloat(n:haxe.Int32):Float return n;
	public static function camlInt64OfFloat(f:Float):Int64 return Float64.toInt64(f);
	public static function camlInt64ToFloat(n:Int64):Float return Float64.ofInt64(n);
	public static function camlNativeintOfFloat(f:Float):Int64 return Float64.toInt64(f);
	public static function camlNativeintToFloat(n:Int64):Float return Float64.ofInt64(n);

	public static function camlInt32BitsOfFloat(f:Float):haxe.Int32 return haxe.io.FPHelper.floatToI32(f);
	public static function camlInt32FloatOfBits(n:haxe.Int32):Float return haxe.io.FPHelper.i32ToFloat(n);
	public static function camlInt64BitsOfFloat(f:Float):Int64 return Float64.bits(f);
	public static function camlInt64FloatOfBits(n:Int64):Float return Float64.ofBits(n);

	public static function camlInt32Compare(a:haxe.Int32, b:haxe.Int32):Int63 return Int63.ofInt(a < b ? -1 : a > b ? 1 : 0);
	public static function camlInt64Compare(a:Int64, b:Int64):Int63 return Int63.ofInt(Int64.compare(a, b) < 0 ? -1 : Int64.compare(a, b) > 0 ? 1 : 0);
	public static function camlNativeintCompare(a:Int64, b:Int64):Int63 return camlInt64Compare(a, b);
	public static function camlIntCompare(a:Int63, b:Int63):Int63 return Int63.ofInt(Int63.compare(a, b) < 0 ? -1 : Int63.compare(a, b) > 0 ? 1 : 0);
}
