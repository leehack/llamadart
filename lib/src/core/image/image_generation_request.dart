import '../exceptions.dart';
import 'image_generation_model.dart';

/// A request to generate one or more images from a text prompt.
class ImageGenerationRequest {
  /// Smallest accepted [width] and [height].
  static const int minDimension = 64;

  /// Largest accepted [width] and [height].
  static const int maxDimension = 2048;

  /// Largest accepted [steps].
  static const int maxSteps = 150;

  /// Largest accepted [guidanceScale].
  static const double maxGuidanceScale = 30;

  /// Largest accepted [count].
  static const int maxCount = 16;

  /// Largest accepted [flowShift].
  static const double maxFlowShift = 100;

  /// Text prompt.
  final String prompt;

  /// Negative prompt. Ignored when the guidance scale is 1, as distilled
  /// models such as SDXS and SD-Turbo use.
  final String negativePrompt;

  /// Output width in pixels: a multiple of 8 from [minDimension] to
  /// [maxDimension]. `null` uses the model's native width
  /// (`ImageGenerationDefaults.width`), such as 512 for SDXS and SD-Turbo or
  /// 1024 for SDXL and newer families. The runtime rounds SD 1.x and 2.x sizes up to a
  /// multiple of 64; `GeneratedImage.width` reports the size produced.
  final int? width;

  /// Output height in pixels, with the same range, default and rounding as
  /// [width].
  final int? height;

  /// Sampling steps from 1 to [maxSteps]. `null` uses the model's default.
  final int? steps;

  /// Classifier-free guidance scale from 0 to [maxGuidanceScale]. `null` uses
  /// the model's default.
  final double? guidanceScale;

  /// Random seed, 0 or greater. `null` picks a random seed; the result
  /// reports the seed used either way.
  final int? seed;

  /// Number of images, from 1 to [maxCount]. Image `i` uses seed `seed + i`.
  final int count;

  /// Sampling method. `null` uses the model's default.
  final ImageGenerationSampler? sampler;

  /// Noise schedule. `null` uses the model's default.
  final ImageGenerationScheduler? scheduler;

  /// Timestep shift of flow-matching models, greater than 0 and at most
  /// [maxFlowShift]. `null` uses the model's default; other models ignore
  /// it.
  final double? flowShift;

  /// Creates an image-generation request.
  const ImageGenerationRequest({
    required this.prompt,
    this.negativePrompt = '',
    this.width,
    this.height,
    this.steps,
    this.guidanceScale,
    this.seed,
    this.count = 1,
    this.sampler,
    this.scheduler,
    this.flowShift,
  });
}

/// Throws [LlamaImageGenerationException] naming the first invalid field of
/// [request].
void validateImageGenerationRequest(ImageGenerationRequest request) {
  Never reject(String message, Object? value) =>
      throw LlamaImageGenerationException(message, value);

  if (request.prompt.trim().isEmpty) {
    reject('The image-generation prompt must not be empty.', null);
  }
  for (final (name, value) in [
    ('width', request.width),
    ('height', request.height),
  ]) {
    if (value != null &&
        (value < ImageGenerationRequest.minDimension ||
            value > ImageGenerationRequest.maxDimension ||
            value % 8 != 0)) {
      reject(
        '$name must be a multiple of 8 from '
        '${ImageGenerationRequest.minDimension} to '
        '${ImageGenerationRequest.maxDimension}.',
        value,
      );
    }
  }
  final steps = request.steps;
  if (steps != null && (steps < 1 || steps > ImageGenerationRequest.maxSteps)) {
    reject(
      'steps must be from 1 to ${ImageGenerationRequest.maxSteps}.',
      steps,
    );
  }
  final guidanceScale = request.guidanceScale;
  if (guidanceScale != null &&
      (!guidanceScale.isFinite ||
          guidanceScale < 0 ||
          guidanceScale > ImageGenerationRequest.maxGuidanceScale)) {
    reject(
      'guidanceScale must be from 0 to '
      '${ImageGenerationRequest.maxGuidanceScale}.',
      guidanceScale,
    );
  }
  final seed = request.seed;
  if (seed != null && seed < 0) {
    reject('seed must be 0 or greater.', seed);
  }
  if (request.count < 1 || request.count > ImageGenerationRequest.maxCount) {
    reject(
      'count must be from 1 to ${ImageGenerationRequest.maxCount}.',
      request.count,
    );
  }
  final flowShift = request.flowShift;
  if (flowShift != null &&
      (!flowShift.isFinite ||
          flowShift <= 0 ||
          flowShift > ImageGenerationRequest.maxFlowShift)) {
    reject(
      'flowShift must be greater than 0 and at most '
      '${ImageGenerationRequest.maxFlowShift}.',
      flowShift,
    );
  }
}
