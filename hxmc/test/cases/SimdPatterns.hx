import haxe.io.Bytes;
import hxmc.simd.*;

// The forms hxmc.simd's code generation picks for particular operands
// (docs/plans/simd.md, "Code generation"), each against the general one by
// its result: shuffles that are unpacks of every width in both orders (with
// a constant operand on either side), permutations of one vector, shuffles
// with zeros, even and odd lanes; a splat of a constant of each width as
// either operand of commutative and other operations; an operation of a
// vector with itself; a choice between vectors on an inlined constant; more
// vectors live than registers (spilled, reused). Printed as 32-bit words.
class SimdPatterns {
	static function println(s:String) {
		#if js
		js.Syntax.code("console.log({0})", s);
		#else
		Sys.println(s);
		#end
	}

	static function hex(x:Int):String
		return StringTools.hex(x, 8).toLowerCase();

	static function words(v:hxmc.simd.V128):String
		return hex(v.w0) + " " + hex(v.w1) + " " + hex(v.w2) + " " + hex(v.w3);

	static function show(name:String, v:hxmc.simd.V128)
		println(name + ": " + words(v));

	// (an inlined constant decides which shuffle: the other's code goes)
	static inline function pick(a:I32x4, b:I32x4, r:Int):I32x4 {
		var t = r < 2 ? a.shuffle(b, 0, 4, 1, 5) : a.shuffle(b, 2, 6, 3, 7);
		return (r & 1) == 0 ? t : t.shuffle(t, 1, 0, 3, 2);
	}

