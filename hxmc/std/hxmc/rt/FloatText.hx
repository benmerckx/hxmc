package hxmc.rt;

import hxmc.I64;
import hxmc.unsafe.LibC;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Ptr;

// Doubles to text and back (once WebAssembly's only; hx_format_float was
// rt_dyn.c's), exactly as the native targets' C library does: parse
// (WebAssembly's strtod, wasm/Libc.hx) rounds correctly
// (to nearest, ties to even; also hexadecimal, inf and nan), and
// hx_format_float writes the shortest decimal that reads back as the same
// double, chosen as rt_dyn.c chose it (the correctly rounded
// prec-significant-digit decimals of printf's %.*e for prec = 1, 2, ...,
// the first that strtod reads back), formatted like JavaScript. Exact
// arithmetic on big integers (32-bit limbs in a frame area, at most 8192
// bits); the common cases take shortcuts: short decimals with small
// exponents are exact in double arithmetic (Clinger), and a candidate
// decimal is compared with the halfway points around the double instead of
// being read back.
@:keep @:allow(hxmc.rt)
class FloatText {
	static inline var LIMBS = 256;
	static inline var BIG = 8 + 4 * LIMBS;
	static inline var MAXDIG = 800; // significant digits kept when reading (more only round)

	static inline function m32():I64
		return ((1 : I64) << 32) - 1;

	// ---- big integers: int32 length at 0, limbs (little-endian) from 8

	static inline function blen(b:Ptr):Int
		return Mem.getI32(b, 0);

	static inline function limb(b:Ptr, i:Int):I64
		return (Mem.getI32(b, 8 + 4 * i) : I64) & m32();

	static inline function setLimb(b:Ptr, i:Int, v:I64)
		Mem.setI32(b, 8 + 4 * i, v.toInt());

	@:hxmc.unsafe static function bset(b:Ptr, v:I64) {
		Mem.setI32(b, 0, 0);
		var n = 0;
		while (!(v == 0)) {
			setLimb(b, n, v & m32());
			v = v >>> 32;
			n++;
		}
		Mem.setI32(b, 0, n);
	}

	@:hxmc.unsafe static function bcopy(d:Ptr, s:Ptr)
		LibC.memcpy(d, s, 8 + 4 * blen(s));

	// b = b * m + add (m, add < 2^32)
	@:hxmc.unsafe static function bmulAdd(b:Ptr, m:I64, add:I64) {
		var n = blen(b);
		var carry = add;
		for (i in 0...n) {
			var t = limb(b, i) * m + carry;
			setLimb(b, i, t & m32());
			carry = t >>> 32;
		}
		if (!(carry == 0)) {
			if (n == LIMBS) overflow();
			setLimb(b, n, carry);
			Mem.setI32(b, 0, n + 1);
		}
	}

	@:hxmc.unsafe static function overflow() {
		var msg = "hxmc: FloatText: number too large\n";
		// (the WebAssembly runtime is typed for a program built for it only)
		#if (hxmc.target == "wasm32-wasi")
		hxmc.rt.wasm.Wasi.writeLit(2, msg);
		hxmc.rt.wasm.Wasi.exit(70);
		#else
		var p = Mem.stack(64);
		for (i in 0...msg.length)
			Mem.setI8(p, i, StringTools.fastCodeAt(msg, i));
		if (Mem.os() == 2) {
			hxmc.unsafe.Win32._write(2, p, msg.length);
			hxmc.unsafe.Win32.exit(70);
		} else {
			hxmc.unsafe.Posix.write(2, p, msg.length);
			hxmc.unsafe.Posix._exit(70);
		}
		#end
	}

	// b *= 10^k
	@:hxmc.unsafe static function bmulPow10(b:Ptr, k:Int) {
		while (k >= 9) {
			bmulAdd(b, 1000000000, 0);
			k -= 9;
		}
		var m = 1;
		for (_ in 0...k)
			m *= 10;
		if (m > 1) bmulAdd(b, m, 0);
	}

