import haxe.Timer;
import haxe.io.Bytes;
import haxe.ds.Vector;
import hxmc.ReadOnlySpan;
import hxmc.Span;
import hxmc.unsafe.Int16;
import hxmc.unsafe.UInt8;
import hxmc.simd.*;

// Image kernels for SIMD (docs/plans/simd.md, "Benchmarks"): an 8x8 integer
// inverse DCT over many blocks, YCbCr to RGBA over a large image, a
// bilinear resize, each as plain Haxe over Bytes and Vector (`bytes`) and as
// a kernel over spans (`span`), and the same in C (simd_bench.c, the same
// data and checksums). `node make.mjs bench-simd` builds and runs every variant; by
// hand:
//   bin/hxmc/hxmc bin/simd-bench/m -cp hxmc/test/bench/simd -main SimdBench -cp bin/hxmc/std --custom-target hxmc [-D hxmc.span-checks=0]
//   bin/simd-bench/m [scale]
// Prints one line per kernel: its name, the median of 7 runs in ns per unit
// (an 8x8 block, an output pixel), the checksum of its output.
class SimdBench {
	static var rng = 0x9E3779B9;

	static inline function next():Int {
		rng ^= rng << 13;
		rng ^= rng >>> 17;
		rng ^= rng << 5;
		return rng;
	}

	static function checksum(b:Bytes, n:Int):Int {
		var h = 0;
		for (i in 0...n)
			h = (h << 5) - h + b.get(i);
		return h;
	}

	static function time(name:String, units:Float, passes:Int, f:() -> Void, out:Bytes, outLen:Int) {
		var r = [];
		for (k in 0...7) {
			var t0 = Timer.stamp();
			for (p in 0...passes)
				f();
			r.push((Timer.stamp() - t0) * 1e9 / (units * passes));
		}
		r.sort(Reflect.compare);
		Sys.println('$name ${Math.round(r[3] * 1000) / 1000} ${checksum(out, outLen)}');
	}

	static function main() {
		var args = Sys.args();
		var scale = args.length > 0 ? Std.parseInt(args[0]) : 1;
		var only = args.length > 1 ? args[1] : null;
		// 4096 blocks (a 512x512 plane): DC in -512..511, an AC coefficient
		// in -32..31 with a chance that falls with its index, else zero
		var blocks = 4096;
		var coef = Bytes.alloc(blocks * 64 * 2), coefV = new Vector<Int>(blocks * 64);
		for (i in 0...blocks * 64) {
			var k = i & 63;
			var v = if (k == 0) (next() & 1023) - 512 else if (unsignedMod(next(), k + 2) < 2) (next() & 63) - 32 else 0;
			coef.setUInt16(i * 2, v & 0xFFFF);
			coefV[i] = v;
		}
		var q = Bytes.alloc(64 * 4), qV = new Vector<Int>(64);
		for (k in 0...64) {
			q.setInt32(k * 4, 1 + 2 * ((k & 7) + (k >> 3)));
			qV[k] = 1 + 2 * ((k & 7) + (k >> 3));
		}
		var idctOut = Bytes.alloc(blocks * 64);
		var wsB = Bytes.alloc(64 * 4);
		// a 1024x1024 image's planes
		var pixels = 1024 * 1024;
		var y = Bytes.alloc(pixels), cb = Bytes.alloc(pixels), cr = Bytes.alloc(pixels);
		for (i in 0...pixels) {
			y.set(i, next() & 255);
			cb.set(i, next() & 255);
			cr.set(i, next() & 255);
		}
		var rgba = Bytes.alloc(pixels * 4);
		// 1024x1024 RGBA up to 1536x1536
		var w = 1024, h = 1024, w2 = 1536, h2 = 1536;
		var src = Bytes.alloc(w * h * 4);
		for (i in 0...w * h * 4)
			src.set(i, next() & 255);
		var dst = Bytes.alloc(w2 * h2 * 4);
		var xofs = Bytes.alloc(w2 * 4), xw = Bytes.alloc(w2 * 4), xofsV = new Vector<Int>(w2), xwV = new Vector<Int>(w2);
		for (x in 0...w2) {
			var num = Std.int(x * (w - 1) * 256 / (w2 - 1)), sx = num >> 8, fx = num & 255;
			if (sx >= w - 1) {
				sx = w - 2;
				fx = 256;
			}
			xofs.setInt32(x * 4, sx * 4);
			xw.setInt32(x * 4, fx);
			xofsV[x] = sx * 4;
			xwV[x] = fx;
		}
		inline function run(name:String)
			return only == null || only == name;
		if (run("idct-bytes"))
			time("idct-bytes", blocks, 16 * scale, () -> Plain.idctAll(coefV, qV, idctOut, blocks), idctOut, blocks * 64);
		if (run("idct-span"))
			time("idct-span", blocks, 16 * scale,
				() -> Kernels.idctAll(ReadOnlySpan.ofBytes(coef), ReadOnlySpan.ofBytes(q), Span.ofBytes(idctOut), Span.ofBytes(wsB), blocks), idctOut, blocks * 64);
		if (run("ycc-bytes"))
			time("ycc-bytes", pixels, 4 * scale, () -> Plain.yccRgba(y, cb, cr, rgba, pixels), rgba, pixels * 4);
		if (run("ycc-span"))
			time("ycc-span", pixels, 4 * scale,
				() -> Kernels.yccRgba(ReadOnlySpan.ofBytes(y), ReadOnlySpan.ofBytes(cb), ReadOnlySpan.ofBytes(cr), Span.ofBytes(rgba)), rgba, pixels * 4);
		if (run("resize-bytes"))
			time("resize-bytes", w2 * h2, 2 * scale, () -> Plain.resizeAll(src, w, h, xofsV, xwV, dst, w2, h2), dst, w2 * h2 * 4);
		if (run("resize-span"))
			time("resize-span", w2 * h2, 2 * scale,
				() -> Kernels.resizeAll(ReadOnlySpan.ofBytes(src), w, h, ReadOnlySpan.ofBytes(xofs), ReadOnlySpan.ofBytes(xw), Span.ofBytes(dst), w2, h2),
				dst, w2 * h2 * 4);
		if (run("idct-simd"))
			time("idct-simd", blocks, 16 * scale, () -> SimdKernels.idctAll(ReadOnlySpan.ofBytes(coef), ReadOnlySpan.ofBytes(q), Span.ofBytes(idctOut), blocks), idctOut,
				blocks * 64);
		if (run("ycc-simd"))
			time("ycc-simd", pixels, 4 * scale,
				() -> SimdKernels.yccRgba(ReadOnlySpan.ofBytes(y), ReadOnlySpan.ofBytes(cb), ReadOnlySpan.ofBytes(cr), Span.ofBytes(rgba)), rgba, pixels * 4);
		if (run("resize-simd"))
			time("resize-simd", w2 * h2, 2 * scale,
				() -> SimdKernels.resizeAll(ReadOnlySpan.ofBytes(src), w, h, ReadOnlySpan.ofBytes(xofs), ReadOnlySpan.ofBytes(xw), Span.ofBytes(dst), w2, h2),
				dst, w2 * h2 * 4);
	}

