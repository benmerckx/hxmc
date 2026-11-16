// The C library CBindings.hx binds: what the header check compiles its
// declarations against (make native-check NATIVE=header), and what CBindings.c defines.
#include <stddef.h>
#include <stdint.h>

struct cb_qr { int32_t q; int32_t r; };
struct cb_obj;

int64_t cb_sum(const uint8_t *p, size_t n);
void cb_fill(uint8_t *p, int v, size_t n);
int cb_divmod(int a, int b, struct cb_qr *out);
struct cb_obj *cb_open(int v);
int cb_value(struct cb_obj *o);
int cb_close(struct cb_obj *o);
int cb_apply(int (*f)(int), int v);
int *cb_counter(void);
int64_t cb_slow_sum(const uint8_t *p, size_t n);
