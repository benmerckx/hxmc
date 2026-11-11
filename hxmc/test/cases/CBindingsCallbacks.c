// The C side of CBindingsCallbacks.hx: asks the source for its text, a
// stretch at a time, and tells the sink each run of units below 0x100
// (script 25) or not (31). Returns runs * 1000 + units.
#include <stddef.h>
#include "CBindingsCallbacks.h"

int cb_analyze(void *source, cb_text_at text_at, void *sink, cb_set_script set_script) {
	uint32_t pos = 0;
	int runs = 0;
	for (;;) {
		const uint16_t *t = NULL;
		uint32_t len = 0;
		if (text_at(source, pos, &t, &len) != 0 || len == 0 || !t) break;
		uint32_t i = 0;
		while (i < len) {
			uint32_t j = i;
			int latin = t[i] < 0x100;
			while (j < len && (t[j] < 0x100) == latin) j++;
			struct cb_analysis a = {latin ? 25 : 31, 0};
			set_script(sink, pos + i, j - i, &a);
			runs++;
			i = j;
		}
		pos += len;
	}
	return runs * 1000 + (int)pos;
}
