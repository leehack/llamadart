@TestOn('vm')
library;

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:llamadart/src/platform/io/model_file_sha256.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('model_sha256_test_');
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  for (final accelerated in <bool>[false, true]) {
    group(accelerated ? 'platform SHA-256' : 'portable SHA-256', () {
      for (final length in <int>[0, 3, 55, 56, 64, 1024 * 1024 + 17]) {
        test(
          'matches reference for $length bytes across chunk boundaries',
          () async {
            final content = List<int>.generate(length, (int i) => i % 251);
            final file = File('${directory.path}/model.gguf');
            await file.writeAsBytes(content);
            expect(
              await modelFileSha256(file, usePlatformAcceleration: accelerated),
              sha256.convert(content).toString(),
            );
          },
        );
      }
      test('detects same-length changed contents on repeated reads', () async {
        final file = File('${directory.path}/model.gguf');
        await file.writeAsString('abc');
        final original = await modelFileSha256(
          file,
          usePlatformAcceleration: accelerated,
        );
        expect(
          original,
          'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
        );
        await file.writeAsString('abd');
        expect(
          await modelFileSha256(file, usePlatformAcceleration: accelerated),
          isNot(original),
        );
      });
      test('propagates missing-file errors from worker isolate', () async {
        await expectLater(
          modelFileSha256(
            File('${directory.path}/missing'),
            usePlatformAcceleration: accelerated,
          ),
          throwsA(isA<FileSystemException>()),
        );
      });
    });
  }
}
