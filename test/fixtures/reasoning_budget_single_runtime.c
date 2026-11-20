#include <stdbool.h>
#include <stdint.h>

#if defined(_WIN32)
#define EXPORT __declspec(dllexport)
#else
#define EXPORT
#endif

struct llama_vocab;
struct llama_sampler;

EXPORT struct llama_sampler *llama_dart_sampler_init_reasoning_budget(
    const struct llama_vocab *vocab, const char *start_tag, const char *end_tag,
    const char *forced_message, int32_t budget_tokens, bool pause_grammar,
    struct llama_sampler *grammar, const int32_t *prompt_tokens,
    int32_t prompt_token_count) {
    return 0;
}
