// The scalar C side of SimdBench.hx (docs/plans/simd.md, "Baseline"): the
// same three kernels, the same data and the same checksums, so that hxmc's
// code can be compared with the system compiler's at -O2, at -O3 without the
// vectorizers and at -O3 with them. `make bench-simd` builds and runs every
// variant; by hand:
//   cc -O2 -o simd_bench simd_bench.c && ./simd_bench [scale]
// Prints one line per kernel: its name, the median of 7 runs in ns per unit
// (an 8x8 block, an output pixel), the checksum of its output.
// The kernels are not inlined into the timing loop, and each pass ends with a
// compiler barrier: inlined, gcc -O3 ran the colour conversion's passes as
// one (0.6 ns a pixel instead of 2.6).
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static uint32_t rng = 0x9E3779B9u;

static uint32_t next(void) {
	rng ^= rng << 13;
	rng ^= rng >> 17;
	rng ^= rng << 5;
	return rng;
}

static double now(void) {
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec * 1e-9;
}

static int32_t checksum(const uint8_t *p, int n) {
	uint32_t h = 0;
	for (int i = 0; i < n; i++) h = (h << 5) - h + p[i];
	return (int32_t)h;
}

static inline int clamp255(int v) { return v < 0 ? 0 : v > 255 ? 255 : v; }

// ---- 8x8 inverse DCT: libjpeg's jpeg_idct_islow (Loeffler, Ligtenberg and
// Moschytz; jidctint.c), dequantizing, a column pass into an int workspace,
// a row pass to samples clamped to 0..255; with the column pass's shortcut
// for an all-zero AC column

#define CONST_BITS 13
#define PASS1_BITS 2
#define FIX_0_298631336 2446
#define FIX_0_390180644 3196
#define FIX_0_541196100 4433
#define FIX_0_765366865 6270
#define FIX_0_899976223 7373
#define FIX_1_175875602 9633
#define FIX_1_501321110 12299
#define FIX_1_847759065 15137
#define FIX_1_961570560 16069
#define FIX_2_053119869 16819
#define FIX_2_562915447 20995
#define FIX_3_072711026 25172
#define DESCALE(x, n) (((x) + (1 << ((n)-1))) >> (n))

