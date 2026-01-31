import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'package:web/web.dart';
import 'dart:convert';
import 'package:llamadart/src/llama_service_interface.dart';
import 'package:llamadart/src/web/wllama_interop.dart';

// Export interface
export 'package:llamadart/src/llama_service_interface.dart';

/// Web implementation of [LlamaServiceBase] using wllama.
class LlamaService implements LlamaServiceBase {
  Wllama? _wllama;
  bool _isReady = false;
  AbortController? _abortController;

  final String _wllamaJsUrl;
  final String _wllamaWasmUrl;

  /// Creates a new LlamaService.
  ///
  /// [wllamaPath] is the URL to `wllama.js` (default: jsDelivr CDN).
  /// [wasmPath] is the URL to `wllama.wasm` (default: jsDelivr CDN).
  LlamaService({String? wllamaPath, String? wasmPath})
    : _wllamaJsUrl =
          wllamaPath ??
          'https://cdn.jsdelivr.net/npm/@wllama/wllama@2.3.7/esm/index.js',
      _wllamaWasmUrl =
          wasmPath ??
          'https://cdn.jsdelivr.net/npm/@wllama/wllama@2.3.7/esm/single-thread/wllama.wasm';

  /// Returns a list of available devices. On web, this reports the WASM environment.
  static Future<List<String>> getAvailableDevices() async {
    // TODO: check for WebGPU support if we enable the experimental backend
    return ["WASM"];
  }

  /// Whether the service is ready for inference.
  @override
  bool get isReady => _isReady;

  /// Initializes the service with the model at [modelPath].
  ///
  /// On web, [modelPath] is treated as a URL or a relative path from the server.
  @override
  Future<void> init(String modelPath, {ModelParams? modelParams}) async {
    // On web, "path" is ambiguous. We assume the user creates a URL
    // or we throw unsupported if they try to pass a file path that isn't a URL.
    // For consistency, we'll try to use it as a URL.
    await initFromUrl(modelPath, modelParams: modelParams);
  }

  /// Initializes the service with the model at the given [modelUrl].
  @override
  Future<void> initFromUrl(String modelUrl, {ModelParams? modelParams}) async {
    if (modelParams != null && modelParams.loras.isNotEmpty) {
      print(
        'Warning: LoRA adapters are not yet supported on Web (Wasm). They will be ignored.',
      );
    }
    if (_wllama != null) {
      // If already initialized, dispose/exit the current instance to load the new one.
      final exitPromise = _wllama!.exit();
      if (exitPromise != null) {
        await exitPromise.toDart;
      }
      _wllama = null;
      _isReady = false;
    }

    // 1. Load the Wllama JS library if not already loaded
    if (!globalContext.has('Wllama')) {
      final completer = Completer<void>();

      // Create a script tag to load the ES module and expose it globally
      final script = document.createElement('script') as HTMLScriptElement;
      script.type = 'module';
      // Note: In Flutter Web, assets are served from assets/...
      // Plugins assets are in assets/packages/<plugin>/...
      // But we are in the plugin itself? No, when running the example app.
      // The relative path from the app index.html is needed.
      // Standard flutter pattern: assets/packages/llamadart/assets/wllama/...
      // Standard CDN path for wllama
      // We use a specific version to ensure compatibility

      script.text =
          '''
        import { Wllama } from "$_wllamaJsUrl";
        window.Wllama = Wllama;
        window.dispatchEvent(new Event('wllama_ready'));
      ''';

      void onReady(Event e) {
        window.removeEventListener('wllama_ready', onReady.toJS);
        completer.complete();
      }

      window.addEventListener('wllama_ready', onReady.toJS);
      document.head!.appendChild(script);

      await completer.future;
    }

    // 2. Initialize Wllama instance
    // We need to pass the paths to the WASM files.
    // The key 'single-thread/wllama.wasm' is required by Wllama.
    final pathConfig = JSObject();
    pathConfig.setProperty(
      'single-thread/wllama.wasm'.toJS,
      _wllamaWasmUrl.toJS,
    );

    _wllama = Wllama(pathConfig);

    final loadPromise = _wllama!.loadModelFromUrl(
      modelUrl,
      LoadModelOptions(useCache: true),
    );
    if (loadPromise == null) {
      throw Exception('Failed to load model: Wllama returned null promise');
    }
    await loadPromise.toDart;

    _isReady = true;
  }

