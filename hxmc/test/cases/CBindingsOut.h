// The C library CBindingsOut.hx binds: out-parameters and structs by value.
#include <stdint.h>

struct co_qr { int32_t q; int32_t r; };

int co_divmod(int a, int b, struct co_qr *out);
void co_minmax(int a, int b, int c, int *min, int *max);
struct co_qr co_make(int q, int r);
int co_total(struct co_qr qr);
int co_scale(const struct co_qr *in, int k);
void co_twice(double *v);
