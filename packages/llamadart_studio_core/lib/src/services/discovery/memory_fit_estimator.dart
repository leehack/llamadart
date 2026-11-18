import 'dart:math' as math;

import 'package:llamadart/llamadart.dart';
import 'package:meta/meta.dart';

/// Fit classification shown on Model Hub cards and Inspector warnings.
enum MemoryFitStatus {
  /// Entire model + KV cache fits comfortably inside reported GPU/unified VRAM.
  fitsInVram('Fits in GPU', 'Full GPU offload expected.'),

  /// Model requires splitting layers across GPU and system RAM, or CPU offload.
  hybridCpuGpu('Hybrid GPU/CPU', 'Partial GPU layer offload recommended.'),

  /// Close to memory ceiling; reduced context or quantized KV cache advised.
  tightMemory('Tight Fit', 'Consider Q8_0/Q4_0 KV cache or smaller context.'),

  /// Likely exceeds device memory budget.
  exceedsMemory('May Exceed Memory', 'High risk of OOM on this device.'),

  /// Host has not reported VRAM/RAM telemetry yet (for example before probe).
  unknown('Unverified Fit', 'Hardware memory budget not reported yet.');

  const MemoryFitStatus(this.badgeLabel, this.guidance);

  /// Short pill label.
  final String badgeLabel;

  /// Actionable explanation.
  final String guidance;
}

/// Result of estimating memory fit and auto-tuned parameters for a model.
@immutable
class MemoryFitAssessment {
  /// Creates a [MemoryFitAssessment].
  const MemoryFitAssessment({
    required this.status,
    required this.estimatedTotalBytes,
    required this.recommendedGpuLayers,
    required this.recommendedContextSize,
    this.availableVramBytes = 0,
  });

  /// Overall fit classification.
  final MemoryFitStatus status;

  /// Estimated model weights + KV cache + compute buffer bytes.
  final int estimatedTotalBytes;

  /// Suggested GPU layer offload count (`99` = all layers, `0` = CPU only).
  final int recommendedGpuLayers;

  /// Suggested context window (`n_ctx`) clamped for safety.
  final int recommendedContextSize;

  /// Reported free VRAM/unified memory in bytes (`0` when unknown).
  final int availableVramBytes;

  /// Human-readable estimated memory requirement (e.g., `1.2 GB`).
  String get estimatedFootprintLabel {
    final gib = estimatedTotalBytes / (1024 * 1024 * 1024);
    if (gib >= 1.0) {
      return '~${gib.toStringAsFixed(1)} GB';
    }
    final mib = estimatedTotalBytes / (1024 * 1024);
    return '~${mib.round()} MB';
  }
}

/// Pure-Dart heuristic planner for VRAM/RAM fit badges and hardware auto-tuning.
abstract final class MemoryFitEstimator {
  static const int _gib = 1024 * 1024 * 1024;
  static const int _mib = 1024 * 1024;

