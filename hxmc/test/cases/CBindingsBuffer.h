// The C library CBindingsBuffer.hx binds: functions over a caller's bytes.
#include <stddef.h>
#include <stdint.h>

void bb_fill(uint8_t *p, size_t n, int v);
int64_t bb_sum(const uint8_t *p, size_t n);
int bb_with(uint8_t *p, size_t n, void (*f)(void));
