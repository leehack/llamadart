import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:llamadart/src/backends/webgpu/interop.dart';

import 'fake_webgpu_decision_bridge.dart';

/// A fake llama-web-bridge instance with the optional completion options
/// probe and the runtime LoRA API.
///
/// Follows the bridge's documented behavior: `getCompletionCapabilities` and
/// `getLoraAdapterCapabilities` report nothing supported until a model load,
/// adapter handles are never reused, and a model load or `dispose` frees every
/// adapter, after which its handle is stale. While an `*Error` field is set,
/// matching calls reject with it.
class FakeFeatureBridge {
  /// Creates the fake. Without [withCompletionProbe] or [withLoraApi] it
  /// models bridge assets that predate `getCompletionCapabilities` or the
  /// LoRA methods.
  FakeFeatureBridge({
    this.withCompletionProbe = true,
    this.withLoraApi = true,
  }) {
    _installModelApi();
    if (withCompletionProbe) _installCompletionProbe();
    if (withLoraApi) _installLoraApi();
  }

  /// Whether `getCompletionCapabilities` exists.
  final bool withCompletionProbe;

  /// Whether the LoRA methods exist.
  final bool withLoraApi;

  /// The JS object handed to the backend.
  final JSObject object = JSObject();

  /// [object] as the interop type.
  LlamaWebGpuBridge get bridge => object as LlamaWebGpuBridge;

  /// Flags `getCompletionCapabilities` reports after a model load.
  Map<String, bool> completionCapabilities = <String, bool>{
    'presencePenalty': true,
    'minP': true,
    'thinkingBudget': true,
  };

  /// Replaces the whole `getCompletionCapabilities` result when set.
  JSAny? completionCapabilitiesResult;

  /// `apiVersion` reported by `getLoraAdapterCapabilities`.
  int loraApiVersion = 1;

  /// `supported` reported by `getLoraAdapterCapabilities` after a model load.
  bool loraSupported = true;

  /// Replaces the whole `getLoraAdapterCapabilities` result when set.
  JSAny? loraCapabilitiesResult;

  /// Replaces the `loadLoraAdapter` result when set.
  JSAny? loraLoadResult;

  /// Rejection messages for matching calls.
  String? completionProbeError,
      completionError,
      loraProbeError,
      loraLoadError,
      loraSetError,
      loraRemoveError,
      loraClearError;

  /// Pieces `createCompletion` streams through `onToken`, with the running
  /// text as `currentText`.
  List<String> completionPieces = const <String>['Hello'];

  /// Every feature call, in order, such as `load`, `probe`, `lora:load` or
  /// `lora:set 7 0.5`.
  final List<String> calls = <String>[];

  /// Options of the last `createCompletion` call.
  JSObject? lastCompletionOptions;

  /// Number of `createCompletion` calls.
  int completionCalls = 0;

  /// Source and `useCache` option of each `loadLoraAdapter` call.
  final List<({String source, bool? useCache})> loraLoads =
      <({String source, bool? useCache})>[];

  /// Scales of the applied adapters, by handle, in first-set order.
  final Map<int, double> appliedAdapters = <int, double>{};

  final Set<int> _liveAdapters = <int>{};
  bool _modelLoaded = false;
  int _nextAdapterHandle = 7;

  /// The value of [name] in [lastCompletionOptions], converted to Dart.
  Object? completionOption(String name) {
    final value = lastCompletionOptions?.getProperty<JSAny?>(name.toJS);
    return value?.dartify();
  }

  void _installModelApi() {
    object
      ..setProperty(
        'loadModelFromUrl'.toJS,
        ((String url, [JSAny? options]) {
          calls.add('load');
          _freeAdapters();
          _modelLoaded = true;
          return Future<void>.value().toJS;
        }).toJS,
      )
      ..setProperty(
        'createCompletion'.toJS,
        ((String prompt, JSObject options) {
          completionCalls += 1;
          lastCompletionOptions = options;
          final error = completionError;
          if (error != null) return rejectWithMessage(error);
          final onToken = options.getProperty<JSAny?>('onToken'.toJS);
          var text = '';
          for (final piece in completionPieces) {
            text += piece;
            if (onToken.isA<JSFunction>()) {
              (onToken as JSFunction).callAsFunction(
                null,
                piece.toJS,
                text.toJS,
              );
            }
          }
          return Future<JSString>.value(text.toJS).toJS;
        }).toJS,
      )
      ..setProperty(
        'loadMultimodalProjector'.toJS,
        ((String url) => Future<JSNumber>.value(1.toJS).toJS).toJS,
      )
      ..setProperty('supportsVision'.toJS, (() => false).toJS)
      ..setProperty('supportsAudio'.toJS, (() => false).toJS)
      ..setProperty('getModelMetadata'.toJS, (() => JSObject()).toJS)
      ..setProperty('getContextSize'.toJS, (() => 4096).toJS)
      ..setProperty('isGpuActive'.toJS, (() => false).toJS)
      ..setProperty('getBackendName'.toJS, (() => 'WebGPU (Fake)').toJS)
      ..setProperty('setLogLevel'.toJS, ((int level) {}).toJS)
      ..setProperty('cancel'.toJS, (() {}).toJS)
      ..setProperty(
        'dispose'.toJS,
        (() {
          calls.add('dispose');
          _freeAdapters();
          _modelLoaded = false;
          return Future<void>.value().toJS;
        }).toJS,
      );
  }

