/// Local weight files for one image-generation model.
///
/// Single-file checkpoints set [model]. Split checkpoints set
/// [diffusionModel] and the matching [vae] and text encoders: [clipL] and
/// [clipG] for SDXL-style models, [clipL], [clipG] and [t5xxl] for SD 3.5,
/// [clipL] and [t5xxl] for FLUX, and [llm] for Z-Image and Qwen-Image.
/// [taesd] adds the tiny autoencoder, which replaces the VAE decoder for
/// faster, lower-memory decoding at a small quality cost.
class ImageGenerationModelFiles {
  /// Single-file checkpoint (`.gguf`, `.safetensors` or `.ckpt`).
  final String? model;

  /// Standalone diffusion (UNet) weights of a split checkpoint.
  final String? diffusionModel;

  /// Standalone VAE weights.
  final String? vae;

  /// Tiny autoencoder (TAESD) weights, such as `madebyollin/taesd`'s
  /// `diffusion_pytorch_model.safetensors`.
  final String? taesd;

  /// Standalone CLIP-L text encoder.
  final String? clipL;

  /// Standalone CLIP-G text encoder.
  final String? clipG;

  /// Standalone T5-XXL text encoder.
  final String? t5xxl;

  /// Standalone language-model text encoder, such as Qwen3-4B for Z-Image or
  /// Qwen2.5-VL-7B for Qwen-Image, as a `.gguf` or `.safetensors` file.
  final String? llm;

  /// Creates a file set. Every path is a local file.
  const ImageGenerationModelFiles({
    this.model,
    this.diffusionModel,
    this.vae,
    this.taesd,
    this.clipL,
    this.clipG,
    this.t5xxl,
    this.llm,
  });

  /// Every non-null path, keyed by its role, in declaration order.
  Map<String, String> get paths => <String, String>{
    'model': ?model,
    'diffusionModel': ?diffusionModel,
    'vae': ?vae,
    'taesd': ?taesd,
    'clipL': ?clipL,
    'clipG': ?clipG,
    't5xxl': ?t5xxl,
    'llm': ?llm,
  };
}

/// Sampling method of a generation.
///
/// A subset of stable-diffusion.cpp's samplers. When neither the request nor
/// the model sets one, the runtime picks the model's default: Euler for
/// transformer models such as SD 3.5, FLUX and Z-Image, and Euler ancestral
/// for UNet models such as SD 1.x, 2.x and SDXL.
enum ImageGenerationSampler {
  /// Euler.
  euler,

  /// Euler ancestral, which adds fresh noise every step.
  eulerAncestral,

  /// DPM++ 2M.
  dpmpp2m,

  /// Latent consistency model sampling, for LCM-distilled checkpoints.
  lcm,
}

/// Noise schedule of a generation.
///
/// A subset of stable-diffusion.cpp's schedulers. When neither the request
/// nor the model sets one, the runtime picks the default for the model and
/// sampler.
enum ImageGenerationScheduler {
  /// The model's discrete training schedule.
  discrete,

  /// Karras et al. (2022) noise levels.
  karras,

  /// Uniform in sigma, as SDXL-Lightning's model card recommends.
  sgmUniform,

  /// Evenly spaced training timesteps.
  simple,
}

/// Sampling defaults a model needs when a request leaves them unset.
class ImageGenerationDefaults {
  /// Sampling steps.
  final int steps;

  /// Classifier-free guidance scale. `1` disables the negative prompt and
  /// halves the work per step.
  final double guidanceScale;

  /// Sampling method, or `null` for the runtime's default for the model.
  final ImageGenerationSampler? sampler;

  /// Noise schedule, or `null` for the runtime's default for the model and
  /// sampler.
  final ImageGenerationScheduler? scheduler;

  /// Timestep shift of flow-matching models (SD 3.5, FLUX, Z-Image,
  /// Qwen-Image), or `null` for the runtime's default for the model. Other
  /// models ignore it. Qwen-Image's reference settings use 3.
  final double? flowShift;

  /// Creates sampling defaults. The defaults suit undistilled SD 1.x and 2.x
  /// checkpoints.
  const ImageGenerationDefaults({
    this.steps = 20,
    this.guidanceScale = 7.0,
    this.sampler,
    this.scheduler,
    this.flowShift,
  });
}

/// Model family a preset was built for.
enum ImageGenerationModelFamily {
  /// SDXS-512, a one-step distilled SD 1.x-size model.
  sdxs,

  /// SD-Turbo, an adversarially distilled SD 2.1 model for 1 to 4 steps.
  sdTurbo,

  /// Any other checkpoint the runtime accepts.
  custom,
}

/// An image-generation model: its files and the sampling defaults it needs.
///
/// Use a preset for the validated models, or [ImageGenerationModel.custom]
/// for other checkpoints stable-diffusion.cpp can load.
class ImageGenerationModel {
  /// Family the preset was built for.
  final ImageGenerationModelFamily family;

  /// Local weight files.
  final ImageGenerationModelFiles files;

  /// Defaults applied when a request leaves steps or guidance unset.
  final ImageGenerationDefaults defaults;

  const ImageGenerationModel._(this.family, this.files, this.defaults);

