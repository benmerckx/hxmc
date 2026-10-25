package hxmc.rt;

import hxmc.I64;
import hxmc.scoped.Scope;
import hxmc.scoped.Slice;

// Math on every target (docs/hxmc.md; docs/plans/math.md): the functions
// no instruction computes exactly, as musl computes them (musl's algorithms,
// and zig's ports of them in zig's libc and compiler_rt, which Linux
// executables linked before; see the license notice below), so that results
// are the same on every system and in WebAssembly. Math's natives are bound
// to them (@:hxmc.host: compiled into the programs that call them), Float's
// % to fmod (Lower.bindHosts); sqrt, abs, floor and ceil are instructions or
// inline code (MirBuild). Scoped code over the scoped abstractions only
// (docs/plans/lowlevel.md, "Two representations, one core"), the same on
// every target, WasmGC too (which used the engine's Math before): no GC
// reference, scoped memory and LibMData's tables only.
//
// musl as a whole is licensed under the following standard MIT license:
//
// Copyright © 2005-2020 Rich Felker, et al.
//
// Permission is hereby granted, free of charge, to any person obtaining
// a copy of this software and associated documentation files (the
// "Software"), to deal in the Software without restriction, including
// without limitation the rights to use, copy, modify, merge, publish,
// distribute, sublicense, and/or sell copies of the Software, and to
// permit persons to whom the Software is furnished to do so, subject to
// the following conditions:
//
// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
// IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
// CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
// TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
// SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
@:keep @:hxmc.noGc @:hxmc.scoped @:hxmc.anyHeap
class LibM {
	// ---- the tables (LibMData: the trusted layer's, on every target)

	static inline function powTab(i:Int):Float
		return LibMData.powTab(i);

	static inline function powPoly(i:Int):Float
		return LibMData.powPoly(i);

	static inline function expTab(i:Int):I64
		return LibMData.expTab(i);

	static inline function expPoly(i:Int):Float
		return LibMData.expPoly(i);

	static inline function logTab(i:Int):Float
		return LibMData.logTab(i);

	static inline function logTab2(i:Int):Float
		return LibMData.logTab2(i);

	static inline function logPoly1(i:Int):Float
		return LibMData.logPoly1(i);

	static inline function logPoly(i:Int):Float
		return LibMData.logPoly(i);

	static inline function ipio2(i:Int):Int
		return LibMData.ipio2(i);

	// ---- bits

	static inline function bits(v:Float):I64
		return Repr.doubleBits(v);

	static inline function ofBits(b:I64):Float
		return Repr.bitsDouble(b);

	// unsigned comparison of 64-bit patterns
	static inline function ultL(a:I64, b:I64):Bool
		return (a ^ ((1 : I64) << 63)) < (b ^ ((1 : I64) << 63));

	// the high word (as an unsigned 32-bit pattern in an Int)
	static inline function hi(v:Float):Int
		return (bits(v) >>> 32).toInt();

	static inline function lo(v:Float):Int
		return bits(v).toInt();

	// unsigned comparisons of 32-bit patterns
	static inline function ult(a:Int, b:Int):Bool
		return (a ^ 0x80000000) < (b ^ 0x80000000);

	static inline function uge(a:Int, b:Int):Bool
		return !ult(a, b);

	static inline function inf():Float
		return ofBits((0x7FF : I64) << 52);

	// musl's scalbn
	static function scalbn(x:Float, n:Int):Float {
		var y = x;
		if (n > 1023) {
			y *= ofBits((0x7FE : I64) << 52); // 0x1p1023
			n -= 1023;
			if (n > 1023) {
				y *= ofBits((0x7FE : I64) << 52);
				n -= 1023;
				if (n > 1023) n = 1023;
			}
		} else if (n < -1022) {
			// make sure the final n < -53 to avoid double rounding in the subnormal range
			var s = ofBits((0x001 : I64) << 52) * ofBits(((0x3FF + 53) : I64) << 52); // 0x1p-1022 * 0x1p53
			y *= s;
			n += 1022 - 53;
			if (n < -1022) {
				y *= s;
				n += 1022 - 53;
				if (n < -1022) n = -1022;
			}
		}
		return y * ofBits(((0x3ff + n) : I64) << 52);
	}

	// ---- sin, cos, tan (musl: __sin.c, __cos.c, __tan.c, __rem_pio2.c, __rem_pio2_large.c)
	// (the kernels inline, as zig's compiler_rt has them)

	static inline function kcos(x:Float, y:Float):Float {
		var z = x * x;
		var zs = z * z;
		var r = z * (4.16666666666666019037e-02 + z * (-1.38888888888741095749e-03 + z * 2.48015872894767294178e-05))
			+ zs * zs * (-2.75573143513906633035e-07 + z * (2.08757232129817482790e-09 + z * -1.13596475577881948265e-11));
		var hz = 0.5 * z;
		var w = 1.0 - hz;
		return w + (((1.0 - w) - hz) + (z * r - x * y));
	}

	static inline function ksin(x:Float, y:Float, iy:Int):Float {
		var S1 = -1.66666666666666324348e-01;
		var z = x * x;
		var w = z * z;
		var r = 8.33333333332248946124e-03 + z * (-1.98412698298579493134e-04 + z * 2.75573137070700676789e-06)
			+ z * w * (-2.50507602534068634195e-08 + z * 1.58969099521155010221e-10);
		var v = z * x;
		return iy == 0 ? x + v * (S1 + z * r) : x - ((z * (0.5 * y - v * r) - y) - v * S1);
	}

