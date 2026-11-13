// The C library CBindingsArrays.hx binds: arrays of structs and scalars.
#include <stddef.h>

struct ca_rect { double x, y, w, h; };

double ca_area(const struct ca_rect *r, size_t n);
void ca_grow(struct ca_rect *r, size_t n, double d);
int ca_max(const int *v, int n);
void ca_iota(double *v, int n);
