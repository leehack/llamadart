import '../exceptions.dart';
import '../models/model_source.dart';

/// Weight files of one image-generation model, keyed by role.
///
/// Single-file checkpoints set `model`. Split checkpoints set
/// `diffusionModel` and the matching `vae` and text encoders: `clipL` and
/// `clipG` for SDXL-style models, `clipL`, `clipG` and `t5xxl` for SD 3.5,
/// `clipL` and `t5xxl` for FLUX, and `llm` for Z-Image and Qwen-Image.
/// `taesd` adds the tiny autoencoder, which replaces the VAE decoder for
/// faster, lower-memory decoding at a small quality cost.
///
/// Build a file set with [ImageGenerationModelFiles.fromSources].
class ImageGenerationModelFiles {
  /// Local path of the single-file checkpoint (`.gguf`, `.safetensors` or
  /// `.ckpt`), or `null` when it is unset or not a local path.
  @Deprecated('Use sources["model"].')
  final String? model;

  /// Local path of the standalone diffusion (UNet) weights of a split
  /// checkpoint, or `null` when unset or not a local path.
  @Deprecated('Use sources["diffusionModel"].')
  final String? diffusionModel;

  /// Local path of the standalone VAE weights, or `null` when unset or not a
  /// local path.
  @Deprecated('Use sources["vae"].')
  final String? vae;

  /// Local path of the tiny autoencoder (TAESD) weights, or `null` when unset
  /// or not a local path.
  @Deprecated('Use sources["taesd"].')
  final String? taesd;

  /// Local path of the standalone CLIP-L text encoder, or `null` when unset
  /// or not a local path.
  @Deprecated('Use sources["clipL"].')
  final String? clipL;

  /// Local path of the standalone CLIP-G text encoder, or `null` when unset
  /// or not a local path.
  @Deprecated('Use sources["clipG"].')
  final String? clipG;

  /// Local path of the standalone T5-XXL text encoder, or `null` when unset
  /// or not a local path.
  @Deprecated('Use sources["t5xxl"].')
  final String? t5xxl;

  /// Local path of the standalone language-model text encoder, or `null`
  /// when unset or not a local path.
  @Deprecated('Use sources["llm"].')
  final String? llm;

  final Map<String, ModelSource>? _sources;

  /// Creates a file set from local paths.
  @Deprecated(
    'Use ImageGenerationModelFiles.fromSources with ModelSource.path(path) '
    'for each file.',
  )
  const ImageGenerationModelFiles({
    this.model,
    this.diffusionModel,
    this.vae,
    this.taesd,
    this.clipL,
    this.clipG,
    this.t5xxl,
    this.llm,
  }) : _sources = null;

  /// Creates a file set whose files come from local paths, HTTP(S) URLs or
  /// Hugging Face, like `LlamaEngine.loadModelSource`.
  ///
  /// - [model]: single-file checkpoint (`.gguf`, `.safetensors` or `.ckpt`).
  /// - [diffusionModel]: standalone diffusion (UNet) weights of a split
  ///   checkpoint.
  /// - [vae]: standalone VAE weights.
  /// - [taesd]: tiny autoencoder (TAESD) weights, such as
  ///   [ImageGenerationPresetFile.taesd].
  /// - [clipL], [clipG], [t5xxl]: standalone CLIP-L, CLIP-G and T5-XXL text
  ///   encoders.
  /// - [llm]: standalone language-model text encoder, such as Qwen3-4B for
  ///   Z-Image or Qwen2.5-VL-7B for Qwen-Image, as a `.gguf` or
  ///   `.safetensors` file.
  ///
  /// `ImageGenerationEngine.load` downloads remote files into the model
  /// cache.
  ImageGenerationModelFiles.fromSources({
    ModelSource? model,
    ModelSource? diffusionModel,
    ModelSource? vae,
    ModelSource? taesd,
    ModelSource? clipL,
    ModelSource? clipG,
    ModelSource? t5xxl,
    ModelSource? llm,
  }) : _sources = Map<String, ModelSource>.unmodifiable(<String, ModelSource>{
         'model': ?model,
         'diffusionModel': ?diffusionModel,
         'vae': ?vae,
         'taesd': ?taesd,
         'clipL': ?clipL,
         'clipG': ?clipG,
         't5xxl': ?t5xxl,
         'llm': ?llm,
       }),
       model = model?.path,
       diffusionModel = diffusionModel?.path,
       vae = vae?.path,
       taesd = taesd?.path,
       clipL = clipL?.path,
       clipG = clipG?.path,
       t5xxl = t5xxl?.path,
       llm = llm?.path;