	static inline function ktan(x:Float, y:Float, odd:Bool):Float {
		var pio4 = 7.85398163397448278999e-01;
		var pio4lo = 3.06161699786838301793e-17;
		var hx = hi(x);
		var big = (hx & 0x7fffffff) >= 0x3FE59428;
		var sign = false;
		if (big) {
			sign = (hx >>> 31) != 0;
			if (sign) {
				x = -x;
				y = -y;
			}
			x = (pio4 - x) + (pio4lo - y);
			y = 0.0;
		}
		var z = x * x;
		var w = z * z;
		var r = 1.33333333333201242699e-01
			+ w * (2.18694882948595424599e-02
				+ w * (3.59207910759131235356e-03 + w * (5.88041240820264096874e-04 + w * (7.81794442939557092300e-05 + w * -1.85586374855275456654e-05))));
		var v = z * (5.39682539762260521377e-02
			+ w * (8.86323982359930005737e-03
				+ w * (1.45620945432529025516e-03 + w * (2.46463134818469906812e-04 + w * (7.14072491382608190305e-05 + w * 2.59073051863633712884e-05)))));
		var s = z * x;
		r = y + z * (s * (r + v) + y) + s * 3.33333333333334091986e-01;
		w = x + r;
		if (big) {
			s = odd ? -1.0 : 1.0;
			v = s - 2.0 * (x + (r - w * w / (w + s)));
			w = sign ? -v : v;
		} else if (odd) {
			// -1.0/(x+r) has up to 2ulp error, so compute it accurately
			var w0 = ofBits(bits(w) & ((-1 : I64) << 32));
			v = r - (w0 - x); // w0+v = r+x
			var a = -1.0 / w;
			var a0 = ofBits(bits(a) & ((-1 : I64) << 32));
			w = a0 + a * (1.0 + a0 * w0 + a0 * v);
		}
		return w;
	}

	static inline var PIO2_1 = 1.57079632673412561417e+00;
	static inline var PIO2_1T = 6.07710050650619224932e-11;

	// x reduced by multiples of pi/2: n and the result y0 + y1
	static inline function medium(ix:Int, x:Float):Reduced {
		var toint = 6755399441055744.0;
		var pio4 = 0.7853981633974483;
		var invpio2 = 6.36619772367581382433e-01;
		var pio2_2 = 6.07710050630396597660e-11;
		var pio2_2t = 2.02226624879595063154e-21;
		var pio2_3 = 2.02226624871116645580e-21;
		var pio2_3t = 8.47842766036889956997e-32;
		// rint(x/(pi/2))
		var fn = x * invpio2 + toint - toint;
		var n = Std.int(fn);
		var r = x - fn * PIO2_1;
		var w = fn * PIO2_1T; // 1st round, good to 85 bits
		// matters with directed rounding
		if (r - w < -pio4) {
			n--;
			fn--;
			r = x - fn * PIO2_1;
			w = fn * PIO2_1T;
		} else if (r - w > pio4) {
			n++;
			fn++;
			r = x - fn * PIO2_1;
			w = fn * PIO2_1T;
		}
		var y0 = r - w;
		var ey = (hi(y0) >>> 20) & 0x7ff;
		var ex = ix >>> 20;
		if (ex - ey > 16) { // 2nd round, good to 118 bits
			var t = r;
			w = fn * pio2_2;
			r = t - w;
			w = fn * pio2_2t - ((t - r) - w);
			y0 = r - w;
			ey = (hi(y0) >>> 20) & 0x7ff;
			if (ex - ey > 49) { // 3rd round, good to 151 bits, covers all cases
				t = r;
				w = fn * pio2_3;
				r = t - w;
				w = fn * pio2_3t - ((t - r) - w);
				y0 = r - w;
			}
		}
		return new Reduced(n, y0, (r - y0) - w);
	}

	// (inline: its result a struct value in registers)
	static inline function remPio2(x:Float):Reduced {
		var u = bits(x);
		var sign = !((u >>> 63) == 0);
		var ix = (u >>> 32).toInt() & 0x7fffffff;
		// (one result made, at the end: a struct value in registers, the
		// constructor inlined; musl's gotos to medium: one call below)
		var n = 0, y0 = 0.0, y1 = 0.0;
		var small = ix <= 0x400f6a7a && (ix & 0xfffff) != 0x921fb; // |x| ~<= 5pi/4, not ~= pi/2 or 2pi/2
		if (small || (ix > 0x400f6a7a && ix <= 0x401c463b && ix != 0x4012d97c && ix != 0x401921fb)) { // |x| ~<= 9pi/4, not ~= 3pi/2 or 4pi/2
			// (k pi/2 away, k <= 4: one round good to 85 bits)
			var k = small ? (ix <= 0x4002d97c ? 1 : 2) : (ix <= 0x4015fdbc ? 3 : 4);
			var c = k * PIO2_1, ct = k * PIO2_1T;
			if (!sign) {
				var z = x - c;
				y0 = z - ct;
				y1 = (z - y0) - ct;
				n = k;
			} else {
				var z = x + c;
				y0 = z + ct;
				y1 = (z - y0) + ct;
				n = -k;
			}
		} else if (ix < 0x413921fb) { // |x| ~< 2^20*(pi/2), medium size (and the cases above)
			var m = medium(ix, x);
			n = m.n;
			y0 = m.y0;
			y1 = m.y1;
		} else if (ix >= 0x7ff00000) { // x is inf or NaN
			y0 = x - x;
			y1 = y0;
		} else { // all other (large) arguments
			var m = remPio2Large1(x, ix, sign);
			n = m.n;
			y0 = m.y0;
			y1 = m.y1;
		}
		return new Reduced(n, y0, y1);
	}

	// (apart: remPio2 stays a leaf function, without a frame)
	static function remPio2Large1(x:Float, ix:Int, sign:Bool):Reduced {
		// set z = scalbn(|x|,-ilogb(x)+23)
		var ui = bits(x);
		ui = ui & ((-1 : I64) >>> 12);
		ui = ui | (((0x3ff + 23) : I64) << 52);
		var z = ofBits(ui);
		var tx:Slice<Float> = Scope.slice(3), ty:Slice<Float> = Scope.slice(2);
		var i = 0;
		while (i < 2) {
			var t:Float = Std.int(z);
			tx[i] = t;
			z = (z - t) * 16777216.0;
			i++;
		}
		tx[i] = z;
		// skip zero terms, first term is non-zero
		while (tx[i] == 0.0)
			i--;
		var n = remPio2Large(tx, ty, (ix >>> 20) - (0x3ff + 23), i + 1);
		return sign ? new Reduced(-n, -ty[0], -ty[1]) : new Reduced(n, ty[0], ty[1]);
	}


