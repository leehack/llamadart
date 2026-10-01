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

  /// SDXL-Lightning 4-step, a progressively distilled SDXL model.
  sdxlLightning,

  /// FLUX.1-schnell, a 12B-parameter distilled flow transformer.
  flux1Schnell,

  /// SD 3.5 Large Turbo, an adversarially distilled 8B MMDiT model.
  sd35LargeTurbo,

  /// Z-Image-Turbo, a 6B distilled single-stream transformer with a Qwen3
  /// text encoder.
  zImageTurbo,

  /// Any other checkpoint the runtime accepts.
  custom,
}

/// An image-generation model: its files and the sampling defaults it needs.
///
/// Use a preset for the validated models, or [ImageGenerationModel.custom]
/// for other checkpoints stable-diffusion.cpp can load.
/// [ImageGenerationModel.sdxs] and [ImageGenerationModel.sdTurbo] fit
/// phones. [ImageGenerationModel.sdxlLightning],
/// [ImageGenerationModel.flux1Schnell], [ImageGenerationModel.sd35LargeTurbo]
/// and [ImageGenerationModel.zImageTurbo] are for desktop GPUs and Macs and
/// generate at 1024x1024.
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

  /// SDXL-Lightning 4-step from ByteDance/SDXL-Lightning's
  /// `sdxl_lightning_4step.safetensors` (6.9 GB), a single-file checkpoint.
  ///
  /// Generates at 1024x1024 in 4 steps at guidance 1 with Euler and the
  /// `sgmUniform` schedule, as the model card recommends. [vaePath] replaces
  /// the checkpoint's VAE, for example with `madebyollin/sdxl-vae-fp16-fix`;
  /// [taesdPath] decodes with `madebyollin/taesdxl`'s
  /// `diffusion_pytorch_model.safetensors` instead, which halved the time
  /// per image on an M4 Max at no visible quality cost. Needs about 8.5 GB
  /// of memory: a desktop GPU or a Mac with 16 GB or more.
  factory ImageGenerationModel.sdxlLightning(
    String modelPath, {
    String? vaePath,
    String? taesdPath,
  }) => ImageGenerationModel._(
    ImageGenerationModelFamily.sdxlLightning,
    ImageGenerationModelFiles(model: modelPath, vae: vaePath, taesd: taesdPath),
    const ImageGenerationDefaults(
      steps: 4,
      guidanceScale: 1,
      sampler: ImageGenerationSampler.euler,
      scheduler: ImageGenerationScheduler.sgmUniform,
    ),
  );

  /// FLUX.1-schnell from split files: the diffusion transformer (such as
  /// `second-state/FLUX.1-schnell-GGUF`'s `flux1-schnell-Q4_0.gguf`,
  /// 6.7 GB), the CLIP-L and T5-XXL text encoders (`clip_l-Q8_0.gguf` and
  /// `t5xxl-Q8_0.gguf`, 5.3 GB together) and a decoder: [vaePath] for the
  /// FLUX autoencoder (`ae.safetensors`) or [taesdPath] for
  /// `madebyollin/taef1`.
  ///
  /// Generates at 1024x1024 in 4 steps at guidance 1. Needs about 15 GB of
  /// memory: a desktop GPU with 16 GB or a Mac with 24 GB or more.
  ///
  /// Throws [ArgumentError] when neither [vaePath] nor [taesdPath] is set.
  factory ImageGenerationModel.flux1Schnell({
    required String diffusionModelPath,
    required String clipLPath,
    required String t5xxlPath,
    String? vaePath,
    String? taesdPath,
  }) => ImageGenerationModel._(
    ImageGenerationModelFamily.flux1Schnell,
    ImageGenerationModelFiles(
      diffusionModel: diffusionModelPath,
      vae: _decoder(vaePath, taesdPath, 'flux1Schnell'),
      taesd: taesdPath,
      clipL: clipLPath,
      t5xxl: t5xxlPath,
    ),
    const ImageGenerationDefaults(steps: 4, guidanceScale: 1),
  );

  /// SD 3.5 Large Turbo from split files: the diffusion transformer (such as
  /// `city96/stable-diffusion-3.5-large-turbo-gguf`'s
  /// `sd3.5_large_turbo-Q4_0.gguf`, 4.8 GB), the CLIP-L, CLIP-G and T5-XXL
  /// text encoders (such as `second-state/stable-diffusion-3.5-medium-GGUF`'s
  /// `clip_l-Q8_0.gguf`, `clip_g-Q8_0.gguf` and `t5xxl-Q8_0.gguf`, 6.1 GB
  /// together) and a decoder: [vaePath] for the SD 3.5 VAE or [taesdPath]
  /// for `madebyollin/taesd3`.
  ///
  /// Generates at 1024x1024 in 4 steps at guidance 1. Needs about 14 GB of
  /// memory: a desktop GPU with 16 GB or a Mac with 24 GB or more.
  ///
  /// Throws [ArgumentError] when neither [vaePath] nor [taesdPath] is set.
  factory ImageGenerationModel.sd35LargeTurbo({
    required String diffusionModelPath,
    required String clipLPath,
    required String clipGPath,
    required String t5xxlPath,
    String? vaePath,
    String? taesdPath,
  }) => ImageGenerationModel._(
    ImageGenerationModelFamily.sd35LargeTurbo,
    ImageGenerationModelFiles(
      diffusionModel: diffusionModelPath,
      vae: _decoder(vaePath, taesdPath, 'sd35LargeTurbo'),
      taesd: taesdPath,
      clipL: clipLPath,
      clipG: clipGPath,
      t5xxl: t5xxlPath,
    ),
    const ImageGenerationDefaults(steps: 4, guidanceScale: 1),
  );

  /// Z-Image-Turbo from split files: the diffusion transformer (such as
  /// `leejet/Z-Image-Turbo-GGUF`'s `z_image_turbo-Q4_K.gguf`, 3.9 GB), the
  /// Qwen3-4B text encoder (such as `unsloth/Qwen3-4B-Instruct-2507-GGUF`'s
  /// `Qwen3-4B-Instruct-2507-Q4_K_M.gguf`, 2.5 GB) and the FLUX autoencoder
  /// (`ae.safetensors`, 335 MB).
  ///
  /// Generates at 1024x1024 in 8 steps at guidance 1. Needs about 8.5 GB of
  /// memory: a desktop GPU with 12 GB or a Mac with 16 GB or more.
  factory ImageGenerationModel.zImageTurbo({
    required String diffusionModelPath,
    required String llmPath,
    required String vaePath,
  }) => ImageGenerationModel._(
    ImageGenerationModelFamily.zImageTurbo,
    ImageGenerationModelFiles(
      diffusionModel: diffusionModelPath,
      vae: vaePath,
      llm: llmPath,
    ),
    const ImageGenerationDefaults(steps: 8, guidanceScale: 1),
  );

  static String? _decoder(String? vaePath, String? taesdPath, String preset) {
    if (vaePath == null && taesdPath == null) {
      throw ArgumentError(
        'ImageGenerationModel.$preset needs vaePath or taesdPath.',
      );
    }
    return vaePath;
  }

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
  /// from 1.8 GB to 0.3 GB, sped up FLUX and SDXL slightly and left
  /// SD 1.x and 2.x unchanged; on its CPU, SD-Turbo sampling was about a
  /// fifth faster. The runtime falls back to regular attention where the
  /// device lacks a kernel.
  final bool? flashAttention;

  /// Whether the full VAE decodes with direct convolutions instead of
  /// unfolding its input first. The output is identical.
  ///
  /// `null` turns it on, except on Metal and when a tiny autoencoder decodes
  /// (an `ImageGenerationModelFiles.taesd` file or the SDXS preset). On an
  /// NVIDIA L4 with Vulkan it cut a 1024x1024 decode from 23 to 56 s to
  /// about 1 s and peak device memory by 4 to 5 GB. On an M4 Max CPU it
  /// left a 512x512 SD-Turbo decode within measurement noise and cut peak
  /// memory from 3.6 to 2.7 GB. On Metal it made decoding about 7 times
  /// slower, and with a tiny autoencoder it saved little memory and slowed
  /// decoding by about 40%.
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