  /// Every set file's source, keyed by role, in the order `model`,
  /// `diffusionModel`, `vae`, `taesd`, `clipL`, `clipG`, `t5xxl`, `llm`.
  ///
  /// A file set created from paths reports each path as a
  /// `ModelSource.path`, and throws [LlamaModelException] naming the role of
  /// an empty or blank path.
  Map<String, ModelSource> get sources {
    final sources = _sources;
    if (sources != null) {
      return sources;
    }
    return Map<String, ModelSource>.unmodifiable(<String, ModelSource>{
      for (final MapEntry(key: role, value: path) in paths.entries)
        role: path.trim().isEmpty
            ? throw LlamaModelException(
                'Image-generation $role file not found: "$path".',
              )
            : ModelSource.path(path),
    });
  }

  /// Every set local path, keyed by role, in declaration order. Files from
  /// URLs or Hugging Face are left out.
  @Deprecated('Use sources.')
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

/// A weight file the image-generation presets use, pinned to a Hugging Face
/// commit so its content never changes.
///
/// The `ImageGenerationModel` presets download these by default. Pass
/// [source] to a preset to choose an optional file, such as
/// `ImageGenerationModel.sdTurboPreset(taesd:
/// ImageGenerationPresetFile.taesd.source)`.
enum ImageGenerationPresetFile {
  /// SDXS-512 Q8_0 checkpoint (683 MB), from
  /// `concedo/sdxs-512-tinySDdistilled-GGUF`.
  sdxs(
    'concedo/sdxs-512-tinySDdistilled-GGUF',
    '3144d898d61492f8382ffcabec055733fc5b2a0e',
    'sdxs-512-tinySDdistilled_Q8_0.gguf',
    682847200,
    '409ab23582ee074c6b9d5395784fc0741b0599fb9d138686c69087c71678eb6a',
  ),

  /// SD-Turbo Q8_0 checkpoint (2.0 GB), from `Green-Sky/SD-Turbo-GGUF`.
  sdTurbo(
    'Green-Sky/SD-Turbo-GGUF',
    '19a31586d02d64a73b4419bc193b3ecfaf38e1f0',
    'sd_turbo-f16-q8_0.gguf',
    2023745376,
    'd50be7655f0a554cf8041c145d88b210bd5f3c545423119dee62ae08cae51580',
  ),

  /// TAESD decoder for SD 1.x and 2.x, including SD-Turbo (10 MB), from
  /// `madebyollin/taesd`.
  taesd(
    'madebyollin/taesd',
    '614f76814bbe30edbe2e627ace1c2234c81a2c0e',
    'diffusion_pytorch_model.safetensors',
    9793292,
    'db169d69145ec4ff064e49d99c95fa05d3eb04ee453de35824a6d0f325513549',
  ),

  /// SDXL-Lightning 4-step checkpoint (6.9 GB), from
  /// `ByteDance/SDXL-Lightning`.
  sdxlLightning(
    'ByteDance/SDXL-Lightning',
    'c9a24f48e1c025556787b0c58dd67a091ece2e44',
    'sdxl_lightning_4step.safetensors',
    6938040682,
    'e0d996ee0013e79d9d3561f50fcafb9a17e3ff07b780358e3b66d67932c4d490',
  ),

  /// TAESDXL decoder for SDXL (10 MB), from `madebyollin/taesdxl`.
  taesdxl(
    'madebyollin/taesdxl',
    'b20258aaef75ef61e659c1e0f14f251cf0ad153e',
    'diffusion_pytorch_model.safetensors',
    9793292,
    'ff4824aca94dd6111e0340fa749347fb74101060d9712cb5ef1ca8f1cf17502f',
  ),

