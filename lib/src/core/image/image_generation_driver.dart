import 'dart:typed_data';

import '../../backends/stable_diffusion/stable_diffusion_runtime_status.dart';
import 'generated_image.dart';
import 'image_generation_model.dart';

/// Model files and runtime settings for one native image-generation context.
final class ImageGenerationSessionConfig {
  /// Local weight files keyed by runtime role: `model` (a checkpoint),
  /// `diffusionModel`, `vae`, `taesd`, `clipL`, `clipG`, `t5xxl` or `llm`.
  final Map<String, String> files;

  /// stable-diffusion.cpp backend name (`cpu`, `gpu`), or `null` for the
  /// runtime default.
  final String? backend;

  /// CPU threads; `0` uses the physical core count.
  final int threads;

  /// Whether the diffusion model uses flash attention.
  final bool flashAttention;

  /// Whether the VAE decodes with direct convolutions.
  final bool vaeDirectConvolution;

  /// Creates a session configuration.
  const ImageGenerationSessionConfig({
    required this.files,
    required this.backend,
    required this.threads,
    this.flashAttention = false,
    this.vaeDirectConvolution = false,
  });
}

/// Fully resolved parameters for one native generation.
final class ImageGenerationSessionRequest {
  /// Prompt.
  final String prompt;

  /// Negative prompt.
  final String negativePrompt;

  /// Width in pixels.
  final int width;

  /// Height in pixels.
  final int height;

  /// Sampling steps.
  final int steps;

  /// Classifier-free guidance scale.
  final double guidanceScale;

  /// Seed of the first image.
  final int seed;

  /// Number of images.
  final int count;

  /// Sampling method, or `null` for the runtime default.
  final ImageGenerationSampler? sampler;

  /// Noise schedule, or `null` for the runtime default.
  final ImageGenerationScheduler? scheduler;

  /// Flow shift, or `null` for the runtime default.
  final double? flowShift;

  /// Creates resolved generation parameters.
  const ImageGenerationSessionRequest({
    required this.prompt,
    required this.negativePrompt,
    required this.width,
    required this.height,
    required this.steps,
    required this.guidanceScale,
    required this.seed,
    required this.count,
    this.sampler,
    this.scheduler,
    this.flowShift,
  });
}

/// Memory the device can give an image model, and where the figure came from.
typedef ImageGenerationMemoryBudget = ({int bytes, String source});

/// Kind of device a model loads on, which decides whose memory bounds it.
enum ImageGenerationComputeDevice {
  /// The CPU: host memory.
  cpu,

  /// An Apple GPU through Metal: unified memory, bounded by Metal's
  /// recommended working set.
  metal,

  /// Any other GPU, such as Vulkan: its own device memory as the runtime
  /// reports it, or host memory when the GPU is an integrated one.
  otherGpu,
}

/// A loaded native image-generation context.
abstract interface class ImageGenerationSession {
  /// Model family the runtime detected, such as `SD 2.x`.
  String get modelVersion;

  /// Runs one generation, reporting native `(step, steps)` progress.
  ///
  /// Returns `null` when the runtime reports failure, which includes a
  /// cancelled generation and a GPU command-buffer abort. The session stays
  /// usable afterwards.
  Future<List<GeneratedImage>?> generate(
    ImageGenerationSessionRequest request,
    void Function(int step, int steps) onProgress,
  );

  /// Asks a running [generate] to stop. Safe to call at any time; the
  /// runtime clears the request when the next generation starts.
  void cancel();

  /// Frees the native context. Must not overlap [generate].
  Future<void> dispose();
}

/// Platform services behind `ImageGenerationEngine`.
abstract interface class ImageGenerationDriver {
  /// Probes the stable_diffusion runtime without loading a model.
  StableDiffusionRuntimeStatus probe();

  /// [probe] without blocking the calling isolate: on native platforms it
  /// runs in a short-lived isolate, because the first probe in a process can
  /// compile GPU shaders for seconds.
  Future<StableDiffusionRuntimeStatus> probeInBackground();

  /// Size of the file at [path] in bytes, or `null` when it does not exist.
  int? fileSize(String path);

  /// Up to [length] bytes of the file at [path] from [offset], for reading
  /// model file headers; fewer at the end of the file.
  Future<Uint8List> readFileRange(String path, int offset, int length);

  /// Memory available to a new model on [device], or `null` when it is not
  /// known. Asking a GPU other than Metal is a native call that can block, so
  /// on native platforms it runs in a short-lived isolate.
  Future<ImageGenerationMemoryBudget?> memoryBudget(
    ImageGenerationComputeDevice device,
  );

  /// Loads a native context. On native platforms the runtime's messages
  /// reach `LlamaLogger` from then on, at the levels `LlamaLogging` has when
  /// this is called.
  ///
  /// Throws `LlamaModelException` when the runtime rejects the files, with
  /// the runtime's reason when it gives one.
  Future<ImageGenerationSession> start(ImageGenerationSessionConfig config);
}

/// Test-only driver override used by focused public API tests.
ImageGenerationDriver? debugImageGenerationDriverOverride;
