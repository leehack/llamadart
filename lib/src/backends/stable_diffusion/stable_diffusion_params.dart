import 'dart:ffi';

import 'package:ffi/ffi.dart';

import '../../core/image/image_generation_driver.dart';
import '../../core/image/image_generation_model.dart';
import 'stable_diffusion_bindings.dart' as sd;

/// Writes [config] into [params], which `sd_ctx_params_init` has filled with
/// the runtime defaults. Strings are allocated with [allocator] and must
/// outlive the `new_sd_ctx` call.
void applyStableDiffusionContextParams(
  Pointer<sd.sd_ctx_params_t> params,
  ImageGenerationSessionConfig config,
  Allocator allocator,
) {
  Pointer<Char> text(String? value) =>
      value == null ? nullptr : value.toNativeUtf8(allocator: allocator).cast();

  final files = config.files;
  params.ref
    ..model_path = text(files['model'])
    ..diffusion_model_path = text(files['diffusionModel'])
    ..vae_path = text(files['vae'])
    ..taesd_path = text(files['taesd'])
    ..clip_l_path = text(files['clipL'])
    ..clip_g_path = text(files['clipG'])
    ..t5xxl_path = text(files['t5xxl'])
    ..llm_path = text(files['llm'])
    ..backend = text(config.backend)
    ..diffusion_flash_attn = config.flashAttention
    ..vae_conv_direct = config.vaeDirectConvolution
    // Load every weight now, so the load pays for reading the files and
    // progress during generation is only sampling. A model that does not fit
    // the device does not fail the load: the runtime's automatic fit keeps
    // some weights in host memory or on disk, which makes sampling slower.
    ..eager_load = true;
  if (config.threads > 0) {
    params.ref.n_threads = config.threads;
  }
}

/// Writes [request] into [params], which `sd_img_gen_params_init` has filled
/// with the runtime defaults. Strings are allocated with [allocator] and must
/// outlive the `generate_image` call.
void applyStableDiffusionGenerationParams(
  Pointer<sd.sd_img_gen_params_t> params,
  ImageGenerationSessionRequest request,
  Allocator allocator,
) {
  params.ref
    ..prompt = request.prompt.toNativeUtf8(allocator: allocator).cast()
    ..negative_prompt = request.negativePrompt
        .toNativeUtf8(allocator: allocator)
        .cast()
    ..width = request.width
    ..height = request.height
    ..seed = request.seed
    ..batch_count = request.count;
  params.ref.sample_params
    ..sample_steps = request.steps
    ..guidance.txt_cfg = request.guidanceScale
    ..sample_method = stableDiffusionSampleMethod(request.sampler)
    ..scheduler = stableDiffusionScheduler(request.scheduler)
    ..flow_shift = stableDiffusionFlowShift(request.flowShift);
}

/// The runtime's sampler for [sampler]. `null` maps to
/// `SAMPLE_METHOD_COUNT`, which makes the runtime pick the model's default.
sd.sample_method_t stableDiffusionSampleMethod(
  ImageGenerationSampler? sampler,
) => switch (sampler) {
  null => sd.sample_method_t.SAMPLE_METHOD_COUNT,
  ImageGenerationSampler.euler => sd.sample_method_t.EULER_SAMPLE_METHOD,
  ImageGenerationSampler.eulerAncestral =>
    sd.sample_method_t.EULER_A_SAMPLE_METHOD,
  ImageGenerationSampler.dpmpp2m => sd.sample_method_t.DPMPP2M_SAMPLE_METHOD,
  ImageGenerationSampler.lcm => sd.sample_method_t.LCM_SAMPLE_METHOD,
};

/// The runtime's scheduler for [scheduler]. `null` maps to
/// `SCHEDULER_COUNT`, which makes the runtime pick the default for the model
/// and sampler.
sd.scheduler_t stableDiffusionScheduler(ImageGenerationScheduler? scheduler) =>
    switch (scheduler) {
      null => sd.scheduler_t.SCHEDULER_COUNT,
      ImageGenerationScheduler.discrete => sd.scheduler_t.DISCRETE_SCHEDULER,
      ImageGenerationScheduler.karras => sd.scheduler_t.KARRAS_SCHEDULER,
      ImageGenerationScheduler.sgmUniform =>
        sd.scheduler_t.SGM_UNIFORM_SCHEDULER,
      ImageGenerationScheduler.simple => sd.scheduler_t.SIMPLE_SCHEDULER,
    };

/// The runtime's flow shift for [flowShift]. `null` maps to infinity, which
/// makes the runtime use the model's default.
double stableDiffusionFlowShift(double? flowShift) =>
    flowShift ?? double.infinity;
