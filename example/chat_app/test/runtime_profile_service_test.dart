import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_chat_example/services/runtime_profile_service.dart';

void main() {
  const service = RuntimeProfileService();

  group('RuntimeProfileService', () {
    test('computes runtime diagnostics fields', () {
      final diagnostics = service.buildDiagnostics(
        metadata: const <String, String>{
          'llamadart.webgpu.n_gpu_layers': '32',
          'llamadart.webgpu.n_threads': '8',
          'llamadart.webgpu.thread_pool_size': '2',
          'llamadart.webgpu.execution': 'worker',
          'llamadart.webgpu.core_variant': 'wasm64',
          'llamadart.webgpu.worker_fallback_reason': 'threads_capped_no_coi',
          'llamadart.webgpu.runtime_notes':
              'threads_capped_no_coi;model_fetch_backend_attempt',
          'llamadart.webgpu.model_source': 'network-fetch',
          'llamadart.webgpu.model_cache_state': 'hit',
        },
      );

      expect(diagnostics.runtimeGpuLayers, 32);
      expect(diagnostics.runtimeThreads, 8);
      expect(diagnostics.runtimeThreadPoolSize, 2);
      expect(diagnostics.runtimeExecution, 'worker');
      expect(diagnostics.runtimeCoreVariant, 'wasm64');
      expect(diagnostics.runtimeWorkerFallbackReason, 'threads_capped_no_coi');
      expect(
        diagnostics.runtimeNotes,
        'threads_capped_no_coi;model_fetch_backend_attempt',
      );
      expect(diagnostics.runtimeModelSource, 'network-fetch');
      expect(diagnostics.runtimeModelCacheState, 'hit');
    });

    test(
      'uses LiteRT-LM web cache diagnostics when WebGPU keys are absent',
      () {
        final diagnostics = service.buildDiagnostics(
          metadata: const <String, String>{
            'llamadart.litert_lm_web.model_source': 'cache',
            'llamadart.litert_lm_web.model_cache_state': 'hit',
          },
        );

        expect(diagnostics.runtimeModelSource, 'cache');
        expect(diagnostics.runtimeModelCacheState, 'hit');
      },
    );

    test('returns fallback estimate when VRAM unavailable', () {
      final estimate = service.estimateDynamicSettings(
        totalVramBytes: 0,
        freeVramBytes: 0,
        isWeb: false,
        preferredBackend: GpuBackend.cpu,
        currentContextSize: 4096,
        backendInfo: 'CPU',
      );

      expect(estimate.gpuLayers, 0);
      expect(estimate.contextSize, 4096);
    });

    test('returns VRAM-based estimate when data is available', () {
      final estimate = service.estimateDynamicSettings(
        totalVramBytes: 8 * 1024 * 1024 * 1024,
        freeVramBytes: 4 * 1024 * 1024 * 1024,
        isWeb: false,
        preferredBackend: GpuBackend.auto,
        currentContextSize: 8192,
        modelBytes: 3 * 1024 * 1024 * 1024,
      );

      expect(estimate.gpuLayers, greaterThan(0));
      expect(estimate.contextSize, 4096);
    });

    test('fully offloads a known model when memory has safe headroom', () {
      final estimate = service.estimateDynamicSettings(
        totalVramBytes: 64 * 1024 * 1024 * 1024,
        freeVramBytes: 56 * 1024 * 1024 * 1024,
        isWeb: false,
        preferredBackend: GpuBackend.auto,
        currentContextSize: 16384,
        modelBytes: 20 * 1024 * 1024 * 1024,
      );

      expect(estimate.gpuLayers, ModelParams.maxGpuLayers);
      expect(estimate.contextSize, 16384);
    });

    test('reduces context before choosing partial offload under pressure', () {
      final estimate = service.estimateDynamicSettings(
        totalVramBytes: 16 * 1024 * 1024 * 1024,
        freeVramBytes: 12 * 1024 * 1024 * 1024,
        isWeb: false,
        preferredBackend: GpuBackend.auto,
        currentContextSize: 16384,
        modelBytes: 12 * 1024 * 1024 * 1024,
      );

      expect(estimate.gpuLayers, inInclusiveRange(1, 98));
      expect(estimate.contextSize, 4096);
    });
  });
}