	static function unsignedMod(a:Int, b:Int):Int {
		// a as an unsigned 32-bit number, modulo b (b small and positive)
		var hi = a >>> 16, lo = a & 0xFFFF;
		return ((hi % b) * 65536 + lo) % b;
	}
}

// The kernels as plain Haxe: coefficients and tables in Vector<Int>, pixels
// in Bytes
class Plain {
	public static function idctAll(coef:Vector<Int>, q:Vector<Int>, out:Bytes, blocks:Int) {
		var ws = new Vector<Int>(64);
		for (b in 0...blocks)
			idct(coef, b * 64, q, out, b * 64, ws);
	}

	static inline function clamp(v:Int):Int
		return v < 0 ? 0 : v > 255 ? 255 : v;

	static function idct(s:Vector<Int>, base:Int, q:Vector<Int>, out:Bytes, ob:Int, ws:Vector<Int>) {
		for (c in 0...8) {
			var i = base + c;
			if (s[i + 8] == 0 && s[i + 16] == 0 && s[i + 24] == 0 && s[i + 32] == 0 && s[i + 40] == 0 && s[i + 48] == 0 && s[i + 56] == 0) {
				var dc = (s[i] * q[c]) << 2;
				for (k in 0...8)
					ws[c + 8 * k] = dc;
				continue;
			}
			var z2 = s[i + 16] * q[c + 16], z3 = s[i + 48] * q[c + 48];
			var z1 = (z2 + z3) * 4433;
			var tmp2 = z1 + z3 * -15137;
			var tmp3 = z1 + z2 * 6270;
			z2 = s[i] * q[c];
			z3 = s[i + 32] * q[c + 32];
			var tmp0 = (z2 + z3) << 13;
			var tmp1 = (z2 - z3) << 13;
			var tmp10 = tmp0 + tmp3, tmp13 = tmp0 - tmp3, tmp11 = tmp1 + tmp2, tmp12 = tmp1 - tmp2;
			tmp0 = s[i + 56] * q[c + 56];
			tmp1 = s[i + 40] * q[c + 40];
			tmp2 = s[i + 24] * q[c + 24];
			tmp3 = s[i + 8] * q[c + 8];
			z1 = tmp0 + tmp3;
			z2 = tmp1 + tmp2;
			z3 = tmp0 + tmp2;
			var z4 = tmp1 + tmp3;
			var z5 = (z3 + z4) * 9633;
			tmp0 *= 2446;
			tmp1 *= 16819;
			tmp2 *= 25172;
			tmp3 *= 12299;
			z1 *= -7373;
			z2 *= -20995;
			z3 = z3 * -16069 + z5;
			z4 = z4 * -3196 + z5;
			tmp0 += z1 + z3;
			tmp1 += z2 + z4;
			tmp2 += z2 + z3;
			tmp3 += z1 + z4;
			ws[c] = (tmp10 + tmp3 + 1024) >> 11;
			ws[c + 56] = (tmp10 - tmp3 + 1024) >> 11;
			ws[c + 8] = (tmp11 + tmp2 + 1024) >> 11;
			ws[c + 48] = (tmp11 - tmp2 + 1024) >> 11;
			ws[c + 16] = (tmp12 + tmp1 + 1024) >> 11;
			ws[c + 40] = (tmp12 - tmp1 + 1024) >> 11;
			ws[c + 24] = (tmp13 + tmp0 + 1024) >> 11;
			ws[c + 32] = (tmp13 - tmp0 + 1024) >> 11;
		}
		for (r in 0...8) {
			var w = r * 8, o = ob + r * 8;
			var z2 = ws[w + 2], z3 = ws[w + 6];
			var z1 = (z2 + z3) * 4433;
			var tmp2 = z1 + z3 * -15137;
			var tmp3 = z1 + z2 * 6270;
			var tmp0 = (ws[w] + ws[w + 4]) << 13;
			var tmp1 = (ws[w] - ws[w + 4]) << 13;
			var tmp10 = tmp0 + tmp3, tmp13 = tmp0 - tmp3, tmp11 = tmp1 + tmp2, tmp12 = tmp1 - tmp2;
			tmp0 = ws[w + 7];
			tmp1 = ws[w + 5];
			tmp2 = ws[w + 3];
			tmp3 = ws[w + 1];
			z1 = tmp0 + tmp3;
			z2 = tmp1 + tmp2;
			z3 = tmp0 + tmp2;
			var z4 = tmp1 + tmp3;
			var z5 = (z3 + z4) * 9633;
			tmp0 *= 2446;
			tmp1 *= 16819;
			tmp2 *= 25172;
			tmp3 *= 12299;
			z1 *= -7373;
			z2 *= -20995;
			z3 = z3 * -16069 + z5;
			z4 = z4 * -3196 + z5;
			tmp0 += z1 + z3;
			tmp1 += z2 + z4;
			tmp2 += z2 + z3;
			tmp3 += z1 + z4;
			out.set(o, clamp(((tmp10 + tmp3 + 131072) >> 18) + 128));
			out.set(o + 7, clamp(((tmp10 - tmp3 + 131072) >> 18) + 128));
			out.set(o + 1, clamp(((tmp11 + tmp2 + 131072) >> 18) + 128));
			out.set(o + 6, clamp(((tmp11 - tmp2 + 131072) >> 18) + 128));
			out.set(o + 2, clamp(((tmp12 + tmp1 + 131072) >> 18) + 128));
			out.set(o + 5, clamp(((tmp12 - tmp1 + 131072) >> 18) + 128));
			out.set(o + 3, clamp(((tmp13 + tmp0 + 131072) >> 18) + 128));
			out.set(o + 4, clamp(((tmp13 - tmp0 + 131072) >> 18) + 128));
		}
	}