  /// FLUX.1-schnell Q4_0 diffusion transformer (6.7 GB), from
  /// `second-state/FLUX.1-schnell-GGUF`.
  flux1Schnell(
    'second-state/FLUX.1-schnell-GGUF',
    '8c45a2ba25e2d02bd34230989fb54983f39e44ec',
    'flux1-schnell-Q4_0.gguf',
    6688845536,
    'b338a7ab5c81600a54be46c4cf950edb3761a52ae163e419beafd250976fb566',
  ),

  /// FLUX autoencoder `ae.safetensors`, also used by Z-Image-Turbo (335 MB),
  /// from `second-state/FLUX.1-schnell-GGUF`.
  fluxVae(
    'second-state/FLUX.1-schnell-GGUF',
    '8c45a2ba25e2d02bd34230989fb54983f39e44ec',
    'ae.safetensors',
    335304388,
    'afc8e28272cd15db3919bacdb6918ce9c1ed22e96cb12c4d5ed0fba823529e38',
  ),

  /// TAEF1 decoder for FLUX (10 MB), from `madebyollin/taef1`.
  taef1(
    'madebyollin/taef1',
    'b1b2d00e9e440cfbf3dedb34266864da86016ceb',
    'diffusion_pytorch_model.safetensors',
    9848636,
    '47a6c2bff850da04b267cab70fe3553fef57255eb9a8e76852baa0a87850e54d',
  ),

  /// CLIP-L Q8_0 text encoder for FLUX and SD 3.5 (131 MB), from
  /// `second-state/stable-diffusion-3.5-medium-GGUF`.
  clipL(
    'second-state/stable-diffusion-3.5-medium-GGUF',
    '58b78c305a43ddfcffe1ab54d7022995f61667ac',
    'clip_l-Q8_0.gguf',
    130864000,
    '482dfa677edb6499a689f1936f287351f3c104d5da9094d8c797da527a98323b',
  ),

  /// CLIP-G Q8_0 text encoder for SD 3.5 (739 MB), from
  /// `second-state/stable-diffusion-3.5-medium-GGUF`.
  clipG(
    'second-state/stable-diffusion-3.5-medium-GGUF',
    '58b78c305a43ddfcffe1ab54d7022995f61667ac',
    'clip_g-Q8_0.gguf',
    738543360,
    '0678985268cc46e8b61ae3671dc1909566b8d6d20a2a2e4b10c7402b59c7dd5a',
  ),

  /// T5-XXL Q8_0 text encoder for FLUX and SD 3.5 (5.2 GB), from
  /// `second-state/stable-diffusion-3.5-medium-GGUF`.
  t5xxl(
    'second-state/stable-diffusion-3.5-medium-GGUF',
    '58b78c305a43ddfcffe1ab54d7022995f61667ac',
    't5xxl-Q8_0.gguf',
    5199794784,
    'fc07757bf7ad40eaf612acc7ed0c0a7ab71189979e0b8b4d14601017baca22de',
  ),

  /// SD 3.5 Large Turbo Q4_0 diffusion transformer (4.8 GB), from
  /// `city96/stable-diffusion-3.5-large-turbo-gguf`.
  sd35LargeTurbo(
    'city96/stable-diffusion-3.5-large-turbo-gguf',
    '527c5548afc123f309238ca6bce7dfe3349aa997',
    'sd3.5_large_turbo-Q4_0.gguf',
    4772054752,
    'ac5e330d0e37a95771cee03efe50370dce79bf08119b6a74c5739196b9906678',
  ),

  /// TAESD3 decoder for SD 3.5 (10 MB), from `madebyollin/taesd3`. The
  /// SD 3.5 VAE is in a gated repository.
  taesd3(
    'madebyollin/taesd3',
    'd58dcaccd2b36fcb7a6b9e93c1cc507acab5a778',
    'diffusion_pytorch_model.safetensors',
    9848636,
    '6f79c1397cb9ce1dac363722dbe70147aee0ccca75e28338f8482fe515891399',
  ),

