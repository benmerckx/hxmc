// The C side of CBindingsArrays.hx.
#include "CBindingsArrays.h"

double ca_area(const struct ca_rect *r, size_t n) {
	double a = 0;
	for (size_t i = 0; i < n; i++) a += r[i].w * r[i].h;
	return a;
}

void ca_grow(struct ca_rect *r, size_t n, double d) {
	for (size_t i = 0; i < n; i++) {
		r[i].x -= d;
		r[i].y -= d;
		r[i].w += 2 * d;
		r[i].h += 2 * d;
	}
}

int ca_max(const int *v, int n) {
	int m = v[0];
	for (int i = 1; i < n; i++)
		if (v[i] > m) m = v[i];
	return m;
}

void ca_iota(double *v, int n) {
	for (int i = 0; i < n; i++) v[i] = i * 0.5;
}
