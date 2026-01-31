import 'package:llamadart/src/llama_service_interface.dart';

// Export interface
export 'package:llamadart/src/llama_service_interface.dart';

/// Stub implementation that throws if used on unsupported platforms.
class LlamaService implements LlamaServiceBase {
  /// Stub implementation of listing devices.
  static Future<List<String>> getAvailableDevices() => Future.value([]);

  @override
  bool get isReady => throw UnimplementedError();

  @override
  Future<void> init(String modelPath, {ModelParams? modelParams}) {
    throw UnimplementedError('LlamaService not supported on this platform');
  }

  @override
  Future<void> initFromUrl(String modelUrl, {ModelParams? modelParams}) {
    throw UnimplementedError('LlamaService not supported on this platform');
  }

  @override
  Stream<String> generate(String prompt, {GenerationParams? params}) {
    throw UnimplementedError('LlamaService not supported on this platform');
  }

  @override
  Future<List<int>> tokenize(String text) {
    throw UnimplementedError('LlamaService not supported on this platform');
  }

  @override
  Future<String> detokenize(List<int> tokens) {
    throw UnimplementedError('LlamaService not supported on this platform');
  }

  @override
  Future<String?> getModelMetadata(String key) {
    throw UnimplementedError('LlamaService not supported on this platform');
  }

  @override
  void cancelGeneration() {
    throw UnimplementedError('LlamaService not supported on this platform');
  }

  @override
  Future<void> dispose() async {
    throw UnimplementedError('LlamaService not supported on this platform');
  }

  @override
  Future<String> applyChatTemplate(
    List<LlamaChatMessage> messages, {
    bool addAssistant = true,
  }) {
    throw UnimplementedError('LlamaService not supported on this platform');
  }

  @override
  Future<String> getBackendName() {
    throw UnimplementedError('LlamaService not supported on this platform');
  }

  @override
  Future<bool> isGpuSupported() {
    throw UnimplementedError('LlamaService not supported on this platform');
  }

  @override
  Future<int> getContextSize() {
    throw UnimplementedError('LlamaService not supported on this platform');
  }

  @override
  Future<int> getTokenCount(String text) {
    throw UnimplementedError('LlamaService not supported on this platform');
  }

  @override
  Future<Map<String, String>> getAllMetadata() {
    throw UnimplementedError('LlamaService not supported on this platform');
  }
}