  /// Z-Image-Turbo Q4_K diffusion transformer (3.9 GB), from
  /// `leejet/Z-Image-Turbo-GGUF`.
  zImageTurbo(
    'leejet/Z-Image-Turbo-GGUF',
    'c61c0e422dc8b541b7548cf33a4ef8302b0f8085',
    'z_image_turbo-Q4_K.gguf',
    3864250304,
    '14b375ab4f226bc5378f68f37e899ef3c2242b8541e61e2bc1aff40976086fbd',
  ),

  /// Qwen3-4B-Instruct-2507 Q4_K_M text encoder for Z-Image-Turbo (2.5 GB),
  /// from `unsloth/Qwen3-4B-Instruct-2507-GGUF`.
  zImageTurboLlm(
    'unsloth/Qwen3-4B-Instruct-2507-GGUF',
    'a06e946bb6b655725eafa393f4a9745d460374c9',
    'Qwen3-4B-Instruct-2507-Q4_K_M.gguf',
    2497281120,
    '3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597',
  );

  const ImageGenerationPresetFile(
    this.repoId,
    this.revision,
    this.filePath,
    this.sizeBytes,
    this.sha256,
  );

  /// Hugging Face repository, such as `madebyollin/taesd`.
  final String repoId;

  /// Commit the file is pinned to.
  final String revision;

  /// Path of the file in [repoId].
  final String filePath;

  /// File size in bytes.
  final int sizeBytes;

  /// Lowercase hexadecimal SHA-256 of the file, as Hugging Face reports it.
  ///
  /// `ImageGenerationEngine.load` does not verify it: the model cache would
  /// hash the whole file again on every load. Apps that verify a download
  /// once can compare against it.
  final String sha256;

  /// The file as a Hugging Face source pinned to [revision].
  ModelSource get source => ModelSource.huggingFace(
    repoId: repoId,
    filePath: filePath,
    revision: revision,
  );

  /// The pinned file [source] names, or `null` for any other source.
  static ImageGenerationPresetFile? of(ModelSource source) {
    for (final file in values) {
      if (file.source.canonicalKey == source.canonicalKey) {
        return file;
      }
    }
    return null;
  }
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

  /// Creates generation defaults. The defaults suit undistilled SD 1.x and
  /// 2.x checkpoints; set [width] and [height] to 1024 for SDXL, SD 3.5,
  /// FLUX and Z-Image checkpoints.
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

/// An image-generation model: its files and the generation defaults it
/// needs.
///
/// Use a preset for the validated models, or [ImageGenerationModel.custom]
/// for other checkpoints stable-diffusion.cpp can load. Each preset
/// downloads its [ImageGenerationPresetFile]s from Hugging Face when
/// `ImageGenerationEngine.load` runs, and takes a `ModelSource` for any file
/// to replace, such as `ModelSource.path` for a local copy.
/// [ImageGenerationModel.sdxsPreset] and [ImageGenerationModel.sdTurboPreset]
/// fit phones and generate at 512x512 by default.
/// [ImageGenerationModel.sdxlLightningPreset],
/// [ImageGenerationModel.flux1SchnellPreset],
/// [ImageGenerationModel.sd35LargeTurboPreset] and
/// [ImageGenerationModel.zImageTurboPreset] are for desktop GPUs and Macs and
/// generate at 1024x1024 by default.
///
/// Building a model does no network or file access.
class ImageGenerationModel {
  /// Family the preset was built for.
  final ImageGenerationModelFamily family;

  /// Weight files.
  final ImageGenerationModelFiles files;

  /// Defaults applied when a request leaves the size, steps, guidance,
  /// sampler, scheduler or flow shift unset.
  final ImageGenerationDefaults defaults;

  const ImageGenerationModel._(this.family, this.files, this.defaults);

  static const ImageGenerationDefaults _oneStep = ImageGenerationDefaults(
    steps: 1,
    guidanceScale: 1,
  );

