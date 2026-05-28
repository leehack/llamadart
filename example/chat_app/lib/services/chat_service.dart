import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:llamadart/llamadart.dart';
import '../models/chat_settings.dart';

/// Service for managing the LLM engine lifecycle.
///
/// This service handles model loading and provides access to the engine.
/// For chat functionality, use [ChatSession] which is created by the provider.
class ChatService {
  final LlamaEngine _engine;
  bool _disposed = false;

  ChatService({LlamaEngine? engine})
    : _engine = engine ?? LlamaEngine(LlamaBackend());

  /// The underlying LlamaEngine instance.
  LlamaEngine get engine => _engine;

  /// Initializes the engine with the given settings.
  Future<void> init(
    ChatSettings settings, {
    Function(double progress)? onProgress,
    bool eagerLoadMultimodalProjector = true,
  }) async {
    if (settings.modelPath == null) throw Exception("Model path is null");

    // Unload existing model if any
    if (_engine.isReady) {
      await _engine.unloadModel();
    }

    Timer? syntheticProgressTimer;
    var syntheticProgress = 0.0;
    var emittedProgress = 0.0;
    var hasObservedModelProgress = false;

    void emitProgress(double value) {
      if (onProgress == null) {
        return;
      }
      final clamped = value.clamp(0.0, 1.0);
      if (clamped <= emittedProgress) {
        return;
      }
      emittedProgress = clamped;
      onProgress(clamped);
    }

    if (onProgress != null) {
      syntheticProgressTimer = Timer.periodic(
        const Duration(milliseconds: 160),
        (_) {
          if (hasObservedModelProgress) {
            return;
          }

          syntheticProgress =
              (syntheticProgress + (1 - syntheticProgress) * 0.1).clamp(
                0.0,
                0.18,
              );
          emitProgress(syntheticProgress);
        },
      );
    }

    final modelParams = _buildModelParams(settings);

    try {
      if (settings.modelPath!.startsWith('http')) {
        await _engine.loadModelFromUrl(
          settings.modelPath!,
          modelParams: modelParams,
          onProgress: onProgress == null
              ? null
              : (progress) {
                  hasObservedModelProgress = true;
                  emitProgress(progress);
                },
        );
      } else {
        await _engine.loadModel(settings.modelPath!, modelParams: modelParams);
      }

      if (_isLiteRtLmModel(settings.modelPath)) {
        emitProgress(0.92);
        await _warmUpLiteRtLmRuntime(settings);
      }

      emitProgress(1.0);
    } finally {
      syntheticProgressTimer?.cancel();
    }

    if (eagerLoadMultimodalProjector &&
        settings.mmprojPath != null &&
        settings.mmprojPath!.isNotEmpty) {
      await loadMultimodalProjector(settings.mmprojPath!);
    }
  }

  bool _isQwen35SmallModel(String? modelPath) {
    final normalized = (modelPath ?? '').toLowerCase();
    return normalized.contains('qwen3.5-0.8b') ||
        normalized.contains('qwen_qwen3.5-0.8b');
  }

  bool _isLiteRtLmModel(String? modelPath) {
    final normalized = (modelPath ?? '')
        .split('?')
        .first
        .split('#')
        .first
        .toLowerCase();
    return normalized.endsWith('.litertlm');
  }