  void _installCompletionProbe() {
    object.setProperty(
      'getCompletionCapabilities'.toJS,
      (() {
        calls.add('probe');
        final error = completionProbeError;
        if (error != null) return rejectWithMessage(error);
        final result = completionCapabilitiesResult;
        if (result != null) return Future<JSAny?>.value(result).toJS;
        final flags = JSObject();
        for (final name in const [
          'presencePenalty',
          'minP',
          'thinkingBudget',
        ]) {
          flags.setProperty(
            name.toJS,
            (_modelLoaded && (completionCapabilities[name] ?? false)).toJS,
          );
        }
        return Future<JSObject>.value(flags).toJS;
      }).toJS,
    );
  }

  void _installLoraApi() {
    object
      ..setProperty(
        'getLoraAdapterCapabilities'.toJS,
        (() {
          calls.add('lora:probe');
          final error = loraProbeError;
          if (error != null) return rejectWithMessage(error);
          final result = loraCapabilitiesResult;
          if (result != null) return Future<JSAny?>.value(result).toJS;
          final capabilities = JSObject()
            ..setProperty('apiVersion'.toJS, loraApiVersion.toJS)
            ..setProperty(
              'supported'.toJS,
              (_modelLoaded && loraSupported).toJS,
            );
          if (!_modelLoaded) {
            capabilities.setProperty(
              'reason'.toJS,
              'WebGPU core is not initialized'.toJS,
            );
          }
          return Future<JSObject>.value(capabilities).toJS;
        }).toJS,
      )
      ..setProperty(
        'loadLoraAdapter'.toJS,
        ((String source, [JSObject? options]) {
          calls.add('lora:load');
          final useCache = options?.getProperty<JSAny?>('useCache'.toJS);
          loraLoads.add((
            source: source,
            useCache: useCache.isA<JSBoolean>()
                ? (useCache as JSBoolean).toDart
                : null,
          ));
          final error = loraLoadError;
          if (error != null) return rejectWithMessage(error);
          final result = loraLoadResult;
          if (result != null) return Future<JSAny?>.value(result).toJS;
          final handle = _nextAdapterHandle++;
          _liveAdapters.add(handle);
          return Future<JSObject>.value(
            JSObject()..setProperty('handle'.toJS, handle.toJS),
          ).toJS;
        }).toJS,
      )
      ..setProperty(
        'setLoraAdapter'.toJS,
        ((int handle, double scale) {
          calls.add('lora:set $handle $scale');
          final error = loraSetError ?? _staleError(handle);
          if (error != null) return rejectWithMessage(error);
          appliedAdapters[handle] = scale;
          return Future<void>.value().toJS;
        }).toJS,
      )
      ..setProperty(
        'removeLoraAdapter'.toJS,
        ((int handle) {
          calls.add('lora:remove $handle');
          final error = loraRemoveError ?? _staleError(handle);
          if (error != null) return rejectWithMessage(error);
          appliedAdapters.remove(handle);
          return Future<void>.value().toJS;
        }).toJS,
      )
      ..setProperty(
        'clearLoraAdapters'.toJS,
        (() {
          calls.add('lora:clear');
          final error = loraClearError;
          if (error != null) return rejectWithMessage(error);
          appliedAdapters.clear();
          return Future<void>.value().toJS;
        }).toJS,
      );
  }

  String? _staleError(int handle) => _liveAdapters.contains(handle)
      ? null
      : 'LoRA adapter $handle is not loaded; its model was unloaded or '
            'replaced. Load the adapter again.';

  void _freeAdapters() {
    _liveAdapters.clear();
    appliedAdapters.clear();
  }
}
