// Independent pinned-runtime C reference; see doc/image_controlnet.md.
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>
#include "stable-diffusion.h"
#include "sd_dart_wrapper.h"

constexpr int size = 256;

// White three-pixel lines on black, as image_controlnet_e2e_test.dart draws.
static void line(std::vector<uint8_t>& rgb, int x0, int y0, int x1, int y1) {
    const int steps = std::abs(x1 - x0) > std::abs(y1 - y0) ? std::abs(x1 - x0) : std::abs(y1 - y0);
    for (int i = 0; i <= steps; ++i) {
        // Dart's ~/ truncates toward zero, as C++ integer division does.
        const int x = x0 + (x1 - x0) * i / steps;
        const int y = y0 + (y1 - y0) * i / steps;
        for (int dy = -1; dy <= 1; ++dy) for (int dx = -1; dx <= 1; ++dx) {
            const int px = x + dx, py = y + dy;
            if (px < 0 || py < 0 || px >= size || py >= size) continue;
            for (int c = 0; c < 3; ++c) rgb[(py * size + px) * 3 + c] = 255;
        }
    }
}

int main(int argc, char** argv) {
    if (argc != 4) {
        std::fprintf(stderr, "usage: reference MODEL CONTROLNET OUTPUT_PREFIX\n");
        return 2;
    }
    std::vector<uint8_t> house(size * size * 3), cross(size * size * 3);
    line(house, 64, 224, 192, 224);
    line(house, 64, 224, 64, 128);
    line(house, 192, 224, 192, 128);
    line(house, 56, 128, 128, 56);
    line(house, 128, 56, 200, 128);
    line(house, 56, 128, 200, 128);
    line(cross, 16, 16, 240, 240);
    line(cross, 240, 16, 16, 240);

    sd_ctx_params_t context_params;
    sd_ctx_params_init(&context_params);
    context_params.model_path = argv[1];
    context_params.control_net_path = argv[2];
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
    std::fprintf(stderr, "FAMILY=%s CONTROLNET=%d\n", sd_get_model_version_name(context),
                 sd_ctx_has_control_net(context) ? 1 : 0);
    // ordinary, house at 1, house at 0, cross at 1, house at 2, ordinary reset.
    for (int mode = 0; mode < 6; ++mode) {
        sd_img_gen_params_t params;
        sd_img_gen_params_init(&params);
        params.prompt = "a small wooden house in a green meadow, photograph";
        params.width = size;
        params.height = size;
        params.seed = 42;
        params.sample_params.sample_steps = 8;
        params.sample_params.guidance.txt_cfg = 7;
        params.sample_params.sample_method = EULER_SAMPLE_METHOD;
        params.sample_params.scheduler = DISCRETE_SCHEDULER;
        if (mode > 0 && mode < 5) {
            params.control_image = {size, size, 3, mode == 3 ? cross.data() : house.data()};
            params.control_strength = mode == 2 ? 0.0f : mode == 4 ? 2.0f : 1.0f;
        }
        sd_image_t* images = nullptr;
        int count = 0;
        if (!sd_dart_generate_image(context, &params, &images, &count) || count != 1) {
            sd_dart_exit_free(context);
            return 4;
        }
        const auto path = std::string(argv[3]) + "-" + std::to_string(mode) + ".ppm";
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
