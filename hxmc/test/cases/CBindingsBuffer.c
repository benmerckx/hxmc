// The C side of CBindingsBuffer.hx: fills, sums, and calls back while it holds the bytes.
#include "CBindingsBuffer.h"

void bb_fill(uint8_t *p, size_t n, int v) {
	for (size_t i = 0; i < n; i++) p[i] = (uint8_t)(v + i);
}

int64_t bb_sum(const uint8_t *p, size_t n) {
	int64_t s = 0;
	for (size_t i = 0; i < n; i++) s += p[i];
	return s;
}

int bb_with(uint8_t *p, size_t n, void (*f)(void)) {
	f();
	p[0] = 42;
	return (int)n;
}
