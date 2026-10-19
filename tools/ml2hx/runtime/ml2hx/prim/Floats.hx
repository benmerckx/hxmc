package ml2hx.prim;

import haxe.Int64;
import ml2hx.rt.*;
import ocaml.stdlib.StdlibModule.StdlibFpclass;

// OCaml's floats.c: C's math library and printf/strtod for doubles.
class Floats {
	public static function camlFormatFloat(fmt:String, x:Float):String {
		var s = new Ints.CSpec(fmt);
		var prec = s.prec < 0 ? 6 : s.prec;
		var str = FloatFormat.format(s.conv, prec, s.plus, s.space, s.hash, x);
		var sign = "";
		var c0 = str.length > 0 ? StringTools.fastCodeAt(str, 0) : 0;
		if (c0 == "-".code || c0 == "+".code || c0 == " ".code) {
			sign = str.charAt(0);
			str = str.substr(1);
		}
		return s.pad(sign, "", str, Math.isFinite(x));
	}

	public static function camlFloatOfString(s:String):Float {
		var v = FloatFormat.parse(s);
		if (v == null) throw new Failure("float_of_string");
		return v;
	}

	// %h: hexadecimal, as caml_hexstring_of_float (prec < 0: exact)
	public static function camlHexstringOfFloat(x:Float, prec:Int63, style:Int):String {
		var p = prec.toInt();
		var sign = Float64.bits(x).high < 0 ? "-" : (style == "+".code ? "+" : (style == " ".code ? " " : ""));
		if (x != x) return "nan";
		if (!Math.isFinite(x)) return sign + "infinity";
		var bits = Float64.bits(x);
		var exp = (bits.high >>> 20) & 0x7FF;
		var mant = Int64.make(bits.high & 0xFFFFF, bits.low);
		if (exp == 0 && mant == 0) {
			exp = 0;
		} else if (exp == 0) {
			exp = -1022;
		} else {
			exp -= 1023;
		}
		var lead = (bits.high >>> 20) & 0x7FF == 0 ? 0 : 1;
		// 13 hex digits of mantissa; round to p digits (half to even)
		var digits = 13;
		if (p >= 0 && p < 13) {
			var shift = (13 - p) * 4;
			var full = Int64.make(lead, 0) << 52 | mant;
			var one = Int64.ofInt(1) << shift;
			var half = one >> 1;
			var rem = full & (one - 1);
			var q = full >> shift;
			if (rem > half || (rem == half && (q & 1) == 1)) q = q + 1;
			full = q << shift;
			lead = ((full >> 52) & 0xF).low;
			mant = full & Int64.make(0xFFFFF, 0xFFFFFFFF);
			digits = p;
		}
		var hex = Ints.unsigned(mant, 16, false);
		hex = StringTools.lpad(hex, "0", 13).substr(0, digits);
		if (p < 0) while (hex.length > 0 && hex.charAt(hex.length - 1) == "0") hex = hex.substr(0, hex.length - 1);
		var e = (x == 0) ? 0 : exp;
		return sign + "0x" + lead + (hex.length > 0 ? "." + hex : "") + "p" + (e >= 0 ? "+" : "") + e;
	}

	public static function camlClassifyFloat(f:Float):StdlibFpclass {
		if (f != f) return FP_nan;
		if (!Math.isFinite(f)) return FP_infinite;
		if (f == 0) return FP_zero;
		var e = (Float64.bits(f).high >>> 20) & 0x7FF;
		return e == 0 ? FP_subnormal : FP_normal;
	}

	public static function camlFrexpFloat(f:Float):Tuple2<Float, Int63> {
		if (f == 0 || !Math.isFinite(f)) return new Tuple2(f, Int63.zero);
		var bits = Float64.bits(f);
		var e = (bits.high >>> 20) & 0x7FF;
		if (e == 0) {
			var r = camlFrexpFloat(f * 18014398509481984.0); // 2^54
			return new Tuple2(r.v0, Int63.sub(r.v1, Int63.ofInt(54)));
		}
		var m = Float64.ofBits(Int64.make((bits.high & 0x800FFFFF) | (1022 << 20), bits.low));
		return new Tuple2(m, Int63.ofInt(e - 1022));
	}

	public static function camlLdexpFloat(f:Float, n:Int63):Float {
		var k = Int63.lt(n, Int63.ofInt(-3000)) ? -3000 : Int63.gt(n, Int63.ofInt(3000)) ? 3000 : n.toInt();
		while (k > 1000) {
			f *= Math.pow(2, 1000);
			k -= 1000;
		}
		while (k < -1000) {
			f *= Math.pow(2, -1000);
			k += 1000;
		}
		// below the normal range in two steps, so a subnormal result rounds once
		if (k < -1022) return f * Math.pow(2, k + 54) * Math.pow(2, -54);
		return f * Math.pow(2, k);
	}

	public static function camlModfFloat(f:Float):Tuple2<Float, Float> {
		if (!Math.isFinite(f)) return new Tuple2(f != f ? f : (f > 0 ? 0.0 : -0.0), f);
		var i = f < 0 ? Math.fceil(f) : Math.ffloor(f);
		var frac = f - i;
		if (frac == 0 && f < 0) frac = -0.0;
		return new Tuple2(frac, i);
	}

	public static function camlFmodFloat(a:Float, b:Float):Float {
		if (b != b || a != a || b == 0 || !Math.isFinite(a)) return Math.NaN;
		if (!Math.isFinite(b)) return a;
		return a % b;
	}