	// __rem_pio2_large for prec = 1 (doubles): x[nx] (24-bit chunks) in tx, y[2] into ty
	static function remPio2Large(x:Slice<Float>, y:Slice<Float>, e0:Int, nx:Int):Int {
		var PIo2:Slice<Float> = Scope.slice(8);
		PIo2[0] = 1.57079625129699707031e+00;
		PIo2[1] = 7.54978941586159635335e-08;
		PIo2[2] = 5.39030252995776476554e-15;
		PIo2[3] = 3.28200341580791294123e-22;
		PIo2[4] = 1.27065575308067607349e-29;
		PIo2[5] = 1.22933308981111328932e-36;
		PIo2[6] = 2.73370053816464559624e-44;
		PIo2[7] = 2.16741683877804819444e-51;
		var iq:Slice<Int> = Scope.slice(20), f:Slice<Float> = Scope.slice(20), fq:Slice<Float> = Scope.slice(20), q:Slice<Float> = Scope.slice(20);
		inline function geti(p:Slice<Int>, k:Int):Int
			return p[k];
		inline function seti(p:Slice<Int>, k:Int, v:Int)
			p[k] = v;
		inline function getf(p:Slice<Float>, k:Int):Float
			return p[k];
		inline function setf(p:Slice<Float>, k:Int, v:Float)
			p[k] = v;
		var jk = 4; // init_jk[prec = 1]
		var jp = jk;
		// determine jx,jv,q0, note that 3>q0
		var jx = nx - 1;
		var jv = e0 - 3;
		jv = jv >= 0 ? Std.int(jv / 24) : -Std.int((-jv + 23) / 24); // floor division
		if (jv < 0) jv = 0;
		var q0 = e0 - 24 * (jv + 1);
		// set up f[0] to f[jx+jk] where f[jx+jk] = ipio2[jv+jk]
		var j = jv - jx;
		var m = jx + jk;
		var i = 0;
		while (i <= m) {
			setf(f, i, j < 0 ? 0.0 : ipio2(j));
			i++;
			j++;
		}
		// compute q[0],q[1],...q[jk]
		i = 0;
		while (i <= jk) {
			var fw = 0.0;
			j = 0;
			while (j <= jx) {
				fw += getf(x, j) * getf(f, jx + i - j);
				j++;
			}
			setf(q, i, fw);
			i++;
		}
		var jz = jk;
		var n = 0, ih = 0;
		var z = 0.0;
		while (true) { // recompute
			// distill q[] into iq[] reversingly
			i = 0;
			j = jz;
			z = getf(q, jz);
			while (j > 0) {
				var fw:Float = Std.int(5.9604644775390625e-08 * z);
				seti(iq, i, Std.int(z - 16777216.0 * fw));
				z = getf(q, j - 1) + fw;
				i++;
				j--;
			}
			// compute n
			z = scalbn(z, q0); // actual value of z
			z -= 8.0 * Math.ffloor(z * 0.125); // trim off integer >= 8
			n = Std.int(z);
			z -= n;
			ih = 0;
			if (q0 > 0) { // need iq[jz-1] to determine n
				i = geti(iq, jz - 1) >> (24 - q0);
				n += i;
				seti(iq, jz - 1, geti(iq, jz - 1) - (i << (24 - q0)));
				ih = geti(iq, jz - 1) >> (23 - q0);
			} else if (q0 == 0)
				ih = geti(iq, jz - 1) >> 23;
			else if (z >= 0.5) ih = 2;
			if (ih > 0) { // q > 0.5
				n += 1;
				var carry = 0;
				i = 0;
				while (i < jz) { // compute 1-q
					j = geti(iq, i);
					if (carry == 0) {
						if (j != 0) {
							carry = 1;
							seti(iq, i, 0x1000000 - j);
						}
					} else
						seti(iq, i, 0xffffff - j);
					i++;
				}
				if (q0 > 0) { // rare case: chance is 1 in 12
					if (q0 == 1) seti(iq, jz - 1, geti(iq, jz - 1) & 0x7fffff);
					if (q0 == 2) seti(iq, jz - 1, geti(iq, jz - 1) & 0x3fffff);
				}
				if (ih == 2) {
					z = 1.0 - z;
					if (carry != 0) z -= scalbn(1.0, q0);
				}
			}
			// check if recomputation is needed
			if (z == 0.0) {
				j = 0;
				i = jz - 1;
				while (i >= jk) {
					j |= geti(iq, i);
					i--;
				}
				if (j == 0) { // need recomputation
					var k = 1;
					while (geti(iq, jk - k) == 0)
						k++; // k = no. of terms needed
					i = jz + 1;
					while (i <= jz + k) { // add q[jz+1] to q[jz+k]
						setf(f, jx + i, ipio2(jv + i));
						var fw = 0.0;
						j = 0;
						while (j <= jx) {
							fw += getf(x, j) * getf(f, jx + i - j);
							j++;
						}
						setf(q, i, fw);
						i++;
					}
					jz += k;
					continue;
				}
			}
			break;
		}
		// chop off zero terms
		if (z == 0.0) {
			jz -= 1;
			q0 -= 24;
			while (geti(iq, jz) == 0) {
				jz--;
				q0 -= 24;
			}
		} else { // break z into 24-bit if necessary
			z = scalbn(z, -q0);
			if (z >= 16777216.0) {
				var fw:Float = Std.int(5.9604644775390625e-08 * z);
				seti(iq, jz, Std.int(z - 16777216.0 * fw));
				jz += 1;
				q0 += 24;
				seti(iq, jz, Std.int(fw));
			} else
				seti(iq, jz, Std.int(z));
		}
		// convert integer "bit" chunk to floating-point value
		var fw = scalbn(1.0, q0);
		i = jz;
		while (i >= 0) {
			setf(q, i, fw * geti(iq, i));
			fw *= 5.9604644775390625e-08;
			i--;
		}
		// compute PIo2[0,...,jp]*q[jz,...,0]
		i = jz;
		while (i >= 0) {
			fw = 0.0;
			var k = 0;
			while (k <= jp && k <= jz - i) {
				fw += getf(PIo2, k) * getf(q, i + k);
				k++;
			}
			setf(fq, jz - i, fw);
			i--;
		}
		// compress fq[] into y[] (prec 1)
		fw = 0.0;
		i = jz;
		while (i >= 0) {
			fw += getf(fq, i);
			i--;
		}
		setf(y, 0, ih == 0 ? fw : -fw);
		fw = getf(fq, 0) - fw;
		i = 1;
		while (i <= jz) {
			fw += getf(fq, i);
			i++;
		}
		setf(y, 1, ih == 0 ? fw : -fw);
		return n & 7;
	}

