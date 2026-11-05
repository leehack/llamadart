import 'package:llamadart/llamadart.dart';

/// The original-mode public load, shared with its model-free mapper control.
Future<ImageGenerationEngine> loadOriginalContainer(
  String model,
  String taesd,
) => ImageGenerationEngine.load(
  ImageGenerationModel(
    ModelSource.path(model),
    role: ImageModelRole.checkpoint,
    components: [
      ImageModelComponent(ModelSource.path(taesd), role: ImageModelRole.taesd),
    ],
  ),
  params: const ImageConditioningCacheParams(
    capacity: 4,
    device: ComputeDevice.cpu,
    threads: 4,
    flashAttention: true,
    vaeDirectConvolution: false,
  ),
  placement: const ImageModelPlacement(autoFit: true),
);
