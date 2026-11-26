package hxmc.rt;

import hxmc.Platform;
import hxmc.I64;
import hxmc.unsafe.LibC;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Ptr;

// Doubles to text and back (once WebAssembly's only; hx_format_float was
// rt_dyn.c's), exactly as the native targets' C library does: parse
// (WebAssembly's strtod, wasm/Libc.hx) rounds correctly
// (to nearest, ties to even; also hexadecimal, inf and nan), and
// hx_format_float writes the shortest decimal that reads back as the same
// double, the nearest to it of those (ties to an even last digit), formatted
// like JavaScript's Number.prototype.toString. The digits come from
// Schubfach (Giulietti, "The Schubfach way to render doubles"): 128-bit
// approximations of powers of ten, no big integers; the smallest two
// subnormals, outside its range, take the exact search (the correctly
// rounded decimals of 1, 2, ... digits, the first within the double's
// rounding interval). Parsing and printf's %f (fixed) are exact arithmetic
// on big integers (32-bit limbs in a frame area, at most 8192 bits); the
// common cases take shortcuts: short decimals with small exponents are
// exact in double arithmetic (Clinger), and a candidate decimal is compared
// with the halfway points around the double instead of being read back.
@:keep @:allow(hxmc.rt)
class FloatText {
	static inline var LIMBS = 256;
	static inline var BIG = 8 + 4 * LIMBS;
	static inline var MAXDIG = 800; // significant digits kept when reading (more only round)

	static inline function m32():I64
		return ((1 : I64) << 32) - 1;

	// ---- big integers: int32 length at 0, limbs (little-endian) from 8

	@:hxmc.unsafe(gc) static inline function blen(b:Ptr):Int
		return Mem.getI32(b, 0);

	@:hxmc.unsafe(gc) static inline function limb(b:Ptr, i:Int):I64
		return (Mem.getI32(b, 8 + 4 * i) : I64) & m32();

