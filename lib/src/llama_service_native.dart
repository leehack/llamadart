import 'dart:async';
import 'llama_service_interface.dart';
import 'llama_engine.dart';
import 'native/native_backend.dart';

// Export types
export 'package:llamadart/src/llama_service_interface.dart';

/// Native implementation of [LlamaServiceBase] using [LlamaEngine] and [NativeLlamaBackend].
///
/// This class provides a platform-specific implementation for desktop and mobile
/// using Dart FFI to communicate with the native llama.cpp library.
class LlamaService implements LlamaServiceBase {
  late final LlamaEngine _engine;
  final NativeLlamaBackend _backend = NativeLlamaBackend();

  /// Creates a new [LlamaService] for native platforms.
  LlamaService({String? wllamaPath, String? wasmPath}) {
    _engine = LlamaEngine(_backend);
  }

  @override
  bool get isReady => _engine.isReady;

  @override
  Future<void> init(String modelPath, {ModelParams? modelParams}) async {
    await _engine.loadModel(
      modelPath,
      modelParams: modelParams ?? const ModelParams(),
    );
  }

  @override
  Future<void> initFromUrl(String modelUrl, {ModelParams? modelParams}) async {
    await _engine.loadModelFromUrl(
      modelUrl,
      modelParams: modelParams ?? const ModelParams(),
    );
  }

  @override
  Stream<String> generate(String prompt, {GenerationParams? params}) {
    return _engine.generate(prompt, params: params ?? const GenerationParams());
  }

  @override
  Stream<String> chat(
    List<LlamaChatMessage> messages, {
    GenerationParams? params,
  }) {
    return _engine.chat(messages, params: params);
  }

  @override
  Future<List<int>> tokenize(String text) => _engine.tokenize(text);

  @override
  Future<String> detokenize(List<int> tokens) => _engine.detokenize(tokens);

  @override
  Future<String?> getModelMetadata(String key) async {
    final meta = await _engine.getMetadata();
    return meta[key];
  }

  @override
  Future<Map<String, String>> getAllMetadata() => _engine.getMetadata();

  @override
  void cancelGeneration() {
    _engine.cancelGeneration();
  }

  @override
  Future<LlamaChatTemplateResult> applyChatTemplate(
    List<LlamaChatMessage> messages, {
    bool addAssistant = true,
  }) async {
    if (!isReady || _engine.modelHandle == null) {
      throw Exception("Service not initialized");
    }
    return _engine.chatTemplate(messages, addAssistant: addAssistant);
  }

  @override
  Future<void> dispose() => _engine.dispose();

  @override
  Future<String> getBackendName() => _engine.getBackendName();

  @override
  Future<bool> isGpuSupported() => _engine.isGpuSupported();

  @override
  Future<int> getContextSize() async {
    final meta = await _engine.getMetadata();
    return int.tryParse(meta['llama.context_length'] ?? "0") ?? 0;
  }

  @override
  Future<int> getTokenCount(String text) async {
    final tokens = await tokenize(text);
    return tokens.length;
  }

  @override
  Future<void> setLoraAdapter(String path, {double scale = 1.0}) =>
      _engine.setLora(path, scale: scale);

  @override
  Future<void> removeLoraAdapter(String path) => _engine.removeLora(path);

  @override
  Future<void> clearLoraAdapters() => _engine.clearLoras();
}