	public static inline function camlSqrtFloat(a:Float):Float return Math.sqrt(a);
	public static inline function camlExpFloat(a:Float):Float return Math.exp(a);
	public static inline function camlLogFloat(a:Float):Float return Math.log(a);
	public static function camlLog10Float(a:Float):Float {
		// exact for powers of ten
		var r = Math.log(a) / Math.log(10);
		var k = Math.fround(r);
		return Math.abs(r - k) < 1e-12 && Math.pow(10, k) == a ? k : r;
	}
	public static function camlLog2Float(a:Float):Float {
		var r = Math.log(a) / Math.log(2);
		var k = Math.fround(r);
		return Math.abs(r - k) < 1e-12 && Math.pow(2, k) == a ? k : r;
	}
	public static function camlExp2Float(a:Float):Float return Math.pow(2, a);
	public static function camlExpm1Float(a:Float):Float {
		if (Math.abs(a) < 1e-5) return a + a * a / 2 + a * a * a / 6;
		return Math.exp(a) - 1;
	}
	public static function camlLog1pFloat(a:Float):Float {
		if (Math.abs(a) < 1e-5) return a - a * a / 2 + a * a * a / 3;
		return Math.log(1 + a);
	}
	public static inline function camlCosFloat(a:Float):Float return Math.cos(a);
	public static inline function camlSinFloat(a:Float):Float return Math.sin(a);
	public static inline function camlTanFloat(a:Float):Float return Math.tan(a);
	public static inline function camlAcosFloat(a:Float):Float return Math.acos(a);
	public static inline function camlAsinFloat(a:Float):Float return Math.asin(a);
	public static inline function camlAtanFloat(a:Float):Float return Math.atan(a);
	public static inline function camlAtan2Float(a:Float, b:Float):Float return Math.atan2(a, b);
	public static function camlCoshFloat(a:Float):Float return (Math.exp(a) + Math.exp(-a)) / 2;
	public static function camlSinhFloat(a:Float):Float return a == 0 ? a : (Math.exp(a) - Math.exp(-a)) / 2;
	public static function camlTanhFloat(a:Float):Float {
		if (a == 0) return a;
		if (a > 20) return 1;
		if (a < -20) return -1;
		var e = Math.exp(2 * a);
		return (e - 1) / (e + 1);
	}
	public static function camlAcoshFloat(a:Float):Float return Math.log(a + Math.sqrt(a * a - 1));
	public static function camlAsinhFloat(a:Float):Float return a == 0 ? a : (a < 0 ? -camlAsinhFloat(-a) : Math.log(a + Math.sqrt(a * a + 1)));
	public static function camlAtanhFloat(a:Float):Float return a == 0 ? a : 0.5 * Math.log((1 + a) / (1 - a));
	public static function camlCbrtFloat(a:Float):Float {
		if (a == 0 || !Math.isFinite(a)) return a;
		var r = a < 0 ? -Math.pow(-a, 1 / 3) : Math.pow(a, 1 / 3);
		var k = Math.fround(r);
		return k * k * k == a ? k : r;
	}
	public static inline function camlCeilFloat(a:Float):Float return Math.fceil(a);
	public static inline function camlFloorFloat(a:Float):Float return Math.ffloor(a);
	public static function camlTruncFloat(a:Float):Float return !Math.isFinite(a) ? a : (a < 0 ? Math.fceil(a) : Math.ffloor(a));
	public static function camlRoundFloat(a:Float):Float {
		// half away from zero
		if (!Math.isFinite(a)) return a;
		var t = camlTruncFloat(a);
		return Math.abs(a - t) >= 0.5 ? t + (a < 0 ? -1 : 1) : t;
	}
	public static function camlPowerFloat(a:Float, b:Float):Float {
		if (b == 0) return 1;
		if (a == 1) return 1;
		return Math.pow(a, b);
	}
	public static function camlHypotFloat(a:Float, b:Float):Float {
		if (Math.isFinite(a) == false && a == a) return Math.POSITIVE_INFINITY;
		if (Math.isFinite(b) == false && b == b) return Math.POSITIVE_INFINITY;
		a = Math.abs(a);
		b = Math.abs(b);
		var m = a > b ? a : b, n = a > b ? b : a;
		if (m == 0) return 0;
		var r = n / m;
		return m * Math.sqrt(1 + r * r);
	}
	public static function camlCopysignFloat(a:Float, b:Float):Float {
		var neg = Float64.bits(b).high < 0;
		var bits = Float64.bits(a);
		return Float64.ofBits(Int64.make(neg ? bits.high | 0x80000000 : bits.high & 0x7FFFFFFF, bits.low));
	}
	public static function camlSignbitFloat(a:Float):Bool return Float64.bits(a).high < 0;
	public static function camlNextafterFloat(a:Float, b:Float):Float {
		if (a != a || b != b) return Math.NaN;
		if (a == b) return b;
		if (a == 0) return b > 0 ? Float64.ofBits(Int64.make(0, 1)) : Float64.ofBits(Int64.make(0x80000000, 1));
		var bits = Float64.bits(a);
		bits = ((a < b) == (a > 0)) ? bits + 1 : bits - 1;
		return Float64.ofBits(bits);
	}
	public static function camlFmaFloat(a:Float, b:Float, c:Float):Float return a * b + c;
	// erf and erfc: W. J. Cody's rational approximations (as in many libms)
	public static function camlErfFloat(x:Float):Float {
		if (x != x) return x;
		if (Math.abs(x) > 6) return x > 0 ? 1 : -1;
		var t = 1 / (1 + 0.5 * Math.abs(x));
		var y = 1 - t * Math.exp(-x * x - 1.26551223 + t * (1.00002368 + t * (0.37409196 + t * (0.09678418 + t * (-0.18628806 + t * (0.27886807 + t * (-1.13520398 + t * (1.48851587 + t * (-0.82215223 + t * 0.17087277)))))))));
		return x >= 0 ? y : -y;
	}
	public static function camlErfcFloat(x:Float):Float return 1 - camlErfFloat(x);
}