  Future<void> _warmUpLiteRtLmRuntime(ChatSettings settings) async {
    final maxTokens = settings.maxTokens > 0 ? settings.maxTokens : 1;
    final completed = Completer<void>();
    late final StreamSubscription<LlamaCompletionChunk> subscription;

    subscription = _engine
        .create(
          [
            LlamaChatMessage.fromText(
              role: LlamaChatRole.user,
              text: 'Warm up the runtime.',
            ),
          ],
          params: GenerationParams(
            maxTokens: maxTokens,
            temp: settings.temperature,
            topK: settings.topK,
            topP: settings.topP,
            seed: 1,
          ),
          enableThinking: false,
        )
        .listen(
          (_) {
            if (!completed.isCompleted) {
              completed.complete();
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            if (!completed.isCompleted) {
              completed.completeError(error, stackTrace);
            }
          },
          onDone: () {
            if (!completed.isCompleted) {
              completed.complete();
            }
          },
        );

    try {
      await completed.future.timeout(const Duration(minutes: 3));
    } finally {
      await subscription.cancel();
      _engine.cancelGeneration();
    }
  }

  ModelParams _buildModelParams(ChatSettings settings) {
    final isAndroidNative =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    final isLiteRtLm = _isLiteRtLmModel(settings.modelPath);
    final usesGpuBackend = settings.preferredBackend != GpuBackend.cpu;
    final usesVulkanBackend =
        settings.preferredBackend == GpuBackend.vulkan ||
        settings.preferredBackend == GpuBackend.auto;
    final safeContextSize = settings.contextSize > 0
        ? settings.contextSize
        : 4096;
    final isQwen35Small = _isQwen35SmallModel(settings.modelPath);

    if (isLiteRtLm) {
      final liteRtLmGpuLayers = settings.preferredBackend == GpuBackend.cpu
          ? 0
          : ModelParams.maxGpuLayers;
      return ModelParams(
        gpuLayers: liteRtLmGpuLayers,
        preferredBackend: settings.preferredBackend,
        contextSize: settings.contextSize,
      );
    }

    int resolvedThreads = settings.numberOfThreads;
    int resolvedThreadsBatch = settings.numberOfThreadsBatch;
    if (isAndroidNative && isQwen35Small) {
      if (settings.preferredBackend == GpuBackend.cpu) {
        if (resolvedThreads <= 0) {
          resolvedThreads = 4;
        }
        if (resolvedThreadsBatch <= 0) {
          resolvedThreadsBatch = resolvedThreads;
        }
      } else if (usesVulkanBackend) {
        if (resolvedThreads <= 0) {
          resolvedThreads = 2;
        }
        if (resolvedThreadsBatch <= 0) {
          resolvedThreadsBatch = resolvedThreads;
        }
      }
    }

    var batchSize = 0;
    var microBatchSize = 0;
    if (isAndroidNative && usesGpuBackend) {
      if (usesVulkanBackend) {
        final preferredBatchCap = _isQwen35SmallModel(settings.modelPath)
            ? 64
            : 32;
        batchSize = math.min(safeContextSize, preferredBatchCap);
        microBatchSize = 1;
      } else {
        batchSize = math.min(safeContextSize, 256);
        microBatchSize = math.min(batchSize, 64);
      }
    }

    return ModelParams(
      gpuLayers: settings.gpuLayers,
      preferredBackend: settings.preferredBackend,
      contextSize: settings.contextSize,
      numberOfThreads: resolvedThreads,
      numberOfThreadsBatch: resolvedThreadsBatch,
      batchSize: batchSize,
      microBatchSize: microBatchSize,
    );
  }

  /// Loads multimodal projector for image/audio requests.
  Future<void> loadMultimodalProjector(String mmprojPath) async {
    if (mmprojPath.isEmpty) {
      throw Exception('Multimodal projector path is empty.');
    }

    try {
      await _engine.loadMultimodalProjector(mmprojPath);
    } catch (e) {
      debugPrint("Failed to load multimodal projector: $e");
      throw Exception(
        'Failed to load multimodal projector ($mmprojPath). '
        'Please verify this mmproj matches the selected model.',
      );
    }
  }

  /// Unloads the active multimodal projector while keeping the model loaded.
  Future<void> unloadMultimodalProjector() async {
    try {
      await _engine.unloadMultimodalProjector();
    } catch (e) {
      debugPrint('Failed to unload multimodal projector: $e');
      rethrow;
    }
  }

  /// Cleans whitespace from response text.
  String cleanResponse(String response) {
    return response.trim();
  }

  /// Unloads the currently loaded model but keeps engine alive.
  Future<void> unloadModel() async {
    _engine.cancelGeneration();
    if (_engine.isReady) {
      await _engine.unloadModel();
    }
  }

  /// Disposes of the engine resources. Safe to call multiple times.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _engine.cancelGeneration();
    await _engine.dispose();
  }

  /// Cancels any ongoing generation.
  void cancelGeneration() {
    _engine.cancelGeneration();
  }
}
