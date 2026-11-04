import haxe.Timer;
import haxe.io.Bytes;
import haxe.ds.Vector;
import hxmc.ReadOnlySpan;
import hxmc.Span;
import hxmc.unsafe.Int16;
import hxmc.unsafe.UInt8;

// Image kernels for SIMD (docs/plans/simd.md, "Baseline"): an 8x8 integer
// inverse DCT over many blocks, YCbCr to RGBA over a large image, a
// bilinear resize, each as plain Haxe over Bytes and Vector (`bytes`) and as
// a kernel over spans (`span`), and the same in C (simd_bench.c, the same
// data and checksums). `make bench-simd` builds and runs every variant; by
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

