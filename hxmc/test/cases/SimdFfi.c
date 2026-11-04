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
// structs with vectors in them, by value both ways: one vector (System V:
// xmm0; AAPCS64: an aggregate of one; Win64: by address), three and four
// vectors (AAPCS64: q0-q2, q0-q3; else memory), a vector among scalars
// (memory everywhere, 16-byte aligned; on the stack after seven words on
// System V)
typedef struct { v4f v; } wrap;
typedef struct { v4i a, b, c; } trio;
typedef struct { v4f a, b, c, d; } quad;
typedef struct { int32_t k; v4i v; double d; } mixed;

wrap w_scale(wrap a, float k) { wrap r = {a.v * k}; return r; }
trio t_rot(trio x, int32_t n) { trio r = {x.b + n, x.c + n, x.a + n}; return r; }
quad q_add(quad x, wrap y) { quad r = {x.a + y.v, x.b + y.v * 2, x.c + y.v * 3, x.d + y.v * 4}; return r; }
mixed m_step(int32_t pre, mixed m, wrap w) {
	mixed r = {m.k + pre, m.v * 3 + (v4i){m.k, 0, 0, pre}, m.d + w.v[0] + w.v[3]};
	return r;
}
double m_far(int32_t a, int32_t b, int32_t c, int32_t d, int32_t e, int32_t f, int32_t g, mixed m) {
	return a + 2 * b + 3 * c + 4 * d + 5 * e + 6 * f + 7 * g + 1000 * m.k + 10000 * (m.v[0] + m.v[1] + m.v[2] + m.v[3]) + m.d;
}
// called back with them
double s_cb(wrap (*f)(wrap, mixed, trio), quad (*g)(quad)) {
	wrap w = {{1, 2, 3, 4}};
	mixed m = {5, {6, 7, 8, 9}, 0.5};
	trio t = {{1, 1, 1, 1}, {2, 2, 2, 2}, {3, 3, 3, 3}};
	wrap r = f(w, m, t);
	quad q = {{1, 2, 3, 4}, {5, 6, 7, 8}, {9, 10, 11, 12}, {13, 14, 15, 16}};
	quad s = g(q);
	return r.v[0] + 10 * r.v[1] + 100 * r.v[2] + 1000 * r.v[3] + s.a[0] + s.b[1] + s.c[2] + s.d[3];
}
// a global's bytes through its symbol (MirBuild folds the address into the
// accesses: arm64's :lo12: offsets of 16, 8 and 4 bytes)
v4i v_global[3] = {{1, 2, 3, 4}, {5, 6, 7, 8}, {9, 10, 11, 12}};
