import 'dart:isolate';

import 'package:llamadart/backend.dart';
import 'package:llamadart/llamadart.dart';

import '../../ports/image_port.dart';
import '../../ports/model_storage_port.dart';

/// Production [StudioImagePort] powered by `llamadart`'s
/// [ImageGenerationEngine].
class DirectLlamaImagePort implements StudioImagePort {
  /// Creates a [DirectLlamaImagePort].
  DirectLlamaImagePort({
    this.requiresLinuxVulkan = false,
    String? Function() linuxVulkanProbe = probeLinuxVulkanUnavailableReason,
  }) : _linuxVulkanProbe = linuxVulkanProbe;

  /// Whether the host bundles the Linux Vulkan image runtime rather than CPU.
  ///
  /// Studio's default build enables this; custom CPU-only hosts leave it false.
  final bool requiresLinuxVulkan;

  final String? Function() _linuxVulkanProbe;

  Future<String?> _runtimeUnavailableReason() async {
    if (!requiresLinuxVulkan) return null;
    final probe = _linuxVulkanProbe;
    return Isolate.run(probe);
  }

  ImageGenerationEngine? _engine;
  ImageGenerationTask? _activeTask;
  String? _loadedModelName;

  @override
  Future<ImageGenerationCapabilities> checkRuntime() async {
    final reason = await _runtimeUnavailableReason();
    if (reason != null) {
      return ImageGenerationCapabilities(
        isSupported: false,
        unsupportedReason: reason,
      );
    }
    return ImageGenerationEngine.checkRuntime();
  }

  @override
  Future<ImageGenerationCapabilities> loadModel({
    required ResolvedModelAssets assets,
    ComputeDevice device = ComputeDevice.auto,
  }) async {
    final reason = await _runtimeUnavailableReason();
    if (reason != null) throw LlamaUnsupportedException(reason);
    _activeTask?.cancel();
    _activeTask = null;
    await _engine?.dispose();
    _engine = null;

    final taesd = assets.companionSources['taesd'];
    final model = ImageGenerationModel(
      assets.primarySource,
      components: <ImageModelComponent>[
        if (taesd != null) ImageModelComponent.auto(taesd),
      ],
    );

    final engine = await ImageGenerationEngine.load(
      model,
      params: ImageModelParams(device: device),
    );
    _engine = engine;
    _loadedModelName = assets.descriptor.name;
    return engine.capabilities;
  }

  @override
  Future<StudioGeneratedImageItem> generateImage({
    required String prompt,
    String negativePrompt = '',
    int width = 512,
    int height = 512,
    int steps = 1,
    double guidanceScale = 1.0,
    int? seed,
    void Function(ImageGenerationProgressEvent event)? onProgress,
  }) async {
    final engine = _engine;
    if (engine == null) {
      throw LlamaStateException(
        'Load an Image Studio model before generating.',
      );
    }

    final task = await engine.generate(
      ImageGenerationRequest(
        prompt: prompt,
        negativePrompt: negativePrompt,
        width: width,
        height: height,
        steps: steps,
        guidanceScale: guidanceScale,
        seed: seed,
      ),
    );
    _activeTask = task;

    final sub = task.events.listen((ImageGenerationEvent event) {
      if (event is ImageGenerationProgressEvent && onProgress != null) {
        onProgress(event);
      }
    });

    try {
      final result = await task.result;
      if (result.images.isEmpty) {
        throw LlamaInferenceException('No image was returned.');
      }
      final first = result.images.first;
      return StudioGeneratedImageItem(
        id: 'img_${DateTime.now().microsecondsSinceEpoch}',
        prompt: prompt,
        negativePrompt: negativePrompt,
        pngBytes: first.toPng(),
        width: first.width,
        height: first.height,
        steps: steps,
        guidanceScale: guidanceScale,
        seed: result.seed,
        elapsedMs: result.elapsed.inMilliseconds,
        modelName: _loadedModelName ?? 'Stable Diffusion',
        createdAt: DateTime.now(),
      );
    } finally {
      await sub.cancel();
      if (identical(_activeTask, task)) {
        _activeTask = null;
      }
    }
  }

  @override
  void cancelGeneration() {
    _activeTask?.cancel();
  }

  @override
  Future<void> dispose() async {
    _activeTask?.cancel();
    _activeTask = null;
    await _engine?.dispose();
    _engine = null;
  }
}
