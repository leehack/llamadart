import 'package:llamadart/src/core/models/config/flash_attention.dart';
import 'package:llamadart/src/core/models/config/gpu_backend.dart';
import 'package:llamadart/src/core/models/config/kv_cache_type.dart';
import 'package:llamadart/src/core/models/inference/model_params.dart';
import 'package:test/test.dart';

void main() {
  test('ModelParams defaults preserve legacy context batching behavior', () {
    const params = ModelParams();

    expect(params.contextSize, 4096);
    expect(params.gpuLayers, ModelParams.maxGpuLayers);
    expect(params.preferredBackend, GpuBackend.auto);
    expect(params.splitMode, ModelSplitMode.layer);
    expect(params.mainGpu, 0);
    expect(params.chatTemplate, isNull);
    expect(params.numberOfThreads, 0);
    expect(params.numberOfThreadsBatch, 0);
    expect(params.batchSize, 0);
    expect(params.microBatchSize, 0);
    expect(params.maxParallelSequences, 1);
    expect(params.useMmap, isTrue);
    expect(params.useMlock, isFalse);
    expect(params.flashAttention, FlashAttention.auto);
    expect(params.cacheTypeK, KvCacheType.f16);
    expect(params.cacheTypeV, KvCacheType.f16);
    expect(params.kvUnified, isNull);
    expect(params.ropeFrequencyBase, isNull);
    expect(params.ropeFrequencyScale, isNull);
    expect(ModelParams.maxGpuLayers, 999);
  });

  test('ModelParams copyWith updates selected fields', () {
    const params = ModelParams(contextSize: 1024);
    final updated = params.copyWith(
      gpuLayers: 2,
      preferredBackend: GpuBackend.metal,
      splitMode: ModelSplitMode.none,
      mainGpu: 1,
      batchSize: 256,
      microBatchSize: 64,
      maxParallelSequences: 8,
    );

    expect(updated.contextSize, 1024);
    expect(updated.gpuLayers, 2);
    expect(updated.preferredBackend, GpuBackend.metal);
    expect(updated.splitMode, ModelSplitMode.none);
    expect(updated.mainGpu, 1);
    expect(updated.batchSize, 256);
    expect(updated.microBatchSize, 64);
    expect(updated.maxParallelSequences, 8);
  });

  test('ModelParams exposes load-time tuning knobs', () {
    const params = ModelParams(
      useMmap: false,
      useMlock: true,
      flashAttention: FlashAttention.enabled,
      cacheTypeK: KvCacheType.q8_0,
      cacheTypeV: KvCacheType.q8_0,
      kvUnified: true,
      ropeFrequencyBase: 1000000.0,
      ropeFrequencyScale: 0.5,
    );

    expect(params.useMmap, isFalse);
    expect(params.useMlock, isTrue);
    expect(params.flashAttention, FlashAttention.enabled);
    expect(params.cacheTypeK, KvCacheType.q8_0);
    expect(params.cacheTypeV, KvCacheType.q8_0);
    expect(params.kvUnified, isTrue);
    expect(params.ropeFrequencyBase, 1000000.0);
    expect(params.ropeFrequencyScale, 0.5);
  });

  test('ModelParams copyWith updates load-time tuning knobs', () {
    const params = ModelParams();
    final updated = params.copyWith(
      useMmap: false,
      useMlock: true,
      flashAttention: FlashAttention.enabled,
      cacheTypeK: KvCacheType.q4_0,
      cacheTypeV: KvCacheType.q8_0,
      kvUnified: false,
      ropeFrequencyBase: 500000.0,
      ropeFrequencyScale: 0.25,
    );

    expect(updated.useMmap, isFalse);
    expect(updated.useMlock, isTrue);
    expect(updated.flashAttention, FlashAttention.enabled);
    expect(updated.cacheTypeK, KvCacheType.q4_0);
    expect(updated.cacheTypeV, KvCacheType.q8_0);
    expect(updated.kvUnified, isFalse);
    expect(updated.ropeFrequencyBase, 500000.0);
    expect(updated.ropeFrequencyScale, 0.25);
  });

  test('ModelParams copyWith preserves unspecified fields', () {
    const original = ModelParams(
      contextSize: 3072,
      gpuLayers: 8,
      preferredBackend: GpuBackend.cuda,
      splitMode: ModelSplitMode.row,
      mainGpu: 2,
      chatTemplate: 'custom-template',
      numberOfThreads: 6,
      numberOfThreadsBatch: 4,
      batchSize: 512,
      microBatchSize: 128,
      maxParallelSequences: 4,
      useMmap: false,
      useMlock: true,
      flashAttention: FlashAttention.enabled,
      cacheTypeK: KvCacheType.q8_0,
      cacheTypeV: KvCacheType.q8_0,
      kvUnified: true,
      ropeFrequencyBase: 1000000.0,
      ropeFrequencyScale: 0.5,
    );

    final updated = original.copyWith(gpuLayers: 12);

    expect(updated.contextSize, 3072);
    expect(updated.gpuLayers, 12);
    expect(updated.preferredBackend, GpuBackend.cuda);
    expect(updated.splitMode, ModelSplitMode.row);
    expect(updated.mainGpu, 2);
    expect(updated.chatTemplate, 'custom-template');
    expect(updated.numberOfThreads, 6);
    expect(updated.numberOfThreadsBatch, 4);
    expect(updated.batchSize, 512);
    expect(updated.microBatchSize, 128);
    expect(updated.maxParallelSequences, 4);
    expect(updated.useMmap, isFalse);
    expect(updated.useMlock, isTrue);
    expect(updated.flashAttention, FlashAttention.enabled);
    expect(updated.cacheTypeK, KvCacheType.q8_0);
    expect(updated.cacheTypeV, KvCacheType.q8_0);
    expect(updated.kvUnified, isTrue);
    expect(updated.ropeFrequencyBase, 1000000.0);
    expect(updated.ropeFrequencyScale, 0.5);
  });

  group('validate(): non-F16 KV requires flash attention', () {
    test('q8_0 K + flashAttention disabled throws ArgumentError', () {
      const p = ModelParams(
        cacheTypeK: KvCacheType.q8_0,
        flashAttention: FlashAttention.disabled,
      );
      expect(p.validate, throwsArgumentError);
    });

    test('q4_0 V + flashAttention disabled throws ArgumentError', () {
      const p = ModelParams(
        cacheTypeV: KvCacheType.q4_0,
        flashAttention: FlashAttention.disabled,
      );
      expect(p.validate, throwsArgumentError);
    });

    test('q8_0 K/V + flashAttention auto is allowed', () {
      const p = ModelParams(
        cacheTypeK: KvCacheType.q8_0,
        cacheTypeV: KvCacheType.q8_0,
        flashAttention: FlashAttention.auto,
      );
      expect(p.validate, returnsNormally);
    });

    test('q8_0 K/V + flashAttention enabled is allowed', () {
      const p = ModelParams(
        cacheTypeK: KvCacheType.q8_0,
        cacheTypeV: KvCacheType.q8_0,
        flashAttention: FlashAttention.enabled,
      );
      expect(p.validate, returnsNormally);
    });

    test('F16 K/V + flashAttention disabled is allowed', () {
      const p = ModelParams(flashAttention: FlashAttention.disabled);
      expect(p.validate, returnsNormally);
    });
  });

  group('copyWith can clear nullable fields back to null', () {
    const populated = ModelParams(
      chatTemplate: 'custom-template',
      kvUnified: true,
      ropeFrequencyBase: 1000000.0,
      ropeFrequencyScale: 0.5,
    );

    test('clearChatTemplate: true sets chatTemplate to null', () {
      final cleared = populated.copyWith(clearChatTemplate: true);
      expect(cleared.chatTemplate, isNull);
      // Other fields preserved.
      expect(cleared.kvUnified, isTrue);
      expect(cleared.ropeFrequencyBase, 1000000.0);
    });

    test('clearKvUnified: true sets kvUnified to null', () {
      final cleared = populated.copyWith(clearKvUnified: true);
      expect(cleared.kvUnified, isNull);
      expect(cleared.chatTemplate, 'custom-template');
    });

    test('clearRopeFrequencyBase: true sets ropeFrequencyBase to null', () {
      final cleared = populated.copyWith(clearRopeFrequencyBase: true);
      expect(cleared.ropeFrequencyBase, isNull);
      expect(cleared.ropeFrequencyScale, 0.5);
    });

    test('clearRopeFrequencyScale: true sets ropeFrequencyScale to null', () {
      final cleared = populated.copyWith(clearRopeFrequencyScale: true);
      expect(cleared.ropeFrequencyScale, isNull);
      expect(cleared.ropeFrequencyBase, 1000000.0);
    });

    test('clear* flags can be combined with new value setters', () {
      final updated = populated.copyWith(
        clearKvUnified: true,
        ropeFrequencyBase: 2000000.0,
        clearRopeFrequencyScale: true,
      );
      expect(updated.kvUnified, isNull);
      expect(updated.ropeFrequencyBase, 2000000.0);
      expect(updated.ropeFrequencyScale, isNull);
    });

    test(
      'without clear flag, passing null does NOT clear (legacy behavior)',
      () {
        // This documents the pre-fix behavior: null means "argument omitted".
        final unchanged = populated.copyWith(kvUnified: null);
        expect(unchanged.kvUnified, isTrue);
      },
    );
  });
}
