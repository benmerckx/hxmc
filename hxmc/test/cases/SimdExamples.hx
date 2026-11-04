import haxe.io.Bytes;
import hxmc.ReadOnlySpan;
import hxmc.Span;
import hxmc.simd.*;
import hxmc.unsafe.UInt8;

// The worked examples of docs/plans/simd.md, each against its scalar
// version: a 4x4 matrix product, a Lanczos-3 row resample of RGBA pixels,
// an audio mix with gain and clamp (16-bit samples, Q15 gain, saturated).
// (The 8x8 IDCT, YCbCr to RGBA and the bilinear resize are
// hxmc/test/bench/simd/SimdBench.hx's.)
@:hxmc.struct @:publicFields class Mat4 {
	// the columns
	var c0:F32x4;
	var c1:F32x4;
	var c2:F32x4;
	var c3:F32x4;

	inline function new(c0:F32x4, c1:F32x4, c2:F32x4, c3:F32x4) {
		this.c0 = c0;
		this.c1 = c1;
		this.c2 = c2;
		this.c3 = c3;
	}

	// a * v: the columns weighted by v's lanes
	static inline function apply(a:Mat4, v:F32x4):F32x4
		return a.c0 * v.swizzle(0, 0, 0, 0) + a.c1 * v.swizzle(1, 1, 1, 1) + a.c2 * v.swizzle(2, 2, 2, 2) + a.c3 * v.swizzle(3, 3, 3, 3);

	static inline function mul(a:Mat4, b:Mat4):Mat4
		return new Mat4(apply(a, b.c0), apply(a, b.c1), apply(a, b.c2), apply(a, b.c3));
}

class SimdExamples {
	static function println(s:String) {
		#if js
		js.Syntax.code("console.log({0})", s);
		#else
		Sys.println(s);
		#end
	}

	static function hex(x:Int):String
		return StringTools.hex(x, 8).toLowerCase();

	static function f32(x:Float):Float
		return haxe.io.FPHelper.i32ToFloat(haxe.io.FPHelper.floatToI32(x));

	// ---- a 4x4 matrix product

	static function matmul() {
		var a = new Mat4(F32x4.make(1, 2, 3, 4), F32x4.make(-1, 0.5, 2, 0), F32x4.make(0, 1, -3, 1), F32x4.make(5, 0, 0, 1));
		var b = new Mat4(F32x4.make(0.25, 1, 0, -2), F32x4.make(1, 1, 1, 1), F32x4.make(3, -1, 0.5, 0), F32x4.make(0, 0, 2, 1));
		var c = Mat4.mul(a, b);
		// (the scalar product, each sum rounded to float32 in the same order)
		var ok = true;
		var ac = [a.c0, a.c1, a.c2, a.c3], bc = [b.c0, b.c1, b.c2, b.c3], cc = [c.c0, c.c1, c.c2, c.c3];
		for (j in 0...4)
			for (i in 0...4) {
				var s = 0.0;
				for (k in 0...4)
					s = f32(s + f32(lane(ac[k], i) * lane(bc[j], k)));
				if (s != lane(cc[j], i)) ok = false;
			}
		println("matmul: " + [for (v in cc) for (i in 0...4) lane(v, i)].join(" ") + (ok ? " (= scalar)" : " (differs)"));
	}

	static function lane(v:F32x4, i:Int):Float
		return switch i {
			case 0: v.get(0);
			case 1: v.get(1);
			case 2: v.get(2);
			case _: v.get(3);
		}

	// ---- a Lanczos-3 row resample: out[x] = sum of six source pixels
	// weighted (float32 RGBA lanes), rounded and saturated to bytes

	static function lanczos(x:Float):Float {
		if (x == 0) return 1;
		if (x <= -3 || x >= 3) return 0;
		var p = Math.PI * x;
		return 3 * Math.sin(p) * Math.sin(p / 3) / (p * p);
	}

	// the first source pixel of each output pixel (clamped to the row) and
	// its six weights, normalized
	static function taps(w:Int, w2:Int):{first:Array<Int>, weights:Bytes} {
		var first = [], weights = Bytes.alloc(w2 * 6 * 4);
		for (x in 0...w2) {
			var c = (x + 0.5) * w / w2 - 0.5;
			var f = Math.floor(c) - 2;
			var ws = [for (k in 0...6) lanczos(c - (f + k))];
			var sum = 0.0;
			for (v in ws)
				sum += v;
			var lo = Std.int(Math.max(0, Math.min(w - 6, f)));
			// (an edge's taps moved inside: the weights follow their pixels)
			var shift = lo - Std.int(f);
			for (k in 0...6) {
				var src = k + shift;
				weights.setFloat((x * 6 + k) * 4, src >= 0 && src < 6 ? ws[src] / sum : 0);
			}
			first.push(lo);
		}
		return {first: first, weights: weights};
	}