	// b <<= s
	@:hxmc.unsafe static function bshl(b:Ptr, s:Int) {
		var n = blen(b);
		if (n == 0 || s == 0) return;
		var w = s >> 5, r = s & 31;
		if (n + w + 1 > LIMBS) overflow();
		var i = n;
		var top:I64 = 0;
		if (r > 0) top = limb(b, n - 1) >>> (32 - r);
		var k = n - 1;
		while (k >= 0) {
			var lo = r > 0 && k > 0 ? limb(b, k - 1) >>> (32 - r) : (0 : I64);
			setLimb(b, k + w, ((limb(b, k) << r) | lo) & m32());
			k--;
		}
		for (j in 0...w)
			setLimb(b, j, 0);
		var nn = n + w;
		if (!(top == 0)) {
			setLimb(b, nn, top);
			nn++;
		}
		Mem.setI32(b, 0, nn);
	}

	@:hxmc.unsafe static function bcmp(a:Ptr, b:Ptr):Int {
		var na = blen(a), nb = blen(b);
		if (na != nb) return na < nb ? -1 : 1;
		var i = na - 1;
		while (i >= 0) {
			var x = limb(a, i), y = limb(b, i);
			if (x != y) return x < y ? -1 : 1;
			i--;
		}
		return 0;
	}

	// b /= d (d < 2^32): the remainder
	@:hxmc.unsafe static function bdivSmall(b:Ptr, d:I64):Int {
		var n = blen(b);
		var r:I64 = 0;
		var i = n - 1;
		while (i >= 0) {
			var cur = (r << 32) | limb(b, i);
			var q = div64(cur, d);
			setLimb(b, i, q);
			r = cur - q * d;
			i--;
		}
		while (n > 0 && limb(b, n - 1) == 0)
			n--;
		Mem.setI32(b, 0, n);
		return r.toInt();
	}

	// unsigned 64 / (d < 2^32) for values < 2^63 (here: cur < d * 2^32)
	static inline function div64(x:I64, d:I64):I64
		return x / d;

	// ---- doubles

	@:hxmc.unsafe static function bits(v:Float):I64 {
		var t = Mem.stack(8);
		Mem.setF64(t, 0, v);
		return Mem.getI64(t, 0);
	}

	@:hxmc.unsafe static function ofBits(b:I64):Float {
		var t = Mem.stack(8);
		Mem.setI64(t, 0, b);
		return Mem.getF64(t, 0);
	}

	@:hxmc.unsafe static inline function inf():Float
		return ofBits((0x7FF : I64) << 52);

	// is X (dig: decimal digits, nd of them, value 0.d1d2... * 10^e10... as D * 10^k) vs b * 2^f
	@:hxmc.unsafe static function cmpDecBin(d:Ptr, k:Int, b:I64, f:Int, t1:Ptr, t2:Ptr):Int {
		bcopy(t1, d);
		if (k > 0) bmulPow10(t1, k);
		bset(t2, b);
		if (k < 0) bmulPow10(t2, -k);
		if (f > 0) bshl(t2, f) else if (f < 0) bshl(t1, -f);
		return bcmp(t1, t2);
	}

	// the double nearest to D * 10^k (D a big integer, positive), ties to even,
	// starting from the estimate z
	@:hxmc.unsafe static function refine(d:Ptr, k:Int, z:Float):Float {
		var t1 = Mem.stack(BIG), t2 = Mem.stack(BIG);
		var b = bits(z);
		if (b == 0) b = 1; // (from the smallest denormal)
		if (b >= ((0x7FF : I64) << 52)) b = ((0x7FF : I64) << 52) - 1; // (from the largest double)
		while (true) {
			var ex = ((b >>> 52) & 0x7FF).toInt();
			var mz = b & ((((1 : I64) << 52)) - 1);
			var ez:Int;
			if (ex == 0) ez = -1074 else {
				mz = mz | ((1 : I64) << 52);
				ez = ex - 1075;
			}
			// the halfway points around b
			var c = cmpDecBin(d, k, mz * 2 + 1, ez - 1, t1, t2);
			if (c > 0 || (c == 0 && !((mz & 1) == 0))) {
				b = b + 1;
				if (b >= ((0x7FF : I64) << 52)) return ofBits((0x7FF : I64) << 52); // infinity
				if (c == 0) return ofBits(b);
				continue;
			}
			var pow2 = ex > 1 && mz == ((1 : I64) << 52);
			c = pow2 ? cmpDecBin(d, k, mz * 4 - 1, ez - 2, t1, t2) : cmpDecBin(d, k, mz * 2 - 1, ez - 1, t1, t2);
			if (c < 0 || (c == 0 && !((mz & 1) == 0))) {
				b = b - 1;
				if (b == 0) return 0.0;
				if (c == 0) return ofBits(b);
				continue;
			}
			return ofBits(b);
		}
	}

