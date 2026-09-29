import 'image_generation_events.dart';

/// Labels stable-diffusion.cpp progress callbacks with a phase.
///
/// The runtime reports every kind of progress through one
/// `(step, steps)` callback with no phase: sampling steps, tensors loaded
/// lazily, and VAE tiles. The labels are derived from the call sequence:
///
/// - Generation starts in [ImageGenerationPhase.encodingPrompt]; the runtime
///   reports nothing while it encodes the prompt.
/// - A callback whose total equals the resolved sampling step count is a
///   sampling step. Each image's pass reports `0/steps` when its first step
///   starts and `k/steps` after step `k`.
/// - When the last image's pass reports `steps/steps`, a
///   [ImageGenerationPhase.decoding] event follows with `0/imageCount`; the
///   runtime reports no decoding progress unless it decodes in tiles.
/// - Any other callback is [ImageGenerationPhase.decoding] once every image
///   is sampled (tiled VAE decode) and [ImageGenerationPhase.loading] before
///   that (lazy tensor loading, which reports tensor counts).
///
/// The engine loads weights eagerly, so loading callbacks do not occur in
/// practice. A lazily loaded tensor group whose size equals the step count
/// would be mislabelled as sampling.
final class ImageGenerationProgressTracker {
  /// Resolved sampling steps per image.
  final int steps;

  /// Number of images requested.
  final int imageCount;

  int _completedImages = 0;

  /// Creates a tracker for one generation.
  ImageGenerationProgressTracker({
    required this.steps,
    required this.imageCount,
  });

  /// The event emitted when generation starts.
  ImageGenerationProgressEvent start() =>
      _event(ImageGenerationPhase.encodingPrompt, 0, steps);

  /// The events one native `(step, total)` callback maps to.
  List<ImageGenerationProgressEvent> onNativeProgress(int step, int total) {
    final allSampled = _completedImages >= imageCount;
    if (total != steps || step < 0 || step > steps || allSampled) {
      return [
        _event(
          allSampled
              ? ImageGenerationPhase.decoding
              : ImageGenerationPhase.loading,
          step,
          total,
        ),
      ];
    }
    final events = [_event(ImageGenerationPhase.sampling, step, steps)];
    if (step == steps) {
      _completedImages++;
      if (_completedImages == imageCount) {
        events.add(_event(ImageGenerationPhase.decoding, 0, imageCount));
      }
    }
    return events;
  }

  ImageGenerationProgressEvent _event(
    ImageGenerationPhase phase,
    int step,
    int total,
  ) => ImageGenerationProgressEvent(
    phase: phase,
    step: step,
    steps: total,
    imageIndex: _completedImages < imageCount
        ? _completedImages
        : imageCount - 1,
    imageCount: imageCount,
  );
}