	public static function yccRgba(y:Bytes, cb:Bytes, cr:Bytes, out:Bytes, n:Int) {
		for (i in 0...n) {
			var yy = y.get(i), b = cb.get(i) - 128, r = cr.get(i) - 128;
			out.set(4 * i, clamp(yy + ((91881 * r + 32768) >> 16)));
			out.set(4 * i + 1, clamp(yy + ((-22554 * b - 46802 * r + 32768) >> 16)));
			out.set(4 * i + 2, clamp(yy + ((116130 * b + 32768) >> 16)));
			out.set(4 * i + 3, 255);
		}
	}

	static function resizeRow(src:Bytes, top:Int, bot:Int, fy:Int, xofs:Vector<Int>, xw:Vector<Int>, dst:Bytes, d:Int, w2:Int) {
		for (x in 0...w2) {
			var o = xofs[x], fx = xw[x];
			for (c in 0...4) {
				var t = src.get(top + o + c) * (256 - fx) + src.get(top + o + 4 + c) * fx;
				var b = src.get(bot + o + c) * (256 - fx) + src.get(bot + o + 4 + c) * fx;
				dst.set(d + 4 * x + c, (t * (256 - fy) + b * fy + 32768) >> 16);
			}
		}
	}

	public static function resizeAll(src:Bytes, w:Int, h:Int, xofs:Vector<Int>, xw:Vector<Int>, dst:Bytes, w2:Int, h2:Int) {
		for (y in 0...h2) {
			var num = Std.int(y * (h - 1) * 256 / (h2 - 1)), sy = num >> 8, fy = num & 255;
			if (sy >= h - 1) {
				sy = h - 2;
				fy = 256;
			}
			resizeRow(src, sy * w * 4, (sy + 1) * w * 4, fy, xofs, xw, dst, y * w2 * 4, w2);
		}
	}
}

