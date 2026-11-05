// Independent direct-C control for the local-only image container suite.
// Compile with the checksum-verified pinned bundle's headers and library.
#include <chrono>
#include <cstdio>
#include <cstring>
#include <filesystem>
#if defined(__APPLE__) || defined(__linux__)
#include <dlfcn.h>
#endif
#include <string>

#include "stable-diffusion.h"
#include "sd_dart_wrapper.h"

namespace {
using Clock = std::chrono::steady_clock;
const auto started = Clock::now();
bool original_mode = false;
std::string quoted(const char* value) {
    std::string out = "\"";
    for (const unsigned char c : std::string(value ? value : "")) {
        if (c == '\\' || c == '\"') out += '\\';
        if (c < 32) { char escaped[7]; std::snprintf(escaped, sizeof(escaped), "\\u%04x", c); out += escaped; }
        else out += c;
    }
    return out + "\"";
}
void stage(const char* name, long long load_ms = -1) {
    if (!original_mode) return;
    const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - started).count();
    std::printf("SD24_STAGE {\"schema\":1,\"stage\":%s,\"elapsedMs\":%lld,\"loadMs\":%lld}\n",
                quoted(name).c_str(), static_cast<long long>(ms), load_ms);
    std::fflush(stdout);
}
}

int main(int argc, char** argv) {
    original_mode = argc == 6 && std::strcmp(argv[1], "--original-mode") == 0;
    if (!original_mode && argc != 3) return 2;
    const char* model = argv[original_mode ? 2 : 1];
    const char* output_path = argv[original_mode ? 4 : 2];
    if (original_mode) {
#if defined(__APPLE__) || defined(__linux__)
        Dl_info binding{};
        if (!dladdr(reinterpret_cast<void*>(&sd_dart_new_sd_ctx), &binding) || !binding.dli_fname) return 8;
        std::printf("SD24_BINDING {\"schema\":1,\"route\":\"native\",\"mappedLibraryPath\":%s}\n", quoted(binding.dli_fname).c_str());
        std::fflush(stdout);
        std::error_code path_error;
        const auto mapped = std::filesystem::canonical(binding.dli_fname, path_error);
        if (path_error) return 8;
        const auto expected = std::filesystem::canonical(argv[5], path_error);
        if (path_error || mapped != expected) return 8;
#else
        return 8;
#endif
    }
    sd_ctx_params_t context_params;
    sd_ctx_params_init(&context_params);
    context_params.model_path = model;
    if (original_mode) context_params.taesd_path = argv[3];
    context_params.backend = "cpu";
    context_params.n_threads = 4;
    context_params.eager_load = true;
    context_params.batched_cfg = false;
    context_params.conditioning_cache_size = original_mode ? 4 : 0;
    if (original_mode) {
        context_params.flash_attn = false;
        context_params.diffusion_flash_attn = true;
        context_params.diffusion_conv_direct = false;
        context_params.vae_conv_direct = false;
        context_params.auto_fit = true;
    }
    context_params.flash_attn_mode = original_mode ? "off,diffusion=on" : "off";
    context_params.conv_direct_mode = "off";
    if (original_mode) {
        std::printf("SD24_CONFIG {\"backend\":%s,\"threads\":%d,\"cache\":%d,\"eager\":%s,\"batchedCfg\":%s,\"diffusionFlash\":%s,\"vaeDirect\":%s,\"flashMode\":%s,\"convMode\":%s,\"autoFit\":%s}\n",
            quoted(context_params.backend).c_str(), context_params.n_threads,
            context_params.conditioning_cache_size, context_params.eager_load ? "true" : "false",
            context_params.batched_cfg ? "true" : "false", context_params.diffusion_flash_attn ? "true" : "false",
            context_params.vae_conv_direct ? "true" : "false", quoted(context_params.flash_attn_mode).c_str(),
            quoted(context_params.conv_direct_mode).c_str(), context_params.auto_fit ? "true" : "false");
        std::fflush(stdout);
    }
    stage("load_begin");
    const auto load_started = Clock::now();
    auto* context = sd_dart_new_sd_ctx(&context_params);
    const auto load_ms = std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - load_started).count();
    stage("load_end", load_ms);
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
    stage("generation_begin", load_ms);
    const bool ok = sd_dart_generate_image(context, &params, &images, &count);
    stage("generation_end", load_ms);
    int result = 0;
    if (!ok || !images || count != 1 || !images[0].data ||
        images[0].width != 128 || images[0].height != 128 || images[0].channel != 3) {
        result = 4;
    } else {
        auto* output = std::fopen(output_path, original_mode ? "wbx" : "wb");
        if (!output) result = 5;
        else {
            std::fprintf(output, "P6\n128 128\n255\n");
            if (std::fwrite(images[0].data, 1, 128 * 128 * 3, output) != 128 * 128 * 3)
                result = 6;
            std::fclose(output);
        }
    }
    stage("pixels_written", load_ms);
    if (images) free_sd_images(images, count);
    sd_dart_exit_free(context);
    stage("disposed", load_ms);
    return result != 0 ? result : original_mode && load_ms >= 45000 ? 7 : 0;
}