	@:hxmc.host("Math_sin") static function sin(x:Float):Float {
		var ix = hi(x) & 0x7fffffff;
		// |x| ~< pi/4
		if (ix <= 0x3fe921fb) {
			if (ix < 0x3e500000) return x; // |x| < 2**-26
			return ksin(x, 0.0, 0);
		}
		// sin(Inf or NaN) is NaN
		if (ix >= 0x7ff00000) return x - x;
		var r = remPio2(x);
		var n = r.n, y0 = r.y0, y1 = r.y1;
		return switch n & 3 {
			case 0: ksin(y0, y1, 1);
			case 1: kcos(y0, y1);
			case 2: -ksin(y0, y1, 1);
			case _: -kcos(y0, y1);
		}
	}

	@:hxmc.host("Math_cos") static function cos(x:Float):Float {
		var ix = hi(x) & 0x7fffffff;
		// |x| ~< pi/4
		if (ix <= 0x3fe921fb) {
			if (ix < 0x3e46a09e) return 1.0; // |x| < 2**-27 * sqrt(2)
			return kcos(x, 0);
		}
		// cos(Inf or NaN) is NaN
		if (ix >= 0x7ff00000) return x - x;
		var r = remPio2(x);
		var n = r.n, y0 = r.y0, y1 = r.y1;
		return switch n & 3 {
			case 0: kcos(y0, y1);
			case 1: -ksin(y0, y1, 1);
			case 2: -kcos(y0, y1);
			case _: ksin(y0, y1, 1);
		}
	}

	@:hxmc.host("Math_tan") static function tan(x:Float):Float {
		var ix = hi(x) & 0x7fffffff;
		// |x| ~< pi/4
		if (ix <= 0x3fe921fb) {
			if (ix < 0x3e400000) return x; // |x| < 2**-27
			return ktan(x, 0.0, false);
		}
		// tan(Inf or NaN) is NaN
		if (ix >= 0x7ff00000) return x - x;
		var r = remPio2(x);
		return ktan(r.y0, r.y1, (r.n & 1) != 0);
	}

	// ---- asin, acos (zig std.math: musl's asin.c, acos.c), atan, atan2 (musl's)

	static inline function asinR(z:Float):Float {
		var p = z * (1.66666666666666657415e-01
			+ z * (-3.25565818622400915405e-01
				+ z * (2.01212532134862925881e-01 + z * (-4.00555345006794114027e-02 + z * (7.91534994289814532176e-04 + z * 3.47933107596021167570e-05)))));
		var q = 1.0 + z * (-2.40339491173441421878e+00 + z * (2.02094576023350569471e+00 + z * (-6.88283971605453293030e-01 + z * 7.70381505559019352791e-02)));
		return p / q;
	}

	static inline var PIO2_HI = 1.57079632679489655800e+00;
	static inline var PIO2_LO = 6.12323399573676603587e-17;

	@:hxmc.host("Math_asin") static function asin(x:Float):Float {
		var hx = hi(x);
		var ix = hx & 0x7fffffff;
		// |x| >= 1 or nan
		if (ix >= 0x3ff00000) {
			// asin(1) = +-pi/2 with inexact
			if (((ix - 0x3ff00000) | lo(x)) == 0) return x * PIO2_HI + 7.52316384526264005099991383822e-37;
			return 0.0 / (x - x);
		}
		// |x| < 0.5
		if (ix < 0x3fe00000) {
			// if 0x1p-1022 <= |x| < 0x1p-26 avoid raising overflow
			if (ix < 0x3e500000 && ix >= 0x00100000) return x;
			return x + x * asinR(x * x);
		}
		// 1 > |x| >= 0.5
		var z = (1.0 - Math.abs(x)) * 0.5;
		var s = Math.sqrt(z);
		var r = asinR(z);
		var res:Float;
		if (ix >= 0x3fef3333) { // |x| > 0.975
			res = PIO2_HI - (2 * (s + s * r) - PIO2_LO);
		} else {
			// f+c = sqrt(z)
			var f = ofBits(bits(s) & ((-1 : I64) << 32));
			var c = (z - f * f) / (s + f);
			res = 0.5 * PIO2_HI - (2.0 * s * r - (PIO2_LO - 2.0 * c) - (0.5 * PIO2_HI - 2.0 * f));
		}
		return (hx >>> 31) != 0 ? -res : res;
	}

