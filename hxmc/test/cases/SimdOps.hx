import haxe.io.Bytes;
import hxmc.simd.*;

// Every vector operation of hxmc.simd (docs/plans/simd.md) on edge values,
// each result printed as its four 32-bit words: the same on every back end
// (x86-64's SSE, arm64's NEON, WebAssembly's simd128) and in the scalar
// implementation (the Mir interpreter, Eval, JavaScript). A float lane
// that is NaN prints as 7fc00000 (7ff80000 00000000): NaN results have no
// specified sign or payload.
class SimdOps {
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

	// float32 lanes, NaN made one
	static function showF(name:String, v:F32x4) {
		var u = v.asU32x4();
		var nan = v.ne(v);
		show(name, U32x4.select(nan, U32x4.splat(0x7fc00000), u));
	}

	static function showD(name:String, v:F64x2) {
		var nan = v.ne(v);
		show(name, I64x2.select(nan, I64x2.splat(haxe.Int64.make(0x7ff80000, 0)), v.asI64x2()));
	}

	static function int(name:String, x:Int)
		println(name + ": " + x);

	// a Float's bits (NaN made one)
	static function float(name:String, x:Float)
		showD(name, F64x2.splat(x));

	// (not inlined: the vectors pass through memory, as struct values do)
	static function id<T>(x:T):T
		return x;