  static const ImageGenerationDefaults _sdxlLightning = ImageGenerationDefaults(
    width: 1024,
    height: 1024,
    steps: 4,
    guidanceScale: 1,
    sampler: ImageGenerationSampler.euler,
    scheduler: ImageGenerationScheduler.sgmUniform,
  );

  static const ImageGenerationDefaults _fourSteps1024 = ImageGenerationDefaults(
    width: 1024,
    height: 1024,
    steps: 4,
    guidanceScale: 1,
  );

  static const ImageGenerationDefaults _zImageTurbo = ImageGenerationDefaults(
    width: 1024,
    height: 1024,
    steps: 8,
    guidanceScale: 1,
  );

  /// SDXS-512, a one-step distilled SD 1.x-size model, from a single-file
  /// checkpoint: [model], by default [ImageGenerationPresetFile.sdxs]
  /// (683 MB).
  ///
  /// SDXS is distilled for exactly one step with guidance 1; more steps or a
  /// higher guidance scale degrade the image.
  factory ImageGenerationModel.sdxsPreset({ModelSource? model}) =>
      ImageGenerationModel._(
        ImageGenerationModelFamily.sdxs,
        ImageGenerationModelFiles.fromSources(
          model: model ?? ImageGenerationPresetFile.sdxs.source,
        ),
        _oneStep,
      );

  /// SD-Turbo, an adversarially distilled SD 2.1 model, from a single-file
  /// checkpoint: [model], by default [ImageGenerationPresetFile.sdTurbo]
  /// (2.0 GB).
  ///
  /// Defaults to one step with guidance 1. SD-Turbo also accepts up to four
  /// steps (`steps: 4`) for more detail at about four times the sampling
  /// time. [taesd] decodes with TAESD instead of the full VAE, which is
  /// several times faster and needs far less memory on phones; pass
  /// [ImageGenerationPresetFile.taesd]'s source for the pinned one.
  factory ImageGenerationModel.sdTurboPreset({
    ModelSource? model,
    ModelSource? taesd,
  }) => ImageGenerationModel._(
    ImageGenerationModelFamily.sdTurbo,
    ImageGenerationModelFiles.fromSources(
      model: model ?? ImageGenerationPresetFile.sdTurbo.source,
      taesd: taesd,
    ),
    _oneStep,
  );

  /// SDXL-Lightning 4-step from a single-file checkpoint: [model], by
  /// default [ImageGenerationPresetFile.sdxlLightning] (6.9 GB).
  ///
  /// Generates at 1024x1024 by default, in 4 steps at guidance 1 with Euler
  /// and the `sgmUniform` schedule, as the model card recommends. [vae]
  /// replaces the checkpoint's VAE, for example with
  /// `madebyollin/sdxl-vae-fp16-fix`; [taesd] decodes with a tiny
  /// autoencoder instead, such as [ImageGenerationPresetFile.taesdxl], which
  /// halved the time per image on an M4 Max at no visible quality cost. The memory check asks
  /// for about 8.6 GiB: a desktop GPU or a Mac with 16 GB or more.
  factory ImageGenerationModel.sdxlLightningPreset({
    ModelSource? model,
    ModelSource? vae,
    ModelSource? taesd,
  }) => ImageGenerationModel._(
    ImageGenerationModelFamily.sdxlLightning,
    ImageGenerationModelFiles.fromSources(
      model: model ?? ImageGenerationPresetFile.sdxlLightning.source,
      vae: vae,
      taesd: taesd,
    ),
    _sdxlLightning,
  );