  /// Estimates memory fit and safe load parameters for a model of
  /// [modelSizeBytes] at [requestedContextSize].
  static MemoryFitAssessment evaluate({
    required int modelSizeBytes,
    required int requestedContextSize,
    required KvCacheType cacheTypeK,
    required KvCacheType cacheTypeV,
    int vramFreeBytes = 0,
    int vramTotalBytes = 0,
    int minRamGb = 2,
    bool isWeb = false,
  }) {
    final clampedRequestedCtx = math.max(512, requestedContextSize);
    final kvFactor = _kvBytesMultiplier(cacheTypeK, cacheTypeV);
    // Conservative KV + compute scratch estimate: ~128 KB per token at F16
    // scaled by model size tier, plus 256 MB runtime overhead.
    final sizeScale = modelSizeBytes > 0
        ? math.max(0.5, math.min(3.0, modelSizeBytes / (4.0 * _gib)))
        : 1.0;
    final kvBytes = (clampedRequestedCtx * 131072 * sizeScale * kvFactor)
        .round();
    final overheadBytes = 256 * _mib;
    final totalEstimated = modelSizeBytes + kvBytes + overheadBytes;

    if (isWeb) {
      // WebGPU browsers typically cap single ArrayBuffers / wasm heaps around
      // 2-4 GB unless memory64 is available.
      const webComfortLimit = 2200 * _mib;
      const webHardLimit = 4200 * _mib;
      if (modelSizeBytes <= 0) {
        return MemoryFitAssessment(
          status: MemoryFitStatus.unknown,
          estimatedTotalBytes: totalEstimated,
          recommendedGpuLayers: 99,
          recommendedContextSize: math.min(clampedRequestedCtx, 4096),
        );
      }
      if (totalEstimated <= webComfortLimit) {
        return MemoryFitAssessment(
          status: MemoryFitStatus.fitsInVram,
          estimatedTotalBytes: totalEstimated,
          recommendedGpuLayers: 99,
          recommendedContextSize: math.min(clampedRequestedCtx, 8192),
        );
      }
      if (totalEstimated <= webHardLimit) {
        return MemoryFitAssessment(
          status: MemoryFitStatus.tightMemory,
          estimatedTotalBytes: totalEstimated,
          recommendedGpuLayers: 99,
          recommendedContextSize: math.min(clampedRequestedCtx, 4096),
        );
      }
      return MemoryFitAssessment(
        status: MemoryFitStatus.exceedsMemory,
        estimatedTotalBytes: totalEstimated,
        recommendedGpuLayers: 99,
        recommendedContextSize: 2048,
      );
    }

    final effectiveBudget = vramFreeBytes > 0 ? vramFreeBytes : vramTotalBytes;
    if (effectiveBudget <= 0 || modelSizeBytes <= 0) {
      return MemoryFitAssessment(
        status: minRamGb >= 24
            ? MemoryFitStatus.tightMemory
            : MemoryFitStatus.unknown,
        estimatedTotalBytes: totalEstimated,
        recommendedGpuLayers: 99,
        recommendedContextSize: clampedRequestedCtx,
      );
    }

    final usableVram = (effectiveBudget * 0.85).round();
    if (totalEstimated <= usableVram) {
      return MemoryFitAssessment(
        status: MemoryFitStatus.fitsInVram,
        estimatedTotalBytes: totalEstimated,
        recommendedGpuLayers: 99,
        recommendedContextSize: clampedRequestedCtx,
        availableVramBytes: effectiveBudget,
      );
    }

    if (modelSizeBytes <= usableVram) {
      // Weights fit, but requested context pushes KV over usable VRAM.
      final shrunkCtx = math.max(2048, (clampedRequestedCtx ~/ 2));
      return MemoryFitAssessment(
        status: MemoryFitStatus.tightMemory,
        estimatedTotalBytes: totalEstimated,
        recommendedGpuLayers: 99,
        recommendedContextSize: shrunkCtx,
        availableVramBytes: effectiveBudget,
      );
    }

    final ratio = usableVram / modelSizeBytes;
    if (ratio >= 0.35) {
      final partialLayers = math.max(8, math.min(48, (ratio * 40).round()));
      return MemoryFitAssessment(
        status: MemoryFitStatus.hybridCpuGpu,
        estimatedTotalBytes: totalEstimated,
        recommendedGpuLayers: partialLayers,
        recommendedContextSize: math.min(clampedRequestedCtx, 4096),
        availableVramBytes: effectiveBudget,
      );
    }

    return MemoryFitAssessment(
      status: MemoryFitStatus.exceedsMemory,
      estimatedTotalBytes: totalEstimated,
      recommendedGpuLayers: 0,
      recommendedContextSize: math.min(clampedRequestedCtx, 2048),
      availableVramBytes: effectiveBudget,
    );
  }

  static double _kvBytesMultiplier(KvCacheType k, KvCacheType v) {
    double weight(KvCacheType type) => switch (type) {
      KvCacheType.f16 => 1.0,
      KvCacheType.q8_0 => 0.55,
      KvCacheType.q4_0 => 0.32,
    };
    return (weight(k) + weight(v)) / 2.0;
  }
}
