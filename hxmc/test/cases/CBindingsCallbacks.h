// The C side of CBindingsCallbacks.hx, shaped as DirectWrite's text
// analysis: a source C asks for text (two out-parameters), a sink it
// tells what it found (a struct by its address).
#include <stdint.h>

struct cb_analysis { uint16_t script; int32_t shapes; };

typedef int (*cb_text_at)(void *self, uint32_t pos, const uint16_t **text, uint32_t *len);
typedef int (*cb_set_script)(void *self, uint32_t pos, uint32_t len, const struct cb_analysis *a);

int cb_analyze(void *source, cb_text_at text_at, void *sink, cb_set_script set_script);