	@:hxmc.host("Math_acos") static function acos(x:Float):Float {
		var hx = hi(x);
		var ix = hx & 0x7fffffff;
		// |x| >= 1 or nan
		if (ix >= 0x3ff00000) {
			if (((ix - 0x3ff00000) | lo(x)) == 0) {
				if ((hx >>> 31) != 0) return 2.0 * PIO2_HI + 7.52316384526264005099991383822e-37;
				return 0.0;
			}
			return 0.0 / (x - x);
		}
		// |x| < 0.5
		if (ix < 0x3fe00000) {
			if (ix <= 0x3c600000) return PIO2_HI + 7.52316384526264005099991383822e-37; // |x| < 2^(-57)
			return PIO2_HI - (x - (PIO2_LO - x * asinR(x * x)));
		}
		// x < -0.5
		if ((hx >>> 31) != 0) {
			var z = (1.0 + x) * 0.5;
			var s = Math.sqrt(z);
			var w = asinR(z) * s - PIO2_LO;
			return 2 * (PIO2_HI - (s + w));
		}
		// x > 0.5
		var z = (1.0 - x) * 0.5;
		var s = Math.sqrt(z);
		var df = ofBits(bits(s) & ((-1 : I64) << 32));
		var c = (z - df * df) / (s + df);
		var w = asinR(z) * s + c;
		return 2.0 * (df + w);
	}

	@:hxmc.host("Math_atan") static function atan(x:Float):Float {
		var u = bits(x);
		var ix = (u >>> 32).toInt() & 0x7fffffff;
		var sign = !((u >>> 63) == 0);
		// |x| >= 2^66
		if (ix >= 0x44100000) {
			if (x != x) return x;
			var z = 1.57079632679489655800e+00 + 7.52316384526264005099991383822e-37;
			return sign ? -z : z;
		}
		var id = -1;
		var xr = x;
		// (atanhi[id], atanlo[id])
		var ahi = 0.0, alo = 0.0;
		if (ix < 0x3fdc0000) { // |x| < 0.4375
			if (ix < 0x3e400000) return x; // |x| < 2^(-27)
		} else {
			var xa = Math.abs(x);
			if (ix < 0x3ff30000) { // |x| < 1.1875
				if (ix < 0x3fe60000) { // 7/16 <= |x| < 11/16
					xr = (2.0 * xa - 1.0) / (2.0 + xa);
					id = 0;
					ahi = 4.63647609000806093515e-01;
					alo = 2.26987774529616870924e-17;
				} else { // 11/16 <= |x| < 19/16
					xr = (xa - 1.0) / (xa + 1.0);
					id = 1;
					ahi = 7.85398163397448278999e-01;
					alo = 3.06161699786838301793e-17;
				}
			} else {
				if (ix < 0x40038000) { // |x| < 2.4375
					xr = (xa - 1.5) / (1.0 + 1.5 * xa);
					id = 2;
					ahi = 9.82793723247329054082e-01;
					alo = 1.39033110312309984516e-17;
				} else { // 2.4375 <= |x| < 2^66
					xr = -1.0 / xa;
					id = 3;
					ahi = 1.57079632679489655800e+00;
					alo = 6.12323399573676603587e-17;
				}
			}
		}
		// end of argument reduction
		var z = xr * xr;
		var w = z * z;
		// break sum from i=0 to 10 aT[i]z^(i+1) into odd and even poly
		var s1 = z * (3.33333333333329318027e-01
			+ w * (1.42857142725034663711e-01
				+ w * (9.09088713343650656196e-02 + w * (6.66107313738753120669e-02 + w * (4.97687799461593236017e-02 + w * 1.62858201153657823623e-02)))));
		var s2 = w * (-1.99999999998764832476e-01
			+ w * (-1.11111104054623557880e-01 + w * (-7.69187620504482999495e-02 + w * (-5.83357013379057348645e-02 + w * -3.65315727442169155270e-02))));
		if (id < 0) return xr - xr * (s1 + s2);
		var zr = ahi - (xr * (s1 + s2) - alo - xr);
		return sign ? -zr : zr;
	}

	@:hxmc.host("Math_atan2") static function atan2(y:Float, x:Float):Float {
		var pi = 3.1415926535897931160E+00;
		var pi_lo = 1.2246467991473531772E-16;
		if (x != x || y != y) return x + y;
		var ix = hi(x), lx = lo(x);
		var iy = hi(y), ly = lo(y);
		if (((ix - 0x3ff00000) | lx) == 0) return atan(y); // x = 1.0
		var m = ((iy >>> 31) & 1) | ((ix >>> 30) & 2); // 2*sign(x)+sign(y)
		ix = ix & 0x7fffffff;
		iy = iy & 0x7fffffff;
		// when y = 0
		if ((iy | ly) == 0) {
			switch m {
				case 0 | 1:
					return y; // atan(+-0,+anything)=+-0
				case 2:
					return pi; // atan(+0,-anything) = pi
				case _:
					return -pi; // atan(-0,-anything) =-pi
			}
		}
		// when x = 0
		if ((ix | lx) == 0) return (m & 1) != 0 ? -pi / 2 : pi / 2;
		// when x is INF
		if (ix == 0x7ff00000) {
			if (iy == 0x7ff00000) {
				switch m {
					case 0:
						return pi / 4; // atan(+INF,+INF)
					case 1:
						return -pi / 4; // atan(-INF,+INF)
					case 2:
						return 3 * pi / 4; // atan(+INF,-INF)
					case _:
						return -3 * pi / 4; // atan(-INF,-INF)
				}
			} else {
				switch m {
					case 0:
						return 0.0; // atan(+...,+INF)
					case 1:
						return -0.0; // atan(-...,+INF)
					case 2:
						return pi; // atan(+...,-INF)
					case _:
						return -pi; // atan(-...,-INF)
				}
			}
		}
		// |y/x| > 0x1p64
		if (ult(ix + (64 << 20), iy) || iy == 0x7ff00000) return (m & 1) != 0 ? -pi / 2 : pi / 2;
		// z = atan(|y/x|) without spurious underflow
		var z:Float;
		if ((m & 2) != 0 && ult(iy + (64 << 20), ix)) z = 0; // |y/x| < 0x1p-64, x<0
		else z = atan(Math.abs(y / x));
		return switch m {
			case 0: z; // atan(+,+)
			case 1: -z; // atan(-,+)
			case 2: pi - (z - pi_lo); // atan(+,-)
			case _: (z - pi_lo) - pi; // atan(-,-)
		}
	}

