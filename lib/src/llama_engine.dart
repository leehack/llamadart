import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:http/http.dart' as http;
import 'llama_backend_interface.dart';
import 'llama_tokenizer.dart';
import 'chat_template_processor.dart';
import 'exceptions.dart';
import 'models/model_params.dart';
import 'models/generation_params.dart';
import 'models/llama_chat_message.dart';
import 'models/llama_chat_template_result.dart';

/// High-level engine that orchestrates models and contexts.
class LlamaEngine {
  final LlamaBackend _backend;
  int? _modelHandle;
  int? _contextHandle;
  bool _isReady = false;
  Pointer<Int8>? _latestCancelToken;

  LlamaTokenizer? _tokenizer;
  ChatTemplateProcessor? _templateProcessor;

  /// Creates a new [LlamaEngine] with the given [backend].
  LlamaEngine(this._backend);

  /// Whether the engine is initialized and ready for inference.
  bool get isReady => _isReady;

  /// The tokenizer associated with the loaded model.
  LlamaTokenizer? get tokenizer => _tokenizer;

  /// The chat template processor associated with the loaded model.
  ChatTemplateProcessor? get templateProcessor => _templateProcessor;

  /// Loads a model from a local [path].
  Future<void> loadModel(
    String path, {
    ModelParams modelParams = const ModelParams(),
  }) async {
    try {
      _modelHandle = await _backend.modelLoad(path, modelParams);
      _contextHandle = await _backend.contextCreate(_modelHandle!, modelParams);

      _tokenizer = LlamaTokenizer(_backend, _modelHandle!);
      _templateProcessor = ChatTemplateProcessor(_backend, _modelHandle!);

      _isReady = true;
    } catch (e) {
      throw LlamaModelException("Failed to load model from $path", e);
    }
  }

  /// Loads a model from a [url].
  Future<void> loadModelFromUrl(
    String url, {
    ModelParams modelParams = const ModelParams(),
  }) async {
    final uri = Uri.parse(url);
    final filename = uri.pathSegments.last;
    final tempDir = Directory.systemTemp.createTempSync('llamadart_model_');
    final file = File('${tempDir.path}/$filename');

    if (!file.existsSync()) {
      final response = await http.get(uri);
      if (response.statusCode != 200) {
        throw LlamaModelException(
          "Failed to download model from $url (status: ${response.statusCode})",
        );
      }
      await file.writeAsBytes(response.bodyBytes);
    }

    await loadModel(file.path, modelParams: modelParams);
  }

  /// Generates a stream of text tokens based on the provided [prompt].
  Stream<String> generate(
    String prompt, {
    GenerationParams params = const GenerationParams(),
  }) async* {
    if (!_isReady || _contextHandle == null) {
      throw LlamaContextException("Engine not ready. Call loadModel first.");
    }

    // Allocate cancellation token
    if (_latestCancelToken != null) {
      malloc.free(_latestCancelToken!);
    }
    _latestCancelToken = malloc<Int8>(1);
    _latestCancelToken!.value = 0;

    try {
      final stream = _backend.generate(
        _contextHandle!,
        prompt,
        params,
        _latestCancelToken!.address,
      );

      // Pipe through UTF-8 decoder to handle multi-byte characters correctly
      final controller = StreamController<List<int>>();
      stream.listen(
        (bytes) => controller.add(bytes),
        onDone: () => controller.close(),
        onError: (e) => controller.addError(e),
      );

      yield* controller.stream
          .transform(const Utf8Decoder(allowMalformed: true))
          .map((text) => text);
    } finally {
      // Free logic for cancel token needs care if stream is kept alive
    }
  }

  /// High-level chat interface that manages the conversation flow.
  Stream<String> chat(
    List<LlamaChatMessage> messages, {
    GenerationParams? params,
  }) async* {
    if (!_isReady || _modelHandle == null) {
      throw LlamaContextException("Engine not ready.");
    }

    final result = await chatTemplate(messages);
    final stops = {...result.stopSequences, ...?params?.stopSequences}.toList();

    yield* generate(
      result.prompt,
      params: (params ?? const GenerationParams()).copyWith(
        stopSequences: stops,
      ),
    );
  }

  /// Formats a list of [messages] into a single prompt string.
  Future<LlamaChatTemplateResult> chatTemplate(
    List<LlamaChatMessage> messages, {
    bool addAssistant = true,
  }) {
    if (!_isReady || _templateProcessor == null) {
      throw LlamaContextException("Engine not ready.");
    }
    return _templateProcessor!.apply(messages, addAssistant: addAssistant);
  }

  /// Encodes the given [text] into a list of token IDs.
  Future<List<int>> tokenize(String text, {bool addSpecial = true}) {
    if (!_isReady || _tokenizer == null) {
      throw LlamaContextException("Engine not ready.");
    }
    return _tokenizer!.encode(text, addSpecial: addSpecial);
  }

  /// Decodes a list of [tokens] back into a human-readable string.
  Future<String> detokenize(List<int> tokens, {bool special = false}) {
    if (!_isReady || _tokenizer == null) {
      throw LlamaContextException("Engine not ready.");
    }
    return _tokenizer!.decode(tokens, special: special);
  }

  /// Retrieves all available metadata from the loaded model.
  Future<Map<String, String>> getMetadata() {
    if (!_isReady || _modelHandle == null) {
      return Future.value({});
    }
    return _backend.modelMetadata(_modelHandle!);
  }

  /// Dynamically loads or updates a LoRA adapter's scale.
  Future<void> setLora(String path, {double scale = 1.0}) {
    if (!_isReady || _contextHandle == null) {
      throw LlamaContextException("Engine not ready.");
    }
    return _backend.setLoraAdapter(_contextHandle!, path, scale);
  }

  /// Removes a specific LoRA adapter from the active session.
  Future<void> removeLora(String path) {
    if (!_isReady || _contextHandle == null) {
      throw LlamaContextException("Engine not ready.");
    }
    return _backend.removeLoraAdapter(_contextHandle!, path);
  }

  /// Removes all active LoRA adapters from the current context.
  Future<void> clearLoras() {
    if (!_isReady || _contextHandle == null) {
      throw LlamaContextException("Engine not ready.");
    }
    return _backend.clearLoraAdapters(_contextHandle!);
  }

  /// Immediately cancels any ongoing generation process.
  void cancelGeneration() {
    if (_latestCancelToken != null) {
      _latestCancelToken!.value = 1;
    }
  }

  /// Internal model handle.
  int? get modelHandle => _modelHandle;

  /// Internal context handle.
  int? get contextHandle => _contextHandle;

  /// Returns the name of the active GPU backend.
  Future<String> getBackendName() => _backend.getBackendName();

  /// Returns true if the current hardware and backend support GPU acceleration.
  Future<bool> isGpuSupported() => _backend.isGpuSupported();

  /// Releases all allocated resources.
  Future<void> dispose() async {
    if (_contextHandle != null) {
      await _backend.contextFree(_contextHandle!);
    }
    if (_modelHandle != null) {
      await _backend.modelFree(_modelHandle!);
    }
    await _backend.dispose();
    if (_latestCancelToken != null) {
      malloc.free(_latestCancelToken!);
      _latestCancelToken = null;
    }
    _isReady = false;
  }
}
