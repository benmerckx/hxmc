// The C side of CBindingsNull.hx: NULL means something to each of these.
#include <stdlib.h>
#include "CBindingsNull.h"

struct cn_node { int v; };

int cn_sum(const int *p, int n) {
	if (!p) return -1;
	int s = 0;
	for (int i = 0; i < n; i++) s += p[i];
	return s;
}

int cn_apply(int (*f)(int), int v) { return f ? f(v) : v; }

struct cn_node *cn_new(int v) {
	struct cn_node *n = malloc(sizeof *n);
	n->v = v;
	return n;
}

int cn_value(const struct cn_node *n) { return n ? n->v : -1; }

int cn_child(struct cn_node *n, struct cn_node **out) {
	if (n->v >= 3) return -1;
	*out = cn_new(n->v + 1);
	return 0;
}

void cn_free(struct cn_node *n) { free(n); }
