#include <stdlib.h>

#ifndef API_MAJOR
#define API_MAJOR 1
#endif
#ifndef API_STATUS
#define API_STATUS 0
#endif

#ifndef OMIT_API_VERSION
int litert_lm_get_api_version(int *major, int *minor, int *patch) {
  *major = API_MAJOR;
  *minor = 0;
  *patch = 0;
  return API_STATUS;
}
#endif

// A missing gate must fail the test process before an incompatible call can
// accidentally look like a supported engine initialization.
void *litert_lm_engine_settings_create(void) { abort(); }
