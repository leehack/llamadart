import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';
import 'dart:js_interop';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:llamadart_validation/llamadart_validation.dart';
import 'package:web/web.dart' as web;

import 'host.dart';

/// Creates the browser host, which exports its in-memory result journal.
ValidationHost createHost() => _WebHost();

class _WebHost implements ValidationHost {
  String? _decisionHead;
  String? _decisionConfig;
  @override
  ValidationEngine createEngine(ValidationProfile profile) =>
      PublicValidationEngine(
        decisionHead: _decisionHead,
        decisionConfig: _decisionConfig,
      );
  final _lines = <String>[];
  http.Client? _client;
  @override
  void cancelPreparation() => _client?.close();
  @override
  String get outputLocation => 'Browser memory; export before closing the tab';

  @override
  Future<({String path, Map<String, dynamic> evidence})> prepare(
    ValidationProfile profile,
  ) async {
    if (profile.runtime == 'litert') {
      throw UnsupportedError(
        'Native LiteRT fixtures are not browser bundles. Supply a separately qualified Web profile.',
      );
    }
    _decisionHead = null;
    _decisionConfig = null;
    final model = await _verify(profile.model);
    final decision = {
      for (final MapEntry(:key, :value) in profile.decisionArtifacts.entries)
        'decision_$key': await _verify(value as Map<String, dynamic>),
    };
    _decisionHead = profile.decisionArtifacts['head']?['url'] as String?;
    _decisionConfig = profile.decisionArtifacts['config']?['url'] as String?;
    // The immutable URL retains the .gguf routing suffix. The bridge owns its
    // URL cache; report that second transfer separately from native file reuse.
    return (
      path: profile.model['url'] as String,
      evidence: {...model, ...decision},
    );
  }

  Future<Map<String, dynamic>> _verify(Map<String, dynamic> lock) async {
    final watch = Stopwatch()..start();
    final client = _client = http.Client();
    final timer = Timer(const Duration(minutes: 5), client.close);
    try {
      final response = await client.send(
        http.Request('GET', Uri.parse(lock['url'] as String)),
      );
      if (response.statusCode != 200) {
        throw StateError('Model download HTTP mismatch');
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.stream) {
        if (bytes.length + chunk.length > (lock['bytes'] as int)) {
          throw StateError('Model size exceeded');
        }
        bytes.add(chunk);
      }
      if (bytes.length != lock['bytes'] ||
          sha256.convert(bytes.takeBytes()).toString() != lock['sha256']) {
        throw const FormatException('Model checksum/size mismatch');
      }
    } finally {
      timer.cancel();
      client.close();
      _client = null;
    }
    return {
      'sha256': lock['sha256'],
      'bytes': lock['bytes'],
      'verified': true,
      'total_ms': watch.elapsedMilliseconds,
      'bridge_transfer': 'immutable URL; bridge may transfer bytes again',
    };
  }

  @override
  Future<void> start(String runId) async {
    _lines.clear();
  }

  @override
  Future<void> emit(Map<String, dynamic> event) async {
    final line = jsonEncode(event);
    _lines.add(line);
    if (line.length <= 32768) {
      web.console.log('LLAMADART_VALIDATION $line'.toJS);
    }
  }

  @override
  Future<ValidationReport> finish() async =>
      ValidationReport.parse(_lines.join('\n'));

  @override
  Future<void> export(String name, String text) async {
    final blob = web.Blob(
      [text.toJS].toJS,
      web.BlobPropertyBag(type: 'application/octet-stream'),
    );
    final url = web.URL.createObjectURL(blob);
    final anchor = web.document.createElement('a') as web.HTMLAnchorElement
      ..href = url
      ..download = name;
    anchor.click();
    Timer(const Duration(seconds: 1), () => web.URL.revokeObjectURL(url));
  }
}