	static inline function isDigit(c:Int):Bool
		return c >= "0".code && c <= "9".code;

	static inline function lower(c:Int):Int
		return c >= "A".code && c <= "Z".code ? c + 32 : c;

	@:hxmc.unsafe static function matchWord(s:Ptr, lit:String):Bool {
		for (i in 0...hxmc.rt.Str.len(lit))
			if (lower(Mem.getU8(s, i)) != hxmc.rt.Str.unit(lit, i)) return false;
		return true;
	}

	static function pow10(k:Int):Float {
		var r = 1.0;
		var x = 10.0;
		while (k > 0) {
			if ((k & 1) != 0) r *= x;
			x *= x;
			k >>= 1;
		}
		return r;
	}

	@:hxmc.unsafe public static function parse(s:Ptr, end:Ptr):Float {
		var p = 0;
		while (Mem.getU8(s, p) == 32 || (Mem.getU8(s, p) >= 9 && Mem.getU8(s, p) <= 13))
			p++;
		var neg = false;
		if (Mem.getU8(s, p) == "-".code || Mem.getU8(s, p) == "+".code) {
			neg = Mem.getU8(s, p) == "-".code;
			p++;
		}
		var r:Float;
		var c0 = lower(Mem.getU8(s, p));
		if (c0 == "i".code && matchWord(s.add(p), "inf")) {
			p += matchWord(s.add(p), "infinity") ? 8 : 3;
			r = inf();
		} else if (c0 == "n".code && matchWord(s.add(p), "nan")) {
			p += 3;
			if (Mem.getU8(s, p) == "(".code) {
				var q = p + 1;
				while (isDigit(Mem.getU8(s, q)) || (lower(Mem.getU8(s, q)) >= "a".code && lower(Mem.getU8(s, q)) <= "z".code) || Mem.getU8(s, q) == "_".code)
					q++;
				if (Mem.getU8(s, q) == ")".code) p = q + 1;
			}
			r = ofBits((0xFFF8 : I64) << 48);
		} else if (c0 == "0".code && lower(Mem.getU8(s, p + 1)) == "x".code && (isHex(Mem.getU8(s, p + 2)) || (Mem.getU8(s, p + 2) == ".".code && isHex(Mem.getU8(s, p + 3))))) {
			var res = Mem.stack(16);
			p = hex(s, p + 2, res);
			r = Mem.getF64(res, 0);
		} else {
			var res = Mem.stack(16);
			var q = decimal(s, p, res);
			if (q == p) {
				if (!end.isNull()) Mem.setPtr(end, 0, s);
				return 0;
			}
			p = q;
			r = Mem.getF64(res, 0);
		}
		if (!end.isNull()) Mem.setPtr(end, 0, s.add(p));
		return neg ? -r : r;
	}

	static inline function isHex(c:Int):Bool
		return isDigit(c) || (lower(c) >= "a".code && lower(c) <= "f".code);

	static inline function hexVal(c:Int):Int
		return isDigit(c) ? c - "0".code : lower(c) - "a".code + 10;

	// hexadecimal (after "0x"): the end; the value at res
	@:hxmc.unsafe static function hex(s:Ptr, p:Int, res:Ptr):Int {
		var m = 0.0;
		var e = 0, digits = 0;
		var seenDot = false;
		while (true) {
			var c = Mem.getU8(s, p);
			if (c == ".".code && !seenDot) {
				seenDot = true;
				p++;
				continue;
			}
			if (!isHex(c)) break;
			if (digits < 15) {
				m = m * 16 + hexVal(c);
				digits++;
				if (seenDot) e -= 4;
			} else if (!seenDot) e += 4;
			p++;
		}
		if (lower(Mem.getU8(s, p)) == "p".code) {
			var q = p + 1;
			var eneg = false;
			if (Mem.getU8(s, q) == "-".code || Mem.getU8(s, q) == "+".code) {
				eneg = Mem.getU8(s, q) == "-".code;
				q++;
			}
			if (isDigit(Mem.getU8(s, q))) {
				var x = 0;
				while (isDigit(Mem.getU8(s, q))) {
					if (x < 100000) x = x * 10 + Mem.getU8(s, q) - "0".code;
					q++;
				}
				e += eneg ? -x : x;
				p = q;
			}
		}
		while (e > 0 && m != inf()) {
			m *= 2;
			e--;
		}
		while (e < 0 && m != 0) {
			m /= 2;
			e++;
		}
		Mem.setF64(res, 0, m);
		return p;
	}

