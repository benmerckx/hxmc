// The C side of CBindings.hx: functions over buffers, out-structs, handles
// and callbacks, as a C library declares them.
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include "CBindings.h"

int64_t cb_sum(const uint8_t *p, size_t n) {
	int64_t s = 0;
	for (size_t i = 0; i < n; i++) s += p[i];
	return s;
}

void cb_fill(uint8_t *p, int v, size_t n) {
	for (size_t i = 0; i < n; i++) p[i] = (uint8_t)(v + i);
}

int cb_divmod(int a, int b, struct cb_qr *out) {
	if (b == 0) return -1;
	out->q = a / b;
	out->r = a % b;
	return 0;
}

struct cb_obj { int value; int open; };
static struct cb_obj objs[4];
static int closed;

struct cb_obj *cb_open(int v) {
	if (v < 0 || v >= 4) return NULL;
	objs[v].value = v * 100;
	objs[v].open = 1;
	return &objs[v];
}

int cb_value(struct cb_obj *o) { return o->open ? o->value : -1; }

int cb_close(struct cb_obj *o) {
	o->open = 0;
	return ++closed;
}

int cb_apply(int (*f)(int), int v) { return f(v) + f(v + 1); }

static int counter;

int *cb_counter(void) { return &counter; }

int64_t cb_slow_sum(const uint8_t *p, size_t n) { return cb_sum(p, n); }