static void idct_islow(const int16_t *in, const int32_t *q, uint8_t *out) {
	int32_t ws[64];
	for (int c = 0; c < 8; c++) {
		const int16_t *s = in + c;
		const int32_t *qq = q + c;
		int32_t *w = ws + c;
		if (s[8] == 0 && s[16] == 0 && s[24] == 0 && s[32] == 0 && s[40] == 0 && s[48] == 0 && s[56] == 0) {
			int32_t dc = (s[0] * qq[0]) << PASS1_BITS;
			for (int k = 0; k < 8; k++) w[8 * k] = dc;
			continue;
		}
		int32_t z2 = s[16] * qq[16], z3 = s[48] * qq[48];
		int32_t z1 = (z2 + z3) * FIX_0_541196100;
		int32_t tmp2 = z1 + z3 * -FIX_1_847759065;
		int32_t tmp3 = z1 + z2 * FIX_0_765366865;
		z2 = s[0] * qq[0];
		z3 = s[32] * qq[32];
		int32_t tmp0 = (z2 + z3) << CONST_BITS;
		int32_t tmp1 = (z2 - z3) << CONST_BITS;
		int32_t tmp10 = tmp0 + tmp3, tmp13 = tmp0 - tmp3, tmp11 = tmp1 + tmp2, tmp12 = tmp1 - tmp2;
		tmp0 = s[56] * qq[56];
		tmp1 = s[40] * qq[40];
		tmp2 = s[24] * qq[24];
		tmp3 = s[8] * qq[8];
		z1 = tmp0 + tmp3;
		z2 = tmp1 + tmp2;
		z3 = tmp0 + tmp2;
		int32_t z4 = tmp1 + tmp3;
		int32_t z5 = (z3 + z4) * FIX_1_175875602;
		tmp0 *= FIX_0_298631336;
		tmp1 *= FIX_2_053119869;
		tmp2 *= FIX_3_072711026;
		tmp3 *= FIX_1_501321110;
		z1 *= -FIX_0_899976223;
		z2 *= -FIX_2_562915447;
		z3 = z3 * -FIX_1_961570560 + z5;
		z4 = z4 * -FIX_0_390180644 + z5;
		tmp0 += z1 + z3;
		tmp1 += z2 + z4;
		tmp2 += z2 + z3;
		tmp3 += z1 + z4;
		w[0] = DESCALE(tmp10 + tmp3, CONST_BITS - PASS1_BITS);
		w[56] = DESCALE(tmp10 - tmp3, CONST_BITS - PASS1_BITS);
		w[8] = DESCALE(tmp11 + tmp2, CONST_BITS - PASS1_BITS);
		w[48] = DESCALE(tmp11 - tmp2, CONST_BITS - PASS1_BITS);
		w[16] = DESCALE(tmp12 + tmp1, CONST_BITS - PASS1_BITS);
		w[40] = DESCALE(tmp12 - tmp1, CONST_BITS - PASS1_BITS);
		w[24] = DESCALE(tmp13 + tmp0, CONST_BITS - PASS1_BITS);
		w[32] = DESCALE(tmp13 - tmp0, CONST_BITS - PASS1_BITS);
	}
	for (int r = 0; r < 8; r++) {
		const int32_t *w = ws + 8 * r;
		uint8_t *o = out + 8 * r;
		int32_t z2 = w[2], z3 = w[6];
		int32_t z1 = (z2 + z3) * FIX_0_541196100;
		int32_t tmp2 = z1 + z3 * -FIX_1_847759065;
		int32_t tmp3 = z1 + z2 * FIX_0_765366865;
		int32_t tmp0 = (w[0] + w[4]) << CONST_BITS;
		int32_t tmp1 = (w[0] - w[4]) << CONST_BITS;
		int32_t tmp10 = tmp0 + tmp3, tmp13 = tmp0 - tmp3, tmp11 = tmp1 + tmp2, tmp12 = tmp1 - tmp2;
		tmp0 = w[7];
		tmp1 = w[5];
		tmp2 = w[3];
		tmp3 = w[1];
		z1 = tmp0 + tmp3;
		z2 = tmp1 + tmp2;
		z3 = tmp0 + tmp2;
		int32_t z4 = tmp1 + tmp3;
		int32_t z5 = (z3 + z4) * FIX_1_175875602;
		tmp0 *= FIX_0_298631336;
		tmp1 *= FIX_2_053119869;
		tmp2 *= FIX_3_072711026;
		tmp3 *= FIX_1_501321110;
		z1 *= -FIX_0_899976223;
		z2 *= -FIX_2_562915447;
		z3 = z3 * -FIX_1_961570560 + z5;
		z4 = z4 * -FIX_0_390180644 + z5;
		tmp0 += z1 + z3;
		tmp1 += z2 + z4;
		tmp2 += z2 + z3;
		tmp3 += z1 + z4;
		const int S = CONST_BITS + PASS1_BITS + 3;
		o[0] = clamp255(DESCALE(tmp10 + tmp3, S) + 128);
		o[7] = clamp255(DESCALE(tmp10 - tmp3, S) + 128);
		o[1] = clamp255(DESCALE(tmp11 + tmp2, S) + 128);
		o[6] = clamp255(DESCALE(tmp11 - tmp2, S) + 128);
		o[2] = clamp255(DESCALE(tmp12 + tmp1, S) + 128);
		o[5] = clamp255(DESCALE(tmp12 - tmp1, S) + 128);
		o[3] = clamp255(DESCALE(tmp13 + tmp0, S) + 128);
		o[4] = clamp255(DESCALE(tmp13 - tmp0, S) + 128);
	}
}

__attribute__((noinline)) static void idct_all(const int16_t *coef, const int32_t *q, uint8_t *out, int blocks) {
	for (int b = 0; b < blocks; b++) idct_islow(coef + 64 * b, q, out + 64 * b);
}

// ---- YCbCr to RGBA (JFIF's full-range BT.601 in 16-bit fixed point, as
// libjpeg's jdcolor.c computes it, without its tables)

__attribute__((noinline)) static void ycc_rgba(const uint8_t *y, const uint8_t *cb, const uint8_t *cr, uint8_t *out, int n) {
	for (int i = 0; i < n; i++) {
		int yy = y[i], b = cb[i] - 128, r = cr[i] - 128;
		out[4 * i] = clamp255(yy + ((91881 * r + 32768) >> 16));
		out[4 * i + 1] = clamp255(yy + ((-22554 * b - 46802 * r + 32768) >> 16));
		out[4 * i + 2] = clamp255(yy + ((116130 * b + 32768) >> 16));
		out[4 * i + 3] = 255;
	}
}

// ---- bilinear resampling of RGBA, one output row: the two source rows at
// byte offsets top and bot, the vertical weight fy (0..256), per output
// pixel its left source pixel's byte offset and horizontal weight (0..256)

static void resize_row(const uint8_t *src, int top, int bot, int fy, const int32_t *xofs, const int32_t *xw, uint8_t *dst,
		int w2) {
	for (int x = 0; x < w2; x++) {
		int o = xofs[x], fx = xw[x];
		for (int c = 0; c < 4; c++) {
			int t = src[top + o + c] * (256 - fx) + src[top + o + 4 + c] * fx;
			int b = src[bot + o + c] * (256 - fx) + src[bot + o + 4 + c] * fx;
			dst[4 * x + c] = (t * (256 - fy) + b * fy + 32768) >> 16;
		}
	}
}