  /// FLUX.1-schnell from split files: the diffusion transformer
  /// [diffusionModel] (by default [ImageGenerationPresetFile.flux1Schnell],
  /// 6.7 GB), the CLIP-L and T5-XXL text encoders [clipL] and [t5xxl]
  /// ([ImageGenerationPresetFile.clipL] and [ImageGenerationPresetFile.t5xxl],
  /// 5.3 GB together) and a decoder.
  ///
  /// The decoder is the FLUX autoencoder [ImageGenerationPresetFile.fluxVae]
  /// unless [vae] or [taesd] is set; then it is exactly the ones set. Pass
  /// [ImageGenerationPresetFile.taef1]'s source as [taesd] for the tiny
  /// decoder.
  ///
  /// Generates at 1024x1024 by default, in 4 steps at guidance 1. The memory
  /// check asks for about 14.5 GiB: a desktop GPU with 16 GB or a Mac with
  /// 24 GB or more.
  factory ImageGenerationModel.flux1SchnellPreset({
    ModelSource? diffusionModel,
    ModelSource? clipL,
    ModelSource? t5xxl,
    ModelSource? vae,
    ModelSource? taesd,
  }) {
    final defaultDecoder = vae == null && taesd == null;
    return ImageGenerationModel._(
      ImageGenerationModelFamily.flux1Schnell,
      ImageGenerationModelFiles.fromSources(
        diffusionModel:
            diffusionModel ?? ImageGenerationPresetFile.flux1Schnell.source,
        vae: defaultDecoder ? ImageGenerationPresetFile.fluxVae.source : vae,
        taesd: taesd,
        clipL: clipL ?? ImageGenerationPresetFile.clipL.source,
        t5xxl: t5xxl ?? ImageGenerationPresetFile.t5xxl.source,
      ),
      _fourSteps1024,
    );
  }

  /// SD 3.5 Large Turbo from split files: the diffusion transformer
  /// [diffusionModel] (by default [ImageGenerationPresetFile.sd35LargeTurbo],
  /// 4.8 GB), the CLIP-L, CLIP-G and T5-XXL text encoders [clipL], [clipG]
  /// and [t5xxl] ([ImageGenerationPresetFile.clipL],
  /// [ImageGenerationPresetFile.clipG] and [ImageGenerationPresetFile.t5xxl],
  /// 6.1 GB together) and a decoder.
  ///
  /// The decoder is the tiny [ImageGenerationPresetFile.taesd3], since the
  /// SD 3.5 VAE repository is gated, unless [vae] or [taesd] is set; then it
  /// is exactly the ones set.
  ///
  /// Generates at 1024x1024 by default, in 4 steps at guidance 1. The memory
  /// check asks for about 13.1 GiB: a desktop GPU with 16 GB or a Mac with
  /// 24 GB or more.
  factory ImageGenerationModel.sd35LargeTurboPreset({
    ModelSource? diffusionModel,
    ModelSource? clipL,
    ModelSource? clipG,
    ModelSource? t5xxl,
    ModelSource? vae,
    ModelSource? taesd,
  }) {
    final defaultDecoder = vae == null && taesd == null;
    return ImageGenerationModel._(
      ImageGenerationModelFamily.sd35LargeTurbo,
      ImageGenerationModelFiles.fromSources(
        diffusionModel:
            diffusionModel ?? ImageGenerationPresetFile.sd35LargeTurbo.source,
        vae: vae,
        taesd: defaultDecoder ? ImageGenerationPresetFile.taesd3.source : taesd,
        clipL: clipL ?? ImageGenerationPresetFile.clipL.source,
        clipG: clipG ?? ImageGenerationPresetFile.clipG.source,
        t5xxl: t5xxl ?? ImageGenerationPresetFile.t5xxl.source,
      ),
      _fourSteps1024,
    );
  }

  /// Z-Image-Turbo from split files: the diffusion transformer
  /// [diffusionModel] (by default [ImageGenerationPresetFile.zImageTurbo],
  /// 3.9 GB), the Qwen3-4B text encoder [llm]
  /// ([ImageGenerationPresetFile.zImageTurboLlm], 2.5 GB) and the FLUX
  /// autoencoder [vae] ([ImageGenerationPresetFile.fluxVae], 335 MB).
  ///
  /// Generates at 1024x1024 by default, in 8 steps at guidance 1. The memory
  /// check asks for about 8.3 GiB: a desktop GPU with 12 GB or a Mac with
  /// 16 GB or more.
  factory ImageGenerationModel.zImageTurboPreset({
    ModelSource? diffusionModel,
    ModelSource? llm,
    ModelSource? vae,
  }) => ImageGenerationModel._(
    ImageGenerationModelFamily.zImageTurbo,
    ImageGenerationModelFiles.fromSources(
      diffusionModel:
          diffusionModel ?? ImageGenerationPresetFile.zImageTurbo.source,
      vae: vae ?? ImageGenerationPresetFile.fluxVae.source,
      llm: llm ?? ImageGenerationPresetFile.zImageTurboLlm.source,
    ),
    _zImageTurbo,
  );