  /// SDXS-512 from a single-file checkpoint, such as
  /// `concedo/sdxs-512-tinySDdistilled-GGUF`'s
  /// `sdxs-512-tinySDdistilled_Q8_0.gguf` (651 MB).
  ///
  /// SDXS is distilled for exactly one step with guidance 1; more steps or a
  /// higher guidance scale degrade the image.
  factory ImageGenerationModel.sdxs(String modelPath) => ImageGenerationModel._(
    ImageGenerationModelFamily.sdxs,
    ImageGenerationModelFiles(model: modelPath),
    const ImageGenerationDefaults(steps: 1, guidanceScale: 1),
  );

  /// SD-Turbo from a single-file checkpoint, such as
  /// `Green-Sky/SD-Turbo-GGUF`'s `sd_turbo-f16-q8_0.gguf` (1.9 GB).
  ///
  /// Defaults to one step with guidance 1. SD-Turbo also accepts up to four
  /// steps (`steps: 4`) for more detail at about four times the sampling
  /// time. [taesdPath] decodes with TAESD instead of the full VAE, which is
  /// several times faster and needs far less memory on phones.
  factory ImageGenerationModel.sdTurbo(String modelPath, {String? taesdPath}) =>
      ImageGenerationModel._(
        ImageGenerationModelFamily.sdTurbo,
        ImageGenerationModelFiles(model: modelPath, taesd: taesdPath),
        const ImageGenerationDefaults(steps: 1, guidanceScale: 1),
      );

  /// Any other checkpoint, with the sampling [defaults] it needs.
  ///
  /// Experimental. Any family the bundled stable-diffusion.cpp supports can
  /// load, including SDXL, SD 3.5, FLUX, Z-Image and Qwen-Image; the
  /// runtime detects the family from the weights. Each family needs its own
  /// file roles (see [ImageGenerationModelFiles]) and [defaults]: distilled
  /// models such as SDXL-Lightning or FLUX.1-schnell use about 4 steps at
  /// guidance 1. A single-file checkpoint that includes its VAE and text
  /// encoders, such as an SD 3.5 Medium GGUF, goes in
  /// [ImageGenerationModelFiles.model], not `diffusionModel`.
  ///
  /// SDXL and newer families need several GB of memory and are meant for
  /// desktop GPUs and Macs, not phones.
  factory ImageGenerationModel.custom(
    ImageGenerationModelFiles files, {
    ImageGenerationDefaults defaults = const ImageGenerationDefaults(),
  }) => ImageGenerationModel._(
    ImageGenerationModelFamily.custom,
    files,
    defaults,
  );
}

/// Device an image-generation engine runs on.
enum ImageGenerationDevice {
  /// The first GPU the runtime reports (Metal on Apple, Vulkan on the Linux
  /// and Windows Vulkan build), otherwise the CPU.
  auto,

  /// The CPU.
  cpu,

  /// The first GPU the runtime reports. Loading fails with
  /// `LlamaUnsupportedException` when there is none, as on Android and the
  /// Linux and Windows CPU builds.
  gpu,
}

/// Runtime settings for an image-generation engine.
class ImageGenerationOptions {
  /// Device to run on.
  final ImageGenerationDevice device;

  /// CPU threads. `0` uses the number of physical cores.
  final int threads;

  /// Whether `ImageGenerationEngine.load` refuses a model that its memory
  /// estimate says cannot fit the device. See `ImageGenerationEngine.load`.
  final bool checkMemory;

  /// Whether the diffusion model uses flash attention, which needs less
  /// memory and is often faster, with output that differs only in rounding.
  ///
  /// `null` turns it on for the CPU and Metal, where it was measured, and
  /// leaves it off on other GPUs such as Vulkan. On an M4 Max it made
  /// SD 3.5 Medium sampling 1.6 times as fast and cut its compute buffer
  /// from 1.8 GiB to 0.3 GiB, sped up FLUX and SDXL slightly and left
  /// SD 1.x and 2.x sampling time unchanged; on its CPU, SD-Turbo sampling
  /// was about a fifth faster. Pixels change slightly. The runtime falls back to regular attention where the
  /// device lacks a kernel.
  final bool? flashAttention;

  /// Whether the full VAE decodes with direct convolutions instead of
  /// unfolding its input first. The output is identical.
  ///
  /// `null` turns it on, except on Metal and when a tiny autoencoder decodes
  /// (an `ImageGenerationModelFiles.taesd` file or the SDXS preset). In
  /// stable-diffusion.cpp's native CLI on an NVIDIA L4 with Vulkan it cut a
  /// 1024x1024 decode from 23 to 56 s to about 1 s and peak device memory by
  /// 4 to 5 GiB. On an M4 Max CPU it made a 512x512 SD-Turbo image about 5%
  /// slower end to end and cut peak memory from 3.6 to 2.7 GiB. On Metal it
  /// made decoding about 7 times slower, and with a tiny autoencoder it saved
  /// little memory and slowed decoding by about 40%.
  final bool? vaeDirectConvolution;

  /// Creates runtime settings.
  const ImageGenerationOptions({
    this.device = ImageGenerationDevice.auto,
    this.threads = 0,
    this.checkMemory = true,
    this.flashAttention,
    this.vaeDirectConvolution,
  });
}
