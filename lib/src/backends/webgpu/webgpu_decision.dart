import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' show Response, URL, document, window;

import '../../core/exceptions.dart';
import '../backend.dart';
import 'interop.dart';

/// Decision API version that [WebGpuDecisionHeads] speaks.
const int webGpuDecisionApiVersion = 1;

/// Bridge assets that [WebGpuDecisionHeads] needs, as named in errors.
const String webGpuDecisionBridgeRequirement =
    'llama-web-bridge assets with the decision API '
    '(apiVersion $webGpuDecisionApiVersion)';

/// Decision heads loaded through the llama.cpp WebGPU bridge.
///
/// Handles are this object's own and never reused. Each head belongs to the
/// bridge instance that loaded it: once the backend replaces or disposes that
/// bridge, or calls [clear], [run] throws [LlamaStateException] and [free]
/// does nothing.
class WebGpuDecisionHeads {
  final Map<int, _WebGpuDecisionHead> _heads = <int, _WebGpuDecisionHead>{};
  int _nextHandle = 1;

  /// Probes [bridge] for decision heads on its loaded model.
  ///
  /// [bridge] is the backend's active bridge, or null when it has none, which
  /// reports that no model is loaded. Bridges without the decision methods, a
  /// capability response with an `apiVersion` other than
  /// [webGpuDecisionApiVersion], and a failed probe report unsupported with an
  /// actionable reason. Throws [LlamaStateException] when the bridge rejects
  /// the probe for its state: disposed, cancelled, or without a model.
  Future<BackendDecisionCapabilities> capabilities(
    LlamaWebGpuBridge? bridge,
  ) async {
    if (bridge == null) {
      return const BackendDecisionCapabilities(
        isSupported: false,
        unsupportedReason:
            'No model is loaded on the Web bridge. Load a ModernBERT encoder '
            'GGUF first.',
      );
    }
    if (!_exposesDecisionApi(bridge)) {
      return const BackendDecisionCapabilities(
        isSupported: false,
        unsupportedReason:
            'Web decision models need $webGpuDecisionBridgeRequirement; the '
            'loaded bridge does not expose it.',
      );
    }
    final JSAny? raw;
    try {
      raw = await _settle(bridge.getDecisionCapabilities());
    } catch (error) {
      final exception = _bridgeException(
        _errorText(error),
        fallback: LlamaUnsupportedException.new,
      );
      if (exception is LlamaStateException) throw exception;
      return BackendDecisionCapabilities(
        isSupported: false,
        unsupportedReason:
            'The Web decision capability probe failed: ${exception.message}',
      );
    }
    if (raw == null || !raw.isA<JSObject>()) {
      return const BackendDecisionCapabilities(
        isSupported: false,
        unsupportedReason: 'The Web decision capability response is invalid.',
      );
    }
    final value = raw as WebGpuDecisionCapabilities;
    final apiVersion = _int(value.apiVersion);
    if (apiVersion != webGpuDecisionApiVersion) {
      return BackendDecisionCapabilities(
        isSupported: false,
        unsupportedReason: _apiVersionSkew(apiVersion),
      );
    }
    if (_bool(value.supported) != true) {
      return BackendDecisionCapabilities(
        isSupported: false,
        unsupportedReason:
            _string(value.reason) ??
            'The loaded Web model does not support decision heads.',
      );
    }
    return const BackendDecisionCapabilities(isSupported: true);
  }

