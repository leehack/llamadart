import 'dart:typed_data';

import '../../backends/stable_diffusion/stable_diffusion_runtime_status.dart';
import '../../backends/stable_diffusion/stable_diffusion_runtime_stub.dart';
import 'image_generation_driver.dart';

/// Creates the driver for platforms without native image generation, such as
/// the web. Its probe always reports the runtime unavailable.
ImageGenerationDriver createImageGenerationDriver() =>
    const _UnsupportedImageGenerationDriver();

class _UnsupportedImageGenerationDriver implements ImageGenerationDriver {
  const _UnsupportedImageGenerationDriver();

  @override
  StableDiffusionRuntimeStatus probe() => probeStableDiffusionRuntime();

  @override
  Future<StableDiffusionRuntimeStatus> probeInBackground() async => probe();

  @override
  int? fileSize(String path) => null;

  @override
  Future<Uint8List> readFileRange(String path, int offset, int length) =>
      Future.error(probe().unavailableReason!);

  @override
  ImageGenerationMemoryBudget? memoryBudget(
    ImageGenerationComputeDevice device,
  ) => null;

  @override
  Future<ImageGenerationSession> start(ImageGenerationSessionConfig config) =>
      Future.error(probe().unavailableReason!);
}
