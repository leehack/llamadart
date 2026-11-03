#define litert_lm_engine_create fixture_public_base_engine_create
#include "c_api_v1_asr.c"
#undef litert_lm_engine_create

static int public_attempts, public_gpu_refusals, public_cpu_creates;
__attribute__((constructor)) static void fixture_public_loaded(void) {
  fputs("PUBLIC_FIXTURE_LOADED\n", stderr);
  fflush(stderr);
}
int fixture_public_engine_attempts(void) { return public_attempts; }
int fixture_public_gpu_refusals(void) { return public_gpu_refusals; }
int fixture_public_cpu_creates(void) { return public_cpu_creates; }
void fixture_public_reset(void) {
  assert(live == 0);
  public_attempts = public_gpu_refusals = public_cpu_creates = 0;
}
int litert_lm_engine_create(void *settings, void **out) {
  ++public_attempts;
  if (!strcmp(settings_text[1], "gpu")) {
    ++public_gpu_refusals;
    *out = NULL;
    snprintf(last_error, sizeof last_error,
             "Android GPU safety preflight refused the known fixture; use CPU.");
    return 9;
  }
  ++public_cpu_creates;
  return fixture_public_base_engine_create(settings, out);
}
