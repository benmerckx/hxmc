package hxmc.simd;

// The vector operations lane by lane (docs/plans/simd.md): what the Mir
// interpreter, Eval, JavaScript and the other targets run, with the results
// of hxmc's vector instructions (WebAssembly's semantics: wrapping integer
// lanes, saturating where named, float32 lanes rounded to nearest even
// after each operation, min and max propagating NaN with -0 below +0,
// conversions saturating, NaN to 0). Operations by their WebAssembly
// opcode (Ops passes them; hxmc.SimdOps' table). A NaN result's sign and
// payload are not specified.
@:hxmc.kernel @:noCompletion class Ref {
	// ---- words and lanes

	static inline function w(v:V128, k:Int):Int
		return k == 0 ? v.w0 : k == 1 ? v.w1 : k == 2 ? v.w2 : v.w3;

	// (v with word k x: a new value, as struct parameters are copies)
	static inline function setW(v:V128, k:Int, x:Int):V128
		return k == 0 ? new V128(x, v.w1, v.w2, v.w3) : k == 1 ? new V128(v.w0, x, v.w2, v.w3) : k == 2 ? new V128(v.w0, v.w1, x, v.w3) : new V128(v.w0, v.w1, v.w2, x);

	static inline function u8(v:V128, k:Int):Int
		return (w(v, k >> 2) >>> ((k & 3) << 3)) & 0xff;

	static inline function s8(v:V128, k:Int):Int
		return (u8(v, k) << 24) >> 24;

	static inline function u16(v:V128, k:Int):Int
		return (w(v, k >> 1) >>> ((k & 1) << 4)) & 0xffff;

	static inline function s16(v:V128, k:Int):Int
		return (u16(v, k) << 16) >> 16;

	static inline function put8(v:V128, k:Int, x:Int):V128 {
		var s = (k & 3) << 3;
		return setW(v, k >> 2, (w(v, k >> 2) & ~(0xff << s)) | ((x & 0xff) << s));
	}

	static inline function put16(v:V128, k:Int, x:Int):V128 {
		var s = (k & 1) << 4;
		return setW(v, k >> 1, (w(v, k >> 1) & ~(0xffff << s)) | ((x & 0xffff) << s));
	}

	static inline function zero():V128
		return new V128(0, 0, 0, 0);

	static inline function sat(x:Int, lo:Int, hi:Int):Int
		return x < lo ? lo : x > hi ? hi : x;

	// unsigned 32-bit comparison
	static inline function ult(a:Int, b:Int):Bool
		return (a ^ 0x80000000) < (b ^ 0x80000000);

	// ---- float lanes: their bits

	static inline function f32(v:V128, k:Int):Float
		return Bits.f32(w(v, k));

	// a Float rounded to float32, as bits
	static inline function f32bits(x:Float):Int
		return Bits.ofF32(x);

	static inline function f64(v:V128, k:Int):Float
		return Bits.f64(w(v, 2 * k), w(v, 2 * k + 1));

	static inline function putF64(v:V128, k:Int, x:Float):V128
		return put64(v, k, Bits.lo(x), Bits.hi(x));

	// ---- 64-bit lanes: two words (lo, hi)

	static inline function lo64(v:V128, k:Int):Int
		return w(v, 2 * k);

	static inline function hi64(v:V128, k:Int):Int
		return w(v, 2 * k + 1);

	static inline function put64(v:V128, k:Int, lo:Int, hi:Int):V128
		return k == 0 ? new V128(lo, hi, v.w2, v.w3) : new V128(v.w0, v.w1, lo, hi);

	// ---- float semantics

	static inline function isNaN(x:Float):Bool
		return x != x;

	// wasm's fmin/fmax: NaN if either is NaN, -0 below +0
	static function fmin(a:Float, b:Float):Float {
		if (isNaN(a) || isNaN(b)) return Math.NaN;
		if (a == 0 && b == 0) return Bits.negZero(a) || Bits.negZero(b) ? -0.0 : 0.0;
		return a < b ? a : b;
	}

	static function fmax(a:Float, b:Float):Float {
		if (isNaN(a) || isNaN(b)) return Math.NaN;
		if (a == 0 && b == 0) return Bits.negZero(a) && Bits.negZero(b) ? -0.0 : 0.0;
		return a > b ? a : b;
	}

	// round half to even (an integer-valued Float stays; NaN and the infinities too)
	static function nearest(x:Float):Float {
		if (isNaN(x) || x == Math.POSITIVE_INFINITY || x == Math.NEGATIVE_INFINITY) return x;
		var f = Math.ffloor(x);
		var d = x - f;
		var r = if (d > 0.5) f + 1 else if (d < 0.5) f else (f * 0.5 == Math.ffloor(f * 0.5) ? f : f + 1);
		// (the sign of a zero result is x's)
		return r == 0 ? (x < 0 || Bits.negZero(x) ? -0.0 : 0.0) : r;
	}

	static function ftrunc(x:Float):Float {
		if (isNaN(x) || x == Math.POSITIVE_INFINITY || x == Math.NEGATIVE_INFINITY) return x;
		var r = x < 0 ? Math.fceil(x) : Math.ffloor(x);
		return r == 0 ? (x < 0 || Bits.negZero(x) ? -0.0 : 0.0) : r;
	}

	static function fceil(x:Float):Float {
		if (isNaN(x) || x == Math.POSITIVE_INFINITY || x == Math.NEGATIVE_INFINITY) return x;
		var r = Math.fceil(x);
		return r == 0 ? (x < 0 || Bits.negZero(x) ? -0.0 : 0.0) : r;
	}

	static function ffloor(x:Float):Float {
		if (isNaN(x) || x == Math.POSITIVE_INFINITY || x == Math.NEGATIVE_INFINITY) return x;
		var r = Math.ffloor(x);
		return r == 0 ? (Bits.negZero(x) ? -0.0 : 0.0) : r;
	}

	// a Float truncated to a 32-bit integer, saturating, NaN to 0
	static function truncSat(x:Float):Int {
		if (isNaN(x)) return 0;
		if (x >= 2147483647.0) return 0x7fffffff;
		if (x <= -2147483648.0) return 0x80000000;
		return Std.int(x);
	}

	// an unsigned 32-bit integer as a Float
	static inline function uf(x:Int):Float
		return x < 0 ? x + 4294967296.0 : x;

	// ---- operations

	public static function const(w0:Int, w1:Int, w2:Int, w3:Int):V128
		return new V128(w0, w1, w2, w3);

	public static function op1(op:Int, a:V128):V128 {
		var r = zero();
		switch op {
			case 0x4d: return new V128(~a.w0, ~a.w1, ~a.w2, ~a.w3);
			// demote, promote, convert
			case 0x5e: // f32x4.demote_f64x2_zero
				r.w0 = f32bits(f64(a, 0));
				r.w1 = f32bits(f64(a, 1));
			case 0x5f: // f64x2.promote_low_f32x4
				r = putF64(r, 0, f32(a, 0));
				r = putF64(r, 1, f32(a, 1));
			case 0x60 | 0x61: // i8x16.abs, neg
				for (k in 0...16) {
					var x = s8(a, k);
					r = put8(r, k, op == 0x60 ? (x < 0 ? -x : x) : -x);
				}
			case 0x80 | 0x81: // i16x8.abs, neg
				for (k in 0...8) {
					var x = s16(a, k);
					r = put16(r, k, op == 0x80 ? (x < 0 ? -x : x) : -x);
				}
			case 0xa0 | 0xa1: // i32x4.abs, neg
				for (k in 0...4) {
					var x = w(a, k);
					r = setW(r, k, Bits.wrap(op == 0xa0 ? (x < 0 ? -x : x) : -x));
				}
			case 0xc1: // i64x2.neg
				for (k in 0...2) {
					var lo = lo64(a, k), hi = hi64(a, k);
					var nlo = Bits.wrap(-lo);
					r = put64(r, k, Bits.wrap(nlo), Bits.wrap(~hi + (lo == 0 ? 1 : 0)));
				}
			case 0x67 | 0x68 | 0x69 | 0x6a | 0xe0 | 0xe1 | 0xe3: // f32x4 rounding, abs, neg, sqrt
				for (k in 0...4) {
					var x = f32(a, k);
					r = setW(r, k, switch op {
						case 0xe0: w(a, k) & 0x7fffffff;
						case 0xe1: w(a, k) ^ 0x80000000;
						case _: f32bits(switch op {
								case 0x67: fceil(x);
								case 0x68: ffloor(x);
								case 0x69: ftrunc(x);
								case 0x6a: nearest(x);
								case _: Math.sqrt(x);
							});
					});
				}
			case 0x74 | 0x75 | 0x7a | 0x94 | 0xec | 0xed | 0xef: // f64x2 rounding, abs, neg, sqrt
				for (k in 0...2) {
					var x = f64(a, k);
					switch op {
						case 0xec: r = put64(r, k, lo64(a, k), hi64(a, k) & 0x7fffffff);
						case 0xed: r = put64(r, k, lo64(a, k), hi64(a, k) ^ 0x80000000);
						case _: r = putF64(r, k, switch op {
								case 0x74: fceil(x);
								case 0x75: ffloor(x);
								case 0x7a: ftrunc(x);
								case 0x94: nearest(x);
								case _: Math.sqrt(x);
							});
					}
				}
			case 0x87 | 0x88 | 0x89 | 0x8a: // i16x8.extend_{low,high}_i8x16_{s,u}
				var base = op == 0x88 || op == 0x8a ? 8 : 0;
				for (k in 0...8)
					r = put16(r, k, op <= 0x88 ? s8(a, base + k) : u8(a, base + k));
			case 0xa7 | 0xa8 | 0xa9 | 0xaa: // i32x4.extend_{low,high}_i16x8_{s,u}
				var base = op == 0xa8 || op == 0xaa ? 4 : 0;
				for (k in 0...4)
					r = setW(r, k, op <= 0xa8 ? s16(a, base + k) : u16(a, base + k));
			case 0xc7 | 0xc8 | 0xc9 | 0xca: // i64x2.extend_{low,high}_i32x4_{s,u}
				var base = op == 0xc8 || op == 0xca ? 2 : 0;
				for (k in 0...2) {
					var x = w(a, base + k);
					r = put64(r, k, x, op <= 0xc8 ? x >> 31 : 0);
				}
			case 0xf8: // i32x4.trunc_sat_f32x4_s
				for (k in 0...4)
					r = setW(r, k, truncSat(f32(a, k)));
			case 0xfa | 0xfb: // f32x4.convert_i32x4_{s,u}
				for (k in 0...4)
					r = setW(r, k, f32bits(op == 0xfa ? w(a, k) : uf(w(a, k))));
			case 0xfc: // i32x4.trunc_sat_f64x2_s_zero
				r.w0 = truncSat(f64(a, 0));
				r.w1 = truncSat(f64(a, 1));
			case 0xfe: // f64x2.convert_low_i32x4_s
				r = putF64(r, 0, a.w0);
				r = putF64(r, 1, a.w1);
			case _:
		}
		return r;
	}

	public static function op2(op:Int, a:V128, b:V128):V128 {
		var r = zero();
		switch op {
			case 0x4e: return new V128(a.w0 & b.w0, a.w1 & b.w1, a.w2 & b.w2, a.w3 & b.w3);
			case 0x4f: return new V128(a.w0 & ~b.w0, a.w1 & ~b.w1, a.w2 & ~b.w2, a.w3 & ~b.w3);
			case 0x50: return new V128(a.w0 | b.w0, a.w1 | b.w1, a.w2 | b.w2, a.w3 | b.w3);
			case 0x51: return new V128(a.w0 ^ b.w0, a.w1 ^ b.w1, a.w2 ^ b.w2, a.w3 ^ b.w3);
			case 0x0e: // i8x16.swizzle
				for (k in 0...16) {
					var i = u8(b, k);
					r = put8(r, k, i < 16 ? u8(a, i) : 0);
				}
			case 0x65 | 0x66: // i8x16.narrow_i16x8_{s,u}
				for (k in 0...16) {
					var x = k < 8 ? s16(a, k) : s16(b, k - 8);
					r = put8(r, k, op == 0x65 ? sat(x, -128, 127) : sat(x, 0, 255));
				}
			case 0x85 | 0x86: // i16x8.narrow_i32x4_{s,u}
				for (k in 0...8) {
					var x = k < 4 ? w(a, k) : w(b, k - 4);
					r = put16(r, k, op == 0x85 ? sat(x, -32768, 32767) : sat(x, 0, 65535));
				}
			case 0xba: // i32x4.dot_i16x8_s
				for (k in 0...4)
					r = setW(r, k, Bits.wrap(s16(a, 2 * k) * s16(b, 2 * k) + s16(a, 2 * k + 1) * s16(b, 2 * k + 1)));
			case 0x82: // i16x8.q15mulr_sat_s
				for (k in 0...8)
					r = put16(r, k, sat((s16(a, k) * s16(b, k) + 0x4000) >> 15, -32768, 32767));
			case _ if (op >= 0x23 && op <= 0x2c || op >= 0x6e && op <= 0x7b): // i8x16
				for (k in 0...16) {
					var x = s8(a, k), y = s8(b, k), ux = u8(a, k), uy = u8(b, k);
					r = put8(r, k, switch op {
						case 0x23: x == y ? -1 : 0;
						case 0x24: x != y ? -1 : 0;
						case 0x25: x < y ? -1 : 0;
						case 0x26: ux < uy ? -1 : 0;
						case 0x27: x > y ? -1 : 0;
						case 0x28: ux > uy ? -1 : 0;
						case 0x29: x <= y ? -1 : 0;
						case 0x2a: ux <= uy ? -1 : 0;
						case 0x2b: x >= y ? -1 : 0;
						case 0x2c: ux >= uy ? -1 : 0;
						case 0x6e: x + y;
						case 0x6f: sat(x + y, -128, 127);
						case 0x70: sat(ux + uy, 0, 255);
						case 0x71: x - y;
						case 0x72: sat(x - y, -128, 127);
						case 0x73: sat(ux - uy, 0, 255);
						case 0x76: x < y ? x : y;
						case 0x77: ux < uy ? ux : uy;
						case 0x78: x > y ? x : y;
						case 0x79: ux > uy ? ux : uy;
						case 0x7b: (ux + uy + 1) >> 1;
						case _: 0;
					});
				}
			case _ if (op >= 0x2d && op <= 0x36 || op >= 0x8e && op <= 0x9b): // i16x8
				for (k in 0...8) {
					var x = s16(a, k), y = s16(b, k), ux = u16(a, k), uy = u16(b, k);
					r = put16(r, k, switch op {
						case 0x2d: x == y ? -1 : 0;
						case 0x2e: x != y ? -1 : 0;
						case 0x2f: x < y ? -1 : 0;
						case 0x30: ux < uy ? -1 : 0;
						case 0x31: x > y ? -1 : 0;
						case 0x32: ux > uy ? -1 : 0;
						case 0x33: x <= y ? -1 : 0;
						case 0x34: ux <= uy ? -1 : 0;
						case 0x35: x >= y ? -1 : 0;
						case 0x36: ux >= uy ? -1 : 0;
						case 0x8e: x + y;
						case 0x8f: sat(x + y, -32768, 32767);
						case 0x90: sat(ux + uy, 0, 65535);
						case 0x91: x - y;
						case 0x92: sat(x - y, -32768, 32767);
						case 0x93: sat(ux - uy, 0, 65535);
						case 0x95: x * y;
						case 0x96: x < y ? x : y;
						case 0x97: ux < uy ? ux : uy;
						case 0x98: x > y ? x : y;
						case 0x99: ux > uy ? ux : uy;
						case 0x9b: (ux + uy + 1) >> 1;
						case _: 0;
					});
				}
			case _ if (op >= 0x37 && op <= 0x40 || op >= 0xae && op <= 0xb9): // i32x4
				for (k in 0...4) {
					var x = w(a, k), y = w(b, k);
					r = setW(r, k, switch op {
						case 0x37: x == y ? -1 : 0;
						case 0x38: x != y ? -1 : 0;
						case 0x39: x < y ? -1 : 0;
						case 0x3a: ult(x, y) ? -1 : 0;
						case 0x3b: x > y ? -1 : 0;
						case 0x3c: ult(y, x) ? -1 : 0;
						case 0x3d: x <= y ? -1 : 0;
						case 0x3e: !ult(y, x) ? -1 : 0;
						case 0x3f: x >= y ? -1 : 0;
						case 0x40: !ult(x, y) ? -1 : 0;
						case 0xae: Bits.wrap(x + y);
						case 0xb1: Bits.wrap(x - y);
						case 0xb5: Bits.mul(x, y);
						case 0xb6: x < y ? x : y;
						case 0xb7: ult(x, y) ? x : y;
						case 0xb8: x > y ? x : y;
						case 0xb9: ult(y, x) ? x : y;
						case _: 0;
					});
				}
			case 0xce | 0xd1: // i64x2.add, sub
				for (k in 0...2) {
					var alo = lo64(a, k), ahi = hi64(a, k), blo = lo64(b, k), bhi = hi64(b, k);
					if (op == 0xce) {
						var lo = Bits.wrap(alo + blo);
						r = put64(r, k, lo, Bits.wrap(ahi + bhi + (ult(lo, alo) ? 1 : 0)));
					} else {
						var lo = Bits.wrap(alo - blo);
						r = put64(r, k, lo, Bits.wrap(ahi - bhi - (ult(alo, blo) ? 1 : 0)));
					}
				}
			case 0xd6 | 0xd7: // i64x2.eq, ne
				for (k in 0...2) {
					var e = lo64(a, k) == lo64(b, k) && hi64(a, k) == hi64(b, k);
					var m = (op == 0xd6) == e ? -1 : 0;
					r = put64(r, k, m, m);
				}
			case _ if (op >= 0x41 && op <= 0x46 || op >= 0xe4 && op <= 0xeb): // f32x4
				for (k in 0...4) {
					var x = f32(a, k), y = f32(b, k);
					r = setW(r, k, switch op {
						case 0x41: x == y ? -1 : 0;
						case 0x42: x != y ? -1 : 0;
						case 0x43: x < y ? -1 : 0;
						case 0x44: x > y ? -1 : 0;
						case 0x45: x <= y ? -1 : 0;
						case 0x46: x >= y ? -1 : 0;
						case 0xe4: f32bits(x + y);
						case 0xe5: f32bits(x - y);
						case 0xe6: f32bits(x * y);
						case 0xe7: f32bits(x / y);
						case 0xe8: f32bits(fmin(x, y));
						case 0xe9: f32bits(fmax(x, y));
						// (pmin: b < a ? b : a, the lane itself)
						case 0xea: y < x ? w(b, k) : w(a, k);
						case 0xeb: x < y ? w(b, k) : w(a, k);
						case _: 0;
					});
				}
			case _ if (op >= 0x47 && op <= 0x4c || op >= 0xf0 && op <= 0xf7): // f64x2
				for (k in 0...2) {
					var x = f64(a, k), y = f64(b, k);
					inline function mask(c:Bool)
						r = put64(r, k, c ? -1 : 0, c ? -1 : 0);
					switch op {
						case 0x47: mask(x == y);
						case 0x48: mask(x != y);
						case 0x49: mask(x < y);
						case 0x4a: mask(x > y);
						case 0x4b: mask(x <= y);
						case 0x4c: mask(x >= y);
						case 0xf0: r = putF64(r, k, x + y);
						case 0xf1: r = putF64(r, k, x - y);
						case 0xf2: r = putF64(r, k, x * y);
						case 0xf3: r = putF64(r, k, x / y);
						case 0xf4: r = putF64(r, k, fmin(x, y));
						case 0xf5: r = putF64(r, k, fmax(x, y));
						case 0xf6: if (y < x) r = put64(r, k, lo64(b, k), hi64(b, k)) else r = put64(r, k, lo64(a, k), hi64(a, k));
						case 0xf7: if (x < y) r = put64(r, k, lo64(b, k), hi64(b, k)) else r = put64(r, k, lo64(a, k), hi64(a, k));
						case _:
					}
				}
			case _:
		}
		return r;
	}

	public static function op3(op:Int, a:V128, b:V128, c:V128):V128 {
		// v128.bitselect: a where c's bits are set, else b
		return new V128((a.w0 & c.w0) | (b.w0 & ~c.w0), (a.w1 & c.w1) | (b.w1 & ~c.w1), (a.w2 & c.w2) | (b.w2 & ~c.w2), (a.w3 & c.w3) | (b.w3 & ~c.w3));
	}

	public static function shift(op:Int, a:V128, n:Int):V128 {
		var r = zero();
		switch op {
			case 0x6b | 0x6c | 0x6d:
				var s = n & 7;
				for (k in 0...16)
					r = put8(r, k, op == 0x6b ? u8(a, k) << s : op == 0x6c ? s8(a, k) >> s : u8(a, k) >>> s);
			case 0x8b | 0x8c | 0x8d:
				var s = n & 15;
				for (k in 0...8)
					r = put16(r, k, op == 0x8b ? u16(a, k) << s : op == 0x8c ? s16(a, k) >> s : u16(a, k) >>> s);
			case 0xab | 0xac | 0xad:
				var s = n & 31;
				for (k in 0...4)
					r = setW(r, k, op == 0xab ? w(a, k) << s : op == 0xac ? w(a, k) >> s : Bits.wrap(w(a, k) >>> s));
			case 0xcb | 0xcc | 0xcd:
				var s = n & 63;
				for (k in 0...2) {
					var lo = lo64(a, k), hi = hi64(a, k);
					if (s == 0) r = put64(r, k, lo, hi) else if (op == 0xcb) {
						if (s < 32) r = put64(r, k, lo << s, (hi << s) | (lo >>> (32 - s))) else r = put64(r, k, 0, lo << (s - 32));
					} else {
						var fill = op == 0xcc ? hi >> 31 : 0;
						if (s < 32) r = put64(r, k, (lo >>> s) | (hi << (32 - s)), op == 0xcc ? hi >> s : Bits.wrap(hi >>> s))
						else r = put64(r, k, op == 0xcc ? hi >> (s - 32) : Bits.wrap(hi >>> (s - 32)), fill);
					}
				}
			case _:
		}
		return r;
	}

	public static function splatInt(op:Int, x:Int):V128 {
		return switch op {
			case 0x0f:
				var b = x & 0xff;
				var v = b | (b << 8) | (b << 16) | (b << 24);
				new V128(v, v, v, v);
			case 0x10:
				var v = (x & 0xffff) | (x << 16);
				new V128(v, v, v, v);
			case _: new V128(x, x, x, x);
		}
	}

	public static function splatI64(op:Int, x:haxe.Int64):V128
		return new V128(x.low, x.high, x.low, x.high);

	public static function splatFloat(op:Int, x:Float):V128 {
		if (op == 0x13) {
			var v = f32bits(x);
			return new V128(v, v, v, v);
		}
		var lo = Bits.lo(x), hi = Bits.hi(x);
		return new V128(lo, hi, lo, hi);
	}

	public static function extractInt(op:Int, a:V128, lane:Int):Int
		return switch op {
			case 0x15: s8(a, lane);
			case 0x16: u8(a, lane);
			case 0x18: s16(a, lane);
			case 0x19: u16(a, lane);
			case _: w(a, lane);
		}

	public static function extractI64(op:Int, a:V128, lane:Int):haxe.Int64
		return haxe.Int64.make(hi64(a, lane), lo64(a, lane));

	public static function extractFloat(op:Int, a:V128, lane:Int):Float
		return op == 0x1f ? f32(a, lane) : f64(a, lane);

	public static function replaceInt(op:Int, a:V128, lane:Int, x:Int):V128 {
		var r = new V128(a.w0, a.w1, a.w2, a.w3);
		switch op {
			case 0x17: r = put8(r, lane, x);
			case 0x1a: r = put16(r, lane, x);
			case _: r = setW(r, lane, x);
		}
		return r;
	}

	public static function replaceI64(op:Int, a:V128, lane:Int, x:haxe.Int64):V128 {
		var r = new V128(a.w0, a.w1, a.w2, a.w3);
		r = put64(r, lane, x.low, x.high);
		return r;
	}

	public static function replaceFloat(op:Int, a:V128, lane:Int, x:Float):V128 {
		var r = new V128(a.w0, a.w1, a.w2, a.w3);
		if (op == 0x20) r = setW(r, lane, f32bits(x)) else r = putF64(r, lane, x);
		return r;
	}

	public static function test(op:Int, a:V128):Int {
		switch op {
			case 0x53: return a.w0 | a.w1 | a.w2 | a.w3 != 0 ? 1 : 0;
			case 0x63:
				for (k in 0...16)
					if (u8(a, k) == 0) return 0;
				return 1;
			case 0x83:
				for (k in 0...8)
					if (u16(a, k) == 0) return 0;
				return 1;
			case 0xa3:
				for (k in 0...4)
					if (w(a, k) == 0) return 0;
				return 1;
			case 0xc3:
				for (k in 0...2)
					if (lo64(a, k) == 0 && hi64(a, k) == 0) return 0;
				return 1;
			case 0x64:
				var m = 0;
				for (k in 0...16)
					if (s8(a, k) < 0) m |= 1 << k;
				return m;
			case 0x84:
				var m = 0;
				for (k in 0...8)
					if (s16(a, k) < 0) m |= 1 << k;
				return m;
			case 0xa4:
				var m = 0;
				for (k in 0...4)
					if (w(a, k) < 0) m |= 1 << k;
				return m;
			case 0xc4:
				return (hi64(a, 0) < 0 ? 1 : 0) | (hi64(a, 1) < 0 ? 2 : 0);
			case _:
		}
		return 0;
	}

	public static function shuffle(a:V128, b:V128, l0:Int, l1:Int, l2:Int, l3:Int, l4:Int, l5:Int, l6:Int, l7:Int, l8:Int, l9:Int, l10:Int, l11:Int,
			l12:Int, l13:Int, l14:Int, l15:Int):V128 {
		var r = zero();
		inline function lane(k:Int, l:Int)
			r = put8(r, k, l < 16 ? u8(a, l) : u8(b, l - 16));
		lane(0, l0);
		lane(1, l1);
		lane(2, l2);
		lane(3, l3);
		lane(4, l4);
		lane(5, l5);
		lane(6, l6);
		lane(7, l7);
		lane(8, l8);
		lane(9, l9);
		lane(10, l10);
		lane(11, l11);
		lane(12, l12);
		lane(13, l13);
		lane(14, l14);
		lane(15, l15);
		return r;
	}
}
