// The dynamic library of CVars.hx (a DLL on Windows, a dylib on macOS; an
// object linked statically on Linux), built by the corpus harness (zig cc).
#include <stdint.h>
#ifdef _WIN32
#define EXPORT __declspec(dllexport)
#else
#define EXPORT __attribute__((visibility("default")))
#endif
EXPORT int32_t dyn_count = 5;
EXPORT const char *dyn_title = "dynamic";
EXPORT int32_t dyn_get_count(void) { return dyn_count; }