  /// Generates a stream of text from the given [prompt].
  @override
  Stream<String> generate(String prompt, {GenerationParams? params}) async* {
    if (!_isReady || _wllama == null) {
      throw Exception('Service not initialized');
    }

    // Initialize abort controller for this generation
    _abortController = AbortController();

    final p = params ?? const GenerationParams();
    final controller = StreamController<List<int>>();

    final onNewToken =
        (JSAny? token, JSAny? piece, JSAny? currentText, JSAny? optionals) {
          if (piece == null || !piece.isA<JSUint8Array>()) {
            return;
          }
          if (currentText == null || !currentText.isA<JSString>()) {
            return;
          }

          // Get bytes
          final bytes = (piece as JSUint8Array).toDart;

          // Check for stop sequences in web using the full text from JS (which handles decoding)
          if (p.stopSequences.isNotEmpty) {
            final fullText = (currentText as JSString).toDart;
            for (final stop in p.stopSequences) {
              if (fullText.endsWith(stop)) {
                _abortController?.abort();
                return;
              }
            }
          }

          controller.add(bytes);
        }.toJS;

    final opts = CompletionOptions(
      nPredict: p.maxTokens,
      sampling: WllamaSamplingConfig.create(
        temp: p.temp,
        topK: p.topK,
        topP: p.topP,
        repeatPenalty: p.penalty,
      ),
      seed: p.seed ?? DateTime.now().millisecondsSinceEpoch,
      onNewToken: onNewToken,
      signal: _abortController?.signal,
    );

    // Using a separate future to drive the completion so we can yield from controller
    () async {
      try {
        final completionPromise = _wllama!.createCompletion(prompt, opts);
        if (completionPromise != null) {
          await completionPromise.toDart;
        }
      } catch (e) {
        controller.addError(e);
      } finally {
        await controller.close();
      }
    }();

    yield* controller.stream.transform(utf8.decoder);
  }

  /// Tokenizes the given [text] into a list of token IDs.
  @override
  Future<List<int>> tokenize(String text) async {
    if (_wllama == null) return [];
    final promise = _wllama!.tokenize(text);
    if (promise == null) return [];
    final tokensRes = await promise.toDart;
    // Wllama returns a TypedArray (usually Uint32Array)
    if (tokensRes.isA<JSUint32Array>()) {
      return (tokensRes as JSUint32Array).toDart.cast<int>().toList();
    } else if (tokensRes.isA<JSInt32Array>()) {
      return (tokensRes as JSInt32Array).toDart.cast<int>().toList();
    } else if (tokensRes.isA<JSArray>()) {
      // Fallback for standard JS arrays if that happens
      return (tokensRes as JSArray).toDart
          .map((e) => (e as JSNumber).toDartInt)
          .toList();
    }

    print('Web: tokenize returned unexpected type: ${tokensRes.runtimeType}');
    return [];
  }

  /// Detokenizes the given [tokens] back into a string.
  @override
  Future<String> detokenize(List<int> tokens) async {
    if (_wllama == null) return "";
    final jsTokens = tokens.map((e) => e.toJS).toList().toJS;
    final promise = _wllama!.detokenize(jsTokens);
    if (promise == null) return "";
    final result = await promise.toDart;
    return result.toDart;
  }

  /// Cancels the current generation.
  @override
  void cancelGeneration() {
    _abortController?.abort();
    _abortController = null;
  }

  /// Applies a chat template to the given [messages].
  @override
  Future<String> applyChatTemplate(
    List<LlamaChatMessage> messages, {
    bool addAssistant = true,
  }) async {
    if (!_isReady || _wllama == null) {
      throw Exception('Service not initialized');
    }

    final jsMessages = messages
        .map((m) {
          final jsMsg = JSObject();
          jsMsg.setProperty('role'.toJS, m.role.toJS);
          jsMsg.setProperty('content'.toJS, m.content.toJS);
          return jsMsg;
        })
        .toList()
        .toJS;

    try {
      // wllama v2.x supports utils.chatTemplate(messages, tmpl)
      // Passing null for tmpl uses the model's internal template
      final promise = _wllama!.utils.chatTemplate(jsMessages);
      // promise cannot be null based on static typing of standard JS compilation,
      // but if runtime issues occur, it throws anyway.
      final prompt = await promise.toDart;
      return prompt.toDart;
    } catch (e) {
      // Manual fallback (ChatML style as a safe default for modern models like Qwen/Yi/etc)
      final buffer = StringBuffer();
      for (final m in messages) {
        if (m.role == 'system') {
          buffer.write('<|im_start|>system\n${m.content}<|im_end|>\n');
        } else if (m.role == 'user') {
          buffer.write('<|im_start|>user\n${m.content}<|im_end|>\n');
        } else if (m.role == 'assistant') {
          buffer.write('<|im_start|>assistant\n${m.content}<|im_end|>\n');
        } else {
          buffer.write('<|im_start|>${m.role}\n${m.content}<|im_end|>\n');
        }
      }
      if (addAssistant) {
        buffer.write('<|im_start|>assistant\n');
      }
      return buffer.toString();
    }
  }

