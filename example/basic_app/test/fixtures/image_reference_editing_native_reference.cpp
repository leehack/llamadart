// Independent pinned-runtime C reference; see doc/image_reference_editing.md.
#include <chrono>
#include <cmath>
#include <cstdio>
#include <string>
#include <vector>
#include "stable-diffusion.h"
#include "sd_dart_wrapper.h"

// The fixture of image_reference_editing_e2e_test.dart: a red disk above a
// dark bar on a light gray background.
static std::vector<uint8_t> reference_pixels(int size) {
    std::vector<uint8_t> pixels(static_cast<size_t>(size) * size * 3);
    for (int y = 0; y < size; ++y) {
        for (int x = 0; x < size; ++x) {
            const int dx = x - 256;
            const int dy = y - 224;
            uint8_t r = 225, g = 225, b = 225;
            if (dx * dx + dy * dy <= 120 * 120) {
                r = 200, g = 30, b = 30;
            } else if (y >= 432 && y < 464 && x >= 64 && x < 448) {
                r = g = b = 40;
            }
            uint8_t* pixel = &pixels[(static_cast<size_t>(y) * size + x) * 3];
            pixel[0] = r, pixel[1] = g, pixel[2] = b;
        }
    }
    return pixels;
}

int main(int argc, char** argv) {
    if (argc != 7) {
        std::fprintf(stderr,
                     "usage: reference DIFFUSION VAE CLIP_L T5XXL edit|plain OUTPUT.ppm\n");
        return 2;
    }
    const std::string mode = argv[5];
    const int size = 512;

    sd_ctx_params_t context_params;
    sd_ctx_params_init(&context_params);
    context_params.diffusion_model_path = argv[1];
    context_params.vae_path = argv[2];
    context_params.clip_l_path = argv[3];
    context_params.t5xxl_path = argv[4];
    context_params.backend = "gpu";
    context_params.eager_load = true;
    context_params.batched_cfg = false;
    // ImageModelParams defaults on Metal: diffusion flash attention on, direct
    // VAE convolution off.
    context_params.diffusion_flash_attn = true;
    context_params.vae_conv_direct = false;
    context_params.flash_attn_mode = "off,diffusion=on";
    context_params.conv_direct_mode = "off";
    sd_dart_progress_enable();
    sd_dart_log_enable();
    sd_dart_log_set_level(2);
    auto* context = sd_dart_new_sd_ctx(&context_params);
    if (!context) return 3;
    std::fprintf(stderr, "FAMILY=%s\n", sd_get_model_version_name(context));

    std::vector<uint8_t> pixels = reference_pixels(size);
    sd_image_t reference = {static_cast<uint32_t>(size), static_cast<uint32_t>(size), 3,
                            pixels.data()};
    sd_img_gen_params_t params;
    sd_img_gen_params_init(&params);
    params.prompt = "Change the red circle to blue. Keep the gray background and the dark bar.";
    params.negative_prompt = "";
    params.width = size;
    params.height = size;
    params.seed = 42;
    params.batch_count = 1;
    params.sample_params.sample_steps = 20;
    params.sample_params.guidance.txt_cfg = 1.0f;
    params.sample_params.sample_method = EULER_SAMPLE_METHOD;
    params.sample_params.scheduler = SCHEDULER_COUNT;
    params.sample_params.flow_shift = INFINITY;
    if (mode == "edit") {
        params.ref_images = &reference;
        params.ref_images_count = 1;
        params.ref_image_args = "preset=flux_kontext";
    }
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
    std::fprintf(stderr, "SIZE=%dx%d ELAPSED_MS=%lld\n", images[0].width, images[0].height,
                 static_cast<long long>(elapsed.count()));
    auto* file = std::fopen(argv[6], "wb");
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
