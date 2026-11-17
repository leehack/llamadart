#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>

#ifdef _WIN32
#define EXPORT __declspec(dllexport)
#else
#define EXPORT __attribute__((visibility("default")))
#endif

// Spy runtime: every export that returns or takes a llama.cpp struct by value
// counts its calls, and the build identity comes from FIXTURE_IDENTITY (unset
// reports a NULL identity). The test passes Dart's generated struct sizes; no
// field is read, so only the by-value calling convention matters.
typedef struct { uint64_t words[CONTEXT_PARAMS_SIZE / 8]; } context_params;
typedef struct { uint64_t words[MODEL_PARAMS_SIZE / 8]; } model_params;
typedef struct { uint8_t bytes[SAMPLER_CHAIN_PARAMS_SIZE]; } sampler_chain_params;
typedef struct { uint8_t bytes[MTMD_CONTEXT_PARAMS_SIZE]; } mtmd_context_params;
typedef struct { uint8_t bytes[MTMD_HELPER_INIT_OPT_SIZE]; } mtmd_helper_init_opt;
typedef struct {
    int32_t n_tokens;
    int32_t *token;
    float *embd;
    int32_t *pos;
    int32_t *n_seq_id;
    int32_t **seq_id;
    int8_t *logits;
} batch;

static int by_value_calls;
static void require_null(void *pointer) { if (pointer) abort(); }

EXPORT int fixture_by_value_calls(void) { return by_value_calls; }

#ifndef OMIT_IDENTITY
EXPORT const char *llama_dart_build_identity(void) { return getenv("FIXTURE_IDENTITY"); }
#endif

EXPORT model_params llama_model_default_params(void) {
    model_params result = {0}; by_value_calls++; return result;
}
EXPORT context_params llama_context_default_params(void) {
    context_params result = {0}; by_value_calls++; return result;
}
EXPORT sampler_chain_params llama_sampler_chain_default_params(void) {
    sampler_chain_params result = {0}; by_value_calls++; return result;
}
EXPORT mtmd_context_params mtmd_context_params_default(void) {
    mtmd_context_params result = {0}; by_value_calls++; return result;
}
EXPORT mtmd_helper_init_opt mtmd_helper_init_opt_default(void) {
    mtmd_helper_init_opt result = {0}; by_value_calls++; return result;
}
EXPORT batch llama_batch_init(int32_t count, int32_t embd, int32_t seq) {
    batch result = {0}; by_value_calls++; return result;
}
EXPORT void llama_batch_free(batch value) {}
EXPORT void *llama_dart_speculative_init(void *model, void *draft, void *context,
                                        context_params params, void *config) {
    require_null(model); require_null(draft); require_null(context); require_null(config);
    by_value_calls++;
    return NULL;
}
EXPORT void llama_dart_speculative_free(void *session) { require_null(session); }
EXPORT void *llama_dart_speculative_get_draft_context(void *session) {
    require_null(session); return NULL;
}
EXPORT bool llama_dart_speculative_begin(void *session, int32_t seq, void *prompt, int32_t count) {
    require_null(session); require_null(prompt); return false;
}
EXPORT bool llama_dart_speculative_process_batch(void *session, batch value) {
    require_null(session); return false;
}
EXPORT int32_t llama_dart_speculative_draft(void *session, int32_t seq, int32_t past,
                                          int32_t last, void *prompt, int32_t count,
                                          int32_t maximum, void *output, int32_t capacity) {
    require_null(session); require_null(prompt); require_null(output); return -1;
}
EXPORT void llama_dart_speculative_accept(void *session, int32_t seq, uint16_t count) {
    require_null(session);
}
EXPORT int32_t llama_dart_sampler_sample_and_accept_n(void *sampler, void *context,
                                                     void *draft, int32_t draft_count,
                                                     void *indices, int32_t index_count,
                                                     void *output, int32_t capacity) {
    require_null(sampler); require_null(context); require_null(draft);
    require_null(indices); require_null(output); return -1;
}
