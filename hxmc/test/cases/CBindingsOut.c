// The C side of CBindingsOut.hx.
#include "CBindingsOut.h"

int co_divmod(int a, int b, struct co_qr *out) {
	if (b == 0) return -1;
	out->q = a / b;
	out->r = a % b;
	return 0;
}

void co_minmax(int a, int b, int c, int *min, int *max) {
	int lo = a, hi = a;
	if (b < lo) lo = b;
	if (c < lo) lo = c;
	if (b > hi) hi = b;
	if (c > hi) hi = c;
	*min = lo;
	*max = hi;
}

struct co_qr co_make(int q, int r) {
	struct co_qr x = {q, r};
	return x;
}

int co_total(struct co_qr qr) { return qr.q * 10 + qr.r; }

int co_scale(const struct co_qr *in, int k) { return (in->q + in->r) * k; }

void co_twice(double *v) { *v *= 2; }