	@:hxmc.kernel static function resampleRow(src:ReadOnlySpan<UInt8>, firstB:ReadOnlySpan<UInt8>, weights:ReadOnlySpan<UInt8>, dst:Span<UInt8>) {
		var first:ReadOnlySpan<Int> = firstB.reinterpret();
		var w2 = first.length;
		if (dst.length < 4 * w2 || weights.length < w2 * 24) return;
		for (x in 0...w2) {
			var o = first[x] * 4;
			var acc = F32x4.zero();
			for (k in 0...6) {
				// one pixel's four bytes as float32 lanes
				var p = U32x4.extendLow(U16x8.extendLow(U8x16.loadSpan32(src, o + 4 * k))).toF32x4();
				acc = p.mulAdd(F32x4.splat(F32x4.loadSpan32(weights, (x * 6 + k) * 4).get(0)), acc);
			}
			// rounded to the nearest (a half to even), saturated to 0-255
			var q = acc.round().toI32x4();
			var b = U8x16.narrow(I16x8.narrow(q, q), I16x8.narrow(q, q));
			b.storeSpan32(dst, 4 * x);
		}
	}

	static function resample() {
		var w = 23, w2 = 37;
		var src = Bytes.alloc(w * 4);
		for (i in 0...w * 4)
			src.set(i, (i * 53 + (i >> 2) * 17) & 0xff);
		var t = taps(w, w2);
		var firstB = Bytes.alloc(w2 * 4);
		for (x in 0...w2)
			firstB.setInt32(x * 4, t.first[x]);
		var dst = Bytes.alloc(w2 * 4);
		resampleRow(ReadOnlySpan.ofBytes(src), ReadOnlySpan.ofBytes(firstB), ReadOnlySpan.ofBytes(t.weights), Span.ofBytes(dst));
		// the scalar version: the same float32 roundings in the same order
		var ok = true;
		for (x in 0...w2)
			for (ch in 0...4) {
				var acc = 0.0;
				for (k in 0...6) {
					var wk = t.weights.getFloat((x * 6 + k) * 4);
					acc = f32(f32(src.get((t.first[x] + k) * 4 + ch) * wk) + acc);
				}
				var r = Math.round(acc);
				// (a half to even, as the vector's round)
				if (r - acc == 0.5 && r % 2 != 0) r -= 1;
				var v = r < 0 ? 0 : r > 255 ? 255 : Std.int(r);
				if (dst.get(x * 4 + ch) != v) ok = false;
			}
		var h = 0;
		for (i in 0...w2 * 4)
			h = (h * 31 + dst.get(i)) | 0;
		println("lanczos: " + hex(h) + (ok ? " (= scalar)" : " (differs)"));
	}

	// ---- an audio mix: two 16-bit streams, each with a Q15 gain, summed
	// and saturated

	@:hxmc.kernel static function mix(a:ReadOnlySpan<UInt8>, b:ReadOnlySpan<UInt8>, out:Span<UInt8>, ga:Int, gb:Int) {
		var n = out.length >> 1;
		if (a.length < 2 * n || b.length < 2 * n) return;
		var va = I16x8.splat(ga), vb = I16x8.splat(gb);
		var i = 0;
		while (i + 8 <= n) {
			I16x8.loadSpan(a, 2 * i).mulQ15(va).addSat(I16x8.loadSpan(b, 2 * i).mulQ15(vb)).storeSpan(out, 2 * i);
			i += 8;
		}
		while (i < n) {
			var x = (a[2 * i] | (a[2 * i + 1] << 8)) << 16 >> 16, y = (b[2 * i] | (b[2 * i + 1] << 8)) << 16 >> 16;
			var s = q15(x, ga) + q15(y, gb);
			s = s < -32768 ? -32768 : s > 32767 ? 32767 : s;
			out[2 * i] = s & 0xff;
			out[2 * i + 1] = (s >> 8) & 0xff;
			i++;
		}
	}

	// (x * g + 0x4000) >> 15, saturated: q15mulr_sat_s
	static inline function q15(x:Int, g:Int):Int {
		var p = (x * g + 0x4000) >> 15;
		return p > 32767 ? 32767 : p;
	}

	static function audio() {
		var n = 45;
		var a = Bytes.alloc(n * 2), b = Bytes.alloc(n * 2), out = Bytes.alloc(n * 2);
		var seed = 12345;
		for (i in 0...n) {
			seed ^= seed << 13;
			seed ^= seed >>> 17;
			seed ^= seed << 5;
			a.setUInt16(i * 2, (seed >> 8) & 0xffff);
			seed ^= seed << 13;
			seed ^= seed >>> 17;
			seed ^= seed << 5;
			b.setUInt16(i * 2, i == 3 ? 0x8000 : (seed >> 8) & 0xffff);
		}
		// a gain of 0.9 and of -1 (-32768: -1.0 times -32768 saturates)
		mix(ReadOnlySpan.ofBytes(a), ReadOnlySpan.ofBytes(b), Span.ofBytes(out), 29491, -32768);
		var ok = true, h = 0;
		for (i in 0...n) {
			var x = a.getUInt16(i * 2) << 16 >> 16, y = b.getUInt16(i * 2) << 16 >> 16;
			var s = q15(x, 29491) + q15(y, -32768);
			s = s < -32768 ? -32768 : s > 32767 ? 32767 : s;
			if (out.getUInt16(i * 2) != (s & 0xffff)) ok = false;
			h = (h * 31 + out.getUInt16(i * 2)) | 0;
		}
		println("audio mix: " + hex(h) + (ok ? " (= scalar)" : " (differs)"));
	}

	static function main() {
		matmul();
		resample();
		audio();
	}
}
