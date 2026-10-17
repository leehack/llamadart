#include <stdint.h>

#ifdef _WIN32
#define EXPORT __declspec(dllexport)
#else
#define EXPORT __attribute__((visibility("default")))
#endif

// No model is allocated: these addresses are identity tokens for Dart's
// liveness checks, and the sampler constructor is looked up but never called.
EXPORT void * llama_model_get_vocab(void * model) {
    return (void *) (uintptr_t) 0x2000;
}
EXPORT void llama_model_free(void * model) {}
EXPORT void llama_free(void * context) {}
EXPORT void * llama_dart_sampler_init_reasoning_budget(void) { return 0; }
