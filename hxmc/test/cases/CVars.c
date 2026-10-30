// The C variables of CVars.hx in an object linked statically, built by the
// corpus harness (zig cc).
#include <stdbool.h>
#include <stdint.h>
int32_t v_counter = 41;
double v_ratio = 1.5;
int8_t v_small = -3;
uint16_t v_wide = 65000;
bool v_flag = true;
float v_quarter = 2.25f;
int64_t v_big = 1234567890123LL;
const char *v_label = "label";
struct pt { int32_t x; double y; } v_origin = {7, 8.5};
int32_t v_get_counter(void) { return v_counter; }
double v_origin_y(void) { return v_origin.y; }
