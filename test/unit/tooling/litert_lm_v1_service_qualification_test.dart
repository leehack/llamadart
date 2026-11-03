@TestOn('vm && (mac-os || linux)')
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late String executable;
  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('litert_v1_identity_');
    executable = '${directory.path}/qualifier';
    final compiled = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'exe',
      'test/fixtures/litert_lm_v1_service_qualification.dart',
      '-o',
      executable,
    ]);
    expect(
      compiled.exitCode,
      0,
      reason: '${compiled.stdout}\n${compiled.stderr}',
    );
  });
  tearDownAll(() => directory.delete(recursive: true));
  for (final wrongLibrary in [false, true]) {
    test(
      'incorrect ${wrongLibrary ? 'library' : 'model'} digest refuses before any runtime load',
      () async {
        final library = File('${directory.path}/not-a-library')
          ..writeAsStringSync('model-free library sentinel');
        final model = File('${directory.path}/not-a-model')
          ..writeAsStringSync('model-free input sentinel');
        final librarySha = sha256.convert(library.readAsBytesSync()).toString();
        final modelSha = sha256.convert(model.readAsBytesSync()).toString();
        final result = await Process.run(executable, [
          library.path,
          wrongLibrary ? '${directory.path}/missing-model' : model.path,
          wrongLibrary ? 'f' * 64 : librarySha,
          wrongLibrary ? modelSha : 'f' * 64,
          directory.path,
          'model-free-identity-negative-control',
        ]);
        expect(result.exitCode, 1);
        final events = '${result.stdout}'
            .split('\n')
            .where((line) => line.startsWith('LITERT_V1_SERVICE_EVENT '))
            .map(
              (line) =>
                  jsonDecode(line.substring('LITERT_V1_SERVICE_EVENT '.length))
                      as Map<String, dynamic>,
            )
            .toList();
        expect(events.map((event) => event['stage']), [
          'failure',
          'cleanup',
          'run_end',
        ]);
        expect(events.first['detail'], contains('SHA256 did not match'));
        expect(events.last['success'], isFalse);
      },
    );
  }
}