	// a decimal number at p: the end (p: none); the value at res
	@:hxmc.unsafe static function decimal(s:Ptr, p:Int, res:Ptr):Int {
		var start = p;
		var dig = Mem.stack(MAXDIG + 8);
		var nd = 0, dropped = 0, intDigits = 0;
		var any = false, seenDot = false, sticky = false;
		var lead = true;
		var fracZeros = 0; // zeros after the point before the first significant digit
		while (true) {
			var c = Mem.getU8(s, p);
			if (c == ".".code && !seenDot) {
				seenDot = true;
				p++;
				continue;
			}
			if (!isDigit(c)) break;
			any = true;
			if (lead && c == "0".code) {
				if (seenDot) fracZeros++;
				p++;
				continue;
			}
			lead = false;
			if (nd < MAXDIG) {
				Mem.setI8(dig, nd, c - "0".code);
				nd++;
				if (!seenDot) intDigits++;
			} else {
				if (c != "0".code) sticky = true;
				if (!seenDot) dropped++;
			}
			p++;
		}
		if (!any) return start;
		var e10 = 0;
		if (lower(Mem.getU8(s, p)) == "e".code) {
			var q = p + 1;
			var eneg = false;
			if (Mem.getU8(s, q) == "-".code || Mem.getU8(s, q) == "+".code) {
				eneg = Mem.getU8(s, q) == "-".code;
				q++;
			}
			if (isDigit(Mem.getU8(s, q))) {
				var x = 0;
				while (isDigit(Mem.getU8(s, q))) {
					if (x < 100000) x = x * 10 + Mem.getU8(s, q) - "0".code;
					q++;
				}
				e10 = eneg ? -x : x;
				p = q;
			}
		}
		// trailing zeros of the kept digits do not count
		while (nd > 0 && Mem.getU8(dig, nd - 1) == 0 && !sticky) {
			nd--;
			if (nd < intDigits) {
				intDigits--;
				dropped++;
			}
		}
		if (nd == 0) {
			Mem.setF64(res, 0, 0.0);
			return p;
		}
		// value = D * 10^k, D the nd digits (with a sticky 1 appended when digits were dropped)
		var k:Int;
		if (intDigits > 0) k = e10 + dropped - (nd - intDigits);
		else k = e10 - fracZeros - nd;
		// out of range
		if (nd + k > 310) {
			Mem.setF64(res, 0, inf());
			return p;
		}
		if (nd + k < -330) {
			Mem.setF64(res, 0, 0.0);
			return p;
		}
		// Clinger's fast path: D exact in a double, 10^|k| too
		if (nd <= 15 && !sticky && k >= -22 && k <= 22) {
			var v = 0.0;
			for (i in 0...nd)
				v = v * 10 + Mem.getU8(dig, i);
			Mem.setF64(res, 0, k >= 0 ? v * pow10(k) : v / pow10(-k));
			return p;
		}
		var d = Mem.stack(BIG);
		bset(d, 0);
		for (i in 0...nd)
			bmulAdd(d, 10, Mem.getU8(dig, i));
		var kk = k;
		if (sticky) {
			bmulAdd(d, 10, 1);
			kk--;
		}
		// an estimate from the first 17 digits
		var est = 0.0;
		var n17 = nd < 17 ? nd : 17;
		for (i in 0...n17)
			est = est * 10 + Mem.getU8(dig, i);
		var ek = k + nd - n17;
		if (ek > 0) {
			while (ek > 22) {
				est *= 1e22;
				ek -= 22;
			}
			est *= pow10(ek);
		} else {
			while (ek < -22) {
				est /= 1e22;
				ek += 22;
			}
			est /= pow10(-ek);
		}
		Mem.setF64(res, 0, refine(d, kk, est));
		return p;
	}

	// ---- formatting

