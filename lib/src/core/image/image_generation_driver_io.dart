import 'dart:isolate';
import 'dart:typed_data';

import '../../backends/stable_diffusion/stable_diffusion_image_worker.dart';
import '../../backends/stable_diffusion/stable_diffusion_memory.dart';
import '../../backends/stable_diffusion/stable_diffusion_runtime_io.dart';
import '../../backends/stable_diffusion/stable_diffusion_runtime_status.dart';
import 'image_generation_driver.dart';

/// Creates the driver for the bundled stable_diffusion runtime.
ImageGenerationDriver createImageGenerationDriver() =>
    const _NativeImageGenerationDriver();

class _NativeImageGenerationDriver implements ImageGenerationDriver {
  const _NativeImageGenerationDriver();

  @override
  StableDiffusionRuntimeStatus probe() => probeStableDiffusionRuntime();

  @override
  Future<StableDiffusionRuntimeStatus> probeInBackground() =>
      Isolate.run(probeStableDiffusionRuntime);

  @override
  int? fileSize(String path) => stableDiffusionFileSize(path);

  @override
  Future<Uint8List> readFileRange(String path, int offset, int length) =>
      readStableDiffusionFileRange(path, offset, length);

  @override
  ImageGenerationMemoryBudget? memoryBudget(
    ImageGenerationComputeDevice device,
  ) => readStableDiffusionMemoryBudget(device: device);

  @override
  Future<ImageGenerationSession> start(ImageGenerationSessionConfig config) =>
      StableDiffusionImageWorker.start(config);
}