// The kernels on spans (docs/interop.md, "Spans")
@:hxmc.kernel class Kernels {
	public static function idctAll(coefB:ReadOnlySpan<UInt8>, qB:ReadOnlySpan<UInt8>, out:Span<UInt8>, wsB:Span<UInt8>, blocks:Int) {
		var coef:ReadOnlySpan<Int16> = coefB.reinterpret(), q:ReadOnlySpan<Int> = qB.reinterpret(), ws:Span<Int> = wsB.reinterpret();
		for (b in 0...blocks)
			idct(coef.sub(b * 64, 64), q, out.sub(b * 64, 64), ws);
	}

	static inline function clamp(v:Int):Int
		return v < 0 ? 0 : v > 255 ? 255 : v;

	static function idct(s:ReadOnlySpan<Int16>, q:ReadOnlySpan<Int>, out:Span<UInt8>, ws:Span<Int>) {
		if (q.length < 64 || s.length < 64 || out.length < 64 || ws.length < 64) return;
		for (c in 0...8) {
			if (s[c + 8] == 0 && s[c + 16] == 0 && s[c + 24] == 0 && s[c + 32] == 0 && s[c + 40] == 0 && s[c + 48] == 0 && s[c + 56] == 0) {
				var dc = (s[c] * q[c]) << 2;
				for (k in 0...8)
					ws[c + 8 * k] = dc;
				continue;
			}
			var z2 = s[c + 16] * q[c + 16], z3 = s[c + 48] * q[c + 48];
			var z1 = (z2 + z3) * 4433;
			var tmp2 = z1 + z3 * -15137;
			var tmp3 = z1 + z2 * 6270;
			z2 = s[c] * q[c];
			z3 = s[c + 32] * q[c + 32];
			var tmp0 = (z2 + z3) << 13;
			var tmp1 = (z2 - z3) << 13;
			var tmp10 = tmp0 + tmp3, tmp13 = tmp0 - tmp3, tmp11 = tmp1 + tmp2, tmp12 = tmp1 - tmp2;
			tmp0 = s[c + 56] * q[c + 56];
			tmp1 = s[c + 40] * q[c + 40];
			tmp2 = s[c + 24] * q[c + 24];
			tmp3 = s[c + 8] * q[c + 8];
			z1 = tmp0 + tmp3;
			z2 = tmp1 + tmp2;
			z3 = tmp0 + tmp2;
			var z4 = tmp1 + tmp3;
			var z5 = (z3 + z4) * 9633;
			tmp0 *= 2446;
			tmp1 *= 16819;
			tmp2 *= 25172;
			tmp3 *= 12299;
			z1 *= -7373;
			z2 *= -20995;
			z3 = z3 * -16069 + z5;
			z4 = z4 * -3196 + z5;
			tmp0 += z1 + z3;
			tmp1 += z2 + z4;
			tmp2 += z2 + z3;
			tmp3 += z1 + z4;
			ws[c] = (tmp10 + tmp3 + 1024) >> 11;
			ws[c + 56] = (tmp10 - tmp3 + 1024) >> 11;
			ws[c + 8] = (tmp11 + tmp2 + 1024) >> 11;
			ws[c + 48] = (tmp11 - tmp2 + 1024) >> 11;
			ws[c + 16] = (tmp12 + tmp1 + 1024) >> 11;
			ws[c + 40] = (tmp12 - tmp1 + 1024) >> 11;
			ws[c + 24] = (tmp13 + tmp0 + 1024) >> 11;
			ws[c + 32] = (tmp13 - tmp0 + 1024) >> 11;
		}
		for (r in 0...8) {
			var w = r * 8, o = r * 8;
			var z2 = ws[w + 2], z3 = ws[w + 6];
			var z1 = (z2 + z3) * 4433;
			var tmp2 = z1 + z3 * -15137;
			var tmp3 = z1 + z2 * 6270;
			var tmp0 = (ws[w] + ws[w + 4]) << 13;
			var tmp1 = (ws[w] - ws[w + 4]) << 13;
			var tmp10 = tmp0 + tmp3, tmp13 = tmp0 - tmp3, tmp11 = tmp1 + tmp2, tmp12 = tmp1 - tmp2;
			tmp0 = ws[w + 7];
			tmp1 = ws[w + 5];
			tmp2 = ws[w + 3];
			tmp3 = ws[w + 1];
			z1 = tmp0 + tmp3;
			z2 = tmp1 + tmp2;
			z3 = tmp0 + tmp2;
			var z4 = tmp1 + tmp3;
			var z5 = (z3 + z4) * 9633;
			tmp0 *= 2446;
			tmp1 *= 16819;
			tmp2 *= 25172;
			tmp3 *= 12299;
			z1 *= -7373;
			z2 *= -20995;
			z3 = z3 * -16069 + z5;
			z4 = z4 * -3196 + z5;
			tmp0 += z1 + z3;
			tmp1 += z2 + z4;
			tmp2 += z2 + z3;
			tmp3 += z1 + z4;
			out[o] = clamp(((tmp10 + tmp3 + 131072) >> 18) + 128);
			out[o + 7] = clamp(((tmp10 - tmp3 + 131072) >> 18) + 128);
			out[o + 1] = clamp(((tmp11 + tmp2 + 131072) >> 18) + 128);
			out[o + 6] = clamp(((tmp11 - tmp2 + 131072) >> 18) + 128);
			out[o + 2] = clamp(((tmp12 + tmp1 + 131072) >> 18) + 128);
			out[o + 5] = clamp(((tmp12 - tmp1 + 131072) >> 18) + 128);
			out[o + 3] = clamp(((tmp13 + tmp0 + 131072) >> 18) + 128);
			out[o + 4] = clamp(((tmp13 - tmp0 + 131072) >> 18) + 128);
		}
	}

	public static function yccRgba(y:ReadOnlySpan<UInt8>, cb:ReadOnlySpan<UInt8>, cr:ReadOnlySpan<UInt8>, out:Span<UInt8>) {
		var n = y.length;
		if (cb.length != n || cr.length != n || out.length < 4 * n) return;
		for (i in 0...n) {
			var yy:Int = y[i], b = cb[i] - 128, r = cr[i] - 128;
			out[4 * i] = clamp(yy + ((91881 * r + 32768) >> 16));
			out[4 * i + 1] = clamp(yy + ((-22554 * b - 46802 * r + 32768) >> 16));
			out[4 * i + 2] = clamp(yy + ((116130 * b + 32768) >> 16));
			out[4 * i + 3] = 255;
		}
	}

	static function resizeRow(t:ReadOnlySpan<UInt8>, b:ReadOnlySpan<UInt8>, fy:Int, xofs:ReadOnlySpan<Int>, xw:ReadOnlySpan<Int>, dst:Span<UInt8>) {
		var w2 = xofs.length;
		if (xw.length != w2 || dst.length < 4 * w2) return;
		for (x in 0...w2) {
			var o = xofs[x], fx = xw[x];
			for (c in 0...4) {
				var top = t[o + c] * (256 - fx) + t[o + 4 + c] * fx;
				var bot = b[o + c] * (256 - fx) + b[o + 4 + c] * fx;
				dst[4 * x + c] = (top * (256 - fy) + bot * fy + 32768) >> 16;
			}
		}
	}

	public static function resizeAll(src:ReadOnlySpan<UInt8>, w:Int, h:Int, xofsB:ReadOnlySpan<UInt8>, xwB:ReadOnlySpan<UInt8>, dst:Span<UInt8>, w2:Int,
			h2:Int) {
		var xofs:ReadOnlySpan<Int> = xofsB.reinterpret(), xw:ReadOnlySpan<Int> = xwB.reinterpret();
		var row = w * 4;
		for (y in 0...h2) {
			var num = Std.int(y * (h - 1) * 256 / (h2 - 1)), sy = num >> 8, fy = num & 255;
			if (sy >= h - 1) {
				sy = h - 2;
				fy = 256;
			}
			resizeRow(src.sub(sy * row, row), src.sub((sy + 1) * row, row), fy, xofs, xw, dst.sub(y * w2 * 4, w2 * 4));
		}
	}
}


