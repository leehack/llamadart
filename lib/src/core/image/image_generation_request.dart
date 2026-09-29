import '../exceptions.dart';

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

  /// Text prompt.
  final String prompt;

  /// Negative prompt. Ignored when the guidance scale is 1, as with the SDXS
  /// and SD-Turbo presets.
  final String negativePrompt;

  /// Output width in pixels: a multiple of 8 from [minDimension] to
  /// [maxDimension]. SD 1.x and 2.x models are trained at 512.
  final int width;

  /// Output height in pixels: a multiple of 8 from [minDimension] to
  /// [maxDimension].
  final int height;

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

  /// Creates an image-generation request.
  const ImageGenerationRequest({
    required this.prompt,
    this.negativePrompt = '',
    this.width = 512,
    this.height = 512,
    this.steps,
    this.guidanceScale,
    this.seed,
    this.count = 1,
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
    if (value < ImageGenerationRequest.minDimension ||
        value > ImageGenerationRequest.maxDimension ||
        value % 8 != 0) {
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
}
