#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>

#ifdef _WIN32
#define EXPORT __declspec(dllexport)
#else
#define EXPORT __attribute__((visibility("default")))
#endif

struct llama_model;
struct mtmd_context;

// llama.cpp v1.0.0 mtmd-helper.h declares these eight bools in this order.
struct mtmd_helper_cap {
    bool chat;
    bool vision;
    bool audio;
    bool video;
    bool audio_stream;
    bool text_gen;
    bool audio_gen;
    bool audio_gen_spk_ref;
};

static const struct llama_model *last_model;
static const struct mtmd_context *last_projector;
static bool video_enabled;

EXPORT void fixture_set_video_enabled(bool enabled) { video_enabled = enabled; }
EXPORT const struct llama_model *fixture_last_model(void) { return last_model; }
EXPORT const struct mtmd_context *fixture_last_projector(void) { return last_projector; }

EXPORT struct mtmd_helper_cap mtmd_helper_get_capabilities(
        const struct llama_model *model, const struct mtmd_context *projector) {
    last_model = model;
    last_projector = projector;
    // Use opposite values so reading any field other than video fails.
    return (struct mtmd_helper_cap) {
        .chat = !video_enabled,
        .vision = !video_enabled,
        .audio = !video_enabled,
        .video = video_enabled,
        .audio_stream = !video_enabled,
        .text_gen = !video_enabled,
        .audio_gen = !video_enabled,
        .audio_gen_spk_ref = !video_enabled,
    };
}

// Fallback discovery requires these exports. This fixture exercises only
// the capability ABI, so any call to the lookup-only stubs is an error.
#define LOOKUP_ONLY(name) EXPORT void name(void) { abort(); }
LOOKUP_ONLY(mtmd_default_marker)
LOOKUP_ONLY(mtmd_context_params_default)
LOOKUP_ONLY(mtmd_init_from_file)
LOOKUP_ONLY(mtmd_free)
LOOKUP_ONLY(mtmd_input_chunks_init)
LOOKUP_ONLY(mtmd_input_chunks_free)
LOOKUP_ONLY(mtmd_helper_init_opt_default)
LOOKUP_ONLY(mtmd_helper_bitmap_init_from_file)
LOOKUP_ONLY(mtmd_helper_bitmap_init_from_buf)
LOOKUP_ONLY(mtmd_bitmap_init_from_audio)
LOOKUP_ONLY(mtmd_support_vision)
LOOKUP_ONLY(mtmd_support_audio)
LOOKUP_ONLY(mtmd_bitmap_free)
LOOKUP_ONLY(mtmd_tokenize)
LOOKUP_ONLY(mtmd_helper_eval_chunks)