// The kernels with hxmc.simd's vectors (docs/plans/simd.md): the same
// results, bit for bit (integer lanes computed as the scalar code's Ints;
// the clamps by saturating narrows)

// eight vectors, a struct value (in registers: Sroa)
@:hxmc.struct @:publicFields class Eight {
	var v0:I32x4;
	var v1:I32x4;
	var v2:I32x4;
	var v3:I32x4;
	var v4:I32x4;
	var v5:I32x4;
	var v6:I32x4;
	var v7:I32x4;

	inline function new() {}
}

@:hxmc.kernel class SimdKernels {
	// ---- the inverse DCT: four columns (or rows) a vector, an 8x8
	// transpose between the passes, one of 16-bit lanes after

	public static function idctAll(coef:ReadOnlySpan<UInt8>, q:ReadOnlySpan<UInt8>, out:Span<UInt8>, blocks:Int) {
		if (coef.length < blocks * 128 || out.length < blocks * 64 || q.length < 256) return;
		for (b in 0...blocks)
			idct(coef, b * 128, q, out, b * 64);
	}

	static inline function c(x:Int):I32x4
		return I32x4.splat(x);

	// jpeg_idct_islow's butterfly on eight vectors (i0 ... i7: the
	// coefficients of a column or row), descaled by shift with its rounding
	static inline function butterfly(i0:I32x4, i1:I32x4, i2:I32x4, i3:I32x4, i4:I32x4, i5:I32x4, i6:I32x4, i7:I32x4, shift:Int, round:Int):Eight {
		var z2 = i2, z3 = i6;
		var z1 = (z2 + z3) * c(4433);
		var tmp2 = z1 + z3 * c(-15137);
		var tmp3 = z1 + z2 * c(6270);
		var tmp0 = (i0 + i4) << 13;
		var tmp1 = (i0 - i4) << 13;
		var tmp10 = tmp0 + tmp3, tmp13 = tmp0 - tmp3, tmp11 = tmp1 + tmp2, tmp12 = tmp1 - tmp2;
		tmp0 = i7;
		tmp1 = i5;
		tmp2 = i3;
		tmp3 = i1;
		z1 = tmp0 + tmp3;
		z2 = tmp1 + tmp2;
		z3 = tmp0 + tmp2;
		var z4 = tmp1 + tmp3;
		var z5 = (z3 + z4) * c(9633);
		tmp0 = tmp0 * c(2446);
		tmp1 = tmp1 * c(16819);
		tmp2 = tmp2 * c(25172);
		tmp3 = tmp3 * c(12299);
		z1 = z1 * c(-7373);
		z2 = z2 * c(-20995);
		z3 = z3 * c(-16069) + z5;
		z4 = z4 * c(-3196) + z5;
		tmp0 = tmp0 + z1 + z3;
		tmp1 = tmp1 + z2 + z4;
		tmp2 = tmp2 + z2 + z3;
		tmp3 = tmp3 + z1 + z4;
		var k = c(round), e = new Eight();
		e.v0 = (tmp10 + tmp3 + k) >> shift;
		e.v7 = (tmp10 - tmp3 + k) >> shift;
		e.v1 = (tmp11 + tmp2 + k) >> shift;
		e.v6 = (tmp11 - tmp2 + k) >> shift;
		e.v2 = (tmp12 + tmp1 + k) >> shift;
		e.v5 = (tmp12 - tmp1 + k) >> shift;
		e.v3 = (tmp13 + tmp0 + k) >> shift;
		e.v4 = (tmp13 - tmp0 + k) >> shift;
		return e;
	}

	// row k's coefficients (lanes 0-3, or 4-7), dequantized
	static inline function row(coef:ReadOnlySpan<UInt8>, at:Int, q:ReadOnlySpan<UInt8>, k:Int, hi:Bool):I32x4 {
		var r = I16x8.loadSpan(coef, at + 16 * k);
		return (hi ? I32x4.extendHigh(r) : I32x4.extendLow(r)) * I32x4.loadSpan(q, 32 * k + (hi ? 16 : 0));
	}

	// lanes 0-3 (r 0, 1) or 2-3 (r 2, 3) of the 4x4 transpose of a, b, c, d: row r
	static inline function t4(a:I32x4, b:I32x4, c:I32x4, d:I32x4, r:Int):I32x4 {
		var t0 = r < 2 ? a.shuffle(b, 0, 4, 1, 5) : a.shuffle(b, 2, 6, 3, 7);
		var t1 = r < 2 ? c.shuffle(d, 0, 4, 1, 5) : c.shuffle(d, 2, 6, 3, 7);
		return (r & 1) == 0 ? t0.shuffle(t1, 0, 1, 4, 5) : t0.shuffle(t1, 2, 3, 6, 7);
	}

	static function idct(coef:ReadOnlySpan<UInt8>, at:Int, q:ReadOnlySpan<UInt8>, out:Span<UInt8>, o:Int) {
		// pass 1: the columns 0-3 (l) and 4-7 (h); w*.vr: the workspace's row r
		var wl = butterfly(row(coef, at, q, 0, false), row(coef, at, q, 1, false), row(coef, at, q, 2, false), row(coef, at, q, 3, false),
			row(coef, at, q, 4, false), row(coef, at, q, 5, false), row(coef, at, q, 6, false), row(coef, at, q, 7, false), 11, 1024);
		var wh = butterfly(row(coef, at, q, 0, true), row(coef, at, q, 1, true), row(coef, at, q, 2, true), row(coef, at, q, 3, true),
			row(coef, at, q, 4, true), row(coef, at, q, 5, true), row(coef, at, q, 6, true), row(coef, at, q, 7, true), 11, 1024);
		// pass 2: the rows 0-3 (l) and 4-7 (h), as lanes: the workspace's columns j
		inline function col(j:Int, hi:Bool):I32x4 {
			return if (!hi) {
				j < 4 ? t4(wl.v0, wl.v1, wl.v2, wl.v3, j) : t4(wh.v0, wh.v1, wh.v2, wh.v3, j - 4);
			} else {
				j < 4 ? t4(wl.v4, wl.v5, wl.v6, wl.v7, j) : t4(wh.v4, wh.v5, wh.v6, wh.v7, j - 4);
			}
		}
		var ol = butterfly(col(0, false), col(1, false), col(2, false), col(3, false), col(4, false), col(5, false), col(6, false), col(7, false), 18,
			131072);
		var oh = butterfly(col(0, true), col(1, true), col(2, true), col(3, true), col(4, true), col(5, true), col(6, true), col(7, true), 18, 131072);
		// output column j's eight rows as 16-bit lanes (+128), transposed to rows, narrowed to bytes (the clamp)
		var m = c(128);
		var a0 = I16x8.narrow(ol.v0 + m, oh.v0 + m), a1 = I16x8.narrow(ol.v1 + m, oh.v1 + m), a2 = I16x8.narrow(ol.v2 + m, oh.v2 + m),
			a3 = I16x8.narrow(ol.v3 + m, oh.v3 + m);
		var a4 = I16x8.narrow(ol.v4 + m, oh.v4 + m), a5 = I16x8.narrow(ol.v5 + m, oh.v5 + m), a6 = I16x8.narrow(ol.v6 + m, oh.v6 + m),
			a7 = I16x8.narrow(ol.v7 + m, oh.v7 + m);
		var b0 = a0.shuffle(a1, 0, 8, 1, 9, 2, 10, 3, 11), b1 = a0.shuffle(a1, 4, 12, 5, 13, 6, 14, 7, 15);
		var b2 = a2.shuffle(a3, 0, 8, 1, 9, 2, 10, 3, 11), b3 = a2.shuffle(a3, 4, 12, 5, 13, 6, 14, 7, 15);
		var b4 = a4.shuffle(a5, 0, 8, 1, 9, 2, 10, 3, 11), b5 = a4.shuffle(a5, 4, 12, 5, 13, 6, 14, 7, 15);
		var b6 = a6.shuffle(a7, 0, 8, 1, 9, 2, 10, 3, 11), b7 = a6.shuffle(a7, 4, 12, 5, 13, 6, 14, 7, 15);
		var c0 = b0.asI32x4().shuffle(b2.asI32x4(), 0, 4, 1, 5), c1 = b0.asI32x4().shuffle(b2.asI32x4(), 2, 6, 3, 7);
		var c2 = b1.asI32x4().shuffle(b3.asI32x4(), 0, 4, 1, 5), c3 = b1.asI32x4().shuffle(b3.asI32x4(), 2, 6, 3, 7);
		var c4 = b4.asI32x4().shuffle(b6.asI32x4(), 0, 4, 1, 5), c5 = b4.asI32x4().shuffle(b6.asI32x4(), 2, 6, 3, 7);
		var c6 = b5.asI32x4().shuffle(b7.asI32x4(), 0, 4, 1, 5), c7 = b5.asI32x4().shuffle(b7.asI32x4(), 2, 6, 3, 7);
		var r0 = c0.asI64x2().shuffle(c4.asI64x2(), 0, 2).asI16x8(), r1 = c0.asI64x2().shuffle(c4.asI64x2(), 1, 3).asI16x8();
		var r2 = c1.asI64x2().shuffle(c5.asI64x2(), 0, 2).asI16x8(), r3 = c1.asI64x2().shuffle(c5.asI64x2(), 1, 3).asI16x8();
		var r4 = c2.asI64x2().shuffle(c6.asI64x2(), 0, 2).asI16x8(), r5 = c2.asI64x2().shuffle(c6.asI64x2(), 1, 3).asI16x8();
		var r6 = c3.asI64x2().shuffle(c7.asI64x2(), 0, 2).asI16x8(), r7 = c3.asI64x2().shuffle(c7.asI64x2(), 1, 3).asI16x8();
		U8x16.narrow(r0, r1).storeSpan(out, o);
		U8x16.narrow(r2, r3).storeSpan(out, o + 16);
		U8x16.narrow(r4, r5).storeSpan(out, o + 32);
		U8x16.narrow(r6, r7).storeSpan(out, o + 48);
	}

	// ---- YCbCr to RGBA: 16 pixels a step in four groups of 32-bit lanes,
	// saturated to bytes, interleaved

	// group g of four of 16 bytes, widened
	static inline function y32(v:U8x16, g:Int):I32x4 {
		var h = g < 2 ? U16x8.extendLow(v) : U16x8.extendHigh(v);
		return ((g & 1) == 0 ? U32x4.extendLow(h) : U32x4.extendHigh(h)).asI32x4();
	}

	static inline function red(y:I32x4, r:I32x4):I32x4
		return y + ((c(91881) * r + c(32768)) >> 16);

	static inline function green(y:I32x4, b:I32x4, r:I32x4):I32x4
		return y + ((c(-22554) * b + c(-46802) * r + c(32768)) >> 16);

	static inline function blue(y:I32x4, b:I32x4):I32x4
		return y + ((c(116130) * b + c(32768)) >> 16);

	static inline function bytes(a:I32x4, b:I32x4, c:I32x4, d:I32x4):U8x16
		return U8x16.narrow(I16x8.narrow(a, b), I16x8.narrow(c, d));

	public static function yccRgba(y:ReadOnlySpan<UInt8>, cb:ReadOnlySpan<UInt8>, cr:ReadOnlySpan<UInt8>, out:Span<UInt8>) {
		var n = y.length;
		if (cb.length != n || cr.length != n || out.length < 4 * n) return;
		var k128 = c(128);
		var alpha = U8x16.splat(255);
		var i = 0;
		while (i + 16 <= n) {
			var yv = U8x16.loadSpan(y, i), bv = U8x16.loadSpan(cb, i), rv = U8x16.loadSpan(cr, i);
			var y0 = y32(yv, 0), y1 = y32(yv, 1), y2 = y32(yv, 2), y3 = y32(yv, 3);
			var b0 = y32(bv, 0) - k128, b1 = y32(bv, 1) - k128, b2 = y32(bv, 2) - k128, b3 = y32(bv, 3) - k128;
			var r0 = y32(rv, 0) - k128, r1 = y32(rv, 1) - k128, r2 = y32(rv, 2) - k128, r3 = y32(rv, 3) - k128;
			var R = bytes(red(y0, r0), red(y1, r1), red(y2, r2), red(y3, r3));
			var G = bytes(green(y0, b0, r0), green(y1, b1, r1), green(y2, b2, r2), green(y3, b3, r3));
			var B = bytes(blue(y0, b0), blue(y1, b1), blue(y2, b2), blue(y3, b3));
			var rg0 = R.shuffle(G, 0, 16, 1, 17, 2, 18, 3, 19, 4, 20, 5, 21, 6, 22, 7, 23), rg1 = R.shuffle(G, 8, 24, 9, 25, 10, 26, 11, 27, 12, 28, 13, 29, 14, 30, 15, 31);
			var ba0 = B.shuffle(alpha, 0, 16, 1, 17, 2, 18, 3, 19, 4, 20, 5, 21, 6, 22, 7, 23), ba1 = B.shuffle(alpha, 8, 24, 9, 25, 10, 26, 11, 27, 12, 28, 13, 29, 14, 30, 15, 31);
			var p = 4 * i;
			rg0.asU16x8().shuffle(ba0.asU16x8(), 0, 8, 1, 9, 2, 10, 3, 11).storeSpan(out, p);
			rg0.asU16x8().shuffle(ba0.asU16x8(), 4, 12, 5, 13, 6, 14, 7, 15).storeSpan(out, p + 16);
			rg1.asU16x8().shuffle(ba1.asU16x8(), 0, 8, 1, 9, 2, 10, 3, 11).storeSpan(out, p + 32);
			rg1.asU16x8().shuffle(ba1.asU16x8(), 4, 12, 5, 13, 6, 14, 7, 15).storeSpan(out, p + 48);
			i += 16;
		}
		// (the rest, one by one)
		while (i < n) {
			var yy:Int = y[i], b = cb[i] - 128, r = cr[i] - 128;
			out[4 * i] = clamp(yy + ((91881 * r + 32768) >> 16));
			out[4 * i + 1] = clamp(yy + ((-22554 * b - 46802 * r + 32768) >> 16));
			out[4 * i + 2] = clamp(yy + ((116130 * b + 32768) >> 16));
			out[4 * i + 3] = 255;
			i++;
		}
	}

	static inline function clamp(v:Int):Int
		return v < 0 ? 0 : v > 255 ? 255 : v;

	// ---- the bilinear resize: an output pixel a step, its two source
	// pixels' channels paired and weighted with one dot product per row

	// the 8 bytes at o, as 16-bit lanes p0.c0, p1.c0, p0.c1, p1.c1, ...
	static inline function pairs(s:ReadOnlySpan<UInt8>, o:Int):I16x8
		return U16x8.extendLow(U8x16.loadSpan64(s, o).shuffle(U8x16.zero(), 0, 4, 1, 5, 2, 6, 3, 7, 16, 16, 16, 16, 16, 16, 16, 16)).asI16x8();

	static function resizeRow(t:ReadOnlySpan<UInt8>, b:ReadOnlySpan<UInt8>, fy:Int, xofs:ReadOnlySpan<Int>, xw:ReadOnlySpan<Int>, dst:Span<UInt8>) {
		var w2 = xofs.length;
		if (xw.length != w2 || dst.length < 4 * w2) return;
		var wy0 = c(256 - fy), wy1 = c(fy), half = c(32768);
		for (x in 0...w2) {
			var o = xofs[x], fx = xw[x];
			// (256 - fx, fx) in each pair of 16-bit lanes
			var wx = c((fx << 16) | (256 - fx)).asI16x8();
			var r = (pairs(t, o).dot(wx) * wy0 + pairs(b, o).dot(wx) * wy1 + half) >> 16;
			var p = I16x8.narrow(r, r);
			U8x16.narrow(p, p).storeSpan32(dst, 4 * x);
		}
	}

	public static function resizeAll(src:ReadOnlySpan<UInt8>, w:Int, h:Int, xofsB:ReadOnlySpan<UInt8>, xwB:ReadOnlySpan<UInt8>, dst:Span<UInt8>, w2:Int,
			h2:Int) {
		var xofs:ReadOnlySpan<Int> = xofsB.reinterpret(), xw:ReadOnlySpan<Int> = xwB.reinterpret();
		var row = w * 4;
		for (y in 0...h2) {
			var num = Std.int(y * (h - 1) * 256 / (h2 - 1)), sy = num >> 8, fy = num & 255;
			if (sy >= h - 1) {
				sy = h - 2;
				fy = 256;
			}
			resizeRow(src.sub(sy * row, row), src.sub((sy + 1) * row, row), fy, xofs, xw, dst.sub(y * w2 * 4, w2 * 4));
		}
	}
}
