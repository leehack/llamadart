/// Local weight files for one image-generation model.
///
/// Single-file checkpoints set [model]. Split checkpoints set
/// [diffusionModel] and the matching [vae] and text encoders. [taesd] adds
/// the tiny autoencoder, which replaces the VAE decoder for faster,
/// lower-memory decoding at a small quality cost.
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

  /// Creates a file set. Every path is a local file.
  const ImageGenerationModelFiles({
    this.model,
    this.diffusionModel,
    this.vae,
    this.taesd,
    this.clipL,
    this.clipG,
    this.t5xxl,
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
  };
}

/// Sampling defaults a model needs when a request leaves them unset.
class ImageGenerationDefaults {
  /// Sampling steps.
  final int steps;

  /// Classifier-free guidance scale. `1` disables the negative prompt and
  /// halves the work per step.
  final double guidanceScale;

  /// Creates sampling defaults. The defaults suit undistilled SD 1.x and 2.x
  /// checkpoints.
  const ImageGenerationDefaults({this.steps = 20, this.guidanceScale = 7.0});
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
/// for other SD 1.x and 2.x checkpoints stable-diffusion.cpp can load.
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
  /// Experimental: only SD 1.x and 2.x-family checkpoints are in scope, and
  /// only SDXS and SD-Turbo are validated. Larger families that
  /// stable-diffusion.cpp supports, such as SDXL or FLUX, may load but are
  /// untested and can exceed phone memory.
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

  /// Creates runtime settings.
  const ImageGenerationOptions({
    this.device = ImageGenerationDevice.auto,
    this.threads = 0,
    this.checkMemory = true,
  });
}
