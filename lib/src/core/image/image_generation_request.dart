import '../exceptions.dart';
import 'image_generation_model.dart';
import 'image_generation_driver.dart';

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

  /// Width and height used when a request leaves them unset.
  static const int defaultDimension = 512;

  /// Steps used when a request leaves them unset.
  static const int defaultSteps = 20;

  /// Guidance scale used when a request leaves it unset.
  static const double defaultGuidanceScale = 7;

  /// Text prompt.
  final String prompt;

  /// Negative prompt. Ignored when the guidance scale is 1, as distilled
  /// models such as SDXS and SD-Turbo use.
  final String negativePrompt;

  /// Output width in pixels: a multiple of 8 from [minDimension] to
  /// [maxDimension]. `null` uses [defaultDimension]. Use the model's native
  /// size: 512 for SD 1.x and 2.x models such as SDXS and SD-Turbo, 1024 for
  /// SDXL and newer families. The runtime rounds SD 1.x and 2.x sizes up to a
  /// multiple of 64; `GeneratedImage.width` reports the size produced.
  final int? width;

  /// Output height in pixels, with the same range, default and rounding as
  /// [width].
  final int? height;

  /// Sampling steps from 1 to [maxSteps]. `null` uses [defaultSteps], which
  /// suits undistilled SD 1.x and 2.x models; distilled models such as SDXS,
  /// SD-Turbo or FLUX.1-schnell need 1 to 8.
  final int? steps;

  /// Classifier-free guidance scale from 0 to [maxGuidanceScale]. `null` uses
  /// [defaultGuidanceScale]; distilled models use 1, which also skips the
  /// negative prompt and halves the work per step.
  final double? guidanceScale;

  /// Random seed, 0 or greater. `null` picks a random seed; the result
  /// reports the seed used either way.
  final int? seed;

  /// Number of images, from 1 to [maxCount]. Image `i` uses seed `seed + i`.
  final int count;

  /// Sampling method. `null` uses the runtime's default for the model.
  final ImageGenerationSampler? sampler;

  /// Noise schedule. `null` uses the runtime's default for the model and
  /// sampler.
  final ImageGenerationScheduler? scheduler;

  /// Timestep shift of flow-matching models, greater than 0 and at most
  /// [maxFlowShift]. `null` uses the runtime's default for the model; other
  /// models ignore it.
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

/// A text-to-image request with independently repeatable texture axes.
///
/// Both axes default to off. When either is enabled, the initial qualified
/// recipe is SDXS (512-DS) with its header-detected embedded tiny decoder,
/// no component overrides, 512 by 512 pixels, and CPU or Metal computation.
/// Load with `flashAttention: false` and `vaeDirectConvolution: false`.
/// Other families, decoders, sizes and runtime options throw
/// [LlamaUnsupportedException] before generation starts.
///
/// The runtime applies circular padding to both diffusion and decoder
/// convolutions. Inspect a repeated tile: this improves continuity but does
/// not promise that every prompt and seed produces a useful texture.
///
/// This separate type preserves existing implementations and subclasses of
/// [ImageGenerationRequest]. Ordinary requests keep their original behavior.
final class SeamlessImageGenerationRequest extends ImageGenerationRequest {
  /// Wraps left and right convolution boundaries.
  final bool circularX;

  /// Wraps top and bottom convolution boundaries.
  final bool circularY;

  /// Creates a request with independently optional circular axes.
  const SeamlessImageGenerationRequest({
    required super.prompt,
    super.negativePrompt,
    super.width,
    super.height,
    super.steps,
    super.guidanceScale,
    super.seed,
    super.count,
    super.sampler,
    super.scheduler,
    super.flowShift,
    this.circularX = false,
    this.circularY = false,
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

/// Rejects circular generation outside the measured SDXS decoder recipe.
/// Checks the native family and header evidence, never the model filename.
void validateSeamlessImageGenerationRecipe(
  ImageGenerationSessionRequest request,
  ImageGenerationSessionConfig config,
  String modelVersion,
) {
  if (!request.circularX && !request.circularY) return;
  if (modelVersion != 'SDXS (512-DS)' ||
      !config.seamlessRecipeVerified ||
      config.files.length != 1 ||
      !config.files.containsKey('model') ||
      request.width != 512 ||
      request.height != 512 ||
      config.flashAttention ||
      config.vaeDirectConvolution) {
    throw LlamaUnsupportedException(
      'Seamless textures require stable_diffusion v0.3.0 SDXS (512-DS), '
      'its header-detected embedded tiny decoder without component overrides '
      'on CPU or Metal, '
      '512 by 512 pixels, flashAttention: false and '
      'vaeDirectConvolution: false. This model or decoder recipe is '
      'not qualified for circular padding.',
    );
  }
}