	static function main() {
		var b = Bytes.alloc(64);
		var seed = 0x2545F491;
		for (i in 0...64) {
			seed ^= seed << 13;
			seed ^= seed >>> 17;
			seed ^= seed << 5;
			b.set(i, seed & 0xff);
		}
		var r0 = U8x16.load(b, 0), r1 = U8x16.load(b, 16), r2 = U8x16.load(b, 32);
		show("load", r0);
		show("load+1", U8x16.load(b, 1));
		// integer edge values
		var e8 = I8x16.zero().with(0, 0).with(1, 1).with(2, -1).with(3, 127).with(4, -128).with(5, 100).with(6, -100).with(7, 64).with(8, -64)
			.with(9, 2).with(10, -2).with(11, 126).with(12, -127).with(13, 50).with(14, -50).with(15, 3);
		var f8 = I8x16.splat(-128).with(1, 127).with(2, 1).with(3, -1).with(4, 100).with(5, 100).with(6, -100).with(7, -64).with(8, 64)
			.with(9, -2).with(10, 2).with(11, 126).with(12, 127).with(13, -51).with(14, 51).with(15, 3);
		show("e8", e8);
		show("f8", f8);
		var e16 = I16x8.zero().with(0, 0).with(1, 1).with(2, -1).with(3, 32767).with(4, -32768).with(5, 30000).with(6, -30000).with(7, 255);
		var f16 = I16x8.splat(-32768).with(1, 32767).with(2, 2).with(3, -2).with(4, -32768).with(5, 30000).with(6, 10000).with(7, -255);
		var e32 = I32x4.make(0, -1, 0x7fffffff, 0x80000000), f32i = I32x4.make(1, -1, 0x80000000, 0x7fffffff);
		var g32 = I32x4.make(123456789, -987654321, 65536, -65537);
		var e64 = I64x2.zero().with(0, haxe.Int64.make(0x80000000, 0)).with(1, haxe.Int64.make(0, 0xffffffff));
		var f64i = I64x2.zero().with(0, haxe.Int64.make(-1, -1)).with(1, haxe.Int64.make(0x12345678, 0x9abcdef0));

		// bitwise
		show("and", r0.asI32x4() & r1.asI32x4());
		show("or", r0.asI32x4() | r1.asI32x4());
		show("xor", r0.asI32x4() ^ r1.asI32x4());
		show("not", ~r0.asI32x4());
		show("andnot", r0.asI32x4().andNot(r1.asI32x4()));
		show("bitselect", I32x4.select(r2.asI32x4(), r0.asI32x4(), r1.asI32x4()));
		int("any r0", r0.any() ? 1 : 0);
		int("any 0", U8x16.zero().any() ? 1 : 0);

		// 8-bit lanes
		show("i8 add", e8 + f8);
		show("i8 sub", e8 - f8);
		show("i8 addSat", e8.addSat(f8));
		show("i8 subSat", e8.subSat(f8));
		show("u8 addSat", e8.asU8x16().addSat(f8.asU8x16()));
		show("u8 subSat", e8.asU8x16().subSat(f8.asU8x16()));
		show("i8 min", e8.min(f8));
		show("i8 max", e8.max(f8));
		show("u8 min", e8.asU8x16().min(f8.asU8x16()));
		show("u8 max", e8.asU8x16().max(f8.asU8x16()));
		show("u8 avg", e8.asU8x16().avg(f8.asU8x16()));
		show("i8 abs", e8.abs());
		show("i8 neg", -e8);
		show("i8 eq", e8.eq(f8));
		show("i8 ne", e8.ne(f8));
		show("i8 lt", e8.lt(f8));
		show("i8 le", e8.le(f8));
		show("i8 gt", e8.gt(f8));
		show("i8 ge", e8.ge(f8));
		show("u8 lt", e8.asU8x16().lt(f8.asU8x16()));
		show("u8 le", e8.asU8x16().le(f8.asU8x16()));
		show("u8 gt", e8.asU8x16().gt(f8.asU8x16()));
		show("u8 ge", e8.asU8x16().ge(f8.asU8x16()));
		show("i8 shl 3", e8 << 3);
		show("i8 shr 3", e8 >> 3);
		show("i8 ushr 3", e8 >>> 3);
		show("i8 shl 9", e8 << 9);
		var k = id(5);
		show("i8 shl k", e8 << k);
		show("i8 shr k", e8 >> k);
		show("i8 ushr k", e8 >>> k);
		show("u8 shr k", e8.asU8x16() >> k);
		int("i8 all", e8.all() ? 1 : 0);
		int("i8 all f8", f8.all() ? 1 : 0);
		int("i8 bitmask", e8.bitmask());
		show("i8 narrow", I8x16.narrow(e16, f16));
		show("u8 narrow", U8x16.narrow(e16, f16));
		show("swizzle", r0.swizzle(U8x16.make(3, 0, 15, 16, 255, 128, 1, 2, 7, 6, 5, 4, 31, 17, 9, 8)));
		show("shuffle", r0.shuffle(r1, 0, 16, 1, 17, 15, 31, 7, 23, 8, 24, 3, 3, 30, 2, 29, 1));
		int("i8 get 2", e8.get(2));
		int("u8 get 2", e8.asU8x16().get(2));
		int("i8 get 4", e8.get(4));

		// 16-bit lanes
		show("i16 add", e16 + f16);
		show("i16 sub", e16 - f16);
		show("i16 mul", e16 * f16);
		show("i16 addSat", e16.addSat(f16));
		show("i16 subSat", e16.subSat(f16));
		show("u16 addSat", e16.asU16x8().addSat(f16.asU16x8()));
		show("u16 subSat", e16.asU16x8().subSat(f16.asU16x8()));
		show("i16 min", e16.min(f16));
		show("i16 max", e16.max(f16));
		show("u16 min", e16.asU16x8().min(f16.asU16x8()));
		show("u16 max", e16.asU16x8().max(f16.asU16x8()));
		show("u16 avg", e16.asU16x8().avg(f16.asU16x8()));
		show("i16 abs", e16.abs());
		show("i16 neg", -e16);
		show("i16 mulQ15", e16.mulQ15(f16));
		show("i16 mulQ15 min", I16x8.splat(-32768).mulQ15(I16x8.splat(-32768)));
		show("i16 eq", e16.eq(f16));
		show("i16 ne", e16.ne(f16));
		show("i16 lt", e16.lt(f16));
		show("i16 le", e16.le(f16));
		show("i16 gt", e16.gt(f16));
		show("i16 ge", e16.ge(f16));
		show("u16 lt", e16.asU16x8().lt(f16.asU16x8()));
		show("u16 le", e16.asU16x8().le(f16.asU16x8()));
		show("u16 gt", e16.asU16x8().gt(f16.asU16x8()));
		show("u16 ge", e16.asU16x8().ge(f16.asU16x8()));
		show("i16 shl 4", e16 << 4);
		show("i16 shr 4", e16 >> 4);
		show("i16 ushr 4", e16 >>> 4);
		show("i16 shl k", e16 << k);
		show("i16 shr k", e16 >> k);
		show("i16 ushr k", e16 >>> k);
		int("i16 all", e16.all() ? 1 : 0);
		int("i16 all f", f16.all() ? 1 : 0);
		int("i16 bitmask", e16.bitmask());
		show("i16 narrow", I16x8.narrow(e32, g32));
		show("u16 narrow", U16x8.narrow(e32, g32));
		show("i16 extendLow", I16x8.extendLow(e8));
		show("i16 extendHigh", I16x8.extendHigh(e8));
		show("u16 extendLow", U16x8.extendLow(e8.asU8x16()));
		show("u16 extendHigh", U16x8.extendHigh(e8.asU8x16()));
		show("i16 shuffle", e16.shuffle(f16, 7, 0, 8, 15, 3, 3, 12, 1));
		int("i16 get 4", e16.get(4));
		int("u16 get 4", e16.asU16x8().get(4));
		show("i16 with", e16.with(3, 0x12345));

		// 32-bit lanes
		show("i32 add", e32 + f32i);
		show("i32 sub", e32 - f32i);
		show("i32 mul", g32 * f32i);
		show("i32 mul2", g32 * g32);
		show("i32 min", e32.min(f32i));
		show("i32 max", e32.max(f32i));
		show("u32 min", e32.asU32x4().min(f32i.asU32x4()));
		show("u32 max", e32.asU32x4().max(f32i.asU32x4()));
		show("i32 abs", e32.abs());
		show("i32 neg", -e32);
		show("i32 eq", e32.eq(f32i));
		show("i32 ne", e32.ne(f32i));
		show("i32 lt", e32.lt(f32i));
		show("i32 le", e32.le(f32i));
		show("i32 gt", e32.gt(f32i));
		show("i32 ge", e32.ge(f32i));
		show("u32 lt", e32.asU32x4().lt(f32i.asU32x4()));
		show("u32 le", e32.asU32x4().le(f32i.asU32x4()));
		show("u32 gt", e32.asU32x4().gt(f32i.asU32x4()));
		show("u32 ge", e32.asU32x4().ge(f32i.asU32x4()));
		show("i32 shl 7", g32 << 7);
		show("i32 shr 7", g32 >> 7);
		show("i32 ushr 7", g32 >>> 7);
		show("i32 shl 33", g32 << 33);
		show("i32 shl k", g32 << k);
		show("i32 shr k", g32 >> k);
		show("i32 ushr k", g32 >>> k);
		int("i32 all", e32.all() ? 1 : 0);
		int("i32 all g", g32.all() ? 1 : 0);
		int("i32 bitmask", g32.bitmask());
		show("i32 dot", I32x4.dot(e16, f16));
		show("i32 extendLow", I32x4.extendLow(e16));
		show("i32 extendHigh", I32x4.extendHigh(e16));
		show("u32 extendLow", U32x4.extendLow(e16.asU16x8()));
		show("u32 extendHigh", U32x4.extendHigh(e16.asU16x8()));
		show("i32 shuffle", g32.shuffle(e32, 3, 4, 1, 6));
		show("i32 swizzle", g32.swizzle(2, 2, 0, 3));
		int("i32 sum", g32.sum());
		int("i32 get 3", g32.get(3));
		show("i32 with", g32.with(1, 77));

		// 64-bit lanes
		show("i64 add", e64 + f64i);
		show("i64 sub", e64 - f64i);
		show("i64 neg", -e64);
		show("i64 eq", e64.eq(f64i));
		show("i64 ne", e64.ne(e64));
		show("i64 shl 13", f64i << 13);
		show("i64 shr 13", f64i >> 13);
		show("i64 ushr 13", f64i >>> 13);
		show("i64 shr 40", f64i >> 40);
		show("i64 shl k", f64i << k);
		show("i64 shr k", f64i >> k);
		show("i64 ushr k", f64i >>> k);
		show("i64 shr 0", f64i >> id(64));
		int("i64 all", e64.all() ? 1 : 0);
		int("i64 bitmask", f64i.bitmask());
		show("i64 extendLow", I64x2.extendLow(e32));
		show("i64 extendHigh", I64x2.extendHigh(e32));
		show("u64 extendLow", I64x2.extendLowU(e32.asU32x4()));
		show("u64 extendHigh", I64x2.extendHighU(e32.asU32x4()));
		println("i64 get 1: " + haxe.Int64.toStr(f64i.get(1)));
		show("i64 shuffle", e64.shuffle(f64i, 3, 0));

		// float32 lanes
		var fa = F32x4.make(1.5, -0.0, 2.5, Math.POSITIVE_INFINITY);
		var fb = F32x4.make(-2.25, 0.0, Math.NaN, 3.0e38);
		var fc = F32x4.make(0.1, -2.5, 3.5, -1e-40);
		var fd = F32x4.make(2147483520.0, -2147483904.0, 4294967040.0, -0.5);
		showF("f32 a", fa);
		showF("f32 c", fc);
		showF("f32 add", fa + fb);
		showF("f32 sub", fa - fb);
		showF("f32 mul", fa * fc);
		showF("f32 div", fc / fa);
		showF("f32 neg", -fc);
		showF("f32 abs", fc.abs());
		showF("f32 sqrt", fa.sqrt());
		showF("f32 min", fa.min(fb));
		showF("f32 max", fa.max(fb));
		showF("f32 min zeros", F32x4.make(0.0, -0.0, -0.0, 0.0).min(F32x4.make(-0.0, 0.0, -0.0, 0.0)));
		showF("f32 max zeros", F32x4.make(0.0, -0.0, -0.0, 0.0).max(F32x4.make(-0.0, 0.0, -0.0, 0.0)));
		showF("f32 pmin", fa.pmin(fb));
		showF("f32 pmax", fa.pmax(fb));
		showF("f32 mulAdd", fa.mulAdd(fc, fb));
		showF("f32 floor", fc.floor());
		showF("f32 ceil", fc.ceil());
		showF("f32 trunc", fc.trunc());
		showF("f32 round", fc.round());
		showF("f32 round 2", F32x4.make(0.5, 1.5, -0.5, -2.5).round());
		show("f32 eq", fa.eq(fb));
		show("f32 ne", fa.ne(fb));
		show("f32 lt", fa.lt(fb));
		show("f32 le", fa.le(fb));
		show("f32 gt", fa.gt(fb));
		show("f32 ge", fa.ge(fb));
		show("f32 toI32x4", fd.toI32x4());
		show("f32 toI32x4 b", fb.toI32x4());
		show("f32 toI32x4 a", fa.toI32x4());
		showF("f32 fromI32x4", F32x4.fromI32x4(g32));
		showF("f32 fromI32x4 e", F32x4.fromI32x4(e32));
		showF("f32 fromU32x4", F32x4.fromU32x4(e32.asU32x4()));
		showF("f32 fromU32x4 g", F32x4.fromU32x4(g32.asU32x4()));
		showF("f32 shuffle", fa.shuffle(fc, 3, 4, 7, 0));
		showF("f32 splat", F32x4.splat(0.1));
		float("f32 get 0", fc.get(0));
		float("f32 get 3", fc.get(3));
		float("f32 sum", fc.sum());
		showF("f32 with", fa.with(2, 1.0 / 3.0));
		showF("f32 clamp", fc.clamp(F32x4.splat(-1), F32x4.splat(1)));

		// float64 lanes
		var da = F64x2.make(1.5, -0.0), db = F64x2.make(Math.NaN, 0.0), dc = F64x2.make(-2.5e300, 0.1), dd = F64x2.make(3e9, -2147483648.5);
		showD("f64 add", da + dc);
		showD("f64 sub", da - dc);
		showD("f64 mul", dc * dc);
		showD("f64 div", da / dc);
		showD("f64 neg", -da);
		showD("f64 abs", dc.abs());
		showD("f64 sqrt", dc.sqrt());
		showD("f64 min", da.min(db));
		showD("f64 max", da.max(db));
		showD("f64 min zeros", da.min(F64x2.make(2.0, 0.0)));
		showD("f64 max zeros", da.max(F64x2.make(2.0, 0.0)));
		showD("f64 pmin", da.pmin(db));
		showD("f64 pmax", da.pmax(db));
		showD("f64 floor", dc.floor());
		showD("f64 ceil", dc.ceil());
		showD("f64 trunc", F64x2.make(-1.5, 2.7).trunc());
		showD("f64 round", F64x2.make(2.5, -3.5).round());
		show("f64 eq", da.eq(db));
		show("f64 ne", da.ne(db));
		show("f64 lt", da.lt(dc));
		show("f64 le", da.le(dc));
		show("f64 gt", da.gt(dc));
		show("f64 ge", da.ge(dc));
		show("f64 toI32x4", dd.toI32x4());
		show("f64 toI32x4 b", db.toI32x4());
		showD("f64 fromI32x4Low", F64x2.fromI32x4Low(e32));
		showD("f64 promoteLow", F64x2.promoteLow(fc));
		showF("f32 demote", F32x4.demote(dc));
		showD("f64 shuffle", da.shuffle(dc, 3, 0));
		float("f64 sum", dc.sum());
		float("f64 get 1", dc.get(1));

		// memory
		var out = Bytes.alloc(48);
		g32.store(out, 3);
		fa.store(out, 20);
		println("store: " + out.toHex());
		show("load back", I32x4.load(out, 3));
		show("through a call", id(g32) + id(f32i));
		try {
			I32x4.load(out, 33);
			println("no error");
		} catch (e:haxe.io.Error) {
			println("load 33: " + e);
		}
		try {
			g32.store(out, -1);
			println("no error");
		} catch (e:haxe.io.Error) {
			println("store -1: " + e);
		}
		println("in a loop: " + loop(b));
	}

	// a loop's vectors in registers: phis, and the sum of 16-byte blocks
	static function loop(b:Bytes):String {
		var acc = I32x4.zero(), m = U8x16.zero();
		var p = 0;
		while (p + 16 <= b.length) {
			var v = U8x16.load(b, p);
			m = m.max(v);
			acc = acc + I32x4.extendLow(I16x8.extendLow(v.asI8x16())) + I32x4.extendHigh(I16x8.extendHigh(v.asI8x16()));
			p += 16;
		}
		return words(acc) + " / " + words(m);
	}
}
