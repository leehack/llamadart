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

  /// Decodes the image in overlapping tiles to lower the decoder's peak
  /// memory. `null` decodes the whole image at once, as before.
  final ImageVaeTiling? vaeTiling;

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
    this.vaeTiling,
  });
}

/// Spatial tiling of an image's VAE decode: `ImageGenerationRequest.vaeTiling`.
///
/// The decoder (the VAE, or the tiny autoencoder that replaces it) runs on
/// one [tileWidth] by [tileHeight] tile of the image at a time instead of on
/// the whole image, and blends where tiles overlap. Its compute buffer then
/// scales with the tile instead of the image, which lowers peak memory most
/// for large images and full VAEs. Decoding takes longer, and pixels change
/// slightly, mostly near tile seams. Sampling, the prompt encoders and the
/// weights are unaffected. A tile larger than the image covers the whole
/// image on that axis.
///
/// Without tiling, the runtime already retries a decode that fails to
/// allocate its buffers with tiles; tiling from the start avoids reaching that
/// limit, as where the system ends an app before an allocation fails. If a
/// tile still does not fit, the runtime retries with smaller tiles.
class ImageVaeTiling {
  /// Smallest accepted [tileWidth] and [tileHeight], and the step both
  /// take: a multiple of every supported decoder's downscale factor.
  static const int minTileSize = 64;

  /// Largest accepted [tileWidth] and [tileHeight].
  static const int maxTileSize = ImageGenerationRequest.maxDimension;

  /// [tileWidth] and [tileHeight] when unset: stable-diffusion.cpp's default.
  static const int defaultTileSize = 256;

  /// Largest accepted [overlap].
  static const double maxOverlap = 0.5;

  /// [overlap] when unset: stable-diffusion.cpp's default.
  static const double defaultOverlap = 0.5;

  /// Tile width in output pixels: a multiple of [minTileSize] up to
  /// [maxTileSize].
  final int tileWidth;

  /// Tile height in output pixels, with the same range as [tileWidth].
  final int tileHeight;

  /// Target fraction of a tile that overlaps its neighbour, from 0 to
  /// [maxOverlap]. More overlap blends seams better and decodes more tiles.
  /// The runtime spaces tiles evenly, so the overlap it uses is close to this
  /// one, and neighbouring tiles always overlap a little.
  final double overlap;

  /// Creates tiling settings.
  const ImageVaeTiling({
    this.tileWidth = defaultTileSize,
    this.tileHeight = defaultTileSize,
    this.overlap = defaultOverlap,
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
  final vaeTiling = request.vaeTiling;
  if (vaeTiling != null) {
    for (final (name, value) in [
      ('vaeTiling.tileWidth', vaeTiling.tileWidth),
      ('vaeTiling.tileHeight', vaeTiling.tileHeight),
    ]) {
      if (value < ImageVaeTiling.minTileSize ||
          value > ImageVaeTiling.maxTileSize ||
          value % ImageVaeTiling.minTileSize != 0) {
        reject(
          '$name must be a multiple of ${ImageVaeTiling.minTileSize} from '
          '${ImageVaeTiling.minTileSize} to ${ImageVaeTiling.maxTileSize}.',
          value,
        );
      }
    }
    final overlap = vaeTiling.overlap;
    if (!overlap.isFinite ||
        overlap < 0 ||
        overlap > ImageVaeTiling.maxOverlap) {
      reject(
        'vaeTiling.overlap must be from 0 to ${ImageVaeTiling.maxOverlap}.',
        overlap,
      );
    }
  }
}
