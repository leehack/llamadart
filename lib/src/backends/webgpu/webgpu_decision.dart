import 'dart:convert';
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
    'llama-web-bridge assets v0.1.47+ with the decision API '
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
  /// bridge fetches the head. URLs that errors show drop user info, query
  /// and fragment; browser and bridge error text is redacted by
  /// [webGpuBridgeErrorText] with [headUrl] or [configUrl], whichever was
  /// being fetched, as a source URL. Throws [LlamaStateException] when
  /// [bridge] is null or rejects the probe or load for its state: disposed,
  /// busy, cancelled, or without a model; [LlamaUnsupportedException] when
  /// [capabilities] reports unsupported or the head reports another decision
  /// API version; [LlamaModelException] when the head or config cannot be
  /// fetched, is malformed, or does not fit the encoder;
  /// [LlamaContextException] when the head's encoder context cannot be
  /// created; and [LlamaDecisionException] for a malformed bridge response.
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
        : await _fetchConfigText(resolvedConfigUrl, configUrl!);

    final JSAny? raw;
    try {
      raw = await _settle(
        bridge.loadDecisionHead(
          resolvedHeadUrl,
          WebGpuDecisionHeadOptions(configJson: configJson),
        ),
      );
    } catch (error) {
      var message = _errorText(error, <String>[
        headUrl,
        resolvedHeadUrl,
      ]).replaceAll('Pass configJson ', 'Pass configPath ');
      if (resolvedConfigUrl != null) {
        message = message.replaceAll(
          'config in configJson ',
          'config in ${_displayUrl(resolvedConfigUrl)} ',
        );
      }
      throw _bridgeException(
        message,
        classifiedText: _coreMessage(_bridgeErrorMessage(error)),
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
    final input = <WebGpuDecisionSequence>[
      for (final sequence in sequences)
        WebGpuDecisionSequence(
          tokens: sequence.tokens.toJS,
          markers: sequence.markers.toJS,
          questionType: sequence.questionType.index,
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

  static Future<String> _fetchConfigText(String url, String sourceUrl) async {
    final message =
        'Cannot read the decision head config at ${_displayUrl(url)}.';
    final Response response;
    try {
      response = await window.fetch(url.toJS).toDart;
    } catch (error) {
      throw LlamaModelException(
        message,
        _errorText(error, <String>[sourceUrl, url]),
      );
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
      throw LlamaModelException(
        message,
        _errorText(error, <String>[sourceUrl, url]),
      );
    }
  }

  static LlamaException _bridgeException(
    String message, {
    String? classifiedText,
    required LlamaException Function(String message) fallback,
  }) {
    final text = classifiedText ?? message;
    if (text.contains(_reloadHint) ||
        text.startsWith('No model loaded') ||
        text.contains('Bridge has been disposed') ||
        text.contains('was cancelled') ||
        text.contains('during active generation')) {
      return LlamaStateException(message);
    }
    if (text.contains('decision encoder context')) {
      return LlamaContextException(message);
    }
    return fallback(message);
  }

  static String _errorText(
    Object error, [
    Iterable<String> sourceUrls = const <String>[],
  ]) => _coreMessage(webGpuBridgeErrorText(error, sourceUrls: sourceUrls));

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

/// Returns the message of a bridge [error] with URLs redacted.
///
/// First, for each of [sourceUrls], these texts are replaced wherever they
/// occur as written, percent-decoded, percent-encoded or JSON-escaped: the
/// URL and its browser-resolved `href`, when the URL starts with `//` or
/// `scheme://`, become `[scheme:]//host[:port]/path`; its userinfo, password,
/// query, query values and fragment, also as the browser parses them, are
/// removed. Userinfo runs from after `//` to the last `@` of the authority,
/// and to the last `@` of the URL. A query value is the text after the first
/// `=` of an `&`-separated part, or the whole part when it has no `=`.
///
/// Then, as a best-effort backstop for other URLs, each whitespace-separated
/// word, without its leading opening and trailing closing quotes, brackets
/// and punctuation, is treated as a URL when it contains `://`, starts with
/// `/`, `./`, `../` or `host.name[:port]/` (optionally after userinfo), is a
/// dotted file name followed by `?` or `#`, or has a `?` or `#` part
/// containing `=`. Such a URL loses its userinfo, then everything from its
/// first `?` or `#`. When the word contains `://` or starts with `//`, the
/// userinfo is everything from after `//` to the last `@` of the word;
/// otherwise it is a `user@` or `user:password@` at the start of the word.
String webGpuBridgeErrorText(
  Object error, {
  Iterable<String> sourceUrls = const <String>[],
}) => _removeSourceUrlSecrets(
  _bridgeErrorMessage(error),
  sourceUrls,
).replaceAllMapped(_word, (match) => _redactWord(match[0]!));

final RegExp _word = RegExp(r'\S+');
final RegExp _wordParts = RegExp(r'''^(["'(<\[]*)(.*?)(["')\]>.,;:!]*)$''');
final RegExp _hostPath = RegExp(
  r'^(?:[^\s/@]+@)?[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+(?::\d+)?/',
);
final RegExp _fileWithQueryOrFragment = RegExp(r'^[\w.-]*\w\.\w+[?#]');
final RegExp _queryOrFragmentWithValue = RegExp(r'[?#][^\s?#=]*=');
final RegExp _leadingUserInfo = RegExp(r'^[^\s/@]+@');
final RegExp _schemeAndSlashes = RegExp(r'[A-Za-z][A-Za-z0-9+.-]*://');
final RegExp _authorityEnd = RegExp(r'[/?#\\]');
final RegExp _percentEscapes = RegExp('(?:%[0-9A-Fa-f]{2})+');

String _removeSourceUrlSecrets(String text, Iterable<String> sourceUrls) {
  final replacements = <String, String>{};
  for (final url in sourceUrls) {
    final browserUrl = _parseBrowserUrl(url);
    if (_authorityStart(url) >= 0) {
      final display = _displayUrl(url);
      for (final whole in <String>[
        url,
        if (browserUrl != null) browserUrl.href,
      ]) {
        for (final form in _encodedForms(whole)) {
          replacements[form] = display;
        }
      }
    }
    for (final secret in _sourceUrlSecrets(url, browserUrl)) {
      for (final form in _encodedForms(secret)) {
        replacements.putIfAbsent(form, () => '');
      }
    }
  }
  replacements.remove('');
  if (replacements.isEmpty) return text;
  final forms = replacements.keys.toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  return text.replaceAllMapped(
    RegExp(forms.map(RegExp.escape).join('|')),
    (match) => replacements[match[0]!]!,
  );
}

Set<String> _sourceUrlSecrets(String url, URL? browserUrl) {
  final secrets = <String>{};
  void addUserInfo(String userInfo) {
    secrets.add(userInfo);
    final colon = userInfo.indexOf(':');
    if (colon >= 0) secrets.add(userInfo.substring(colon + 1));
  }

  void addQuery(String query) {
    secrets.add(query);
    for (final part in query.split('&')) {
      final equals = part.indexOf('=');
      secrets.add(equals < 0 ? part : part.substring(equals + 1));
    }
  }

  final queryStarts = <int>[0];
  final start = _authorityStart(url);
  if (start >= 0) {
    final end = url.indexOf(_authorityEnd, start);
    final authority = url.substring(start, end < 0 ? url.length : end);
    for (final at in <int>[
      start + authority.lastIndexOf('@'),
      url.lastIndexOf('@'),
    ]) {
      if (at < start) continue;
      addUserInfo(url.substring(start, at));
      queryStarts.add(at + 1);
    }
  }
  for (final from in queryStarts) {
    final fragment = url.indexOf('#', from);
    final query = url.indexOf('?', from);
    if (fragment >= 0) secrets.add(url.substring(fragment + 1));
    if (query >= 0 && (fragment < 0 || query < fragment)) {
      addQuery(url.substring(query + 1, fragment < 0 ? url.length : fragment));
    }
  }
  if (browserUrl != null) {
    final username = browserUrl.username;
    final password = browserUrl.password;
    addUserInfo(password.isEmpty ? username : '$username:$password');
    if (browserUrl.search.isNotEmpty) addQuery(browserUrl.search.substring(1));
    if (browserUrl.hash.isNotEmpty) secrets.add(browserUrl.hash.substring(1));
  }
  return secrets;
}

Set<String> _encodedForms(String text) {
  final forms = <String>{text};
  void add(String Function() form) {
    try {
      forms.add(form());
    } catch (_) {}
  }

  add(() => Uri.encodeComponent(text));
  add(() => Uri.encodeFull(text));
  add(() {
    final json = jsonEncode(text);
    return json.substring(1, json.length - 1);
  });
  for (final decoded in <String>[
    _percentDecoded(text),
    _percentDecoded(text.replaceAll('+', ' ')),
  ]) {
    forms.add(decoded);
    add(() => Uri.encodeComponent(decoded));
  }
  return forms;
}

String _percentDecoded(String text) => text.replaceAllMapped(
  _percentEscapes,
  (match) => utf8.decode(<int>[
    for (var i = 0; i < match[0]!.length; i += 3)
      int.parse(match[0]!.substring(i + 1, i + 3), radix: 16),
  ], allowMalformed: true),
);

int _authorityStart(String url) {
  if (url.startsWith('//')) return 2;
  return _schemeAndSlashes.matchAsPrefix(url)?.end ?? -1;
}

URL? _parseBrowserUrl(String url) {
  if (url.isEmpty) return null;
  try {
    return URL(url, document.baseURI);
  } catch (_) {
    return null;
  }
}

String _redactWord(String word) {
  final parts = _wordParts.firstMatch(word)!;
  final url = parts[2]!;
  final isUrl =
      url.contains('://') ||
      url.startsWith('/') ||
      url.startsWith('./') ||
      url.startsWith('../') ||
      _hostPath.hasMatch(url) ||
      _fileWithQueryOrFragment.hasMatch(url) ||
      _queryOrFragmentWithValue.hasMatch(url);
  if (!isUrl) return word;
  return '${parts[1]}${_redactUrl(url)}${parts[3]}';
}

String _redactUrl(String url) {
  final base = _withoutUserInfoQueryAndFragment(url);
  if (base.contains('://')) {
    return base.replaceAllMapped(
      WebGpuDecisionHeads._absoluteUrl,
      (match) => _displayUrl(match[0]!),
    );
  }
  if (base.startsWith('//')) return _displayUrl(base);
  return base.replaceFirst(_leadingUserInfo, '');
}

String _withoutUserInfoQueryAndFragment(String url) {
  var base = url;
  final slashes = base.startsWith('//') ? 0 : base.indexOf('://');
  if (slashes >= 0) {
    final start = base.indexOf('//', slashes) + 2;
    final at = base.lastIndexOf('@');
    if (at >= start) base = base.substring(0, start) + base.substring(at + 1);
  }
  final end = base.indexOf(RegExp('[?#]'));
  return end < 0 ? base : base.substring(0, end);
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
  final base = _withoutUserInfoQueryAndFragment(url);
  final uri = Uri.tryParse(base);
  if (uri == null) return base;
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
