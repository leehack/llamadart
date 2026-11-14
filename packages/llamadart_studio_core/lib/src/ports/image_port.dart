import 'dart:typed_data';

import 'package:llamadart/llamadart.dart';
import 'package:meta/meta.dart';

import 'model_storage_port.dart';

/// Generated image artifact stored in Image Studio's session gallery.
@immutable
class StudioGeneratedImageItem {
  /// Creates a [StudioGeneratedImageItem].
  const StudioGeneratedImageItem({
    required this.id,
    required this.prompt,
    required this.negativePrompt,
    required this.pngBytes,
    required this.width,
    required this.height,
    required this.steps,
    required this.guidanceScale,
    required this.seed,
    required this.elapsedMs,
    required this.modelName,
    required this.createdAt,
  });

  /// Unique gallery item ID.
  final String id;

  /// Positive prompt.
  final String prompt;

  /// Negative prompt.
  final String negativePrompt;

  /// Encoded PNG bytes.
  final Uint8List pngBytes;

  /// Output width in pixels.
  final int width;

  /// Output height in pixels.
  final int height;

  /// Sampling steps run.
  final int steps;

  /// CFG scale used.
  final double guidanceScale;

  /// Deterministic seed used by the sampler.
  final int seed;

  /// Wall-clock generation time in milliseconds.
  final int elapsedMs;

  /// Diffusion checkpoint display name.
  final String modelName;

  /// Creation timestamp.
  final DateTime createdAt;
}

/// Port wrapping Stable Diffusion image generation.
abstract interface class StudioImagePort {
  /// Probes runtime support before loading a checkpoint.
  Future<ImageGenerationCapabilities> checkRuntime();

  /// Loads a diffusion checkpoint (and optional TAESD companion).
  Future<ImageGenerationCapabilities> loadModel({
    required ResolvedModelAssets assets,
    ComputeDevice device = ComputeDevice.auto,
  });

  /// Generates an image, emitting step progress via [onProgress].
  Future<StudioGeneratedImageItem> generateImage({
    required String prompt,
    String negativePrompt = '',
    int width = 512,
    int height = 512,
    int steps = 1,
    double guidanceScale = 1.0,
    int? seed,
    void Function(ImageGenerationProgressEvent event)? onProgress,
  });

  /// Requests cooperative cancellation of the active diffusion pass.
  void cancelGeneration();

  /// Disposes the active diffusion engine.
  Future<void> dispose();
}