__attribute__((noinline)) static void resize_all(const uint8_t *src, int w, int h, const int32_t *xofs, const int32_t *xw, uint8_t *dst, int w2,
		int h2) {
	for (int y = 0; y < h2; y++) {
		int num = y * (h - 1) * 256 / (h2 - 1), sy = num >> 8, fy = num & 255;
		if (sy >= h - 1) {
			sy = h - 2;
			fy = 256;
		}
		resize_row(src, sy * w * 4, (sy + 1) * w * 4, fy, xofs, xw, dst + y * w2 * 4, w2);
	}
}

// ---- the driver

typedef struct {
	int blocks;
	int16_t *coef;
	int32_t q[64];
	uint8_t *idctOut;
	int pixels;
	uint8_t *y, *cb, *cr, *rgba;
	int w, h, w2, h2;
	uint8_t *src, *dst;
	int32_t *xofs, *xw;
} Data;

static int cmp(const void *a, const void *b) {
	double x = *(const double *)a, y = *(const double *)b;
	return x < y ? -1 : x > y;
}

#define TIME(name, units, passes, body, out, outLen) \
	do { \
		double r[7]; \
		for (int k = 0; k < 7; k++) { \
			double t0 = now(); \
			for (int p = 0; p < (passes); p++) { \
				body; \
				__asm__ volatile("" ::: "memory"); \
			} \
			r[k] = (now() - t0) * 1e9 / ((double)(units) * (passes)); \
		} \
		qsort(r, 7, sizeof(double), cmp); \
		printf("%s %.3f %d\n", name, r[3], checksum(out, outLen)); \
	} while (0)

int main(int argc, char **argv) {
	int scale = argc > 1 ? atoi(argv[1]) : 1;
	Data d;
	// 4096 blocks (a 512x512 plane): DC in -512..511, an AC coefficient in
	// -32..31 with a chance that falls with its index, else zero
	d.blocks = 4096;
	d.coef = malloc(d.blocks * 64 * sizeof(int16_t));
	for (int i = 0; i < d.blocks * 64; i++) {
		int k = i & 63;
		if (k == 0) d.coef[i] = (int16_t)((int)(next() & 1023) - 512);
		else if (next() % (k + 2) < 2) d.coef[i] = (int16_t)((int)(next() & 63) - 32);
		else d.coef[i] = 0;
	}
	for (int k = 0; k < 64; k++) d.q[k] = 1 + 2 * ((k & 7) + (k >> 3));
	d.idctOut = malloc(d.blocks * 64);
	// a 1024x1024 image's planes
	d.pixels = 1024 * 1024;
	d.y = malloc(d.pixels);
	d.cb = malloc(d.pixels);
	d.cr = malloc(d.pixels);
	for (int i = 0; i < d.pixels; i++) {
		d.y[i] = next() & 255;
		d.cb[i] = next() & 255;
		d.cr[i] = next() & 255;
	}
	d.rgba = malloc(d.pixels * 4);
	// 1024x1024 RGBA up to 1536x1536
	d.w = 1024;
	d.h = 1024;
	d.w2 = 1536;
	d.h2 = 1536;
	d.src = malloc(d.w * d.h * 4);
	for (int i = 0; i < d.w * d.h * 4; i++) d.src[i] = next() & 255;
	d.dst = malloc(d.w2 * d.h2 * 4);
	d.xofs = malloc(d.w2 * sizeof(int32_t));
	d.xw = malloc(d.w2 * sizeof(int32_t));
	for (int x = 0; x < d.w2; x++) {
		int num = x * (d.w - 1) * 256 / (d.w2 - 1), sx = num >> 8, fx = num & 255;
		if (sx >= d.w - 1) {
			sx = d.w - 2;
			fx = 256;
		}
		d.xofs[x] = sx * 4;
		d.xw[x] = fx;
	}
	TIME("idct", d.blocks, 16 * scale, idct_all(d.coef, d.q, d.idctOut, d.blocks), d.idctOut, d.blocks * 64);
	TIME("ycc", d.pixels, 4 * scale, ycc_rgba(d.y, d.cb, d.cr, d.rgba, d.pixels), d.rgba, d.pixels * 4);
	TIME("resize", d.w2 * d.h2, 2 * scale, resize_all(d.src, d.w, d.h, d.xofs, d.xw, d.dst, d.w2, d.h2), d.dst,
			d.w2 * d.h2 * 4);
	return 0;
}
