// The C library CBindingsStrings.hx binds: C strings in and out.
#include <stddef.h>

int cs_len(const char *s);
const char *cs_greet(void);
char *cs_upper(const char *s);
void cs_free(char *p);
const char *cs_none(void);
int cs_join(const char *a, const char *b, char *out, size_t n);