  /// Returns model metadata for the given [key], or null if not found.
  @override
  Future<String?> getModelMetadata(String key) async {
    if (!_isReady || _wllama == null) {
      return null;
    }

    try {
      final jsWllama = _wllama as JSObject;
      JSAny? res;

      // Try getModelMetadata (Wllama v2 method)
      if (jsWllama.has('getModelMetadata')) {
        res = _wllama!.getModelMetadata(key);
      }
      // Try metadata property (Wllama v2 property)
      else if (jsWllama.has('metadata')) {
        final meta = jsWllama.getProperty('metadata'.toJS) as JSObject;
        res = meta.getProperty(key.toJS);
      }
      // Try legacy getMetadata
      else if (jsWllama.has('getMetadata')) {
        res = _wllama!.getMetadata(key);
      }

      if (res == null || res.isUndefined || res.isNull) return null;

      // Convert JS value to string
      if (res.isA<JSString>()) {
        return (res as JSString).toDart;
      }
      return res.toString();
    } catch (e) {
      return null;
    }
  }

  /// Disposes the service and the underlying wllama instance.
  @override
  Future<void> dispose() async {
    final exitPromise = _wllama?.exit();
    if (exitPromise != null) {
      await exitPromise.toDart;
    }
    _wllama = null;
    _isReady = false;
  }

  /// Returns the resolved context size.
  @override
  Future<int> getContextSize() async {
    if (_wllama == null) return 0;
    // Try to get from metadata or default
    final nCtx = await getModelMetadata("n_ctx");
    if (nCtx != null) return int.tryParse(nCtx) ?? 2048;
    return 2048;
  }

  /// Returns the token count for the given [text].
  @override
  Future<int> getTokenCount(String text) async {
    final tokens = await tokenize(text);
    return tokens.length;
  }

  /// Returns all model metadata keys and values.
  @override
  Future<Map<String, String>> getAllMetadata() async {
    if (_wllama == null) {
      return {};
    }

    try {
      final jsWllama = _wllama as JSObject;
      JSObject? meta;

      // Try getModelMetadata() (Wllama v2)
      if (jsWllama.has('getModelMetadata')) {
        final res = _wllama!.getModelMetadata();
        if (!res.isUndefined && !res.isNull && res.isA<JSObject>()) {
          meta = res as JSObject;
        }
      }
      // Try metadata property (Wllama v2)
      if (meta == null && jsWllama.has('metadata')) {
        final res = jsWllama.getProperty('metadata'.toJS);
        if (!res.isUndefined && !res.isNull && res.isA<JSObject>()) {
          meta = res as JSObject;
        }
      }
      // Try legacy getMetadata()
      if (meta == null && jsWllama.has('getMetadata')) {
        final res = _wllama!.getMetadata();
        if (!res.isUndefined && !res.isNull && res.isA<JSObject>()) {
          meta = res as JSObject;
        }
      }

      if (meta == null) {
        return {};
      }

      final result = <String, String>{};
      final jsMeta = meta;

      // Use JS Object.keys to iterate
      final keys = _jsObjectKeys(jsMeta);
      for (int i = 0; i < keys.length; i++) {
        final key = keys.getProperty(i.toJS);
        if (key.isA<JSString>()) {
          final keyStr = (key as JSString).toDart;
          final val = jsMeta.getProperty(keyStr.toJS);
          if (val.isA<JSString>()) {
            result[keyStr] = (val as JSString).toDart;
          } else {
            result[keyStr] = val.toString();
          }
        }
      }
      return result;
    } catch (e) {
      return {};
    }
  }

  // Helper to get JS object keys
  JSArray _jsObjectKeys(JSObject obj) {
    return (globalContext.getProperty('Object'.toJS) as JSObject).callMethod(
          'keys'.toJS,
          obj,
        )
        as JSArray;
  }

  /// Returns the name of the backend being used.
  @override
  Future<String> getBackendName() async => "WASM (Web)";

  /// Returns true if GPU acceleration is supported.
  @override
  Future<bool> isGpuSupported() async => false; // WebGPU not yet explicitly toggled

  @override
  Future<void> setLoraAdapter(String path, {double scale = 1.0}) async {
    print('LoRA is not yet supported on Web (Wasm).');
  }

  @override
  Future<void> removeLoraAdapter(String path) async {
    print('LoRA is not yet supported on Web (Wasm).');
  }

  @override
  Future<void> clearLoraAdapters() async {
    print('LoRA is not yet supported on Web (Wasm).');
  }
}
