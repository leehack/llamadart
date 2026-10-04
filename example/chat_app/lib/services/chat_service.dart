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

  /// The source of a model or projector file at [location]: an `http(s)` URL
  /// the runtime or the model cache fetches, or else a path, which a native
  /// runtime opens and a browser reads as a URL.
  static ModelSource modelSourceFor(String location) =>
      location.startsWith('http')
      ? ModelSource.parse(location)
      : ModelSource.path(location);

  /// Initializes the engine with the given settings.
  ///
  /// Throws [LlamaStateException] after [dispose]: a model loaded then would
  /// still be allocated when the app exits.
  Future<void> init(
    ChatSettings settings, {
    Function(double progress)? onProgress,
    bool eagerLoadMultimodalProjector = true,
    bool eagerWarmUpLiteRtLmRuntime = true,
  }) async {
    if (settings.modelPath == null) throw Exception("Model path is null");
    _throwIfDisposed();

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
      _throwIfDisposed();
      final modelPath = settings.modelPath!;
      // setModel replaces a loaded model. A local file reports its whole size
      // before the runtime starts loading it, so only a fetched model drives
      // the progress bar.
      await _engine.setModel(
        LlamaModel(modelSourceFor(modelPath)),
        params: modelParams,
        onProgress: onProgress == null || !modelPath.startsWith('http')
            ? null
            : (progress) {
                final fraction = progress.fraction;
                if (fraction == null) return;
                hasObservedModelProgress = true;
                emitProgress(fraction);
              },
      );

      final isLiteRtLmModel = _engine.runtime == LlamaRuntime.liteRtLm;
      final directAudioLiteRtLm =
          isLiteRtLmModel &&
          settings.directMediaInput &&
          settings.modelSupportsAudio;
      if (eagerWarmUpLiteRtLmRuntime &&
          isLiteRtLmModel &&
          !directAudioLiteRtLm) {
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
      try {
        await loadMultimodalProjector(settings.mmprojPath!);
      } catch (error, stackTrace) {
        // A projector failure happens after the text model is already loaded.
        // Release that partial runtime so a retry starts with a fresh bridge
        // instead of retaining a broken worker and another model-sized
        // allocation.
        if (_engine.isReady) {
          try {
            await _engine.unloadModel();
          } catch (cleanupError) {
            debugPrint(
              'Failed to release model after multimodal projector error: '
              '$cleanupError',
            );
          }
        }
        Error.throwWithStackTrace(error, stackTrace);
      }
    }
  }

  bool _isQwen35SmallModel(String? modelPath) {
    final normalized = (modelPath ?? '').toLowerCase();
    return normalized.contains('qwen3.5-0.8b') ||
        normalized.contains('qwen_qwen3.5-0.8b');
  }

  bool _isLiteRtLmModel(String? modelPath) {
    return ModelFormat.fromPath(modelPath ?? '') == ModelFormat.liteRtLm;
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
    final resolvedGpuLayers = !usesGpuBackend
        ? 0
        : !kIsWeb && settings.gpuLayers >= 99
        ? ModelParams.maxGpuLayers
        : settings.gpuLayers;
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
        contextSize: safeContextSize,
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

    var batchSize = settings.batchSize;
    var microBatchSize = settings.microBatchSize;
    if (kIsWeb && settings.modelSupportsSpeechToText) {
      if (batchSize <= 0) {
        batchSize = math.min(safeContextSize, 512);
      }
      if (microBatchSize <= 0) {
        microBatchSize = math.min(batchSize, 128);
      }
    }
    if (isAndroidNative && usesGpuBackend) {
      if (usesVulkanBackend) {
        final preferredBatchCap = _isQwen35SmallModel(settings.modelPath)
            ? 64
            : 32;
        if (batchSize <= 0) {
          batchSize = math.min(safeContextSize, preferredBatchCap);
        }
        if (microBatchSize <= 0) {
          microBatchSize = 1;
        }
      } else {
        if (batchSize <= 0) {
          batchSize = math.min(safeContextSize, 256);
        }
        if (microBatchSize <= 0) {
          microBatchSize = math.min(batchSize, 64);
        }
      }
    }
    if (batchSize > 0 && microBatchSize > batchSize) {
      microBatchSize = batchSize;
    }

    // On web, forward the known model size so the WebGPU backend can select the
    // 64-bit (mem64) core up front for models that exceed the wasm32 address
    // space. This is size-driven; there is no hardcoded model-name list.
    final hint = settings.modelBytesHint ?? 0;
    final int? modelBytesHint = kIsWeb && hint > 0 ? hint : null;

    return ModelParams(
      gpuLayers: resolvedGpuLayers,
      preferredBackend: settings.preferredBackend,
      contextSize: settings.contextSize,
      numberOfThreads: resolvedThreads,
      numberOfThreadsBatch: resolvedThreadsBatch,
      batchSize: batchSize,
      microBatchSize: microBatchSize,
      modelBytesHint: modelBytesHint,
    );
  }

  /// Loads multimodal projector for image/audio requests.
  Future<void> loadMultimodalProjector(String mmprojPath) async {
    if (mmprojPath.isEmpty) {
      throw Exception('Multimodal projector path is empty.');
    }
    _throwIfDisposed();

    try {
      await _engine.loadMultimodalProjectorSource(modelSourceFor(mmprojPath));
    } catch (e) {
      debugPrint("Failed to load multimodal projector: $e");
      final normalizedError = e.toString().toLowerCase();
      final webRuntimeUnavailable =
          kIsWeb &&
          (normalizedError.contains('memory access out of bounds') ||
              normalizedError.contains('out of memory') ||
              normalizedError.contains('array buffer allocation failed') ||
              normalizedError.contains('unwind'));
      if (webRuntimeUnavailable) {
        throw LlamaContextException(
          'The browser multimodal runtime ran out of usable WebAssembly '
          'memory or became invalid while loading the projector. Close other '
          'tabs running local models, then tap Load model again or reload '
          'this page.',
          e,
        );
      }
      throw LlamaContextException(
        'Failed to load multimodal projector ($mmprojPath). '
        'Please verify this mmproj matches the selected model.',
        e,
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

  void _throwIfDisposed() {
    if (_disposed) {
      throw LlamaStateException('The chat engine is disposed.');
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
