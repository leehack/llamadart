// Independent direct-C settings reference for the local-only texture suite.
// Compile against the extracted pinned v0.3.0 bundle; see
// doc/image_seamless_textures.md. No Dart mapping helper is involved.
#include <cstddef>
#include <cstdio>
#include <string>

#include "stable-diffusion.h"
#include "sd_dart_wrapper.h"

static_assert(offsetof(sd_img_gen_params_t, circular_x) == 540);
static_assert(offsetof(sd_img_gen_params_t, circular_y) == 541);

int main(int argc, char** argv) {
    if (argc != 5) {
        std::fprintf(stderr, "usage: reference MODEL cpu|gpu TAESD|none OUTPUT_PREFIX\n");
        return 2;
    }
    sd_ctx_params_t context_params;
    sd_ctx_params_init(&context_params);
    context_params.model_path = argv[1];
    context_params.backend = argv[2];
    context_params.n_threads = 4;
    context_params.eager_load = true;
    context_params.batched_cfg = false;
    context_params.flash_attn_mode = "off";
    context_params.conv_direct_mode = "off";
    if (std::string(argv[3]) != "none") {
        context_params.taesd_path = argv[3];
    }
    sd_dart_log_enable();
    sd_dart_log_set_level(0);
    auto* context = sd_dart_new_sd_ctx(&context_params);
    if (!context) return 3;
    std::fprintf(stderr, "FAMILY=%s\n", sd_get_model_version_name(context));
    for (int mode = 0; mode < 5; ++mode) {
        sd_img_gen_params_t params;
        sd_img_gen_params_init(&params);
        params.prompt = "seamless texture of weathered gray stone, uniform rough stone surface, flat lighting, top down";
        params.width = 512;
        params.height = 512;
        params.seed = 42;
        params.sample_params.sample_steps = 4;
        params.sample_params.guidance.txt_cfg = 1;
        params.sample_params.sample_method = EULER_SAMPLE_METHOD;
        params.sample_params.scheduler = DISCRETE_SCHEDULER;
        params.circular_x = mode == 1 || mode == 3;
        params.circular_y = mode == 2 || mode == 3;
        sd_image_t* images = nullptr;
        int count = 0;
        if (!sd_dart_generate_image(context, &params, &images, &count)) {
            sd_dart_exit_free(context);
            return 4;
        }
        const auto path = std::string(argv[4]) + "-" + std::to_string(mode) + ".ppm";
        auto* file = std::fopen(path.c_str(), "wb");
        if (!file) {
            free_sd_images(images, count);
            sd_dart_exit_free(context);
            return 5;
        }
        std::fprintf(file, "P6\n%d %d\n255\n", images[0].width, images[0].height);
        std::fwrite(images[0].data, 1, images[0].width * images[0].height * 3, file);
        std::fclose(file);
        free_sd_images(images, count);
        std::fprintf(stderr, "WROTE=%s\n", path.c_str());
    }
    sd_dart_exit_free(context);
}
