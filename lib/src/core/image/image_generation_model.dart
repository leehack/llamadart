import '../models/model_source.dart';

/// Weight files of one image-generation model, one `ModelSource` per role.
///
/// Each file can be a local path (`ModelSource.path`), an HTTP(S) URL or a
/// Hugging Face file; `ImageGenerationEngine.load` resolves them like
/// `LlamaEngine.loadModelSource`.
///
/// Single-file checkpoints set [model]. Split checkpoints set
/// [diffusionModel] and the matching [vae] and text encoders: [clipL] and
/// [clipG] for SDXL-style models, [clipL], [clipG] and [t5xxl] for SD 3.5,
/// [clipL] and [t5xxl] for FLUX, and [llm] for Z-Image and Qwen-Image.
/// [taesd] adds a tiny autoencoder, which replaces the VAE decoder for
/// faster, lower-memory decoding at a small quality cost.
class ImageGenerationModelFiles {
  /// Single-file checkpoint (`.gguf`, `.safetensors` or `.ckpt`). A
  /// checkpoint that includes its VAE and text encoders, such as an SD 3.5
  /// Medium GGUF, goes here, not in [diffusionModel].
  final ModelSource? model;

  /// Standalone diffusion (UNet or transformer) weights of a split
  /// checkpoint.
  final ModelSource? diffusionModel;

  /// Standalone VAE weights.
  final ModelSource? vae;

  /// Tiny autoencoder (TAESD) weights, such as `madebyollin/taesd`'s
  /// `diffusion_pytorch_model.safetensors`.
  final ModelSource? taesd;

  /// Standalone CLIP-L text encoder.
  final ModelSource? clipL;

  /// Standalone CLIP-G text encoder.
  final ModelSource? clipG;

  /// Standalone T5-XXL text encoder.
  final ModelSource? t5xxl;

  /// Standalone language-model text encoder, such as Qwen3-4B for Z-Image or
  /// Qwen2.5-VL-7B for Qwen-Image, as a `.gguf` or `.safetensors` file.
  final ModelSource? llm;

  /// Creates a file set. Building it does no network or file access.
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

  /// Every set file, keyed by role, in declaration order: `model`,
  /// `diffusionModel`, `vae`, `taesd`, `clipL`, `clipG`, `t5xxl`, `llm`.
  Map<String, ModelSource> get sources => <String, ModelSource>{
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

/// Output size and sampling defaults a model needs when a request leaves
/// them unset.
class ImageGenerationDefaults {
  /// Output width in pixels: the model's native width.
  final int width;

  /// Output height in pixels: the model's native height.
  final int height;

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

  /// Creates generation defaults: 512x512, 20 steps at guidance 7 and the
  /// runtime's own sampler, schedule and flow shift unless set. Distilled
  /// models need their own steps and guidance, and families trained at
  /// 1024x1024 need that size.
  const ImageGenerationDefaults({
    this.width = 512,
    this.height = 512,
    this.steps = 20,
    this.guidanceScale = 7.0,
    this.sampler,
    this.scheduler,
    this.flowShift,
  });
}

/// An image-generation model: its files and the generation defaults it
/// needs.
///
/// Any family the bundled stable-diffusion.cpp supports can load, including
/// SD 1.x, 2.x, SDXL, SD 3.5, FLUX, Z-Image and Qwen-Image; the runtime
/// detects the family from the weights. Each family needs its own file roles
/// (see [ImageGenerationModelFiles]) and [defaults]: distilled models such as
/// SDXS, SD-Turbo, SDXL-Lightning or FLUX.1-schnell sample 1 to 8 steps at
/// guidance 1, and families trained at 1024x1024 need `width: 1024, height:
/// 1024`.
///
/// ```dart
/// final sdxs = ImageGenerationModel(
///   files: ImageGenerationModelFiles(
///     model: ModelSource.parse(
///       'hf://concedo/sdxs-512-tinySDdistilled-GGUF/'
///       'sdxs-512-tinySDdistilled_Q8_0.gguf',
///     ),
///   ),
///   defaults: const ImageGenerationDefaults(steps: 1, guidanceScale: 1),
/// );
/// ```
class ImageGenerationModel {
  /// Weight files.
  final ImageGenerationModelFiles files;

  /// Defaults applied when a request leaves the size, steps, guidance,
  /// sampler, scheduler or flow shift unset.
  final ImageGenerationDefaults defaults;

  /// Creates a model from its [files] and the [defaults] its requests use.
  /// Building it does no network or file access.
  const ImageGenerationModel({
    required this.files,
    this.defaults = const ImageGenerationDefaults(),
  });
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

  /// Whether the VAE decoder runs its convolutions directly instead of
  /// unfolding its input first. The output is identical.
  ///
  /// `null` turns it on, except on Metal and when the files include a
  /// `taesd` decoder. In stable-diffusion.cpp's native CLI on an NVIDIA L4
  /// with Vulkan it cut a 1024x1024 decode from 23 to 56 s to about 1 s and
  /// peak device memory by 4 to 5 GiB. On an M4 Max CPU it made a 512x512
  /// SD-Turbo image about 5% slower end to end and cut peak memory from 3.6
  /// to 2.7 GiB. On Metal it made decoding about 7 times slower, and with a
  /// `taesd` decoder it saved little memory and slowed decoding by about 40%.
  ///
  /// The engine cannot tell before loading that a checkpoint embeds a tiny
  /// autoencoder, as SDXS does. For SDXS on an M4 Max CPU, `null` (on) took
  /// 1.4 to 1.7 s per 512x512 image against 1.2 to 1.3 s with `false`, and
  /// peaked at 1.32 GiB of process memory against 1.56 GiB; set `false` for
  /// such a checkpoint when speed matters more than memory. On Metal `null`
  /// is off.
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
