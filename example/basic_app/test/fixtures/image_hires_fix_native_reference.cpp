// Independent pinned-runtime C reference; see doc/image_hires_fix.md.
#include <chrono>
#include <cstdio>
#include <cstring>
#include <map>
#include <string>
#include <vector>
#include "stable-diffusion.h"
#include "sd_dart_wrapper.h"

struct Recipe {
    int steps;
    float cfg;
    int hires_steps;
    float strength;
};

// The recipes of image_hires_fix_e2e_test.dart: 512 square, then 768 square.
static const std::map<std::string, Recipe> recipes = {
    {"sd15", {12, 7.0f, 8, 0.55f}},
    {"turbo", {2, 1.0f, 2, 0.5f}},
};

int main(int argc, char** argv) {
    if (argc != 6 || !recipes.count(argv[3])) {
        std::fprintf(stderr,
                     "usage: reference MODEL cpu|gpu sd15|turbo base|final|hires OUTPUT.ppm\n");
        return 2;
    }
    const Recipe recipe = recipes.at(argv[3]);
    const std::string mode = argv[4];

    sd_ctx_params_t context_params;
    sd_ctx_params_init(&context_params);
    context_params.model_path = argv[1];
    context_params.backend = argv[2];
    context_params.eager_load = true;
    context_params.batched_cfg = false;
    context_params.flash_attn_mode = "off";
    context_params.conv_direct_mode = "off";
    sd_dart_progress_enable();
    sd_dart_log_enable();
    sd_dart_log_set_level(2);
    auto* context = sd_dart_new_sd_ctx(&context_params);
    if (!context) return 3;
    std::fprintf(stderr, "FAMILY=%s\n", sd_get_model_version_name(context));

    sd_img_gen_params_t params;
    sd_img_gen_params_init(&params);
    params.prompt = "a red fox sitting in a snowy forest, photograph";
    params.negative_prompt = "blurry";
    params.width = mode == "final" ? 768 : 512;
    params.height = params.width;
    params.seed = 42;
    params.batch_count = 1;
    params.sample_params.sample_steps = recipe.steps;
    params.sample_params.guidance.txt_cfg = recipe.cfg;
    params.sample_params.sample_method = EULER_SAMPLE_METHOD;
    params.sample_params.scheduler = DISCRETE_SCHEDULER;
    if (mode == "hires") {
        params.hires.enabled = true;
        params.hires.upscaler = SD_HIRES_UPSCALER_LATENT;
        params.hires.scale = 0;
        params.hires.target_width = 768;
        params.hires.target_height = 768;
        params.hires.steps = recipe.hires_steps;
        params.hires.denoising_strength = recipe.strength;
    }
    uint64_t before = 0;
    sd_dart_progress_read(0, nullptr, 0, &before);
    sd_image_t* images = nullptr;
    int count = 0;
    const auto start = std::chrono::steady_clock::now();
    const bool ok = sd_dart_generate_image(context, &params, &images, &count);
    const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - start);
    if (!ok || count != 1) {
        sd_dart_exit_free(context);
        return 4;
    }
    // Sampling reports per step total, to compare with the Dart progress.
    std::map<int, int> totals;
    std::vector<sd_dart_progress_t> reports(64);
    for (uint64_t after = before, latest = before;;) {
        const size_t read = sd_dart_progress_read(after, reports.data(), reports.size(), &latest);
        for (size_t i = 0; i < read; ++i) {
            totals[reports[i].steps]++;
            after = reports[i].sequence;
        }
        if (read == 0 || after >= latest) break;
    }
    for (const auto& [total, reported] : totals) {
        std::fprintf(stderr, "REPORTS total=%d count=%d\n", total, reported);
    }
    std::fprintf(stderr, "SIZE=%dx%d ELAPSED_MS=%lld\n", images[0].width, images[0].height,
                 static_cast<long long>(elapsed.count()));
    auto* file = std::fopen(argv[5], "wb");
    if (!file) {
        free_sd_images(images, count);
        sd_dart_exit_free(context);
        return 5;
    }
    std::fprintf(file, "P6\n%d %d\n255\n", images[0].width, images[0].height);
    std::fwrite(images[0].data, 1, images[0].width * images[0].height * 3, file);
    std::fclose(file);
    free_sd_images(images, count);
    sd_dart_exit_free(context);
}