  /// SDXS-512 from a local single-file checkpoint.
  @Deprecated(
    'Use ImageGenerationModel.sdxsPreset(model: ModelSource.path(modelPath)), '
    'or sdxsPreset() to download the pinned file.',
  )
  factory ImageGenerationModel.sdxs(String modelPath) => ImageGenerationModel._(
    ImageGenerationModelFamily.sdxs,
    ImageGenerationModelFiles(model: modelPath),
    _oneStep,
  );

  /// SD-Turbo from a local single-file checkpoint, optionally decoding with
  /// TAESD from [taesdPath].
  @Deprecated(
    'Use ImageGenerationModel.sdTurboPreset(model: ModelSource.path(...), '
    'taesd: ModelSource.path(...)).',
  )
  factory ImageGenerationModel.sdTurbo(String modelPath, {String? taesdPath}) =>
      ImageGenerationModel._(
        ImageGenerationModelFamily.sdTurbo,
        ImageGenerationModelFiles(model: modelPath, taesd: taesdPath),
        _oneStep,
      );

  /// SDXL-Lightning 4-step from a local single-file checkpoint.
  @Deprecated(
    'Use ImageGenerationModel.sdxlLightningPreset with ModelSource.path for '
    'each local file.',
  )
  factory ImageGenerationModel.sdxlLightning(
    String modelPath, {
    String? vaePath,
    String? taesdPath,
  }) => ImageGenerationModel._(
    ImageGenerationModelFamily.sdxlLightning,
    ImageGenerationModelFiles(model: modelPath, vae: vaePath, taesd: taesdPath),
    _sdxlLightning,
  );

  /// FLUX.1-schnell from local split files.
  ///
  /// Throws [ArgumentError] when neither [vaePath] nor [taesdPath] is set.
  @Deprecated(
    'Use ImageGenerationModel.flux1SchnellPreset with ModelSource.path for '
    'each local file.',
  )
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
    _fourSteps1024,
  );

  /// SD 3.5 Large Turbo from local split files.
  ///
  /// Throws [ArgumentError] when neither [vaePath] nor [taesdPath] is set.
  @Deprecated(
    'Use ImageGenerationModel.sd35LargeTurboPreset with ModelSource.path for '
    'each local file.',
  )
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
    _fourSteps1024,
  );

  /// Z-Image-Turbo from local split files.
  @Deprecated(
    'Use ImageGenerationModel.zImageTurboPreset with ModelSource.path for '
    'each local file.',
  )
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
    _zImageTurbo,
  );

  static String? _decoder(String? vaePath, String? taesdPath, String preset) {
    if (vaePath == null && taesdPath == null) {
      throw ArgumentError(
        'ImageGenerationModel.$preset needs vaePath or taesdPath.',
      );
    }
    return vaePath;
  }

  /// Any other checkpoint, with the size and sampling [defaults] it needs.
  ///
  /// Experimental. Any family the bundled stable-diffusion.cpp supports can
  /// load, including SDXL, SD 3.5, FLUX, Z-Image and Qwen-Image; the
  /// runtime detects the family from the weights. Each family needs its own
  /// file roles (see [ImageGenerationModelFiles]) and [defaults]: distilled
  /// models such as SDXL-Lightning or FLUX.1-schnell use about 4 steps at
  /// guidance 1, and families trained at 1024x1024 need `width: 1024,
  /// height: 1024`, since the defaults are 512x512. A single-file checkpoint
  /// that includes its VAE and text encoders, such as an SD 3.5 Medium GGUF,
  /// goes in the `model` role, not `diffusionModel`.
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
  /// (a `taesd` file or the SDXS preset). In
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
