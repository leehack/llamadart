import '../../core/image/image_generation_model.dart';
import 'stable_diffusion_bindings.dart' as sd;

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
