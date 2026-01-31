@JS()
library;

import 'dart:js_interop';

/// Binding to the Wllama JS class.
@JS('Wllama')
extension type Wllama._(JSObject _) implements JSObject {
  /// Creates a new Wllama instance.
  /// [pathConfig] is the assets path configuration (AssetsPathConfig).
  /// [config] is the Wllama configuration (WllamaConfig).
  external factory Wllama(JSAny pathConfig, [WllamaConfig? config]);

  /// Loads a model from a URL.
  external JSPromise<JSAny?>? loadModelFromUrl(
    String url, [
    LoadModelOptions? config,
  ]);

  /// Creates a completion.
  external JSPromise<JSString>? createCompletion(
    String prompt,
    CompletionOptions? opts,
  );

  /// Get metadata from the model.
  /// If [key] is provided, returns specific value. Otherwise returns full object.
  external JSAny getMetadata([String? key]);

  /// Get model metadata (Wllama v2)
  external JSAny getModelMetadata([String? key]);

  /// Metadata property (Wllama v2)
  external JSObject get metadata;

  /// Exits the Wllama instance.
  external JSPromise<JSAny?>? exit();

  /// Utility functions.
  external WllamaUtils get utils;

  /// Tokenize the given text.
  external JSPromise<JSAny>? tokenize(String text);

  /// Detokenize the given tokens.
  external JSPromise<JSString>? detokenize(JSArray tokens);
}

/// Utility functions for Wllama.
@JS()
@anonymous
extension type WllamaUtils._(JSObject _) implements JSObject {
  /// Applies a chat template to messages.
  external JSPromise<JSString> chatTemplate(JSArray messages, [String? tmpl]);
}

/// Configuration for Wllama.
@JS()
@anonymous
extension type WllamaConfig._(JSObject _) implements JSObject {
  /// Creates a new configuration.
  external factory WllamaConfig({
    bool? suppressNativeLog,
    // Add other fields as needed
  });
}

/// Options for loading a model.
@JS()
@anonymous
extension type LoadModelOptions._(JSObject _) implements JSObject {
  /// Creates new load model options.
  external factory LoadModelOptions({bool? useCache, JSFunction? onProgress});
}

/// Options for completion.
@JS()
@anonymous
extension type CompletionOptions._(JSObject _) implements JSObject {
  /// Creates new completion options.
  external factory CompletionOptions({
    int nPredict,
    WllamaSamplingConfig sampling,
    int seed,
    JSFunction? onNewToken,
    JSAny? signal,
  });
}

/// Sampling configuration for Wllama.
@JS()
@anonymous
extension type WllamaSamplingConfig._(JSObject _) implements JSObject {
  external factory WllamaSamplingConfig._raw({
    double temp,
    @JS('top_k') int topK,
    @JS('top_p') double topP,
    @JS('repeat_penalty') double repeatPenalty,
  });

  /// Creates a sampling configuration with Dart-style usage.
  static WllamaSamplingConfig create({
    required double temp,
    required int topK,
    required double topP,
    required double repeatPenalty,
  }) {
    return WllamaSamplingConfig._raw(
      temp: temp,
      topK: topK,
      topP: topP,
      repeatPenalty: repeatPenalty,
    );
  }
}
