// Independent pinned-runtime C reference; see doc/image_editing.md.
#include <cstdio>
#include <string>
#include <vector>
#include "stable-diffusion.h"
#include "sd_dart_wrapper.h"

int main(int argc, char** argv) {
    if (argc != 3) {
        std::fprintf(stderr, "usage: reference MODEL OUTPUT_PREFIX\n");
        return 2;
    }
    constexpr int size = 256;
    std::vector<uint8_t> rgb(size * size * 3), mask(size * size);
    for (int y = 0; y < size; ++y) for (int x = 0; x < size; ++x) {
        const int i = y * size + x;
        rgb[i * 3] = (x / 32 % 2) ? 220 : 40;
        rgb[i * 3 + 1] = (y / 32 % 2) ? 200 : 60;
        rgb[i * 3 + 2] = (x + y) % 256;
    }
    sd_ctx_params_t context_params;
    sd_ctx_params_init(&context_params);
    context_params.model_path = argv[1];
    context_params.backend = "cpu";
    context_params.n_threads = 4;
    context_params.eager_load = true;
    context_params.batched_cfg = false;
    context_params.flash_attn_mode = "off";
    context_params.conv_direct_mode = "off";
    sd_dart_log_enable();
    sd_dart_log_set_level(2);
    auto* context = sd_dart_new_sd_ctx(&context_params);
    if (!context) return 3;
    std::fprintf(stderr, "FAMILY=%s\n", sd_get_model_version_name(context));
    // ordinary, unmasked 1, unmasked .5, white, black, left-white, ordinary reset.
    for (int mode = 0; mode < 7; ++mode) {
        sd_img_gen_params_t params;
        sd_img_gen_params_init(&params);
        params.prompt = "a colorful painting of a small wooden house in a green meadow";
        params.width = size;
        params.height = size;
        params.seed = 42;
        params.sample_params.sample_steps = 4;
        params.sample_params.guidance.txt_cfg = 1;
        params.sample_params.sample_method = EULER_SAMPLE_METHOD;
        params.sample_params.scheduler = DISCRETE_SCHEDULER;
        if (mode > 0 && mode < 6) {
            params.init_image = {size, size, 3, rgb.data()};
            params.strength = mode == 2 ? 0.5f : 1.0f;
        }
        if (mode >= 3 && mode <= 5) {
            for (int i = 0; i < size * size; ++i)
                mask[i] = mode == 3 || (mode == 5 && i % size < size / 2) ? 255 : 0;
            params.mask_image = {size, size, 1, mask.data()};
        }
        sd_image_t* images = nullptr;
        int count = 0;
        if (!sd_dart_generate_image(context, &params, &images, &count) || count != 1) {
            sd_dart_exit_free(context);
            return 4;
        }
        const auto path = std::string(argv[2]) + "-" + std::to_string(mode) + ".ppm";
        auto* file = std::fopen(path.c_str(), "wb");
        if (!file) { free_sd_images(images, count); sd_dart_exit_free(context); return 5; }
        std::fprintf(file, "P6\n%d %d\n255\n", images[0].width, images[0].height);
        std::fwrite(images[0].data, 1, images[0].width * images[0].height * 3, file);
        std::fclose(file);
        free_sd_images(images, count);
        std::fprintf(stderr, "WROTE=%s\n", path.c_str());
    }
    sd_dart_exit_free(context);
}
