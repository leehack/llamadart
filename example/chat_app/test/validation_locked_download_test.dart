import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:llamadart_chat_example/validation/locked_download.dart';

const _url = 'https://example.invalid/model.gguf';

Map<String, dynamic> _lock(int bytes, String sha256) => {
  'url': _url,
  'bytes': bytes,
  'sha256': sha256,
};

MockClient _serve(Stream<List<int>> body, {int status = 200}) =>
    MockClient.streaming(
      (request, _) async => http.StreamedResponse(body, status),
    );

void main() {
  final data = Uint8List.fromList(List.generate(1000, (i) => i % 251));
  final chunks = [data.sublist(0, 1), data.sublist(1, 600), data.sublist(600)];
  final digest = sha256.convert(data).toString();

  test('hashes a chunked download exactly', () async {
    await verifyLockedDownload(
      _serve(Stream.fromIterable(chunks)),
      _lock(data.length, digest),
    );
  });

  test('rejects a digest or length mismatch and a short download', () async {
    for (final (body, lock) in [
      (chunks, _lock(data.length, sha256.convert([1]).toString())),
      (chunks.take(2), _lock(data.length, digest)),
      (chunks.take(2), _lock(600, digest)),
    ]) {
      await expectLater(
        verifyLockedDownload(_serve(Stream.fromIterable(body)), lock),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            'Model checksum/size mismatch',
          ),
        ),
      );
    }
  });

  test('stops at the first byte past the locked size', () async {
    var pulled = 0;
    final body = Stream.fromIterable(chunks).map((chunk) {
      pulled++;
      return chunk;
    });
    await expectLater(
      verifyLockedDownload(_serve(body), _lock(data.length - 1, digest)),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'Model size exceeded',
        ),
      ),
    );
    expect(pulled, chunks.length);
    await expectLater(
      verifyLockedDownload(
        _serve(Stream.fromIterable(chunks)),
        _lock(600, digest),
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('fails on a non-200 status or an interrupted stream', () async {
    await expectLater(
      verifyLockedDownload(
        _serve(Stream.fromIterable(chunks), status: 206),
        _lock(data.length, digest),
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'Model download HTTP mismatch',
        ),
      ),
    );
    final interrupted = StreamController<List<int>>();
    final check = verifyLockedDownload(
      _serve(interrupted.stream),
      _lock(data.length, digest),
    );
    interrupted
      ..add(chunks.first)
      ..addError(http.ClientException('Connection closed'));
    await expectLater(check, throwsA(isA<http.ClientException>()));
    await interrupted.close();
  });

  test('hashes each chunk before the next one arrives', () async {
    final buffer = Uint8List(256);
    Iterable<Uint8List> reused() sync* {
      for (var i = 0; i < 4; i++) {
        yield buffer..fillRange(0, buffer.length, i);
      }
    }

    await verifyLockedDownload(
      _serve(Stream.fromIterable(reused())),
      _lock(
        1024,
        sha256.convert([
          for (var i = 0; i < 4; i++) ...List.filled(256, i),
        ]).toString(),
      ),
    );
  });
}