	@:hxmc.unsafe(gc) static inline function setLimb(b:Ptr, i:Int, v:I64)
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
		#if (!hxmc.os || hxmc.os == "windows")
		if (Platform.os() == 2) {
			hxmc.unsafe.Win32._write(2, p, msg.length);
			hxmc.unsafe.Win32.exit(70);
		} else
		#end
		{
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

	@:hxmc.kernel static function bits(v:Float):I64
		return Mem.f64Bits(v);

	@:hxmc.kernel static function ofBits(b:I64):Float
		return Mem.bitsF64(b);

	static inline function inf():Float
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

	// ---- shortest digits (Schubfach)

	static inline var K_MIN = -324;

	// for k from K_MIN to 292: g = floor(10^-k / 2^r) + 1, 2^125 <= g - 1 <
	// 2^126 (r = flog2pow10(-k) - 125), as g1 = g >> 63 and g0 = its low 63
	// bits, in hex (made by BigInt arithmetic)
	static final G = "4f0cedc95a718dd45b01e8b09aa0d1b57e7b160ef71c1621119ca780f767b5ee652f44d8c5b011b40e16ec672c52f7f250f29d7a37c00e29581256b8f0425ff540c21794f96671ba79a84560c0351991679cf287f570b5f775da089acd21c28152e3f5399126f7f944ae6d48a41b0201424ff76140ebf99436f1f106e9af34cd6a198bcece465c2057e981a4a918547b54e13ca571d1e34d2cbace1d541376c943e763b78e4182a423c8a4e44342c56e6ca56c58e39c043a060dd4a06b9e08b056eabd13e9499cfb1e7176e6bc7e6d59458897432107b0c87ec12bebc9febde16f40f20501a5e7a77e01dfdfa99796355900c19d9aeb1fb94b34b319547944f74733ce17af227fc755c3c27aa9fa9d9371ec7cf2b1d0cc72560603f7765dc8ea5b2397288e40a38e7804cff92b7e3a5548e945ba0b66e93f13370cc755fe951174a86f90123e41fe51f1ae0bbcca881b5d538c7341cb67fe74c1580963d539af4aa93d29016f866543cde0078310faf377752ea8024c0a3c0616333f381b2b1e5f90f22001d66e963811c298f9af55b14c73f4e667debede600e35472e25de287a532170a63131643349eed849d6303f61dc1ac084f4278342a18be03b11c0334e49af006a5cec691bb46fe695a7ccf57d42b19a43c7e0a82c53e63dbc3fae5564355ae1cfd31a20237651cafcffbeaa502aaf1b0ca8e1b335f8416f30cc9888402225af3d53e7c25e603458f3d6e06d669d0918621fd9374a3386f4b957cd7b52173a79e8197a926e8f9f2a2ddfd79641ac2ec7ece12edb720c7f54f17fdfab69137e0cae3517c61ce0cbbb1bffcc45540f980a24f74638171a3c95afffd69e433facd4ea5f6b60127b63aaf33312186b991487dd6578996a5f05de51eb50265614106cb11dfa145518d17ea7ef735244dcd9f08db194dd2a7a41321ff2c2a86e2e2980e2b5bafb5d906850331e043f5824ee00b55e2f2f647386a68f4b36994683f19a2ab1bf5936c2d21ed908f87b70d31c29dde93228579e1cfe280e5a5d5a427cee4b20f4ed2c7e7d98200b7b7e483530bea280c3f109fecae019a2c93273884dfdd0ce064e43314499c29e0eb65c6d0b3173d8050b4f5a9d47cee4d89149f0d5c129799da272aee4397250ad41764e22cea8c295d1377e39f583b448685ea4e8a553cede4112cb61913629d3874bb72084430be500756f8140f8217605792500d39e796e676f18cece59cf233c60ea670fb1fabeb93f470bd847d8e8fd4d885272f4c89894329f3cad064720ca7c0d50b7ee0dc0ed37652de1a3a50143633dda2cbe7167242c50f1814fb734364f64ae8a31f452833d0d8e010c92902b7f077da9e986ea6b7b48e334e0ea8045659f97bb2138bb8949071c2a4d88669d514c796280fa2fa120d27ceea46d1ee44109fab533fb594d670eca58838a7f1d680ff788532bc2160b4add5a6c10cb62533ff939dc2301ab22a24aaebcda3c4e4299942e49b59aef354ea22563e1c9d86a8f537d42bc2b18554a9d089fcfa95a553f75fdcefcef46776ee406e63fbaae4432c4cb0bfd8c385f8be99f1e9962256d1e07ab466279f4327975cb64289d08574b3955d1e8619028612b091ced4a6d45d5c777db204e0d06b4226db0bdd5246fbc72595e9a167b24536a491ac9550659638eade54811fc1d0f883a7bd444054782d88b1dd341964a72d361fca9d004726af411c952028a43eaebcffaa94cd35b88c3416ddb353b4fef230cc88770a9493a35cdf17c2a960cbf4f3d6d3926ee7529efafe8c6aa8961321862485b717c5dbb262653d22207675b46b506af8dfd4afc1e850fdb4e6c52af6bc405593e6477f9ca6e7fc54a47377f12d33bc1fd6d5ffb085866376e9f45ff42429634cabd4cc8d379eb5f8bb26b329b68782a3bcb7adaebf64565ac512b842bda59dd2c776248bcc5045156a73c69bcaeae4a89f94ea09704037445526387ca25583ba1947dcdbe6cd253a21e05a6103bc05f68ed64a498570ea94e7e37b80cfc99e5ed8a5083ad1272210b982c933d96e184be0840695741f4e73c797075cadf1ad09807670ef2032171fa5c4d8944982ae759a452725b35b45b2eb03e076a135585e15041f515c49048f22664d2bb42aad1810d698822d41a0e503e07b7920444826815546ce8a9ae71d9cb1fc60e69d0685344438a53baf1f4ae3c196b3ebb0d20429d6c1085f7e9877d2d0f11fdf815006a9456739e5fee05fdbd58db31934400554345294b7ff19e649760af5adc3666aa9c6ea878ccb5ca3a8c344bc4938a3dddc75886c70a2b082ed65d096a0fa1cb17d246d238d4ef39bf12173abb3fb4a2797571505aee4b8f981d0b912b992103f5885aa6af25093face40940efadb4032ad3488558ea6dcc8a5007672624900288a974088e43e2e0dd4c723ea36db337410e5cd3a5031be717705b654f8af5c5cda54a42ea68e31f45f362b772d5916b0aeb76d1770e383209860458b7bc1bde77dd5f0df8d82cf4d46b1d13c630164b93184c0b2d79bd90a9ef30dc9e8cdea2dc1379ab7bf5fc1aa97f0160fdae310493516155fcc4c9aeedff1ab3fe24f403a90e4dde63d0a158be656229981d9002eda57c97061a9bc130a269dc2695b337e2a163ac04e2163426e854b01ede28f9821b4fbcd0b4de901f2043c018b1ba6134e27f9481216419cb671f99c11c5d68549d6610674de9ae3c524c7b00e37ded107e51a6b90b2158304209fc00b5fe57406541522da2811359ce3b3000919845cd1d68837c3734ebc2e3784ccdb5c06fae95539c635f5d8968b62d0a3e2b0059587742e382b2b13aba2b3da1cb5599e113936b059deab52ac378629c7888f634ec1e559e17eef755692d3549fa072b5d89b1447e798bf91120f11107fb38ef7e07c16d9728dff4e834b501a65ec17f300c6857ac20b32a535d5d4e1eb23465c009ed46234d5c21dc4ab124e55b5d1e333b2470387bc69c93aab5216ef894fd1ec50659c6c96bb076222a4df2607730e56a6c47d23abc8d2b4e883e5b805f5a5121f072e9f7941512174063c59a322a1b697f5bee5fa9aa74df6703047b5b54e2bacc498b7fbaeec3e5ec0269fc4910b5623d75abff917e063cac6a432d41b45569fb5e2332dacb38308a21cf5767c37787fc4b4f5be23c2cf3a167d912b9692c6cca787ef969f9e185cf595b5128a847147660659454c7e79e3f6115da86ed05a9f84d1e1043d31fb1cc4dab1538bd9e21937b634d3951cc4fad62ab552795c9cf5262b5d7610e3d0c8b0222aa86116e3f754ef7df80d830d6d54e822204dabe992a7e59659af38157bc17369cd49130f51065145148c2cddfc95f5ee3dd40f3f74050dd0dd3cf0b196e1918b64a9a5cc5cd40b0d7dca5a27abe4746f83baeb09e3e678159610903f797253e59f91780fd2f52cde11a6d9cc61250feae60df9a6426423e4daebe1704db5a65584d7faeb68569fd4917968b3af910a226e265e4573b54caa0dfaba295940d4e8581eb1d129543d54d7fbc821143243ed134bc1742116c887bff94034ed206cae8546025368256d396661002a5746bd586a9e6842b9b457611eb40021df709779eee520356166f234fdeccd02ff15bf297e3b66bbcef58e90cb23d73598e165bacb62b8963f34720d6f4fdf5e13e451623c4efa11cc271ce24bb2fefceca3b569fa17f682e035b0b5095bff30bd515dee61acc53580348d5da11665c09772b18b8157042accf74895ce8a3c6758b5e8df355806aae185d3ab0ba1c9ec46f653e5c4466bbbe7a4a955a2e7d4bd0593765169d1efc986177555d172edfb3c2256e8a94fe60f3cf5f777dac257fc3016abed543feb3f63f4c5f97bceacc9c013bcbddcffef65e997a328c6177adc6685fac961997f0975b61c209e792f16b867fbd44e1465a12af4e34d4b9425abc6b7fca9d810514dbbf7d21545b9d5dfa4632ddc8ce6e87c5ff641aa9e2e44b2e9e5be4a0a525396b32501554b5836f587e7cb6e6ea842def5c4011109135f2ad3230925255368b25e36681b41b898448504db6ea21f0dea30452015ce2d469d37357c5881b2718826a419ab0b576bb0f8f5fd139af527a01ef68f781225791b27f4c81f5e550c3364a53f9341b79415b99239b2b1dda35c508432dc3492dcde2e102e288e4ae916a6d6b7c6ba849496b01516a74a1174f10ae55fd22ed076def344121f6e745d8da2544ca82573924bf5d1a8192529e4714eb6e10d08b8ea1322e5d9c1d50fd3e87dd580d73a2d880f4f217b01773fdcb9fe44671294f139a5d8e4626792997d6198470b50ee4ec2a2f4a3d0a5b75bfbcf59f5a2a7250bcee8c3b4a6eaf916630c47f4821f50d63f209c921f2260deb5a36cc736988156cb6760e69837016455d247a5c546cddf091f80b6e02c011d117506249dd23e4c074c66f719bccdb0dac404e762e9fd467213d7f68f947c4e2ad33b05e8bb3105280fdff6d94396a4ef0f6274ba2f5a6a86731993e102deea58d91b97904bc3dda3eb5c23019e3176f48e92760d09697e1cbc49b4014b5ac590720ec4d73abacb4a303af4cdd5e237a6c1a577bec45e12104d2b247c8969f2a46908a63236b1a80d0a88e6ca0787f5505406f4f4f88e200a6ed3f0a19f9ff773766bf7ee5a7d0010b15315cf65ccbf1f23dfe6584864000d5aa8e172b7d6ff4c1cb325136d1cccd77bba478ef978cc3ce3c2840f8a7d70ac62fb713f2dfa3cfd8302067f43fbe77a37f8b398499061959e6995329cc985fb5ffa26136e0d1ade185484287d6e04c91994f00f8b3daf181376d6a72f166e0e8f54b1b27862b1c01f2475528c11f1a53f76f2f52d1bc1667f50644209a7f48432c590c424163451ff7386d00f7320d3846f47a039bd2083325265733f8f4d76038c37b361641a028ea8545c32d90ac4cfa362f5e78348020bb9e6f9eaf4de07b29f04bca59ed99cdf8fc594bbf71806287f3563b7b247b0b2d96476fcc5acd1b9ff611c92f50626f57ac724c7a2ae1c5ccbd02db7ee703e559125b7061bbe7d170971be2cbec031de0dc4926b496530df3ac164f09899c17e716750aba8a1e7cb9133d4b4275c68ca4f05da22ed4e530940f4aa29b916ba3b7264ae825771dc076726ee87c74561c928577d9d58b62cd8a513173fa53bcfa84085fe177a2b5713b74278ffb7630c869a04cb45fb55df42f901fa662c4f3d387b37aba32bbc986b28032a3d13b1fb8d91f622e8efca1388ecd0ee9742f4c93e0e64e8ba596e760723d58bac3590a0fe71e7dac3c24a5671d2f412ad228101971c96489c9b6eab8e42600ef0e8673478e3b506e3af8bbc71ceb1a58d86b8f6c71c940582f2d6305b0bc1513e0560c56c16e66f37eaf04d5e7933b530089ad579be2525c6558d0ab1fa915dc006e2446164f41e384470d55b2ed5e4999f1b69e783f696c06d81555eb157d428fe92430c06554566be0111188de31020cba835a33844378564cda746d7e5a680a2ecf7b5c696bf3bd47c3ed7bfd770cdd17b25efa42565c976c9cbdfccb1270b0dfc1e595024516df8a16fe63d55b8d5a4c9b1e10ce6e8aff4357fd6c89127bc3adc4fce7b0586f329c466456d40ec96957d0ca52f346bf5bb0385045763f07877973d50f2971322c4d26e6d58a31a5a58f1fbb4b755a8e89d75252446e5aeaead8e62f6f91487207df750e9d252f22557a51bf8c7473e9a63254e42ea21836ef2a1c65ad865cbaeb5b771cf21b2cf8bf54e3848ad24a2f22af927d8e7c23fa32aa4f9d3bdb76b1d118ea627d935329eaaa18fb92f85ef4a74721e864760f54bbbb472fa8c64bf6ec38e7ed1d2b25dd62fc38f2ed6c798b138e3fe1c84522fbd1938e517bdf613c0fa4ffe7d36a4f2fdadc71dac97f4dc9a61d998642bb58f3157d27e23acc7c75d695c2706ac574b82261d969f7ad63917877cec0556b10934eb4adee5fbe4fa793930bcd11224075d8908b2519657f7285b812e1b50400bc8db411d4f56e65f537c675815d9c66fd3e29a7dd91255190f96b91344ae36bfdcb54864ada844140c78940f6a24f6ffe3c439ea2486a6867a5a867f103b27ffd2d38fdd073dc53861e20532736286664242d97d9f64a42d1b1b375b8f82051e9b68adfe191d56ae91c5255f4c0341ca924116635b621558749db77f7002963ba83411e915e81446c3b15f99266876962029a7edab2016d79f82328ea3da60f03375d97c450015794c6828721caeb259c2c4adfd0400146109eced2816f225149bd08b30d0001701a97b150cf18373542c80deb48000159aedfc10d7279c57768a00b22a0000147bf19673df52e3779208008e880000172cb5bd86321e38c5b673341740000015bd5e313828182d67c528f67900000014977e8dc68679bdf16a872b940000001758ca7c70d7292fe5773eac2000000015e0a1fd27128759845f65568000000014b3b4ca85a86c47a04c5112000000001785ee10d5da46d9007a1b50000000001604be73de4838ad952e7c400000000014d0985cb1d3608ae0f1fd000000000017b426fab61f00de331cc800000000001629b8c891b2671825b0a0000000000014ee2d6d415b85ace7c080000000000017e37be2022c0914b134000000000000164f964e68233a76f290000000000000150c783eb9b5c85f25400000000000001409f9cbc7c4a04c210000000000000016765c793fa10079d000000000000000152b7d2dcc80cd2e40000000000000001422ca8b0a00a4250000000000000000169e10de76676d080000000000000000154b40b1f852bda00000000000000000143c33c193756480000000000000000016c6b935b8bbd4000000000000000000156bc75e2d631000000000000000000014563918244f4000000000000000000016f05b59d3b200000000000000000000158d15e17628000000000000000000001470de4df82000000000000000000000171afd498d000000000000000000000015af3107a40000000000000000000000148c27395000000000000000000000001746a52880000000000000000000000015d21dba00000000000000000000000014a817c80000000000000000000000001773594000000000000000000000000015f5e10000000000000000000000000014c4b40000000000000000000000000017a12000000000000000000000000000161a800000000000000000000000000014e2000000000000000000000000000017d0000000000000000000000000000016400000000000000000000000000000150000000000000000000000000000001400000000000000000000000000000016666666666666666333333333333333451eb851eb851eb850f5c28f5c28f5c294189374bc6a7ef9d5916872b020c49bb68db8bac710cb29574f0d844d013a92b53e2d6238da3c21143f3e0370cdc8755431bde82d7b634da698fe69270b06c446b5fca6af2bd215e0f4ca41d811a46d455e63b88c230e77e3f70834acdae9f1044b82fa09b5a52cb4c5a02a23e254c0d6df37f675ef6eadf2d5cd10396a2134757f5ff85e592557f3de3da69454e75d3465e6604b7a844657e4fe1edd10b9175709709a125da07094a19697c81ac1bef5a126e1a84ae6c0754e1213067bce326480ebe7b9d58566c43e74dc052fd8285734aca5f6226f0ad530baf9a1e626a6d5c3bd5191b525a24426fbfae7eb521f149c97747490eae834ebfcc8b9890e7f4760f253edb4ab0d24acc7a78f41b0cba5e72843249088d75223d2ec729af3d624b8ed0283a6d3df734fdbf05baf2978178e480405d7b965854c931a2c4b758cf60b6cd004ac945135d6dc14f03c5e0a54d5f0a66a23a9da931249aa59c9e4d517bcb43d769f762a84ea0f76f60fd488263090312bb2c4eed254d92bf80caa0684f3a68dbc8f03f241dd7a89933d54d207ec3daf94180650662f2a75b8622150065697bfa9acd1d9f025bb91604e810cd51212ffbaf0a7e18684960de6a5340a440e7599625a1fe7a203ab3e521dc33b667d88f56a29cca5d19f7863b696052bd5313a5dee87d6eb07b2c6b62bab3756442761e4bed31255a2f56bc4efbc2c4506a5696dfe1e83bc3655793b192d13a1a5512124cb4b9c969377942f475742e7b440e750a2a2e3aba5f9435905df68b966ce3ee76a9e3912a65b9ef4d63241289571cbec554b60dbb6afb25d78283420745b0989ddd5e716308c8eb12cecf68066f80f42fc8971bd15adb11b7b14bd9a35933f68ca078e30e157c0e2c8dd647b5475cc53d4d2d82715dfcd823a4ab6c91722e086215159d82632e269f6ddf141b5b5806b4ddaae4684f581ee5f17f434949133890b155838672ace584c1329c3b74eb8db44eef38d76aae3c079b842d2a5d893e29d8bf60ac55583006160357554ad431bb13cc4d567779c004de6912ab77b9e92b52e07bbe258f99a163db51115fc7edbc424d2fcb37a614811caf740d4c9ff163683dbfd57951aa00e3bf900b7a998238a6c932ef754f7667d2cc19ab6214682d523a8f262aa5f8530f09ae224e76b9bddb620c1e55519375a5a1581b7d8ac2c95f0346973bb5b8bc3c3559c5646f023ab26905457c9160969691149e5058ce955b87376b16dab3ababa743b240470baaaf9f5f8878aef622efb902f566d812aab29898db0de4bd04b2c19e54524675555bad471557ea30d08f014b7641d1f7777c8a9f444654f3da0c01092c694ff258c744320723bb1fc346680eac543ff513d29cf4d24fc8e635d1ecd88a43665da9754a5d75263a51c4a7f0ad3b6bd6fc425543c8bb56c3b607731aaec45645969b77696d62789c919f8f488bd04504787c5f878ab546e3a7b2d906d6406e6d8d93cc0c11223e390c515b3e239a5857a4763cd6741b4b60d6a77c31b61546ac8391ca4529af55e7121f968e2b44711405b6106ea9190971b698f0e3786d5a766af80d255414078e2bad8d82c6bd485ebbf9a41ddcdc6c71bc8ad79bd23173cac65c39c961612d82c7448c2c83825ca23849c7d44de73e023903a356cf9b4a1b603b064371857e682d9c82abd94976923391a39f1c094a4048fa6aac8edb5edb5c7482e5b00755003a61eef072494be2b05d35848cd2773361e7f259f507796ab3c855a0e1513eb89ca6508fee716122296d114d810d7efa16eb73a6585b4db4edf0daa4673e3261abef8fb846af7c54afe7c43a3eca1d691318e5f3a44b6376f31fd02e98a164540f471e5c836f4f925c1973587a1b0376729f4b7d35f37f50935bebc0c35e38bd84321261efeb65da0f7cbc9a35e513cad0280eb4bfef517b3f96fd482b1d5ca240200bc3ccbf412f66126439bc1763b50019a3030a33684bd683d38f93591f88002904d1a9ea536fdecfdc72dc4732d3335403daee5542bfe57316c249d25bdc291003158b776acca251be03a95112f9db4cd1bc1258557081dafe6954407594af70a7c9a847445a017bfebaa9cd4476f2c0863aed066d5ccf2ccac442e23a57eacda3917b3c577d728a3bd035817b7988a482dac8fd45fdf53b630cf79b15fad3b6cf156d976ffcbb923814bf5e565e1f8ae4ef15be5996fc74f9aa32b211e4e608b725aaff47abfd2a6154f55b27ea51a0928488cc72acc843ceee555e7310829a840741465bbd6d030bf1dde542739baed005cdd249645735a327e4b74ec2e2f24004a4a8756d5855d1d96df24ad16b1d333aa10c5df11377db1457f52241227dc2954da34b2742c648dd132a4e9a81fe35443e1c783ed13d4161b844175d9cc9eed39694603240fdcde7c69c7917b0a18bdc78764cf500cb0b1fd2171412f3b46fe393927b219ade7832e9be535185ed7fd285b6628148b1f9c2549842a79e57997537c54ecdd3c1949b76e03552e512e12a93047e161f9c20f8be336eeb081e3510eb3964de7fb01a6098293f226ce4f740bc2e50b1ffc0151a13543281f0b72c33c9be408e66334414dc4342018d5f568fd498674a3d1ed354939f1ccf48988a7fba8d52a1ca7f0f76dc7f30a5d3ad3b99620b421b0865a5f8b06573b7dc8a96144e6f69c4da3c3cc11a3c52bfc7442353b0b1549d7b6363cdae96756639034f7626f443b12f82b63e25454451c735d92b525d6c4eb26abd303ba23a1c71efc1deea2e56a55b889759c94e61b05b2634b254f245511606df7b07721af37c1e908eaa5b6ee8233e325e72502b1f2cfdb41776f858b9b5cb5b7ec1d96f4c23fe29ac5f2d46faf7d5e2cbce4772a34ffe87bd18f171918c896adfb07304387ffda5fb5b1b5adad6d4557fc05c0360666484c915af48af1243779966b002b3851d3707448c744b506bf28f0ab31dec082ebe7207465d090d2328726ef564bcd358985b39054a6da41c205b8bf76a30a913ad15c7387715d36033c5acbf5d1aa81f7b560b8c5f44a919c3048a327daeece5fc44d6094c36edae359d3b5b7e258a51969d780879f17c49ef61f89316a276e8f0fbf33f618dfd07f2b4c6dc121b9253f3fcc2994e0b30d328909f1641afa843299702147cdeb4850db431bd4f7f739ea8f19ced63e55d373e29c1643f99294bba5ae3f14feab0f8fe87cde97fadbaa2fb7be98d7fdde7f4ca72e30f7f7c5dd1925fdc15664b1ff7085be8d94c637e4141e649ab51d5b32c06afed7a704f983434b83aef4177c2899ef3246226a6135cf6f9c8bf68bf9da8fe51d3d03dd685618b29413253cc7e20cb74a9734b12044e08edcdc24309fe80a2c3bac26f419d0b3a57d7ce6b4330cdd1392ad1320294dec3bfbfb055cf5a3e40fa88a7419baa4bcfcc995a44a5e1cb672ed3b91ae2eea30ca3ade16dd636123eb152c177d17dd1add2afcf57de91a832277567797464a7be42263f464ba7b9c1b92ab94790508631ce84ff70790c5c6928445c0c1a1a704fb0d4cc59fa7049edb9d049567b4859d95a43d647fb8d07f161736e11fc39e17aae9cab732c14d98235857d032d2968c44a94455c2343e134f79dfd4f575453d03ba9d149b5cfe75d92e4ca72ac4376402fbb0e75efb30bc8eb07ab0446d256cd192b495e595c096d88d2ef1d0575123dadbc3a4b7ab0078ad3dbf24a6ac40e97be302f78c44cd8de1fc650771139b0f2c9e6b1609d0a4718196b7378da948d8f07ebc14d4a6e9f467abc5c60aedd3e0c0656347baa4a9870c46094344afb9679a3bd2062eea2138d69e6dd103bfc78614fca804f254e760abb1f1726966393810ca2007ea21723445e98252423d2859b476999654e78e9037ee01d69b642047c392148510b93ed9c6580176e2b680396941aa040d60ff149eaccdf71bc53361210154d67bce64edcaae1661c6085235019bbae52fd850be3bbe7847d1a041c4014962542646a6fe9631f9d4a7b367d0010781d6a3a43e6423832955d91f0c8001a59c854fb698501c68ede17a7f3d3334847d443fc546a67d20be479532975c2a039766cc6ed770c83463b0eeb75893766c25657058ac5a39c382f25892ad42c523512459e089e1c7cf9bf37a0ef102374f7426f6340fcfa618f9859017e8038bb2536591c33fd951ad9467a67986693c8ea914749c33144157a9f151fad1edca0bba8720f9eb539bbf7650832ae97c76792a55b3fb22a94965f84068ef21305ec755148ffc1bbaa11e6031ed8c1a8d189f77474cc692c434fd66b4af4690e1c0ff2535d705423690cab89225d20d8167328434ac0434f873d560735174d79ab8f5369779a054c0b95567221bee25c45b21f0e5fae6aa33c77785b3498b5169e2818d84c8b888296c5f9e25d46f7454b5347137a78da6a8ad65c9d7ba4bed545520b5261fa48553bdeb07e2fb6ff110441a2a84e61d37763188d3172f8cc0d9d014eed7d6952589e8daeb61e5ae015c80217e1645441e07ed7bef81848b344a001acb4504367e6cbdfcbf9603a2903b3348a2a4035ecb8a3196ffb002e873628f6d4ee66bcadf43828b32b19e40b89db2487e352308b29c686f5bc14b66fa17c1d398341c06f549ed25e301091f2e7967dc79c6933e554315096b3341cb7d8f0c93f5f542984435aa6def5767d5fe0c0a0ff80435469cf7bb8b25e2b977fe70080cc666bba42e592c11d635f58cca4cd9ae0a3562e9beadbcdb11c4c470a1d7148b3b644f216557ca48db03d05a1b1276d5c926e5023bbfaa0e2b37b3c35e83f1560e958401c96621a4ef62f635e5365aab3ed4699b0784e7b725e591c4b75eaeef65870f5e726e3f8b6fd74fa125644b18a265a5e5285832d5f3143fb41de9d5ad4eb484b75379c244c274ffc34b2177bdd8973abeebf603a13724cc6bab68bf962745c898bcc4cfb42c20a38955ed6611b904a07a309d72f689b21c6dde5784dafa776729e762518a75e693e2fd58d49190b5ec2185e8413b9185431bfde0aa0e0d54bce79e536762dad29c1664b3bb3e711794a5ca1f0bd15e20f9bd6dec5eca4e861084a1b26fdab1b2616457f04bd50ba4da03b48ebfe227c1e783798d09773c87c33920e46636a6030c058f480f252d9635c74d8384f884d0d66ad90672842474f7d2a469372d370711ef14052869b6c7f2eaa0a8584858134fe4ecd50d75f1465beee6ed136d1342a650bd773df7f4351658b8bda9240f6551da312c319329c411e093caedb672b5db14f4235adc21768300ec77e2bd8457c4ee536bc49368a5359a56c64efe0377d0bea92303a920842ae1df050bfe693173cbba8269541a06ab02fe6e79970eb3ec792a6a422029a5559bfebec7ac0bc3239421ee9b4cee14447ccbcbd2f00965b6101b25490a5816d3fadfac84b34242bce691d541aa268576624c8a03c29b6563eba7ddce21b8745eb50a08030215e78322ecb171b49396fdee7673380356459e9e47824f87527597f1f85c2ccf7836187e9f9b72d2a864798e6049bd72c69346cbb2e2c242205728e3cd42c8b7a4220adf849e039d0075ba4fd768a092e9b33be603b19c7d99f4950cac53b3a8baf42feb3627b0647b3754e113b91f745e55197856a5e7072b85dd80dc941929e5127ac6abb7ec05bc64b133e3a9adbb1da52f05562cbcd1638781ec9f75e2c4fc41e4d556adfae89f36018a192b1bd0c9c7ea444557fbed4c34ce0814227ca707d4bb69d1132ff109c7b00ced03faa4d955f8a94e851981a9362670bd9cc883e1132d543ed0e1348754eb8d647d6d364da5bddcff0d80f6d2b7df48a0c8aebd49112fc7fe7c018aeab64c3a1a3a25643a728c9ffec99ad5889509c814fb511cfb90707fff07af113a1407d343fc40e3fc71f39998d2f2742e7672eb9ffa016cc717ec28f484b7204a4528bc7ffb345705b189ba5d36f8e6a1d42096ccc8f6ac0487a161e42bfa521b169a8ae1418aacd41435696d132a1cf815486f1a9ad5571011c454574288172ce439f27baf1112734169dd129ba0128a56c31d92b1b4ea520242fb50f9001daa1568e4755af721db3368c90d940017bb4453e9f77bf8e7e29120a0d7a999ac95d6eca98bf98e3fd0e50101590f5c4756158a213cc7a4ffda526734473f7d05de846e80fd6c83ffe1d6b8f69f65fd9e4b971734c8ad9fffcfc45b24323cc8fd45c5ac2a3a247fffd966af502830a0ca9e3489bb61b6ccccadf08c402026e7087e9742c569247ae1164746cd003e3e73fdb5cf04541d2f1a78376bd73364fec33154a59d101758e1f9c5efdf5c50cbcf5ab76f61b3588e365c74b2fefa1adfb22ab5f2b48f7a0b5eb0608f3261af195b5554c22a0c61a2b226b20c284e25ade2aab79d1013cf6ab6a451ad0d49d5e304444617400fd9222bb6a48a7107de4f369d04df6673141b562bb53b8d9fe50c2bb0d7cbd71e86922379252c15cca1ad12b4863cac186ba81c60e75677d6e7bda89064fd5679efb9b04d85dec645863153a6c7fbbd8fe5f5e6e27497a3a2704eec3df";

	static function word(at:Int):I64 {
		var v:I64 = 0;
		for (i in at...at + 16) {
			var c = hxmc.rt.Str.unit(G, i);
			v = (v << 4) | (c <= "9".code ? c - "0".code : c - "a".code + 10);
		}
		return v;
	}

	static inline function hl(hi:Int, lo:Int):I64
		return ((hi : I64) << 32) | ((lo : I64) & m32());

	// the high 64 bits of x * y, both below 2^63
	static function mulHigh(x:I64, y:I64):I64 {
		var x0 = x & m32(), x1 = x >>> 32, y0 = y & m32(), y1 = y >>> 32;
		var t = x1 * y0 + ((x0 * y0) >>> 32);
		var w = x0 * y1 + (t & m32());
		return x1 * y1 + (t >>> 32) + (w >>> 32);
	}

	// floor(e log10(2)), floor(e log10(3/4 2^e)'s), floor(e log2(10))
	static inline function flog10pow2(e:Int):Int
		return (((e : I64) * hl(0x9a, 0x209a84fb)) >> 41).toInt();

	static inline function flog10threeQuartersPow2(e:Int):Int
		return (((e : I64) * hl(0x9a, 0x209a84fb) - hl(0x3f, 0xf7f85779)) >> 41).toInt();

	static inline function flog2pow10(e:Int):Int
		return (e * 1741647) >> 19;

	// g * cp / 2^127, rounded to odd
	static function rop(g1:I64, g0:I64, cp:I64):I64 {
		var x1 = mulHigh(g0, cp);
		var y0 = g1 * cp;
		var y1 = mulHigh(g1, cp);
		var z = (y0 >>> 1) + x1;
		var vbp = y1 + (z >>> 63);
		var m63 = hl(0x7fffffff, 0xffffffff);
		return vbp | (((z & m63) + m63) >>> 63);
	}

	// v = c * 2^q (c > 2 when q is the subnormals'): the shortest decimal f *
	// 10^k in v's rounding interval, the nearest to v, f at res and k at res + 8
	@:hxmc.unsafe static function schubfach(q:Int, c:I64, res:Ptr) {
		var out = (c & 1).toInt();
		var cb = c << 2;
		var cbr = cb + 2;
		var cbl:I64;
		var k:Int;
		if (!(c == ((1 : I64) << 52)) || q == -1074) {
			cbl = cb - 2;
			k = flog10pow2(q);
		} else {
			cbl = cb - 1;
			k = flog10threeQuartersPow2(q);
		}
		var h = q + flog2pow10(-k) + 2;
		var at = (k - K_MIN) * 32;
		var g1 = word(at), g0 = word(at + 16);
		var vb = rop(g1, g0, cb << h);
		var vbl = rop(g1, g0, cbl << h);
		var vbr = rop(g1, g0, cbr << h);
		var s = vb >> 2;
		Mem.setI32(res, 8, k);
		// (Java's has s >= 100: its text has two digits at least, JavaScript's
		// one, which only subnormals' s of two digits can come to)
		if (s >= 10) {
			var sp10 = mulHigh(s, hl(0x19999999, 0x999999a0)) * 10;
			var tp10 = sp10 + 10;
			var upin = vbl + out <= sp10 << 2;
			var wpin = (tp10 << 2) + out <= vbr;
			if (upin != wpin) {
				Mem.setI64(res, 0, upin ? sp10 : tp10);
				return;
			}
		}
		var t = s + 1;
		var uin = vbl + out <= s << 2;
		var win = (t << 2) + out <= vbr;
		if (uin != win) {
			Mem.setI64(res, 0, uin ? s : t);
			return;
		}
		var cmp = vb - ((s + t) << 1);
		Mem.setI64(res, 0, cmp < 0 || (cmp == 0 && (s & 1) == 0) ? s : t);
	}

	// the exact search: the digits at cand, their number; the exponent of the first at *ep
	@:hxmc.unsafe static function exactShortest(v:Float, cand:Ptr, ep:Ptr):Int {
		var dig = Mem.stack(1200);
		var dp = Mem.stack(8);
		var nd = exactDigits(v, dig, dp);
		var e10 = Mem.getI32(dp, 0);
		// the first precision whose correctly rounded decimal reads back as v
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
		Mem.setI32(ep, 0, ce);
		return prec;
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
		var cand = Mem.stack(24);
		var n:Int, ce:Int;
		var b = bits(v);
		var bq = ((b >>> 52) & 0x7FF).toInt();
		var t = b & ((((1 : I64) << 52)) - 1);
		if (bq == 0 && t < 3) {
			var ep = Mem.stack(8);
			n = exactShortest(v, cand, ep);
			ce = Mem.getI32(ep, 0);
		} else {
			var res = Mem.stack(16);
			var mq = 1075 - bq;
			var c = bq == 0 ? t : t | ((1 : I64) << 52);
			// (integers below 2^53: their own digits)
			if (bq != 0 && mq > 0 && mq < 53 && (c >> mq) << mq == c) {
				Mem.setI64(res, 0, c >> mq);
				Mem.setI32(res, 8, 0);
			} else schubfach(bq == 0 ? -1074 : -mq, c, res);
			var f = Mem.getI64(res, 0), k = Mem.getI32(res, 8);
			while (f % 10 == 0) {
				f = f / 10;
				k++;
			}
			n = 0;
			var g = f;
			while (!(g == 0)) {
				g = g / 10;
				n++;
			}
			var i = n;
			while (!(f == 0)) {
				Mem.setI8(cand, --i, (f % 10).toInt());
				f = f / 10;
			}
			ce = k + n - 1;
		}
		// (printf's digits: trailing zeros only from a carry, written as they are)
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
