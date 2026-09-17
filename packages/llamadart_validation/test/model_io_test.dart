import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:llamadart_validation/io.dart';
import 'package:llamadart_validation/llamadart_validation.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

class BlockedClient extends http.BaseClient {
  final response = Completer<http.StreamedResponse>();
  bool closed = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      response.future;
  @override
  void close() {
    closed = true;
    if (!response.isCompleted) {
      response.completeError(http.ClientException('cancelled'));
    }
  }
}

void main() {
  late Directory cache;
  late ValidationProfile profile;
  final bytes = utf8.encode('model fixture bytes');
  setUp(() {
    cache = Directory.systemTemp.createTempSync('validation-model-test-');
    final json =
        jsonDecode(
              File('assets/profiles/tiny-gguf-cpu.json').readAsStringSync(),
            )
            as Map<String, dynamic>;
    json['model']['sha256'] = sha256.convert(bytes).toString();
    json['model']['bytes'] = bytes.length;
    profile = ValidationProfile.fromJson(json);
  });
  tearDown(() => cache.deleteSync(recursive: true));
  test('verified cache hit never downloads again', () async {
    var calls = 0;
    final first = await prepareModel(
      profile,
      cache,
      client: MockClient((_) async {
        calls++;
        return http.Response.bytes(bytes, 200);
      }),
    );
    expect(first.evidence['verified'], true);
    final second = await prepareModel(
      profile,
      cache,
      client: MockClient((_) async => throw StateError('unexpected network')),
    );
    expect(second.evidence['cache_hit'], true);
    expect(calls, 1);
  });
  test(
    'oversized or wrong-hash download leaves no partial or cached model',
    () async {
      for (final content in [
        List<int>.filled(bytes.length, 0),
        [...bytes, 0],
      ]) {
        await expectLater(
          prepareModel(
            profile,
            cache,
            client: MockClient((_) async => http.Response.bytes(content, 200)),
          ),
          throwsFormatException,
        );
        expect(cache.listSync(recursive: true).whereType<File>(), isEmpty);
      }
    },
  );
  test('invalid supplied file is retained for the user', () async {
    final input = File(p.join(cache.path, 'user-model.gguf'))
      ..writeAsStringSync('wrong');
    await expectLater(
      prepareModel(profile, cache, suppliedPath: input.path),
      throwsFormatException,
    );
    expect(input.readAsStringSync(), 'wrong');
  });
  test(
    'deadline closes the active request and removes partial files',
    () async {
      final client = BlockedClient();
      await expectLater(
        prepareModel(
          profile,
          cache,
          client: client,
          timeout: const Duration(milliseconds: 5),
        ),
        throwsA(isA<http.ClientException>()),
      );
      expect(client.closed, true);
      expect(cache.listSync(recursive: true).whereType<File>(), isEmpty);
    },
  );
}