	// the exact decimal digits of v (> 0, finite) into dig: their number;
	// the decimal exponent of the first at *e10 (value = 0.d1d2... no: d1.d2... * 10^e10)
	@:hxmc.unsafe static function exactDigits(v:Float, dig:Ptr, e10:Ptr):Int {
		var b = bits(v);
		var ex = ((b >>> 52) & 0x7FF).toInt();
		var m = b & ((((1 : I64) << 52)) - 1);
		var e:Int;
		if (ex == 0) e = -1074 else {
			m = m | ((1 : I64) << 52);
			e = ex - 1075;
		}
		var n = Mem.stack(BIG);
		bset(n, m);
		var frac = 0;
		if (e >= 0) bshl(n, e) else {
			// m * 2^e = m * 5^-e / 10^-e
			var k = -e;
			while (k >= 13) {
				bmulAdd(n, 1220703125, 0);
				k -= 13;
			}
			var f = 1;
			for (_ in 0...k)
				f *= 5;
			if (f > 1) bmulAdd(n, f, 0);
			frac = -e;
		}
		// decimal digits, 9 at a time from the low end
		var tmp = Mem.stack(1200);
		var nt = 0;
		while (blen(n) > 0) {
			var r = bdivSmall(n, 1000000000);
			for (_ in 0...9) {
				Mem.setI8(tmp, nt, r % 10);
				r = Std.int(r / 10);
				nt++;
			}
		}
		while (nt > 1 && Mem.getU8(tmp, nt - 1) == 0)
			nt--;
		// most significant first
		for (i in 0...nt)
			Mem.setI8(dig, i, Mem.getU8(tmp, nt - 1 - i));
		Mem.setI32(e10, 0, nt - 1 - frac);
		// trailing zeros dropped
		var nd = nt;
		while (nd > 1 && Mem.getU8(dig, nd - 1) == 0)
			nd--;
		return nd;
	}

	// printf's %.<decimals>f of v into out (at most 330 + decimals bytes, no
	// NUL): its length. The exact value rounded to nearest, ties to even, as the
	// C library rounds (the runtime's reports: RT_STATS, the census).
	@:hxmc.unsafe public static function fixed(v:Float, decimals:Int, out:Ptr):Int {
		var o = 0;
		inline function put(c:Int) {
			Mem.setI8(out, o, c);
			o++;
		}
		if (v != v) {
			if (bits(v) < 0) put("-".code);
			put("n".code);
			put("a".code);
			put("n".code);
			return o;
		}
		if (bits(v) < 0) {
			put("-".code);
			v = -v;
		}
		if (v == inf()) {
			put("i".code);
			put("n".code);
			put("f".code);
			return o;
		}
		// the exact digits d1 d2 ... with d1 at 10^e10; those kept: down to 10^-decimals
		var dig = Mem.stack(1200);
		var nd = 0, e10 = 0;
		if (v != 0) {
			var ep = Mem.stack(8);
			nd = exactDigits(v, dig, ep);
			e10 = Mem.getI32(ep, 0);
		}
		// kept digits: positions e10 down to -decimals (index i is 10^(e10 - i))
		var keep = e10 + decimals + 1;
		// round at `keep` (ties to even on the exact value)
		inline function digit(i:Int):Int
			return i >= 0 && i < nd ? Mem.getU8(dig, i) : 0;
		var up = false;
		if (keep < nd) {
			var first = keep >= 0 ? digit(keep) : 0;
			if (keep < 0) up = false else if (first > 5) up = true else if (first == 5) {
				// (a nonzero digit past it: exactDigits drops trailing zeros)
				var rest = nd > keep + 1;
				up = rest || (keep > 0 && digit(keep - 1) % 2 == 1);
			}
		}
		// the kept digits as a number string: integer part from 10^max(e10, 0)
		var top = e10 > 0 ? e10 : 0;
		var n = top + decimals + 1; // digits from 10^top down to 10^-decimals
		var d = Mem.stack(1400);
		for (k in 0...n) {
			var i = e10 - (top - k); // index of 10^(top - k)
			Mem.setI8(d, k, i < keep ? digit(i) : 0);
		}
		if (up) {
			var k = n - 1;
			while (k >= 0) {
				var x = Mem.getU8(d, k) + 1;
				if (x < 10) {
					Mem.setI8(d, k, x);
					break;
				}
				Mem.setI8(d, k, 0);
				k--;
			}
			if (k < 0) put("1".code);
		}
		for (k in 0...n) {
			if (k == top + 1) put(".".code);
			put(48 + Mem.getU8(d, k));
		}
		return o;
	}

