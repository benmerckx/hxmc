// The C side of SimdFfi.hx, built per target by the corpus harness (zig cc):
// C's native 128-bit vectors (the compilers' vector_size(16) types, which
// each ABI passes as __m128 or float32x4_t) by value, both ways.
#include <stdint.h>
typedef float v4f __attribute__((vector_size(16)));
typedef int32_t v4i __attribute__((vector_size(16)));
typedef double v2d __attribute__((vector_size(16)));

v4f v_madd(v4f a, v4f b, v4f c) { return a * b + c; }
v4i v_mix(int32_t k, v4i a, double d, v4i b) { return a + b * k + (int32_t)d; }
double v_sum(v4f a, v2d b) { return a[0] + 2 * a[1] + 3 * a[2] + 4 * a[3] + 10 * b[0] + 100 * b[1]; }
v4f v_make(float x, float y, float z, float w) { v4f r = {x, y, z, w}; return r; }
v2d v_swap(v2d a) { v2d r = {a[1], a[0]}; return r; }
// eight vectors: every vector argument register, and a double after them on the stack
v4i v_eight(v4i a, v4i b, v4i c, v4i d, v4i e, v4i f, v4i g, v4i h) { return a + 2 * b + 3 * c + 4 * d + 5 * e + 6 * f + 7 * g + 8 * h; }
// called back: vectors into and out of a Haxe function
double v_cb(v4f (*f)(v4f, int32_t, v4f)) {
	v4f a = {1, 2, 3, 4}, b = {0.5f, 0.25f, 0.125f, -1};
	v4f r = f(a, 3, b);
	return r[0] + 10 * r[1] + 100 * r[2] + 1000 * r[3];
}