  /// Loads the decision head at [headUrl] into [bridge].
  ///
  /// [bridge] is the backend's active bridge, or null when it has none. Both
  /// URLs resolve against the document base URL. [configUrl], when given, is
  /// fetched here before the head and passed to the bridge as text; the
  /// bridge fetches the head. URLs in errors drop user info, query and
  /// fragment. Throws [LlamaStateException] when [bridge] is null or rejects
  /// the probe or load for its state: disposed, busy, cancelled, or without a
  /// model; [LlamaUnsupportedException] when [capabilities] reports
  /// unsupported or the head reports another decision API version;
  /// [LlamaModelException] when the head or config cannot be fetched, is
  /// malformed, or does not fit the encoder; [LlamaContextException] when the
  /// head's encoder context cannot be created; and [LlamaDecisionException]
  /// for a malformed bridge response.
  Future<BackendDecisionHeadInfo> load(
    LlamaWebGpuBridge? bridge,
    String headUrl, {
    String? configUrl,
  }) async {
    if (bridge == null) {
      throw LlamaStateException(
        'No model is loaded on the Web bridge. Load the decision encoder '
        'before its head.',
      );
    }
    final capabilities = await this.capabilities(bridge);
    if (!capabilities.isSupported) {
      throw LlamaUnsupportedException(
        capabilities.unsupportedReason ??
            'The loaded Web model does not support decision heads.',
      );
    }
    final resolvedHeadUrl = _resolveUrl(headUrl);
    final resolvedConfigUrl = configUrl == null ? null : _resolveUrl(configUrl);
    final configJson = resolvedConfigUrl == null
        ? null
        : await _fetchConfigText(resolvedConfigUrl);

    final JSAny? raw;
    try {
      raw = await _settle(
        bridge.loadDecisionHead(
          resolvedHeadUrl,
          WebGpuDecisionHeadOptions(configJson: configJson),
        ),
      );
    } catch (error) {
      var message = _errorText(
        error,
      ).replaceAll('Pass configJson ', 'Pass configPath ');
      if (resolvedConfigUrl != null) {
        message = message.replaceAll(
          'config in configJson ',
          'config in ${_displayUrl(resolvedConfigUrl)} ',
        );
      }
      throw _bridgeException(
        message,
        fallback: (message) =>
            LlamaModelException(message, _displayUrl(resolvedHeadUrl)),
      );
    }

    final info = raw != null && raw.isA<JSObject>()
        ? raw as WebGpuDecisionHeadInfo
        : null;
    final bridgeHandle = info == null ? null : _int(info.handle);
    Future<void> release() async {
      if (bridgeHandle == null || bridgeHandle <= 0) return;
      try {
        await _settle(bridge.freeDecisionHead(bridgeHandle));
      } catch (_) {}
    }

    final apiVersion = info == null ? null : _int(info.apiVersion);
    if (info != null && apiVersion != webGpuDecisionApiVersion) {
      await release();
      throw LlamaUnsupportedException(_apiVersionSkew(apiVersion));
    }
    final hiddenSize = info == null ? null : _int(info.hiddenSize);
    final clsToken = info == null ? null : _int(info.clsToken);
    final sepToken = info == null ? null : _int(info.sepToken);
    final maskToken = info == null ? null : _int(info.maskToken);
    final maskText = info == null ? null : _rawString(info.maskText);
    final configText = info == null ? null : _rawString(info.configJson);
    final deviceName = info == null ? null : _rawString(info.deviceName);
    if (bridgeHandle == null ||
        bridgeHandle <= 0 ||
        hiddenSize == null ||
        clsToken == null ||
        sepToken == null ||
        maskToken == null ||
        maskText == null ||
        configText == null ||
        deviceName == null) {
      await release();
      throw LlamaDecisionException(
        'The Web decision runtime returned a malformed head description.',
      );
    }

    final handle = _nextHandle++;
    _heads[handle] = _WebGpuDecisionHead(bridge, bridgeHandle);
    return BackendDecisionHeadInfo(
      handle: handle,
      hiddenSize: hiddenSize,
      clsToken: clsToken,
      sepToken: sepToken,
      maskToken: maskToken,
      maskText: maskText,
      configJson: configText,
      deviceName: deviceName,
    );
  }

