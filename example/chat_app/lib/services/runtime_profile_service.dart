import 'dart:math' as math;

import 'package:llamadart/llamadart.dart';

import '../utils/backend_utils.dart';

/// Runtime diagnostics and dynamic-setting heuristics.
class RuntimeProfileService {
  const RuntimeProfileService();

  ({
    int? runtimeGpuLayers,
    int? runtimeThreads,
    int? runtimeThreadPoolSize,
    String? runtimeExecution,
    String? runtimeCoreVariant,
    String? runtimeWorkerFallbackReason,
    String? runtimeNotes,
    String? runtimeModelSource,
    String? runtimeModelCacheState,
  })
  buildDiagnostics({required Map<String, String> metadata}) {
    final runtimeGpuLayers = int.tryParse(
      metadata['llamadart.webgpu.n_gpu_layers'] ?? '',
    );
    final runtimeThreads = int.tryParse(
      metadata['llamadart.webgpu.n_threads'] ?? '',
    );
    final runtimeThreadPoolSize = int.tryParse(
      metadata['llamadart.webgpu.thread_pool_size'] ?? '',
    );

    return (
      runtimeGpuLayers: runtimeGpuLayers,
      runtimeThreads: runtimeThreads,
      runtimeThreadPoolSize: runtimeThreadPoolSize,
      runtimeExecution: _metadataValue(metadata, 'llamadart.webgpu.execution'),
      runtimeCoreVariant: _metadataValue(
        metadata,
        'llamadart.webgpu.core_variant',
      ),
      runtimeWorkerFallbackReason: _metadataValue(
        metadata,
        'llamadart.webgpu.worker_fallback_reason',
      ),
      runtimeNotes: _metadataValue(metadata, 'llamadart.webgpu.runtime_notes'),
      runtimeModelSource: _metadataValue(
        metadata,
        'llamadart.webgpu.model_source',
        fallbackKey: 'llamadart.litert_lm_web.model_source',
      ),
      runtimeModelCacheState: _metadataValue(
        metadata,
        'llamadart.webgpu.model_cache_state',
        fallbackKey: 'llamadart.litert_lm_web.model_cache_state',
      ),
    );
  }

  String? _metadataValue(
    Map<String, String> metadata,
    String key, {
    String? fallbackKey,
  }) {
    final value = (metadata[key] ?? metadata[fallbackKey])?.trim();
    if (value == null || value.isEmpty) {
      return null;
    }
    return value;
  }

  ({int gpuLayers, int contextSize}) estimateDynamicSettings({
    required int totalVramBytes,
    required int freeVramBytes,
    required bool isWeb,
    required GpuBackend preferredBackend,
    required int currentContextSize,
    int modelBytes = 0,
    String? backendInfo,
  }) {
    final requestedContext = currentContextSize <= 0
        ? 4096
        : currentContextSize.clamp(2048, 32768).toInt();
    if (preferredBackend == GpuBackend.cpu) {
      return (gpuLayers: 0, contextSize: requestedContext);
    }

    if (totalVramBytes <= 0) {
      return (
        gpuLayers: _fallbackEstimatedGpuLayers(
          isWeb: isWeb,
          preferredBackend: preferredBackend,
          backendInfo: backendInfo,
        ),
        contextSize: requestedContext,
      );
    }

    final freeVramGb = freeVramBytes / (1024 * 1024 * 1024);
    if (isWeb || modelBytes <= 0) {
      final recommendedLayers = (freeVramGb * 24).round().clamp(0, 98);
      return (
        gpuLayers: recommendedLayers,
        contextSize: freeVramGb < 2 ? 2048 : math.min(requestedContext, 4096),
      );
    }

    // Device memory can be unified with system RAM (Apple Silicon) or
    // dedicated VRAM. Keep both a percentage reserve and current-free-memory
    // reserve so Auto does not crowd out the OS and other applications.
    final reportedFree = freeVramBytes > 0
        ? math.min(freeVramBytes, totalVramBytes)
        : totalVramBytes;
    final safeBudget = math.min(
      (reportedFree * 0.90).floor(),
      (totalVramBytes * 0.80).floor(),
    );

    var recommendedContext = requestedContext;
    while (recommendedContext > 4096 &&
        _estimatedRuntimeBytes(modelBytes, recommendedContext) > safeBudget) {
      recommendedContext = math.max(4096, recommendedContext ~/ 2);
    }

    final requiredBytes = _estimatedRuntimeBytes(
      modelBytes,
      recommendedContext,
    );
    if (requiredBytes <= safeBudget) {
      return (
        gpuLayers: ModelParams.maxGpuLayers,
        contextSize: recommendedContext,
      );
    }

    final runtimeOverhead = _estimatedRuntimeOverhead(recommendedContext);
    final availableWeightBytes = math.max(0, safeBudget - runtimeOverhead);
    final reservedWeightBytes = (modelBytes * 1.18).ceil();
    final offloadRatio = reservedWeightBytes <= 0
        ? 0.0
        : (availableWeightBytes / reservedWeightBytes).clamp(0.0, 1.0);
    return (
      gpuLayers: (offloadRatio * 98).floor().clamp(0, 98),
      contextSize: recommendedContext,
    );
  }

  int _estimatedRuntimeBytes(int modelBytes, int contextSize) {
    return (modelBytes * 1.18).ceil() + _estimatedRuntimeOverhead(contextSize);
  }

  int _estimatedRuntimeOverhead(int contextSize) {
    const gib = 1024 * 1024 * 1024;
    const contextChunkBytes = 512 * 1024 * 1024;
    final contextChunks = math.max(1, (contextSize / 4096).ceil());
    return gib + (contextChunks * contextChunkBytes);
  }

  int _fallbackEstimatedGpuLayers({
    required bool isWeb,
    required GpuBackend preferredBackend,
    String? backendInfo,
  }) {
    if (isWeb) {
      return 99;
    }

    if (preferredBackend == GpuBackend.cpu) {
      return 0;
    }

    if (preferredBackend != GpuBackend.auto) {
      return 32;
    }

    final info = backendInfo?.trim();
    if (info == null || info.isEmpty) {
      return 32;
    }

    final bestBackend = BackendUtils.selectBestBackendFromInfo(info);
    return bestBackend == GpuBackend.cpu ? 0 : 32;
  }
}
