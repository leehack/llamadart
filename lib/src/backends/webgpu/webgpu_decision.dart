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
          'config in ${_sourceDisplayUrl(resolvedConfigUrl)} ',
        );
      }
      throw _bridgeException(
        message,
        classifiedText: _coreMessage(_bridgeErrorMessage(error)),
        fallback: (message) =>
            LlamaModelException(message, _sourceDisplayUrl(resolvedHeadUrl)),
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
        'Cannot read the decision head config at ${_sourceDisplayUrl(url)}.';
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
/// `scheme://`, become its display form (below); its userinfo, password,
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
/// containing `=`. From a leading `//`, or its first `scheme://` before any
/// `?` or `#`, the rest of the word becomes its display form; otherwise the
/// word loses everything from its first `?` or `#`, then a leading `user@`
/// or `user:password@`.
///
/// The display form is `[scheme:]//host[:port]/path`. The authority runs from
/// after `//` to the first `/`, `?`, `#` or `\`, and the host follows its
/// last `@`. When the authority has no `@` and is not a `host[:port]`, the
/// host follows the last `@` before the first `?` or `#` instead. The host is
/// left out when neither applies, when an authority with an `@` and an empty
/// or `/` path is followed by `?` or `#` and then another `@`, or, for a
/// source URL, when the display
/// form would contain its userinfo, password, query, a query value or its
/// fragment as the browser reads them.
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
final RegExp _queryOrFragment = RegExp('[?#]');
final RegExp _hostAndPort = RegExp(
  r'^(?:[^\s/?#@\\:\[\]"<>]*|\[[0-9A-Fa-f:.]+\])(?::\d*)?$',
);
final RegExp _percentEscapes = RegExp('(?:%[0-9A-Fa-f]{2})+');

String _removeSourceUrlSecrets(String text, Iterable<String> sourceUrls) {
  final replacements = <String, String>{};
  for (final url in sourceUrls) {
    final browserUrl = _parseBrowserUrl(url);
    if (_authorityStart(url) >= 0) {
      final display = _sourceDisplayUrl(url, browserUrl);
      for (final whole in <String>[
        url,
        if (browserUrl != null) browserUrl.href,
      ]) {
        for (final form in _encodedForms(whole)) {
          replacements[form] = display;
        }
      }
    }
    final secrets = _sourceUrlSecrets(url, browserUrl);
    for (final secret in <String>{...secrets.parsed, ...secrets.extended}) {
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

/// Secrets of a source URL: `parsed` where the browser reads them, and
/// `extended` from userinfo that runs to the last `@` of the whole URL.
typedef _SourceUrlSecrets = ({Set<String> parsed, Set<String> extended});

_SourceUrlSecrets _sourceUrlSecrets(String url, URL? browserUrl) {
  final parsed = <String>{};
  final extended = <String>{};
  void addUserInfo(Set<String> secrets, String userInfo) {
    secrets.add(userInfo);
    final colon = userInfo.indexOf(':');
    if (colon >= 0) secrets.add(userInfo.substring(colon + 1));
  }

  void addQueryAndFragment(Set<String> secrets, int from) {
    final fragment = url.indexOf('#', from);
    final query = url.indexOf('?', from);
    if (fragment >= 0) secrets.add(url.substring(fragment + 1));
    if (query >= 0 && (fragment < 0 || query < fragment)) {
      _addQuery(
        secrets,
        url.substring(query + 1, fragment < 0 ? null : fragment),
      );
    }
  }

  addQueryAndFragment(parsed, 0);
  final start = _authorityStart(url);
  if (start >= 0) {
    final end = url.indexOf(_authorityEnd, start);
    final authority = url.substring(start, end < 0 ? url.length : end);
    final authorityAt = authority.lastIndexOf('@');
    if (authorityAt >= 0) {
      addUserInfo(parsed, authority.substring(0, authorityAt));
    }
    final lastAt = url.lastIndexOf('@');
    if (lastAt >= start && lastAt != start + authorityAt) {
      addUserInfo(extended, url.substring(start, lastAt));
      addQueryAndFragment(extended, lastAt + 1);
    }
  }
  if (browserUrl != null) {
    final username = browserUrl.username;
    final password = browserUrl.password;
    addUserInfo(parsed, password.isEmpty ? username : '$username:$password');
    if (browserUrl.search.isNotEmpty) {
      _addQuery(parsed, browserUrl.search.substring(1));
    }
    if (browserUrl.hash.isNotEmpty) parsed.add(browserUrl.hash.substring(1));
  }
  parsed.remove('');
  extended.remove('');
  return (parsed: parsed, extended: extended);
}

void _addQuery(Set<String> secrets, String query) {
  secrets.add(query);
  for (final part in query.split('&')) {
    final equals = part.indexOf('=');
    secrets.add(equals < 0 ? part : part.substring(equals + 1));
  }
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
  if (url.startsWith('//')) return _displayUrl(url);
  final scheme = _schemeAndSlashes.firstMatch(url);
  final end = url.indexOf(_queryOrFragment);
  if (scheme != null && (end < 0 || scheme.start < end)) {
    return url.substring(0, scheme.start) +
        _displayUrl(url.substring(scheme.start));
  }
  final base = end < 0 ? url : url.substring(0, end);
  return base.replaceFirst(_leadingUserInfo, '');
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

/// The display form of a source [url], without its host when the display
/// form would contain one of its `parsed` secrets.
String _sourceDisplayUrl(String url, [URL? browserUrl]) {
  final display = _displayUrl(url);
  final start = _authorityStart(url);
  if (start < 0) return display;
  final secrets = _sourceUrlSecrets(url, browserUrl ?? _parseBrowserUrl(url));
  for (final secret in secrets.parsed) {
    for (final form in _encodedForms(secret)) {
      if (form.isNotEmpty && display.contains(form)) {
        return url.substring(0, start).toLowerCase();
      }
    }
  }
  return display;
}

String _displayUrl(String url) {
  final start = _authorityStart(url);
  if (start < 0) {
    final end = url.indexOf(_queryOrFragment);
    final base = end < 0 ? url : url.substring(0, end);
    final uri = Uri.tryParse(base);
    if (uri == null) return base;
    return Uri(
      scheme: uri.hasScheme ? uri.scheme : null,
      host: uri.hasAuthority ? uri.host : null,
      port: uri.hasPort ? uri.port : null,
      path: uri.path,
    ).toString();
  }
  final prefix = url.substring(0, start).toLowerCase();
  var end = url.indexOf(_authorityEnd, start);
  if (end < 0) end = url.length;
  final authority = url.substring(start, end);
  final at = authority.lastIndexOf('@');
  String? host = at < 0 ? authority : authority.substring(at + 1);
  if (at >= 0) {
    final pathEnd = url.indexOf(_queryOrFragment, end);
    final path = pathEnd < 0 ? '' : url.substring(end, pathEnd);
    if (pathEnd >= 0 &&
        (path.isEmpty || path == '/') &&
        url.indexOf('@', pathEnd) >= 0) {
      host = null;
    }
  } else if (!_hostAndPort.hasMatch(authority)) {
    final queryStart = url.indexOf(_queryOrFragment, start);
    final lastAt = url
        .substring(0, queryStart < 0 ? url.length : queryStart)
        .lastIndexOf('@');
    host = null;
    if (lastAt >= start) {
      end = url.indexOf(_authorityEnd, lastAt + 1);
      if (end < 0) end = url.length;
      host = url.substring(lastAt + 1, end);
    }
  }
  if (host == null) return prefix;
  final rest = url.substring(end);
  final queryStart = rest.indexOf(_queryOrFragment);
  var path = queryStart < 0 ? rest : rest.substring(0, queryStart);
  if (path.contains('://')) path = _redactUrl(path);
  final uri = Uri.tryParse('$prefix$host$path');
  if (uri == null) return '$prefix$host$path';
  return Uri(
    scheme: uri.hasScheme ? uri.scheme : null,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    path: uri.path,
  ).toString();
}

class _WebGpuDecisionHead {
  _WebGpuDecisionHead(this.bridge, this.bridgeHandle);

  final LlamaWebGpuBridge bridge;
  final int bridgeHandle;
}
