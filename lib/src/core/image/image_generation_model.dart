import '../models/model_source.dart';

/// Runtime role of an image-model file.
///
/// `ImageGenerationEngine.load` detects each file's role from its header;
/// set one with [ImageModelComponent.new] only for a file it cannot
/// classify. Load errors also name files by role.
enum ImageModelRole {
  /// A full checkpoint: diffusion weights, usually with their VAE and text
  /// encoders, such as SD 1.x, 2.x, SDXL or SD 3.5 Medium single files.
  checkpoint,

  /// Standalone diffusion weights (UNet or transformer) of a split model.
  diffusionModel,

  /// A VAE.
  vae,

  /// A tiny autoencoder (TAESD), which replaces the VAE decoder for faster,
  /// lower-memory decoding at a small quality cost.
  taesd,

  /// A CLIP-L text encoder (or SD 2.x's OpenCLIP-H).
  clipL,

  /// A CLIP-G text encoder.
  clipG,

  /// A T5-XXL text encoder.
  t5xxl,

  /// A language-model text encoder, such as Qwen3-4B for Z-Image.
  llm,
}

/// A file of an image model besides its main file.
class ImageModelComponent {
  /// Where the file comes from.
  final ModelSource source;

  /// The role the caller set, or `null` to detect it from the file.
  final ImageModelRole? role;

  /// A file whose role is detected from its header.
  const ImageModelComponent.auto(this.source) : role = null;

  /// A file in [role], for a file the header check cannot classify, such as
  /// a `.ckpt` file, or to choose between layouts it cannot tell apart.
  const ImageModelComponent(this.source, {required ImageModelRole this.role});
}

/// An image-generation model: a main file and the other files it needs.
///
/// Each file is a `ModelSource` (local path, HTTP(S) URL or Hugging Face
/// file) that `ImageGenerationEngine.load` downloads if needed and then
/// assigns to its runtime role from its header, so files can be listed in
/// any order. The set needs one file with diffusion weights: a checkpoint or
/// a split model's diffusion model, plus its VAE, tiny autoencoder and text
/// encoders.
///
/// ```dart
/// final flux = ImageGenerationModel(
///   ModelSource.path('flux1-schnell-Q4_0.gguf'),
///   components: [
///     ImageModelComponent.auto(ModelSource.path('ae.safetensors')),
///     ImageModelComponent.auto(ModelSource.path('clip_l-Q8_0.gguf')),
///     ImageModelComponent.auto(ModelSource.path('t5xxl-Q8_0.gguf')),
///   ],
/// );
/// ```
///
/// Building a model does no network or file access.
class ImageGenerationModel {
  /// The main file, usually the checkpoint or diffusion model.
  final ModelSource source;

  /// The role the caller set for [source], or `null` to detect it.
  final ImageModelRole? role;

  /// The other files.
  final List<ImageModelComponent> components;

  /// Creates a model from its main [source] and other [components]. Set
  /// [role] only when the header check cannot classify [source].
  const ImageGenerationModel(
    this.source, {
    this.role,
    this.components = const <ImageModelComponent>[],
  });
}

/// Sampling method of a generation.
///
/// A subset of stable-diffusion.cpp's samplers. When the request leaves it
/// unset, the runtime picks the model's default: Euler for
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
/// A subset of stable-diffusion.cpp's schedulers. When the request leaves it
/// unset, the runtime picks the default for the model and sampler.
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