	static function main() {
		var b = Bytes.alloc(64);
		var seed = 0x13579BDF;
		for (i in 0...64) {
			seed ^= seed << 13;
			seed ^= seed >>> 17;
			seed ^= seed << 5;
			b.set(i, seed & 0xff);
		}
		var x = U8x16.load(b, 0), y = U8x16.load(b, 16), z = U8x16.load(b, 32);
		show("x", x);
		show("y", y);
		// bytes: unpacks, both orders, a constant either side, a vector with itself
		show("u8 lo", x.shuffle(y, 0, 16, 1, 17, 2, 18, 3, 19, 4, 20, 5, 21, 6, 22, 7, 23));
		show("u8 hi", x.shuffle(y, 8, 24, 9, 25, 10, 26, 11, 27, 12, 28, 13, 29, 14, 30, 15, 31));
		show("u8 lo yx", x.shuffle(y, 16, 0, 17, 1, 18, 2, 19, 3, 20, 4, 21, 5, 22, 6, 23, 7));
		show("u8 hi yx", x.shuffle(y, 24, 8, 25, 9, 26, 10, 27, 11, 28, 12, 29, 13, 30, 14, 31, 15));
		show("u8 lo k", x.shuffle(U8x16.splat(255), 0, 16, 1, 17, 2, 18, 3, 19, 4, 20, 5, 21, 6, 22, 7, 23));
		show("u8 lo k7", x.shuffle(U8x16.splat(7), 0, 16, 1, 17, 2, 18, 3, 19, 4, 20, 5, 21, 6, 22, 7, 23));
		show("u8 k7 lo", U8x16.splat(7).shuffle(x, 0, 16, 1, 17, 2, 18, 3, 19, 4, 20, 5, 21, 6, 22, 7, 23));
		show("u8 hi xx", x.shuffle(x, 8, 24, 9, 25, 10, 26, 11, 27, 12, 28, 13, 29, 14, 30, 15, 31));
		show("u8 even", x.shuffle(y, 0, 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22, 24, 26, 28, 30));
		show("u8 odd", x.shuffle(y, 1, 3, 5, 7, 9, 11, 13, 15, 17, 19, 21, 23, 25, 27, 29, 31));
		// with zeros: either side
		show("u8 x0", x.shuffle(U8x16.zero(), 0, 4, 1, 5, 2, 6, 3, 7, 16, 16, 16, 16, 16, 16, 16, 16));
		show("u8 0x", U8x16.zero().shuffle(x, 0, 31, 1, 30, 2, 29, 3, 28, 4, 27, 5, 26, 6, 25, 7, 24));
		show("u8 x0 lo", x.shuffle(U8x16.zero(), 0, 16, 1, 17, 2, 18, 3, 19, 4, 20, 5, 21, 6, 22, 7, 23));
		// 16-bit lanes
		var p = x.asI16x8(), q = y.asI16x8();
		show("i16 lo", p.shuffle(q, 0, 8, 1, 9, 2, 10, 3, 11));
		show("i16 hi", p.shuffle(q, 4, 12, 5, 13, 6, 14, 7, 15));
		show("i16 lo yx", p.shuffle(q, 8, 0, 9, 1, 10, 2, 11, 3));
		show("i16 hi yx", p.shuffle(q, 12, 4, 13, 5, 14, 6, 15, 7));
		show("i16 even", p.shuffle(q, 0, 2, 4, 6, 8, 10, 12, 14));
		show("i16 odd", p.shuffle(q, 1, 3, 5, 7, 9, 11, 13, 15));
		show("i16 k lo", I16x8.splat(-2).shuffle(p, 0, 8, 1, 9, 2, 10, 3, 11));
		// 32-bit lanes: unpacks, permutations of one vector, even and odd
		var r = x.asI32x4(), s = y.asI32x4();
		show("i32 lo", r.shuffle(s, 0, 4, 1, 5));
		show("i32 hi", r.shuffle(s, 2, 6, 3, 7));
		show("i32 lo yx", r.shuffle(s, 4, 0, 5, 1));
		show("i32 hi yx", r.shuffle(s, 6, 2, 7, 3));
		show("i32 rev", r.shuffle(s, 3, 2, 1, 0));
		show("i32 rev b", r.shuffle(s, 7, 6, 5, 4));
		show("i32 dup", r.shuffle(s, 1, 1, 1, 1));
		show("i32 even", r.shuffle(s, 0, 2, 4, 6));
		show("i32 odd", r.shuffle(s, 1, 3, 5, 7));
		show("i32 mixed", r.shuffle(s, 0, 5, 2, 7));
		// 64-bit lanes
		var u = x.asI64x2(), v = y.asI64x2();
		show("i64 lo", u.shuffle(v, 0, 2));
		show("i64 hi", u.shuffle(v, 1, 3));
		show("i64 lo yx", u.shuffle(v, 2, 0));
		show("i64 hi yx", u.shuffle(v, 3, 1));
		show("i64 swap", u.shuffle(v, 1, 0));
		// splats of constants as operands, either side
		show("k + r", I32x4.splat(0x12345) + r);
		show("r * k", r * I32x4.splat(-7373));
		show("k * r", I32x4.splat(91881) * r);
		show("k - r", I32x4.splat(1000) - r);
		show("r - k", r - I32x4.splat(1000));
		show("i8 k - x", I8x16.splat(-100) - x.asI8x16());
		show("i8 x +sat k", x.asI8x16().addSat(I8x16.splat(-128)));
		show("u16 k max", U16x8.splat(0x8001).max(x.asU16x8()));
		show("i16 k mul", I16x8.splat(-3) * x.asI16x8());
		show("i64 k + u", I64x2.splat(haxe.Int64.make(0x7fffffff, -1)) + u);
		show("k & r", I32x4.splat(0x0f0f0f0f) & r);
		show("r andNot k", r.andNot(I32x4.splat(0xff00ff)));
		show("k andNot r", I32x4.splat(0xff00ff).andNot(r));
		show("k gt r", I32x4.splat(0).gt(r));
		show("r eq k", r.eq(I32x4.splat(r.get(2))));
		show("narrow k", I16x8.narrow(I32x4.splat(70000), r));
		// a vector with itself
		show("r + r", r + r);
		show("narrow r r", I16x8.narrow(r, r));
		show("u8 narrow p p", U8x16.narrow(p, p));
		// an inlined constant's choice
		show("pick 0", pick(r, s, 0));
		show("pick 1", pick(r, s, 1));
		show("pick 2", pick(r, s, 2));
		show("pick 3", pick(r, s, 3));
		// twenty-four live, constants among them (spilled, reloaded)
		var w = z.asI32x4();
		var a0 = r * I32x4.splat(3), a1 = s * I32x4.splat(5), a2 = w * I32x4.splat(7), a3 = r + s, a4 = s + w, a5 = w + r;
		var a6 = a0 - a1, a7 = a1 - a2, a8 = a2 - a0, a9 = a3 * a4, a10 = a4 * a5, a11 = a5 * a3;
		var a12 = a6 ^ a9, a13 = a7 ^ a10, a14 = a8 ^ a11, a15 = a12 + I32x4.splat(11), a16 = a13 + I32x4.splat(13), a17 = a14 + I32x4.splat(17);
		var a18 = a15 * a0, a19 = a16 * a1, a20 = a17 * a2, a21 = a18 + a3, a22 = a19 + a4, a23 = a20 + a5;
		var sum = a0 + a1 + a2 + a3 + a4 + a5 + a6 + a7 + a8 + a9 + a10 + a11;
		sum = sum ^ (a12 + a13 + a14 + a15 + a16 + a17 + a18 + a19 + a20 + a21 + a22 + a23);
		show("live", sum);
		show("live a23", a23);
		// in a loop: constants hoisted or folded, a shuffle with a constant each round
		var acc = I32x4.zero();
		var k = 0;
		while (k + 16 <= b.length) {
			var e = U8x16.load(b, k);
			var lo = e.shuffle(U8x16.zero(), 0, 16, 1, 17, 2, 18, 3, 19, 4, 20, 5, 21, 6, 22, 7, 23).asI16x8();
			acc = acc + lo.dot(I16x8.splat(3)) * I32x4.splat(k + 1) + I32x4.splat(0x101);
			k += 16;
		}
		show("loop", acc);
	}
}