  /// Runs [sequences] through the head [handle] on [bridge], in order.
  ///
  /// [bridge] is the backend's active bridge, or null when it has none.
  /// Throws [LlamaStateException] when the head is not loaded on [bridge],
  /// including when the bridge lost it, which also forgets the head, and when
  /// the bridge has no model or is busy; [LlamaInferenceException] when a
  /// sequence is invalid or the encoder or head pass fails; and
  /// [LlamaDecisionException] for malformed outputs.
  Future<List<BackendDecisionOutput>> run(
    LlamaWebGpuBridge? bridge,
    int handle,
    List<BackendDecisionSequence> sequences,
  ) async {
    final head = _heads[handle];
    if (head == null || bridge == null || !identical(head.bridge, bridge)) {
      _heads.remove(handle);
      throw LlamaStateException(
        'Decision head $handle is not loaded on this Web runtime; it was '
        'freed, its model was unloaded, or the bridge restarted. Load the '
        'decision head again.',
      );
    }
    for (var i = 0; i < sequences.length; i++) {
      final questionType = sequences[i].questionType;
      if (questionType < _int32Min || questionType > _int32Max) {
        throw LlamaInferenceException(
          'Decision sequence $i has question type $questionType; expected 0 '
          '(choice), 1 (score) or 2 (noul).',
        );
      }
    }
    final input = <WebGpuDecisionSequence>[
      for (final sequence in sequences)
        WebGpuDecisionSequence(
          tokens: sequence.tokens.toJS,
          markers: sequence.markers.toJS,
          questionType: sequence.questionType,
        ),
    ].toJS;

    final JSAny? raw;
    try {
      raw = await _settle(bridge.runDecision(head.bridgeHandle, input));
    } catch (error) {
      final exception = _bridgeException(
        _errorText(error),
        fallback: LlamaInferenceException.new,
      );
      if (exception.message.contains(_reloadHint)) {
        _heads.remove(handle);
      }
      throw exception;
    }
    return _parseOutputs(raw);
  }

  /// Frees the head [handle] on [bridge].
  ///
  /// Does nothing when the head is not loaded on [bridge]. Bridge failures
  /// throw a [LlamaException].
  Future<void> free(LlamaWebGpuBridge? bridge, int handle) async {
    final head = _heads.remove(handle);
    if (head == null || bridge == null || !identical(head.bridge, bridge)) {
      return;
    }
    try {
      await _settle(bridge.freeDecisionHead(head.bridgeHandle));
    } catch (error) {
      throw _bridgeException(
        _errorText(error),
        fallback: LlamaStateException.new,
      );
    }
  }

  /// Forgets every head, for when the bridge freed them all.
  void clear() => _heads.clear();

  static const String _reloadHint = 'Load the decision head again';
  static const int _int32Min = -0x80000000;
  static const int _int32Max = 0x7fffffff;
  static final RegExp _absoluteUrl = RegExp(
    r'[A-Za-z][A-Za-z0-9+.-]*://[^\s"<>]+',
  );

  static bool _exposesDecisionApi(LlamaWebGpuBridge bridge) {
    for (final name in const <String>[
      'getDecisionCapabilities',
      'loadDecisionHead',
      'runDecision',
      'freeDecisionHead',
    ]) {
      if (!bridge.getProperty<JSAny?>(name.toJS).isA<JSFunction>()) {
        return false;
      }
    }
    return true;
  }

  static String _apiVersionSkew(int? apiVersion) =>
      'The Web bridge implements decision API version '
      '${apiVersion ?? 'unknown'}; llamadart needs '
      '$webGpuDecisionBridgeRequirement.';

  static List<BackendDecisionOutput> _parseOutputs(JSAny? raw) {
    LlamaDecisionException malformed() => LlamaDecisionException(
      'The Web decision runtime returned malformed outputs.',
    );
    if (raw == null || !raw.isA<JSArray>()) throw malformed();
    final outputs = <BackendDecisionOutput>[];
    for (final item in (raw as JSArray<JSAny?>).toDart) {
      final output = item != null && item.isA<JSObject>()
          ? _parseOutput(item as WebGpuDecisionOutput)
          : null;
      if (output == null) throw malformed();
      outputs.add(output);
    }
    return outputs;
  }