	// ---- exp (zig's exp: musl's former exp.c), log (musl's log.c)

	@:hxmc.host("Math_exp") static function exp(x:Float):Float {
		var ln2hi = 6.93147180369123816490e-01;
		var ln2lo = 1.90821492927058770002e-10;
		var invln2 = 1.44269504088896338700e+00;
		var hx = hi(x);
		var sign = hx >>> 31;
		hx = hx & 0x7FFFFFFF;
		if (x != x) return x;
		// |x| >= 708.39 or nan
		if (hx >= 0x4086232B) {
			if (hx > 0x7FF00000) return x; // nan
			if (x > 709.782712893383973096) return inf(); // overflow
			if (x < -708.39641853226410622) {
				if (x < -745.13321910194110842) return 0;
			}
		}
		// argument reduction
		var k = 0;
		var hi_ = 0.0, lo_ = 0.0;
		if (hx > 0x3FD62E42) { // |x| > 0.5 * ln2
			if (hx > 0x3FF0A2B2) // |x| >= 1.5 * ln2
				// (copysign(0.5, x) for musl's half[sign]: no branch on the
				// sign, which random signs mispredict half the time)
				k = Std.int(invln2 * x + ofBits(bits(0.5) | (bits(x) & ((1 : I64) << 63))));
			else
				k = 1 - sign - sign;
			var dk:Float = k;
			hi_ = x - dk * ln2hi;
			lo_ = dk * ln2lo;
			x = hi_ - lo_;
		} else if (hx > 0x3E300000) { // |x| > 2^(-28)
			k = 0;
			hi_ = x;
			lo_ = 0;
		} else
			return 1 + x;
		var xx = x * x;
		var c = x - xx * (1.66666666666666019037e-01
			+ xx * (-2.77777777770155933842e-03 + xx * (6.61375632143793436117e-05 + xx * (-1.65339022054652515390e-06 + xx * 4.13813679705723846039e-08))));
		var y = 1 + (x * c / (2 - c) - lo_ + hi_);
		// (scalbn's common case inline: one multiplication by 2^k, exact;
		// y * 1.0 is y for k == 0)
		return k >= -1022 && k <= 1023 ? y * ofBits(((0x3ff + k) : I64) << 52) : scalbn(y, k);
	}

	@:hxmc.host("Math_log") static function log(x:Float):Float {
		var ix = bits(x);
		var LO = bits(1.0 - 0.0625);
		var HI = bits(1.0 + 0.064697265625); // 1.0 + 0x1.09p-4
		if (!(ix < LO) && ix < HI) {
			if (ix == bits(1.0)) return 0;
			var r = x - 1;
			var r2 = r * r;
			var r3 = r * r2;
			inline function p1(i:Int):Float
				return logPoly1(i);
			var y = r3 * (p1(1) + r * p1(2) + r2 * p1(3) + r3 * (p1(4) + r * p1(5) + r2 * p1(6) + r3 * (p1(7) + r * p1(8) + r2 * p1(9) + r3 * p1(10))));
			var w = r * 134217728.0; // 0x1p27
			var rhi = r + w - w;
			var rlo = r - rhi;
			w = rhi * rhi * p1(0);
			var hi_ = r + w;
			var lo_ = r - hi_ + w + p1(0) * rlo * (rhi + r);
			return y + lo_ + hi_;
		}
		var top = (ix >>> 48).toInt();
		if (top < 0x0010 || 0x7ff0 <= top) {
			if ((ix << 1) == 0) return -inf();
			if (ix == bits(inf())) return x;
			if ((top & 0x8000) != 0 || (top & 0x7ff0) == 0x7ff0) return (x - x) / 0.0;
			ix = bits(x * 4503599627370496.0) - ((52 : I64) << 52); // x * 0x1p52
		}
		var tmp = ix - ((0x3fe60000 : I64) << 32);
		var i = ((tmp >>> 45) & 127).toInt();
		var k = (tmp >> 52).toInt();
		var iz = ix - (tmp & (((0xfff : I64)) << 52));
		var invc = logTab(2 * i);
		var logc = logTab(2 * i + 1);
		var z = ofBits(iz);
		var r = (z - logTab2(2 * i) - logTab2(2 * i + 1)) * invc;
		var kd:Float = k;
		var w = kd * 0.6931471805598903 + logc;
		var hi_ = w + r;
		var lo_ = w - hi_ + r + kd * 5.497923018708371e-14;
		var r2 = r * r;
		inline function p(i:Int):Float
			return logPoly(i);
		return lo_ + r2 * p(0) + r * r2 * (p(1) + r * p(2) + r2 * (p(3) + r * p(4))) + hi_;
	}

	// ---- pow (musl's pow.c, ARM's optimized routines)

	static inline function top12(x:Float):Int
		return (bits(x) >>> 52).toInt();

	// log(x) for the bits ix of x (normalized): hi, and its tail
	// (inline, as musl's static inline log_inline)
	static inline function logInline(ix:I64):Split {
		var OFF = ((0x3fe69555 : I64) << 32);
		var tmp = ix - OFF;
		var i = ((tmp >>> 45) & 127).toInt();
		var k = (tmp >> 52).toInt(); // arithmetic shift
		var iz = ix - (tmp & ((0xfff : I64) << 52));
		var z = ofBits(iz);
		var kd:Float = k;
		// log(x) = k*Ln2 + log(c) + log1p(z/c-1)
		var invc = powTab(3 * i);
		var logc = powTab(3 * i + 1);
		var logctail = powTab(3 * i + 2);
		// split z such that rhi, rlo and rhi*rhi are exact and |rlo| <= |r|
		var zhi = ofBits((iz + ((1 : I64) << 31)) & ((-1 : I64) << 32));
		var zlo = z - zhi;
		var rhi = zhi * invc - 1.0;
		var rlo = zlo * invc;
		var r = rhi + rlo;
		// k*Ln2 + log(c) + r
		var t1 = kd * 0.6931471805598903 + logc;
		var t2 = t1 + r;
		var lo1 = kd * 5.497923018708371e-14 + logctail;
		var lo2 = t1 - t2 + r;
		inline function A(i:Int):Float
			return powPoly(i);
		var ar = A(0) * r; // A[0] = -0.5
		var ar2 = r * ar;
		var ar3 = r * ar2;
		// k*Ln2 + log(c) + r + A[0]*r*r
		var arhi = A(0) * rhi;
		var arhi2 = rhi * arhi;
		var hi_ = t2 + arhi2;
		var lo3 = rlo * (ar + arhi);
		var lo4 = t2 - hi_ + arhi2;
		// p = log1p(r) - r - A[0]*r*r
		var p = ar3 * (A(1) + r * A(2) + ar2 * (A(3) + r * A(4) + ar2 * (A(5) + r * A(6))));
		var lo_ = lo1 + lo2 + lo3 + lo4 + p;
		var y = hi_ + lo_;
		return new Split(y, hi_ - y + lo_);
	}

