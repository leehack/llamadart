import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'package:web/web.dart';
import '../llama_backend_interface.dart';
import '../models/model_params.dart';
import '../models/generation_params.dart';
import '../models/llama_chat_message.dart';
import '../models/llama_chat_template_result.dart';
import 'wllama_interop.dart';

/// Web implementation of [LlamaBackend] using wllama.
///
/// This backend uses WebAssembly to run llama.cpp in the browser.
class WebLlamaBackend implements LlamaBackend {
  Wllama? _wllama;
  bool _isReady = false;
  AbortController? _abortController;

  final String _wllamaJsUrl;
  final String _wllamaWasmUrl;

  /// Creates a new [WebLlamaBackend] with the given [wllamaPath] and [wasmPath].
  WebLlamaBackend({String? wllamaPath, String? wasmPath})
    : _wllamaJsUrl =
          wllamaPath ??
          'https://cdn.jsdelivr.net/npm/@wllama/wllama@2.3.7/esm/index.js',
      _wllamaWasmUrl =
          wasmPath ??
          'https://cdn.jsdelivr.net/npm/@wllama/wllama@2.3.7/esm/single-thread/wllama.wasm';

  @override
  bool get isReady => _isReady;

  Future<void> _ensureLibrary() async {
    if (globalContext.has('Wllama')) return;

    final completer = Completer<void>();
    final script = document.createElement('script') as HTMLScriptElement;
    script.type = 'module';
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

  @override
  Future<int> modelLoad(String path, ModelParams params) async {
    return modelLoadFromUrl(path, params);
  }

  @override
  Future<int> modelLoadFromUrl(String url, ModelParams params) async {
    await _ensureLibrary();

    if (_wllama != null) {
      final promise = _wllama!.exit();
      if (promise != null) await promise.toDart;
    }

    final pathConfig = JSObject();
    pathConfig.setProperty(
      'single-thread/wllama.wasm'.toJS,
      _wllamaWasmUrl.toJS,
    );
    _wllama = Wllama(pathConfig);

    final loadPromise = _wllama!.loadModelFromUrl(
      url,
      LoadModelOptions(useCache: true),
    );
    if (loadPromise != null) await loadPromise.toDart;

    _isReady = true;
    return 1; // wllama usually manages one model at a time
  }

  @override
  Future<void> modelFree(int modelHandle) async {
    final promise = _wllama?.exit();
    if (promise != null) await promise.toDart;
    _wllama = null;
    _isReady = false;
  }

  @override
  Future<int> contextCreate(int modelHandle, ModelParams params) async {
    return 1; // wllama manages context internally with model
  }

  @override
  Future<void> contextFree(int contextHandle) async {
    // No-op for wllama
  }

  @override
  Stream<List<int>> generate(
    int contextHandle,
    String prompt,
    GenerationParams params,
    int cancelTokenAddress,
  ) {
    final controller = StreamController<List<int>>();
    _abortController = AbortController();

    final onNewToken =
        (JSAny? token, JSAny? piece, JSAny? currentText, JSAny? optionals) {
          if (piece == null || !piece.isA<JSUint8Array>()) return;
          final bytes = (piece as JSUint8Array).toDart;

          // Stop sequence check
          if (params.stopSequences.isNotEmpty &&
              currentText != null &&
              currentText.isA<JSString>()) {
            final fullText = (currentText as JSString).toDart;
            if (params.stopSequences.any((s) => fullText.endsWith(s))) {
              _abortController?.abort();
              return;
            }
          }
          controller.add(bytes);
        }.toJS;

    final opts = CompletionOptions(
      nPredict: params.maxTokens,
      sampling: WllamaSamplingConfig.create(
        temp: params.temp,
        topK: params.topK,
        topP: params.topP,
        repeatPenalty: params.penalty,
      ),
      seed: params.seed ?? DateTime.now().millisecondsSinceEpoch,
      onNewToken: onNewToken,
      signal: _abortController?.signal,
    );

    final promise = _wllama!.createCompletion(prompt, opts) as JSPromise?;
    promise?.toDart.then(
      (_) => controller.close(),
      onError: (e) => controller.addError(e),
    );

    return controller.stream;
  }

  @override
  Future<List<int>> tokenize(
    int modelHandle,
    String text, {
    bool addSpecial = true,
  }) async {
    final promise = _wllama?.tokenize(text) as JSPromise?;
    if (promise == null) return [];
    final res = await promise.toDart;
    if (res == null) return [];
    if (res.isA<JSUint32Array>()) {
      return (res as JSUint32Array).toDart.cast<int>().toList();
    }
    if (res.isA<JSInt32Array>()) {
      return (res as JSInt32Array).toDart.cast<int>().toList();
    }
    return [];
  }

  @override
  Future<String> detokenize(
    int modelHandle,
    List<int> tokens, {
    bool special = false,
  }) async {
    final jsTokens = tokens.map((e) => e.toJS).toList().toJS;
    final promise = _wllama?.detokenize(jsTokens) as JSPromise?;
    if (promise == null) return "";
    final res = await promise.toDart;
    return (res as JSString?)?.toDart ?? "";
  }

  @override
  Future<Map<String, String>> modelMetadata(int modelHandle) async {
    final promise = _wllama?.getModelMetadata() as JSPromise?;
    if (promise == null) return {};
    final metaJs = await promise.toDart;
    if (metaJs == null || !metaJs.isA<JSObject>()) return {};

    final result = <String, String>{};
    final jsMeta = metaJs as JSObject;
    final keys =
        (globalContext.getProperty('Object'.toJS) as JSObject).callMethod(
              'keys'.toJS,
              jsMeta,
            )
            as JSArray;

    for (int i = 0; i < keys.length; i++) {
      final key = (keys.getProperty(i.toJS) as JSString).toDart;
      final val = jsMeta.getProperty(key.toJS);
      result[key] = val.isA<JSString>()
          ? (val as JSString).toDart
          : val.toString();
    }
    return result;
  }

  @override
  Future<LlamaChatTemplateResult> applyChatTemplate(
    int modelHandle,
    List<LlamaChatMessage> messages, {
    bool addAssistant = true,
  }) async {
    final jsMessages = messages
        .map((m) {
          final jsMsg = JSObject();
          jsMsg.setProperty('role'.toJS, m.role.toJS);
          jsMsg.setProperty('content'.toJS, m.content.toJS);
          return jsMsg;
        })
        .toList()
        .toJS;

    final promise = _wllama?.utils.chatTemplate(jsMessages) as JSPromise?;
    if (promise == null) throw Exception("Wllama utils not available");
    final promptJs = await promise.toDart;
    final metadata = await modelMetadata(modelHandle);

    final stops = <String>[];
    final tmpl = metadata['tokenizer.chat_template']?.toLowerCase() ?? "";
    if (tmpl.contains('im_end')) stops.add('<|im_end|>');
    if (tmpl.contains('eot_id')) stops.add('<|eot_id|>');

    return LlamaChatTemplateResult(
      prompt: (promptJs as JSString).toDart,
      stopSequences: stops,
    );
  }

  @override
  Future<void> setLoraAdapter(
    int contextHandle,
    String path,
    double scale,
  ) async {}
  @override
  Future<void> removeLoraAdapter(int contextHandle, String path) async {}
  @override
  Future<void> clearLoraAdapters(int contextHandle) async {}

  @override
  Future<String> getBackendName() async => "WASM (Web)";
  @override
  Future<bool> isGpuSupported() async => false;

  @override
  Future<void> dispose() async {
    final promise = _wllama?.exit() as JSPromise?;
    if (promise != null) await promise.toDart;
    _wllama = null;
    _isReady = false;
  }
}