  static BackendDecisionOutput? _parseOutput(WebGpuDecisionOutput output) {
    final logits = output.logits;
    final actLogits = output.actLogits;
    if (logits == null ||
        actLogits == null ||
        !logits.isA<JSFloat32Array>() ||
        !actLogits.isA<JSFloat32Array>()) {
      return null;
    }
    return BackendDecisionOutput(
      logits: (logits as JSFloat32Array).toDart,
      actLogits: (actLogits as JSFloat32Array).toDart,
    );
  }

  static Future<String> _fetchConfigText(String url) async {
    final message =
        'Cannot read the decision head config at ${_displayUrl(url)}.';
    final Response response;
    try {
      response = await window.fetch(url.toJS).toDart;
    } catch (error) {
      throw LlamaModelException(message, _errorText(error));
    }
    if (!response.ok) {
      throw LlamaModelException(
        message,
        'HTTP ${response.status} ${response.statusText}'.trim(),
      );
    }
    try {
      return (await response.text().toDart).toDart;
    } catch (error) {
      throw LlamaModelException(message, _errorText(error));
    }
  }

  static LlamaException _bridgeException(
    String message, {
    required LlamaException Function(String message) fallback,
  }) {
    if (message.contains(_reloadHint) ||
        message.startsWith('No model loaded') ||
        message.contains('Bridge has been disposed') ||
        message.contains('was cancelled') ||
        message.contains('during active generation')) {
      return LlamaStateException(message);
    }
    if (message.contains('decision encoder context')) {
      return LlamaContextException(message);
    }
    return fallback(message);
  }

  static String _errorText(Object error) => _coreMessage(
    _bridgeErrorMessage(error),
  ).replaceAllMapped(_absoluteUrl, (match) => _displayUrl(match[0]!));

  static String _resolveUrl(String url) {
    if (url.isEmpty) return url;
    try {
      return URL(url, document.baseURI).href;
    } catch (_) {
      return url;
    }
  }

  static String _coreMessage(String message) {
    for (final prefix in const <String>[
      'Failed to load decision head: ',
      'Decision run failed: ',
    ]) {
      if (message.startsWith(prefix)) {
        return message.substring(prefix.length);
      }
    }
    return message;
  }

  static Future<JSAny?> _settle(JSAny? value) async {
    if (value != null && value.isA<JSPromise>()) {
      return (value as JSPromise<JSAny?>).toDart;
    }
    return value;
  }

  static int? _int(JSAny? value) {
    if (value == null || !value.isA<JSNumber>()) return null;
    final number = (value as JSNumber).toDartDouble;
    if (!number.isFinite || number != number.truncateToDouble()) return null;
    return number.toInt();
  }

  static bool? _bool(JSAny? value) => value != null && value.isA<JSBoolean>()
      ? (value as JSBoolean).toDart
      : null;

  static String? _rawString(JSAny? value) =>
      value != null && value.isA<JSString>()
      ? (value as JSString).toDart
      : null;

  static String? _string(JSAny? value) {
    final text = _rawString(value);
    return text == null || text.isEmpty ? null : text;
  }
}

String _bridgeErrorMessage(Object error) {
  try {
    final message = (error as JSObject).getProperty<JSAny?>('message'.toJS);
    if (message != null && message.isA<JSString>()) {
      return (message as JSString).toDart;
    }
  } catch (_) {}
  return error.toString();
}

String _displayUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) {
    final end = url.indexOf(RegExp('[?#]'));
    return (end < 0 ? url : url.substring(0, end)).replaceFirst(
      RegExp('//[^/]*@'),
      '//',
    );
  }
  return Uri(
    scheme: uri.hasScheme ? uri.scheme : null,
    host: uri.hasAuthority ? uri.host : null,
    port: uri.hasPort ? uri.port : null,
    path: uri.path,
  ).toString();
}

class _WebGpuDecisionHead {
  _WebGpuDecisionHead(this.bridge, this.bridgeHandle);

  final LlamaWebGpuBridge bridge;
  final int bridgeHandle;
}