	// shortest representation that reads back as the same double, formatted like JavaScript
	@:hxmc.host("hx_format_float") @:hxmc.unsafe static function format(v:Float, out:Ptr):Void {
		var o = 0;
		inline function put(c:Int) {
			Mem.setI8(out, o, c);
			o++;
		}
		if (v != v) {
			put("N".code);
			put("a".code);
			put("N".code);
			put(0);
			return;
		}
		if (v == inf() || v == -inf()) {
			if (v < 0) put("-".code);
			for (i in 0...8)
				put(hxmc.rt.Str.unit("Infinity", i));
			put(0);
			return;
		}
		if (v == 0) {
			if (!(bits(v) == 0)) put("-".code);
			put("0".code);
			put(0);
			return;
		}
		var neg = v < 0;
		if (neg) v = -v;
		var dig = Mem.stack(1200);
		var ep = Mem.stack(8);
		var nd = exactDigits(v, dig, ep);
		var e10 = Mem.getI32(ep, 0);
		// the first precision whose correctly rounded decimal reads back as v
		var cand = Mem.stack(24);
		var b = bits(v);
		var ex = ((b >>> 52) & 0x7FF).toInt();
		var m = b & ((((1 : I64) << 52)) - 1);
		var e:Int;
		if (ex == 0) e = -1074 else {
			m = m | ((1 : I64) << 52);
			e = ex - 1075;
		}
		var t1 = Mem.stack(BIG), t2 = Mem.stack(BIG), cb = Mem.stack(BIG);
		var prec = 1, ce = e10;
		while (prec <= 17) {
			// round dig to prec digits (ties to even, on the exact value)
			ce = e10;
			for (i in 0...prec)
				Mem.setI8(cand, i, i < nd ? Mem.getU8(dig, i) : 0);
			if (nd > prec) {
				var next = Mem.getU8(dig, prec);
				// (a nonzero digit past it: exactDigits drops trailing zeros)
				var rest = nd > prec + 1;
				var up = next > 5 || (next == 5 && (rest || (Mem.getU8(cand, prec - 1) & 1) != 0));
				if (up) {
					var i = prec - 1;
					while (i >= 0) {
						var c = Mem.getU8(cand, i) + 1;
						if (c < 10) {
							Mem.setI8(cand, i, c);
							break;
						}
						Mem.setI8(cand, i, 0);
						i--;
					}
					if (i < 0) {
						// 99..9 -> 100..0
						Mem.setI8(cand, 0, 1);
						for (j in 1...prec)
							Mem.setI8(cand, j, 0);
						ce++;
					}
				}
			}
			if (prec >= nd && ce == e10) break; // exact
			// cand * 10^(ce - prec + 1) within v's rounding interval?
			bset(cb, 0);
			for (i in 0...prec)
				bmulAdd(cb, 10, Mem.getU8(cand, i));
			var k = ce - prec + 1;
			var hi = cmpDecBin(cb, k, m * 2 + 1, e - 1, t1, t2);
			var pow2 = ex > 1 && m == ((1 : I64) << 52);
			var lo = pow2 ? cmpDecBin(cb, k, m * 4 - 1, e - 2, t1, t2) : cmpDecBin(cb, k, m * 2 - 1, e - 1, t1, t2);
			var even = (m & 1) == 0;
			if ((hi < 0 || (hi == 0 && even)) && (lo > 0 || (lo == 0 && even))) break;
			prec++;
		}
		if (prec > 17) prec = 17;
		// (printf's digits: trailing zeros only from a carry, written as they are)
		var n = prec;
		if (neg) put("-".code);
		var exp = ce;
		if (exp >= 21 || exp < -6) {
			put("0".code + Mem.getU8(cand, 0));
			if (n > 1) {
				put(".".code);
				for (i in 1...n)
					put("0".code + Mem.getU8(cand, i));
			}
			put("e".code);
			put(exp < 0 ? "-".code : "+".code);
			var a = exp < 0 ? -exp : exp;
			if (a >= 100) put("0".code + Std.int(a / 100));
			if (a >= 10) put("0".code + Std.int(a / 10) % 10);
			put("0".code + a % 10);
		} else if (exp >= 0) {
			for (k in 0...exp + 1)
				put(k < n ? "0".code + Mem.getU8(cand, k) : "0".code);
			if (n > exp + 1) {
				put(".".code);
				for (k in exp + 1...n)
					put("0".code + Mem.getU8(cand, k));
			}
		} else {
			put("0".code);
			put(".".code);
			for (_ in 0...-exp - 1)
				put("0".code);
			for (k in 0...n)
				put("0".code + Mem.getU8(cand, k));
		}
		put(0);
	}
}