	static function specialcase(tmp:Float, sbits:I64, ki:I64):Float {
		if ((ki & ((1 : I64) << 31)) == 0) {
			// k > 0, the exponent of scale might have overflowed by <= 460
			sbits = sbits - ((1009 : I64) << 52);
			var scale = ofBits(sbits);
			return ofBits(((0x3ff + 1009) : I64) << 52) * (scale + scale * tmp); // 0x1p1009
		}
		// k < 0, need special care in the subnormal range
		sbits = sbits + ((1022 : I64) << 52);
		var scale = ofBits(sbits);
		var y = scale + scale * tmp;
		if (Math.abs(y) < 1.0) {
			var one = y < 0.0 ? -1.0 : 1.0;
			var lo_ = scale - y + scale * tmp;
			var hi_ = one + y;
			lo_ = one - hi_ + y + lo_;
			y = (hi_ + lo_) - one;
			// fix the sign of 0
			if (y == 0.0) y = ofBits(sbits & ((1 : I64) << 63));
		}
		return ofBits((1 : I64) << 52) * y; // 0x1p-1022
	}

	static inline var SIGN_BIAS = 0x800 << 7;

	// (inline, as musl's static inline exp_inline; its rare cases apart)
	static inline function expInline(x:Float, xtail:Float, signBias:Int):Float {
		var abstop = top12(x) & 0x7ff;
		var small = top12(5.551115123125783e-17); // 0x1p-54
		// large x is special cased below (specialcase)
		var large = uge(abstop - small, top12(512.0) - small);
		return large && (uge(abstop - small, 0x80000000) || abstop >= top12(1024.0)) ? expEdge(x, signBias) : expTail(x, xtail, signBias, large);
	}

	// exp_inline for tiny x, and for huge x (inf and nan are already handled)
	static function expEdge(x:Float, signBias:Int):Float {
		var abstop = top12(x) & 0x7ff;
		var small = top12(5.551115123125783e-17); // 0x1p-54
		if (uge(abstop - small, 0x80000000)) {
			// avoid spurious underflow for tiny x; 0 is common input
			var one = 1.0 + x;
			return signBias != 0 ? -one : one;
		}
		if (!((bits(x) >>> 63) == 0)) return signBias != 0 ? -0.0 : 0.0; // __math_uflow
		return signBias != 0 ? -inf() : inf(); // __math_oflow
	}

	static inline function expTail(x:Float, xtail:Float, signBias:Int, large:Bool):Float {
		// exp(x) = 2^(k/N) * exp(r), with exp(r) in [2^(-1/2N),2^(1/2N)]
		var z = 184.6649652337873 * x; // InvLn2N
		var shift = 6755399441055744.0;
		var kd = z + shift;
		var ki = bits(kd);
		kd -= shift;
		var r = x + kd * -0.005415212348111709 + kd * -1.2864023111638346e-14;
		// the code assumes 2^-200 < |xtail| < 2^-8/N
		r += xtail;
		// 2^(k/N) ~= scale * (1 + tail)
		var idx = 2 * (ki & 127).toInt();
		var top = (ki + signBias) << (52 - 7);
		var tail = ofBits(expTab(idx));
		// this is only a valid scale when -1023*N < k < 1024*N
		var sbits = expTab(idx + 1) + top;
		// exp(x) = 2^(k/N) * exp(r) ~= scale + scale * (tail + exp(r) - 1)
		var r2 = r * r;
		inline function C(i:Int):Float
			return expPoly(i);
		var tmp = tail + r + r2 * (C(0) + r * C(1)) + r2 * r2 * (C(2) + r * C(3));
		var scale = ofBits(sbits);
		return large ? specialcase(tmp, sbits, ki) : scale + scale * tmp;
	}

	// 0 if not int, 1 if odd int, 2 if even int (iy: a non-zero finite double)
	static function checkint(iy:I64):Int {
		var e = ((iy >>> 52) & 0x7ff).toInt();
		if (e < 0x3ff) return 0;
		if (e > 0x3ff + 52) return 2;
		if (!((iy & (((1 : I64) << (0x3ff + 52 - e)) - 1)) == 0)) return 0;
		if (!((iy & ((1 : I64) << (0x3ff + 52 - e))) == 0)) return 1;
		return 2;
	}

	// 0, infinity or nan
	static inline function zeroinfnan(i:I64):Bool
		return !ultL(i * 2 - 1, bits(inf()) * 2 - 1);

	@:hxmc.host("Math_pow") static function pow(x:Float, y:Float):Float {
		var topx = top12(x), topy = top12(y);
		// (the special cases apart: nothing lives across a call here)
		if (uge(topx - 0x001, 0x7ff - 0x001) || uge((topy & 0x7ff) - 0x3be, 0x43e - 0x3be)) return powSpecial(x, y);
		return powCore(bits(x), y, 0);
	}

