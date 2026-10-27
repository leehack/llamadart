// Independent direct-C control for bounded local complete-checkpoint sets.
// Compile with the checksum-verified pinned bundle's headers and library.
#include <cstdio>

#include "stable-diffusion.h"
#include "sd_dart_wrapper.h"

int main(int argc, char** argv) {
    if (argc != 3) return 2;
    sd_ctx_params_t context_params;
    sd_ctx_params_init(&context_params);
    context_params.model_path = argv[1];
    context_params.backend = "cpu";
    context_params.n_threads = 4;
    context_params.eager_load = true;
    context_params.batched_cfg = false;
    context_params.conditioning_cache_size = 0;
    context_params.flash_attn_mode = "off";
    context_params.conv_direct_mode = "off";
    auto* context = sd_dart_new_sd_ctx(&context_params);
    if (!context) return 3;
    std::fprintf(stderr, "FAMILY=%s\n", sd_get_model_version_name(context));
    sd_img_gen_params_t params;
    sd_img_gen_params_init(&params);
    params.prompt = "a red fox in a green forest, watercolor painting";
    params.width = 128;
    params.height = 128;
    params.seed = 42;
    params.sample_params.sample_steps = 1;
    params.sample_params.guidance.txt_cfg = 1;
    params.sample_params.sample_method = EULER_SAMPLE_METHOD;
    params.sample_params.scheduler = DISCRETE_SCHEDULER;
    sd_image_t* images = nullptr;
    int count = 0;
    const bool ok = sd_dart_generate_image(context, &params, &images, &count);
    int result = 0;
    if (!ok || !images || count != 1 || !images[0].data ||
        images[0].width != 128 || images[0].height != 128 || images[0].channel != 3) {
        result = 4;
    } else {
        auto* output = std::fopen(argv[2], "wb");
        if (!output) result = 5;
        else {
            std::fprintf(output, "P6\n128 128\n255\n");
            if (std::fwrite(images[0].data, 1, 128 * 128 * 3, output) != 128 * 128 * 3)
                result = 6;
            std::fclose(output);
        }
    }
    if (images) free_sd_images(images, count);
    sd_dart_exit_free(context);
    return result;
}
