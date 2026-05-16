import '../backend.dart';
import '../../core/models/chat/content_part.dart';
import '../../core/models/config/log_level.dart';
import '../../core/models/inference/generation_params.dart';
import '../../core/models/inference/model_params.dart';
import '../webgpu/webgpu_backend.dart';

/// Creates a web backend that can route between multiple web runtimes.
LlamaBackend createBackend() => WebAutoBackend();

/// Uses the unified web backend implementation.
class WebAutoBackend
    implements
        LlamaBackend,
        BackendAvailability,
        BackendBatchEmbeddings,
        BackendStatePersistence,
        BackendStatePersistenceSupport {
  final LlamaBackend _delegate;

  /// Creates a web backend router.
  ///
  /// Optional backend is injectable for testing.
  WebAutoBackend({LlamaBackend? webBackend})
    : _delegate = webBackend ?? WebGpuLlamaBackend();

  @override
  bool get isReady => _delegate.isReady;

  @override
  bool get supportsStatePersistence {
    final delegate = _delegate;
    if (delegate is BackendStatePersistenceSupport) {
      return (delegate as BackendStatePersistenceSupport)
          .supportsStatePersistence;
    }
    return delegate is BackendStatePersistence;
  }

  @override
  Future<int> modelLoad(String path, ModelParams params) {
    return _delegate.modelLoad(path, params);
  }

  @override
  Future<int> modelLoadFromUrl(
    String url,
    ModelParams params, {
    Function(double p1)? onProgress,
  }) {
    return _delegate.modelLoadFromUrl(url, params, onProgress: onProgress);
  }

  @override
  Future<void> modelFree(int modelHandle) {
    return _delegate.modelFree(modelHandle);
  }

  @override
  Future<int> contextCreate(int modelHandle, ModelParams params) {
    return _delegate.contextCreate(modelHandle, params);
  }

  @override
  Future<void> contextFree(int contextHandle) {
    return _delegate.contextFree(contextHandle);
  }

  @override
  Future<int> getContextSize(int contextHandle) {
    return _delegate.getContextSize(contextHandle);
  }

  @override
  Stream<List<int>> generate(
    int contextHandle,
    String prompt,
    GenerationParams params, {
    List<LlamaContentPart>? parts,
  }) {
    return _delegate.generate(contextHandle, prompt, params, parts: parts);
  }

  @override
  void cancelGeneration() {
    _delegate.cancelGeneration();
  }

  @override
  Future<List<double>> embed(
    int contextHandle,
    String text, {
    bool normalize = true,
  }) {
    final delegate = _delegate;
    if (delegate is BackendEmbeddings) {
      return (delegate as BackendEmbeddings).embed(
        contextHandle,
        text,
        normalize: normalize,
      );
    }
    throw UnsupportedError(
      'Embeddings are not supported by the active web backend.',
    );
  }

  @override
  Future<List<List<double>>> embedBatch(
    int contextHandle,
    List<String> texts, {
    bool normalize = true,
  }) async {
    if (texts.isEmpty) {
      return const <List<double>>[];
    }

    final delegate = _delegate;
    if (delegate is BackendBatchEmbeddings) {
      return (delegate as BackendBatchEmbeddings).embedBatch(
        contextHandle,
        texts,
        normalize: normalize,
      );
    }

    if (delegate is BackendEmbeddings) {
      final vectors = <List<double>>[];
      for (final text in texts) {
        vectors.add(
          await (delegate as BackendEmbeddings).embed(
            contextHandle,
            text,
            normalize: normalize,
          ),
        );
      }
      return vectors;
    }

    throw UnsupportedError(
      'Embeddings are not supported by the active web backend.',
    );
  }

  @override
  Future<bool> stateSaveFile(int contextHandle, String path, List<int> tokens) {
    final delegate = _delegate;
    if (delegate is BackendStatePersistence) {
      return (delegate as BackendStatePersistence).stateSaveFile(
        contextHandle,
        path,
        tokens,
      );
    }
    throw UnsupportedError(
      'State persistence is not supported by the active web backend.',
    );
  }

  @override
  Future<StateLoadResult> stateLoadFile(
    int contextHandle,
    String path,
    int tokenCapacity,
  ) {
    final delegate = _delegate;
    if (delegate is BackendStatePersistence) {
      return (delegate as BackendStatePersistence).stateLoadFile(
        contextHandle,
        path,
        tokenCapacity,
      );
    }
    throw UnsupportedError(
      'State persistence is not supported by the active web backend.',
    );
  }

  @override
  Future<List<int>> tokenize(
    int modelHandle,
    String text, {
    bool addSpecial = true,
  }) {
    return _delegate.tokenize(modelHandle, text, addSpecial: addSpecial);
  }

  @override
  Future<String> detokenize(
    int modelHandle,
    List<int> tokens, {
    bool special = false,
  }) {
    return _delegate.detokenize(modelHandle, tokens, special: special);
  }

  @override
  Future<Map<String, String>> modelMetadata(int modelHandle) {
    return _delegate.modelMetadata(modelHandle);
  }

  @override
  Future<void> setLoraAdapter(int contextHandle, String path, double scale) {
    return _delegate.setLoraAdapter(contextHandle, path, scale);
  }

  @override
  Future<void> removeLoraAdapter(int contextHandle, String path) {
    return _delegate.removeLoraAdapter(contextHandle, path);
  }

  @override
  Future<void> clearLoraAdapters(int contextHandle) {
    return _delegate.clearLoraAdapters(contextHandle);
  }

  @override
  Future<String> getBackendName() {
    return _delegate.getBackendName();
  }

  @override
  Future<String> getAvailableBackends() {
    final delegate = _delegate;
    if (delegate is BackendAvailability) {
      return (delegate as BackendAvailability).getAvailableBackends();
    }
    return delegate.getBackendName();
  }

  @override
  bool get supportsUrlLoading => _delegate.supportsUrlLoading;

  @override
  Future<bool> isGpuSupported() {
    return _delegate.isGpuSupported();
  }

  @override
  Future<void> setLogLevel(LlamaLogLevel level) {
    return _delegate.setLogLevel(level);
  }

  @override
  Future<void> dispose() {
    return _delegate.dispose();
  }

  @override
  Future<int?> multimodalContextCreate(int modelHandle, String mmProjPath) {
    return _delegate.multimodalContextCreate(modelHandle, mmProjPath);
  }

  @override
  Future<void> multimodalContextFree(int mmContextHandle) {
    return _delegate.multimodalContextFree(mmContextHandle);
  }

  @override
  Future<bool> supportsVision(int mmContextHandle) {
    return _delegate.supportsVision(mmContextHandle);
  }

  @override
  Future<bool> supportsAudio(int mmContextHandle) {
    return _delegate.supportsAudio(mmContextHandle);
  }

  @override
  Future<({int total, int free})> getVramInfo() {
    return _delegate.getVramInfo();
  }

  @override
  Future<String> applyChatTemplate(
    int modelHandle,
    List<Map<String, dynamic>> messages, {
    String? customTemplate,
    bool addAssistant = true,
  }) {
    return _delegate.applyChatTemplate(
      modelHandle,
      messages,
      customTemplate: customTemplate,
      addAssistant: addAssistant,
    );
  }
}
