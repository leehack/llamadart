import '../../backends/stable_diffusion/stable_diffusion_runtime_status.dart';
import 'generated_image.dart';

/// Model files and runtime settings for one native image-generation context.
final class ImageGenerationSessionConfig {
  /// Weight files keyed by role, as in `ImageGenerationModelFiles.paths`.
  final Map<String, String> files;

  /// stable-diffusion.cpp backend name (`cpu`, `gpu`), or `null` for the
  /// runtime default.
  final String? backend;

  /// CPU threads; `0` uses the physical core count.
  final int threads;

  /// Creates a session configuration.
  const ImageGenerationSessionConfig({
    required this.files,
    required this.backend,
    required this.threads,
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
  });
}

/// Memory the device can give an image model, and where the figure came from.
typedef ImageGenerationMemoryBudget = ({int bytes, String source});

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

  /// Size of the file at [path] in bytes, or `null` when it does not exist.
  int? fileSize(String path);

  /// Memory available to a new model, or `null` when the platform does not
  /// report it.
  ImageGenerationMemoryBudget? memoryBudget();

  /// Loads a native context.
  ///
  /// Throws `LlamaModelException` when the runtime rejects the files.
  Future<ImageGenerationSession> start(ImageGenerationSessionConfig config);
}

/// Test-only driver override used by focused public API tests.
ImageGenerationDriver? debugImageGenerationDriverOverride;
