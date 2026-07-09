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
    String? backendInfo,
  }) {
    if (totalVramBytes <= 0) {
      return (
        gpuLayers: _fallbackEstimatedGpuLayers(
          isWeb: isWeb,
          preferredBackend: preferredBackend,
          backendInfo: backendInfo,
        ),
        contextSize: currentContextSize == 0
            ? 4096
            : currentContextSize.clamp(2048, 32768),
      );
    }

    final freeVramGb = freeVramBytes / (1024 * 1024 * 1024);
    var recommendedLayers = (freeVramGb * 24).round();
    if (recommendedLayers > 98) {
      recommendedLayers = 98;
    }
    if (recommendedLayers < 0) {
      recommendedLayers = 0;
    }

    var recommendedContext = 4096;
    if (freeVramGb < 2.0) {
      recommendedContext = 2048;
    }

    return (gpuLayers: recommendedLayers, contextSize: recommendedContext);
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