	// pow for (x < 0x1p-126 or inf or nan) or (|y| < 0x1p-65 or |y| >= 0x1p63 or nan)
	static function powSpecial(x:Float, y:Float):Float {
		var signBias = 0;
		var ix = bits(x), iy = bits(y);
		var topx = top12(x), topy = top12(y);
		if (zeroinfnan(iy)) {
			if (iy * 2 == 0) return 1.0;
			if (ix == bits(1.0)) return 1.0;
			if (ultL(bits(inf()) * 2, ix * 2) || ultL(bits(inf()) * 2, iy * 2)) return x + y;
			if (ix * 2 == bits(1.0) * 2) return 1.0;
			if (ultL(ix * 2, bits(1.0) * 2) == ((iy >>> 63) == 0)) return 0.0; // |x|<1 && y==inf or |x|>1 && y==-inf
			return y * y;
		}
		if (zeroinfnan(ix)) {
			var x2 = x * x;
			if (!((ix >>> 63) == 0) && checkint(iy) == 1) x2 = -x2;
			return !((iy >>> 63) == 0) ? 1 / x2 : x2;
		}
		// here x and y are non-zero finite
		if (!((ix >>> 63) == 0)) {
			// finite x < 0
			var yint = checkint(iy);
			if (yint == 0) return (x - x) / (x - x); // __math_invalid
			if (yint == 1) signBias = SIGN_BIAS;
			ix = ix & ((-1 : I64) >>> 1);
			topx = topx & 0x7ff;
		}
		if (uge((topy & 0x7ff) - 0x3be, 0x43e - 0x3be)) {
			// note: sign_bias == 0 here because y is not odd
			if (ix == bits(1.0)) return 1.0;
			if ((topy & 0x7ff) < 0x3be) {
				// |y| < 2^-65, x^y ~= 1 + y*log(x)
				return ultL(bits(1.0), ix) ? 1.0 + y : 1.0 - y;
			}
			return (ultL(bits(1.0), ix)) == (topy < 0x800) ? inf() : 0.0;
		}
		if (topx == 0) {
			// normalize subnormal x so exponent becomes negative
			ix = bits(x * 4503599627370496.0);
			ix = ix & ((-1 : I64) >>> 1);
			ix = ix - ((52 : I64) << 52);
		}
		return powCore(ix, y, signBias);
	}

	// x^y from the bits of x (normalized, made positive)
	static inline function powCore(ix:I64, y:Float, signBias:Int):Float {
		var iy = bits(y);
		var l = logInline(ix);
		var hi_ = l.hi, lo_ = l.lo;
		var yhi = ofBits(iy & ((-1 : I64) << 27));
		var ylo = y - yhi;
		var lhi = ofBits(bits(hi_) & ((-1 : I64) << 27));
		var llo = hi_ - lhi + lo_;
		var ehi = yhi * lhi;
		var elo = ylo * lhi + y * llo; // |elo| < |ehi| * 2^-25
		return expInline(ehi, elo, signBias);
	}

	// musl's fmod (src/math/fmod.c)
	@:hxmc.host("fmod") static function fmod(x:Float, y:Float):Float {
		var ux = bits(x), uy = bits(y);
		var ex = ((ux >>> 52) & 0x7ff).toInt();
		var ey = ((uy >>> 52) & 0x7ff).toInt();
		var sx = ux >>> 63;
		var uxi = ux;
		if ((uy << 1) == 0 || y != y || ex == 0x7ff) return (x * y) / (x * y);
		if (ultL(ux << 1, uy << 1) || (ux << 1) == (uy << 1)) {
			if ((ux << 1) == (uy << 1)) return 0 * x;
			return x;
		}
		// normalize x and y
		if (ex == 0) {
			var i = uxi << 12;
			while ((i >>> 63) == 0) {
				ex--;
				i = i << 1;
			}
			uxi = uxi << (-ex + 1);
		} else {
			uxi = uxi & ((-1 : I64) >>> 12);
			uxi = uxi | ((1 : I64) << 52);
		}
		if (ey == 0) {
			var i = uy << 12;
			while ((i >>> 63) == 0) {
				ey--;
				i = i << 1;
			}
			uy = uy << (-ey + 1);
		} else {
			uy = uy & ((-1 : I64) >>> 12);
			uy = uy | ((1 : I64) << 52);
		}
		// x mod y (`if (i >> 63 == 0) { if (i == 0) return 0*x; uxi = i; }`
		// without a branch on the sign: a mask, as C compilers make it)
		while (ex > ey) {
			var i = uxi - uy;
			if (i == 0) return 0 * x;
			var neg = i >> 63;
			uxi = (i & ~neg) | (uxi & neg);
			uxi = uxi << 1;
			ex--;
		}
		var i = uxi - uy;
		if (i == 0) return 0 * x;
		var neg = i >> 63;
		uxi = (i & ~neg) | (uxi & neg);
		while ((uxi >>> 52) == 0) {
			uxi = uxi << 1;
			ex--;
		}
		// scale result
		if (ex > 0) {
			uxi = uxi - ((1 : I64) << 52);
			uxi = uxi | ((ex : I64) << 52);
		} else
			uxi = uxi >>> (-ex + 1);
		uxi = uxi | (sx << 63);
		return ofBits(uxi);
	}
}

// x reduced by multiples of pi/2: n and y0 + y1 (struct values: @:hxmc.struct
// too, for the stage0 tool, to which a scoped class is an object; fields final,
// an object on WasmGC)
@:hxmc.struct @:hxmc.scoped @:noCompletion class Reduced {
	public final n:Int;
	public final y0:Float;
	public final y1:Float;

	public inline function new(n:Int, y0:Float, y1:Float) {
		this.n = n;
		this.y0 = y0;
		this.y1 = y1;
	}
}

// a value as hi + lo
@:hxmc.struct @:hxmc.scoped @:noCompletion class Split {
	public final hi:Float;
	public final lo:Float;

	public inline function new(hi:Float, lo:Float) {
		this.hi = hi;
		this.lo = lo;
	}
}
