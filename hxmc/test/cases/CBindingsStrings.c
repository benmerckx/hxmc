// The C side of CBindingsStrings.hx: functions taking and returning C strings.
#include <stdlib.h>
#include <string.h>
#include "CBindingsStrings.h"

int cs_len(const char *s) { return s ? (int)strlen(s) : -1; }

const char *cs_greet(void) { return "hello from C"; }

char *cs_upper(const char *s) {
	size_t n = strlen(s);
	char *r = malloc(n + 1);
	for (size_t i = 0; i <= n; i++) r[i] = s[i] >= 'a' && s[i] <= 'z' ? s[i] - 32 : s[i];
	return r;
}

void cs_free(char *p) { free(p); }

const char *cs_none(void) { return NULL; }

int cs_join(const char *a, const char *b, char *out, size_t n) {
	size_t la = strlen(a), lb = strlen(b);
	if (la + lb + 1 > n) return -1;
	memcpy(out, a, la);
	memcpy(out + la, b, lb + 1);
	return (int)(la + lb);
}
